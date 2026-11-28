#import "ISHKernelBridge.h"

#if DSBOT_ISH_RUNTIME_ENABLED && __has_include(<ish/ish.h>)

#define ISH_INTERNAL 1
#import <ish/ish.h>
#undef ISH_INTERNAL
#import <ish/fs/devices.h>
#import <ish/fs/path.h>
#import <ish/fs/tty.h>
#import <ish/kernel/init.h>
#import <ish/kernel/task.h>

#import <pthread.h>
#import <errno.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <time.h>
#import <unistd.h>
#import <limits.h>

static NSString *const DSBotISHBridgeErrorDomain = @"io.github.dsbot.ish-runtime";
static const NSUInteger DSBOT_ISH_MAX_SESSIONS = 4;

@interface DSBOTISHSession : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) DSBotISHOutputHandler outputHandler;
@property(nonatomic, copy) DSBotISHExitHandler exitHandler;
@property(nonatomic, assign) struct tty *tty;
@property(nonatomic, assign) int processID;
@property(nonatomic, assign) int processGroupID;
@property(nonatomic, assign) BOOL exited;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, assign) int exitStatus;
@property(nonatomic, assign) NSUInteger activeOperations;
@end

@implementation DSBOTISHSession
@end

@interface ISHKernelBridge ()
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) dispatch_queue_t setupQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSBOTISHSession *> *sessionsByID;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DSBOTISHSession *> *sessionsByTTY;
@property(nonatomic, assign) NSInteger state;
@property(nonatomic, copy) NSString *rootPath;
@property(nonatomic, copy) NSString *workspacePath;
@property(nonatomic, strong, nullable) NSError *bootError;
- (instancetype)initPrivate;
- (void)bootKernelOnCurrentThread:(NSError **)error;
- (void)deliverOutput:(NSData *)data ttyNumber:(int)ttyNumber;
- (void)processExited:(int)processID status:(int)status;
- (void)finalizeSession:(DSBOTISHSession *)session;
- (NSError *)error:(NSInteger)code message:(NSString *)message;
@end

static struct tty_driver_ops dsbot_ish_tty_ops;
static struct tty_driver dsbot_ish_console_driver;
static struct tty_driver dsbot_ish_pty_driver;
extern const char *sock_tmp_prefix;

static void *DSBotISHBootThread(void *context) {
    ISHKernelBridge *bridge = (__bridge_transfer ISHKernelBridge *)context;
    NSError *error = nil;
    @autoreleasepool {
        [bridge bootKernelOnCurrentThread:&error];
    }
    [bridge.condition lock];
    bridge.bootError = error;
    bridge.state = error == nil ? 2 : 3;
    [bridge.condition broadcast];
    [bridge.condition unlock];

    // iSH's init task records this thread and uses thread-local `current`.
    // Keep that host thread alive for the lifetime of the in-process engine.
    for (;;) pause();
    return NULL;
}

static int DSBotISHTTYWrite(struct tty *tty, const void *buffer, size_t length, bool blocking) {
    (void)blocking;
    if (length == 0) return 0;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:buffer length:length];
        [[ISHKernelBridge shared] deliverOutput:data ttyNumber:tty->num];
    }
    return (int)length;
}

static int DSBotISHTTYInit(struct tty *tty) {
    (void)tty;
    return 0;
}

static void DSBotISHTTYCleanup(struct tty *tty) {
    (void)tty;
}

static void DSBotISHProcessExit(struct task *task, int code) {
    [[ISHKernelBridge shared] processExited:task->pid status:code];
}

static BOOL DSBotISHIsDescendant(struct task *task, pid_t rootPID) {
    int hops = 0;
    while (task != NULL && hops < MAX_PID) {
        if (task->pid == rootPID) return YES;
        struct task *parent = task->parent;
        if (parent == NULL) return NO;
        pid_t_ parentPID = parent->pid;
        if (parentPID == 0 || parentPID >= MAX_PID || pid_get_task((dword_t)parentPID) != parent) return NO;
        task = parent;
        hops++;
    }
    return NO;
}

static void DSBotISHSignalTree(int processID, int signal, struct task *expectedRoot, int processGroupID) {
    if (processID <= 1 || expectedRoot == NULL) return;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *root = pid_get_task((dword_t)processID);
    if (root != NULL && root == expectedRoot) {
        for (int pid = 2; pid < MAX_PID; pid++) {
            struct task *task = pid_get_task((dword_t)pid);
            if (task == NULL) continue;
            BOOL sameGroup = processGroupID != 0 && task->group != NULL && task->group->pgid == processGroupID;
            if (sameGroup || DSBotISHIsDescendant(task, (pid_t)processID)) send_signal(task, signal, info);
        }
    }
    unlock(&pids_lock);
}

@implementation ISHKernelBridge

+ (instancetype)shared {
    static ISHKernelBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bridge = [[ISHKernelBridge alloc] initPrivate];
    });
    return bridge;
}

- (instancetype)init {
    return [ISHKernelBridge shared];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _setupQueue = dispatch_queue_create("io.github.dsbot.ish.session-setup", DISPATCH_QUEUE_SERIAL);
        _sessionsByID = [NSMutableDictionary dictionary];
        _sessionsByTTY = [NSMutableDictionary dictionary];
        _state = 0;
    }
    return self;
}

- (NSError *)bootWithRootPath:(NSString *)rootPath workspacePath:(NSString *)workspacePath {
    [self.condition lock];
    if (self.state == 2) {
        BOOL sameRoot = [self.rootPath isEqualToString:rootPath] && [self.workspacePath isEqualToString:workspacePath];
        [self.condition unlock];
        return sameRoot ? nil : [self error:1 message:@"The iSH engine is already mounted with a different workspace."];
    }
    if (self.state == 3) {
        NSError *failure = self.bootError ?: [self error:2 message:@"The iSH engine failed to boot."];
        [self.condition unlock];
        return failure;
    }
    if (self.state == 0) {
        self.rootPath = [rootPath copy];
        self.workspacePath = [workspacePath copy];
        self.state = 1;
        pthread_t thread;
        int createError = pthread_create(&thread, NULL, DSBotISHBootThread, (__bridge_retained void *)self);
        if (createError != 0) {
            self.state = 3;
            self.bootError = [self error:createError message:@"Could not start the iSH boot thread."];
            [self.condition unlock];
            return self.bootError;
        }
        pthread_detach(thread);
    }
    NSDate *bootDeadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
    while (self.state == 1 && [self.condition waitUntilDate:bootDeadline]) {}
    BOOL ready = self.state == 2;
    NSError *failure = ready ? nil : (self.bootError ?: [self error:19 message:@"The iSH engine boot exceeded 120 seconds."]);
    [self.condition unlock];
    return failure;
}

- (void)bootKernelOnCurrentThread:(NSError **)error {
    dsbot_ish_tty_ops = (struct tty_driver_ops){
        .init = DSBotISHTTYInit,
        .write = DSBotISHTTYWrite,
        .cleanup = DSBotISHTTYCleanup,
    };
    dsbot_ish_console_driver = (struct tty_driver){
        .ops = &dsbot_ish_tty_ops,
        .major = TTY_CONSOLE_MAJOR,
        .ttys = calloc(8, sizeof(struct tty *)),
        .limit = 8,
    };
    dsbot_ish_pty_driver = (struct tty_driver){.ops = &dsbot_ish_tty_ops};

    NSString *dataPath = [self.rootPath stringByAppendingPathComponent:@"data"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath isDirectory:nil] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:self.workspacePath isDirectory:nil]) {
        if (error) *error = [self error:3 message:@"The persistent fakefs or authorized DSH workspace is missing."];
        return;
    }
    if (mount_root(&fakefs, dataPath.fileSystemRepresentation) < 0) {
        if (error) *error = [self error:4 message:@"Could not mount the persistent iSH fakefs root."];
        return;
    }
    char canonicalDataPath[PATH_MAX];
    if (realpath(dataPath.fileSystemRepresentation, canonicalDataPath) != NULL) {
        fakefs_set_rootfs_data_path(canonicalDataPath);
    }
    struct stat workspaceEntry;
    NSString *guestWorkspaceEntry = [dataPath stringByAppendingPathComponent:@"workspace"];
    int workspaceEntryResult = lstat(guestWorkspaceEntry.fileSystemRepresentation, &workspaceEntry);
    if ((workspaceEntryResult == 0 && !S_ISLNK(workspaceEntry.st_mode)) ||
        (workspaceEntryResult < 0 && errno != ENOENT)) {
        if (error) *error = [self error:20 message:@"The persistent rootfs /workspace entry is not a safe DSH mount point; it was left untouched."];
        return;
    }
    int result = become_first_process();
    if (result < 0) {
        if (error) *error = [self error:5 message:[NSString stringWithFormat:@"iSH init creation failed (%d).", result]];
        return;
    }
    long hostPageSize = getpagesize();
    if (hostPageSize <= 0) {
        if (error) *error = [self error:23 message:@"Could not determine the host page size for the iSH memory limit."];
        return;
    }
    ish_set_anon_page_limit((long)((256ULL * 1024ULL * 1024ULL) / (uint64_t)hostPageSize));

    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/proc", 0755);
    struct { const char *path; int major; int minor; } devices[] = {
        {"/dev/tty1", TTY_CONSOLE_MAJOR, 1},
        {"/dev/tty", TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx", TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
        {"/dev/null", MEM_MAJOR, DEV_NULL_MINOR},
        {"/dev/zero", MEM_MAJOR, DEV_ZERO_MINOR},
        {"/dev/full", MEM_MAJOR, DEV_FULL_MINOR},
        {"/dev/random", MEM_MAJOR, DEV_RANDOM_MINOR},
        {"/dev/urandom", MEM_MAJOR, DEV_URANDOM_MINOR},
    };
    for (size_t index = 0; index < sizeof(devices) / sizeof(devices[0]); index++) {
        generic_mknodat(AT_PWD, devices[index].path, S_IFCHR | 0666,
                        dev_make(devices[index].major, devices[index].minor));
    }
    if (do_mount(&procfs, "proc", "/proc", "", 0) < 0 ||
        do_mount(&devptsfs, "devpts", "/dev/pts", "", 0) < 0) {
        if (error) *error = [self error:6 message:@"Could not mount iSH procfs/devpts."];
        return;
    }
    tty_drivers[TTY_CONSOLE_MAJOR] = &dsbot_ish_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    if (create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1) < 0) {
        if (error) *error = [self error:7 message:@"Could not initialize iSH console stdio."];
        return;
    }
    if (fakefs_bind_mount("/workspace", self.workspacePath.fileSystemRepresentation, false) < 0) {
        if (error) *error = [self error:8 message:@"Could not bind the authorized DSH workspace into iSH."];
        return;
    }
    NSString *socketPrefix = [[NSTemporaryDirectory() stringByStandardizingPath] stringByAppendingPathComponent:@"dsh-uds-"];
    size_t socketCapacity = sizeof(((struct sockaddr_un *)0)->sun_path);
    const char *socketPrefixBytes = socketPrefix.fileSystemRepresentation;
    // Leave room for a maximum pid, separator, and uint32 socket id.
    if (socketPrefixBytes == NULL || strlen(socketPrefixBytes) + 17 >= socketCapacity) {
        if (error) *error = [self error:21 message:@"The app temporary path is too long for iSH Unix-domain sockets."];
        return;
    }
    sock_tmp_prefix = strdup(socketPrefixBytes);
    if (sock_tmp_prefix == NULL) {
        if (error) *error = [self error:22 message:@"Could not reserve the iSH Unix-domain socket path."];
        return;
    }
    exit_hook = DSBotISHProcessExit;

    // Alpine's init is PID 1 and reaps PTY shells and their descendants.
    // Without a live init task, completed sessions would remain zombies.
    const char initArgv[] = "/sbin/init\0\0";
    const char initEnvp[] =
        "TERM=xterm-256color\0HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "LANG=C.UTF-8\0\0";
    result = do_execve("/sbin/init", 1, initArgv, initEnvp);
    if (result < 0) {
        if (error) *error = [self error:24 message:[NSString stringWithFormat:@"Could not start Alpine init as the iSH reaper (%d).", result]];
        return;
    }
    result = task_start(current);
    if (result < 0) {
        if (error) *error = [self error:25 message:[NSString stringWithFormat:@"Could not start the iSH init task (%d).", result]];
        return;
    }
}

- (NSError *)openSessionWithID:(NSString *)sessionID rows:(NSUInteger)rows columns:(NSUInteger)columns
            outputHandler:(DSBotISHOutputHandler)outputHandler exitHandler:(DSBotISHExitHandler)exitHandler {
    if (sessionID.length == 0 || rows < 2 || rows > 300 || columns < 2 || columns > 500) {
        return [self error:9 message:@"The iSH PTY identity or dimensions are invalid."];
    }
    __block BOOL opened = NO;
    __block NSError *openError = nil;
    dispatch_sync(self.setupQueue, ^{
        [self.condition lock];
        BOOL ready = self.state == 2;
        BOOL duplicate = self.sessionsByID[sessionID] != nil;
        BOOL full = self.sessionsByID.count >= DSBOT_ISH_MAX_SESSIONS;
        [self.condition unlock];
        if (!ready || duplicate || full) {
            openError = [self error:10 message:!ready ? @"The iSH engine is not ready." : (duplicate ? @"The iSH PTY identity is already in use." : @"The iSH PTY session limit has been reached.")];
            return;
        }

        int result = become_new_init_child();
        if (result < 0) {
            openError = [self error:11 message:[NSString stringWithFormat:@"Could not create an iSH session task (%d).", result]];
            return;
        }
        struct tty *tty = pty_open_fake(&dsbot_ish_pty_driver);
        if (IS_ERR(tty)) {
            openError = [self error:12 message:@"Could not allocate an iSH PTY."];
            return;
        }
        tty_set_winsize(tty, (struct winsize_){.row = (word_t)rows, .col = (word_t)columns});

        struct fd *workspace = generic_open("/workspace", O_RDONLY_, 0);
        if (IS_ERR(workspace)) {
            lock(&ttys_lock);
            tty_release(tty);
            unlock(&ttys_lock);
            openError = [self error:13 message:@"The DSH workspace is unavailable in iSH."];
            return;
        }
        fs_chdir(current->fs, workspace);
        NSString *stdioPath = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
        result = create_stdio(stdioPath.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (result < 0) {
            lock(&ttys_lock);
            tty_release(tty);
            unlock(&ttys_lock);
            openError = [self error:14 message:[NSString stringWithFormat:@"Could not connect iSH PTY stdio (%d).", result]];
            return;
        }

        DSBOTISHSession *session = [[DSBOTISHSession alloc] init];
        session.identifier = sessionID;
        session.outputHandler = outputHandler;
        session.exitHandler = exitHandler;
        session.tty = tty;
        [self.condition lock];
        self.sessionsByID[sessionID] = session;
        self.sessionsByTTY[@(tty->num)] = session;
        [self.condition unlock];

        const char argv[] = "/bin/ash\0-i\0\0";
        const char envp[] =
            "TERM=xterm-256color\0HOME=/root\0PWD=/workspace\0"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin\0"
            "LANG=C.UTF-8\0ENV=/etc/profile\0\0";
        result = do_execve("/bin/ash", 2, argv, envp);
        if (result < 0) {
            [self.condition lock];
            [self.sessionsByID removeObjectForKey:sessionID];
            [self.sessionsByTTY removeObjectForKey:@(tty->num)];
            [self.condition unlock];
            lock(&ttys_lock);
            tty_release(tty);
            unlock(&ttys_lock);
            openError = [self error:15 message:[NSString stringWithFormat:@"Could not exec /bin/ash in iSH (%d).", result]];
            return;
        }
        session.processID = current->pid;
        session.processGroupID = current->group->pgid;
        result = task_start(current);
        if (result < 0) {
            [self.condition lock];
            [self.sessionsByID removeObjectForKey:sessionID];
            [self.sessionsByTTY removeObjectForKey:@(tty->num)];
            [self.condition unlock];
            lock(&ttys_lock);
            tty_release(tty);
            unlock(&ttys_lock);
            openError = [self error:16 message:[NSString stringWithFormat:@"Could not start iSH session task (%d).", result]];
            return;
        }
        opened = YES;
    });
    return opened ? nil : openError;
}

- (NSError *)writeInput:(NSData *)data sessionID:(NSString *)sessionID {
    if (data.length == 0) return nil;
    if (data.length > 64 * 1024) {
        return [self error:17 message:@"The iSH PTY input exceeds the 64 KiB write limit."];
    }
    [self.condition lock];
    DSBOTISHSession *session = self.sessionsByID[sessionID];
    struct tty *tty = session.exited || session.closing ? NULL : session.tty;
    if (tty != NULL) session.activeOperations++;
    [self.condition unlock];
    if (tty == NULL) {
        return [self error:17 message:@"The iSH PTY is closed."];
    }
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    struct timespec started;
    clock_gettime(CLOCK_MONOTONIC, &started);
    while (offset < data.length) {
        size_t count = MIN((size_t)1024, data.length - offset);
        ssize_t written = tty_input(tty, (const char *)bytes + offset, count, false);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written == _EAGAIN || written == _EINTR) {
            [self.condition lock];
            BOOL closing = session.closing || session.exited;
            [self.condition unlock];
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (closing || now.tv_sec - started.tv_sec >= 10) {
                [self endOperationForSession:session];
                return [self error:18 message:closing ? @"The iSH PTY closed during input." : @"The iSH PTY remained backpressured for 10 seconds."];
            }
            usleep(1000);
            continue;
        }
        if (written < 0 || (size_t)written != count) {
            [self endOperationForSession:session];
            return [self error:18 message:@"The iSH PTY rejected input before the complete write was delivered."];
        }
    }
    [self endOperationForSession:session];
    return nil;
}

- (BOOL)resizeSessionID:(NSString *)sessionID rows:(NSUInteger)rows columns:(NSUInteger)columns {
    if (rows < 2 || rows > 300 || columns < 2 || columns > 500) return NO;
    [self.condition lock];
    DSBOTISHSession *session = self.sessionsByID[sessionID];
    struct tty *tty = session.exited || session.closing ? NULL : session.tty;
    if (tty != NULL) session.activeOperations++;
    [self.condition unlock];
    if (tty == NULL) return NO;
    tty_set_winsize(tty, (struct winsize_){.row = (word_t)rows, .col = (word_t)columns});
    [self endOperationForSession:session];
    return YES;
}

- (BOOL)closeSessionID:(NSString *)sessionID {
    [self.condition lock];
    DSBOTISHSession *session = self.sessionsByID[sessionID];
    if (session == nil) {
        [self.condition unlock];
        return YES;
    }
    session.closing = YES;
    int pid = session.processID;
    int pgid = session.processGroupID;
    BOOL exited = session.exited;
    [self.condition unlock];

    struct task *expectedRoot = NULL;
    if (!exited && pid > 1) {
        lock(&pids_lock);
        expectedRoot = pid_get_task((dword_t)pid);
        unlock(&pids_lock);
    }

    if (!exited && pid > 1 && expectedRoot != NULL) {
        DSBotISHSignalTree(pid, SIGTERM_, expectedRoot, pgid);
    }
    [self.condition lock];
    NSDate *termDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while ((!session.exited || session.activeOperations > 0) && [self.condition waitUntilDate:termDeadline]) {}
    exited = session.exited && session.activeOperations == 0;
    [self.condition unlock];
    if (!exited && pid > 1 && expectedRoot != NULL) {
        DSBotISHSignalTree(pid, SIGKILL_, expectedRoot, pgid);
        [self.condition lock];
        NSDate *killDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while ((!session.exited || session.activeOperations > 0) && [self.condition waitUntilDate:killDeadline]) {}
        exited = session.exited && session.activeOperations == 0;
        [self.condition unlock];
    }
    if (exited) [self finalizeSession:session];
    return exited;
}

- (void)closeAllSessions {
    [self.condition lock];
    NSArray<NSString *> *identifiers = self.sessionsByID.allKeys;
    [self.condition unlock];
    for (NSString *identifier in identifiers) [self closeSessionID:identifier];
}

- (void)endOperationForSession:(DSBOTISHSession *)session {
    [self.condition lock];
    if (session.activeOperations > 0) session.activeOperations--;
    BOOL shouldFinalize = session.closing && session.exited && session.activeOperations == 0;
    [self.condition broadcast];
    [self.condition unlock];
    if (shouldFinalize) dispatch_async(self.setupQueue, ^{ [self finalizeSession:session]; });
}

- (void)deliverOutput:(NSData *)data ttyNumber:(int)ttyNumber {
    [self.condition lock];
    DSBotISHSession *session = self.sessionsByTTY[@(ttyNumber)];
    DSBotISHOutputHandler handler = session.outputHandler;
    [self.condition unlock];
    if (handler != nil) handler(data);
}

- (void)processExited:(int)processID status:(int)status {
    [self.condition lock];
    DSBOTISHSession *session = nil;
    for (DSBOTISHSession *candidate in self.sessionsByID.allValues) {
        if (candidate.processID == processID) { session = candidate; break; }
    }
    if (session != nil && !session.exited) {
        session.exited = YES;
        session.exitStatus = status;
        DSBotISHExitHandler handler = session.exitHandler;
        [self.condition broadcast];
        BOOL shouldFinalize = session.closing && session.activeOperations == 0;
        [self.condition unlock];
        if (handler != nil) handler((int32_t)status);
        if (shouldFinalize) dispatch_async(self.setupQueue, ^{ [self finalizeSession:session]; });
        return;
    }
    [self.condition unlock];
}

- (void)finalizeSession:(DSBOTISHSession *)session {
    [self.condition lock];
    if (self.sessionsByID[session.identifier] != session || !session.exited) {
        [self.condition unlock];
        return;
    }
    [self.sessionsByID removeObjectForKey:session.identifier];
    [self.sessionsByTTY removeObjectForKey:@(session.tty->num)];
    struct tty *tty = session.tty;
    session.tty = NULL;
    session.outputHandler = nil;
    session.exitHandler = nil;
    [self.condition unlock];
    if (tty != NULL) {
        lock(&ttys_lock);
        tty_release(tty);
        unlock(&ttys_lock);
    }
}

- (NSError *)error:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:DSBotISHBridgeErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end

#else

@implementation ISHKernelBridge

+ (instancetype)shared {
    static ISHKernelBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [[ISHKernelBridge alloc] init]; });
    return bridge;
}

- (NSError *)bootWithRootPath:(NSString *)rootPath workspacePath:(NSString *)workspacePath {
    (void)rootPath; (void)workspacePath;
    return [NSError errorWithDomain:@"io.github.dsbot.ish-runtime" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"This build does not include the pinned iSH ARM64 engine."}];
}

- (NSError *)openSessionWithID:(NSString *)sessionID rows:(NSUInteger)rows columns:(NSUInteger)columns
            outputHandler:(DSBotISHOutputHandler)outputHandler exitHandler:(DSBotISHExitHandler)exitHandler {
    (void)sessionID; (void)rows; (void)columns; (void)outputHandler; (void)exitHandler;
    return [NSError errorWithDomain:@"io.github.dsbot.ish-runtime" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"This build does not include the pinned iSH ARM64 engine."}];
}

- (NSError *)writeInput:(NSData *)data sessionID:(NSString *)sessionID {
    (void)data; (void)sessionID;
    return [NSError errorWithDomain:@"io.github.dsbot.ish-runtime" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"This build does not include the pinned iSH ARM64 engine."}];
}
- (BOOL)resizeSessionID:(NSString *)sessionID rows:(NSUInteger)rows columns:(NSUInteger)columns {
    (void)sessionID; (void)rows; (void)columns; return NO;
}
- (BOOL)closeSessionID:(NSString *)sessionID { (void)sessionID; return YES; }
- (void)closeAllSessions {}

@end

#endif
