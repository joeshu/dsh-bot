/* SPDX-License-Identifier: MIT
 *
 * DS Bot guest PTY broker for the Alpine ARM64 initramfs.
 *
 * Serial protocol (all integer fields are big endian):
 *   header = "DSBP" | version:u16 | type:u16 | session:u32 | length:u32
 *   host -> guest: 1 CREATE(rows:u16, cols:u16), 2 INPUT(bytes),
 *                  3 RESIZE(rows:u16, cols:u16), 4 CLOSE, 5 PING
 *   guest -> host: 0x81 OUTPUT(bytes), 0x82 EXIT(status:i32),
 *                  0x83 ERROR(UTF-8), 0x84 READY, 0x85 PONG
 *
 * The UART is only the transport. Every created shell has its own kernel PTY,
 * session, unprivileged UID, working directory, resource limits, and PTY job
 * control. The host must authenticate owner/session access before sending a
 * frame; the guest UART is not exposed to guest processes or the network.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define PROTOCOL_VERSION 1
#define HEADER_BYTES 16
#define MAX_FRAME_BYTES (64u * 1024u)
#define MAX_INPUT_BYTES (64u * 1024u)
#define MAX_OUTPUT_QUEUE (1024u * 1024u)
#define MAX_SESSIONS 4
#define PTY_READ_BYTES (16u * 1024u)
#define SESSION_CLOSE_GRACE_SECONDS 2

enum FrameType {
    FRAME_CREATE = 1,
    FRAME_INPUT = 2,
    FRAME_RESIZE = 3,
    FRAME_CLOSE = 4,
    FRAME_PING = 5,
    FRAME_OUTPUT = 0x81,
    FRAME_EXIT = 0x82,
    FRAME_ERROR = 0x83,
    FRAME_READY = 0x84,
    FRAME_PONG = 0x85,
};

struct GuestSession {
    uint32_t id;
    uid_t uid;
    gid_t gid;
    pid_t pid;
    int master_fd;
    unsigned char *input;
    size_t input_len;
    size_t input_offset;
    int close_requested;
    int child_exited;
    int pty_eof;
    int wait_status;
    time_t kill_deadline;
};

static struct GuestSession sessions[MAX_SESSIONS];
static unsigned char serial_input[HEADER_BYTES + MAX_FRAME_BYTES];
static size_t serial_input_len;
static unsigned char *serial_output;
static size_t serial_output_len;
static size_t serial_output_offset;
static size_t serial_output_capacity;
static int serial_fd = -1;
static int kernel_log_fd = -1;

static uint16_t read_u16(const unsigned char *value) {
    return (uint16_t)(((uint16_t)value[0] << 8) | value[1]);
}

static uint32_t read_u32(const unsigned char *value) {
    return ((uint32_t)value[0] << 24) | ((uint32_t)value[1] << 16)
        | ((uint32_t)value[2] << 8) | (uint32_t)value[3];
}

static void write_u16(unsigned char *output, uint16_t value) {
    output[0] = (unsigned char)(value >> 8);
    output[1] = (unsigned char)value;
}

static void write_u32(unsigned char *output, uint32_t value) {
    output[0] = (unsigned char)(value >> 24);
    output[1] = (unsigned char)(value >> 16);
    output[2] = (unsigned char)(value >> 8);
    output[3] = (unsigned char)value;
}

static size_t serial_output_pending(void) {
    return serial_output_len - serial_output_offset;
}

static void log_message(const char *format, ...) {
    if (kernel_log_fd < 0) return;
    char message[512];
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    if (count <= 0) return;
    size_t length = (size_t)count;
    if (length >= sizeof(message)) length = sizeof(message) - 1;
    ssize_t written = write(kernel_log_fd, message, length);
    (void)written;
}

static int append_serial_bytes(const unsigned char *bytes, size_t length) {
    size_t pending = serial_output_pending();
    if (length > MAX_OUTPUT_QUEUE || pending > MAX_OUTPUT_QUEUE - length) return -1;
    if (serial_output_offset && (serial_output_len + length > MAX_OUTPUT_QUEUE)) {
        memmove(serial_output, serial_output + serial_output_offset, pending);
        serial_output_len = pending;
        serial_output_offset = 0;
    }
    size_t required = serial_output_len + length;
    if (required > MAX_OUTPUT_QUEUE) return -1;
    if (required > serial_output_capacity) {
        size_t capacity = serial_output_capacity ? serial_output_capacity : 4096;
        while (capacity < required && capacity < MAX_OUTPUT_QUEUE) capacity *= 2;
        if (capacity > MAX_OUTPUT_QUEUE) capacity = MAX_OUTPUT_QUEUE;
        unsigned char *replacement = realloc(serial_output, capacity);
        if (!replacement) return -1;
        serial_output = replacement;
        serial_output_capacity = capacity;
    }
    memcpy(serial_output + serial_output_len, bytes, length);
    serial_output_len = required;
    return 0;
}

static int send_frame(uint16_t type, uint32_t session_id, const void *payload, size_t length) {
    if (length > MAX_FRAME_BYTES) return -1;
    size_t frame_length = HEADER_BYTES + length;
    unsigned char *frame = malloc(frame_length);
    if (!frame) return -1;
    memcpy(frame, "DSBP", 4);
    write_u16(frame + 4, PROTOCOL_VERSION);
    write_u16(frame + 6, type);
    write_u32(frame + 8, session_id);
    write_u32(frame + 12, (uint32_t)length);
    if (length) memcpy(frame + HEADER_BYTES, payload, length);
    int result = append_serial_bytes(frame, frame_length);
    free(frame);
    return result;
}

static void send_error(uint32_t session_id, const char *message) {
    size_t length = strlen(message);
    if (length > 512) length = 512;
    (void)send_frame(FRAME_ERROR, session_id, message, length);
}

static struct GuestSession *find_session(uint32_t id) {
    if (!id) return NULL;
    for (size_t index = 0; index < MAX_SESSIONS; index++) {
        if (sessions[index].id == id && sessions[index].master_fd >= 0) return &sessions[index];
    }
    return NULL;
}

static struct GuestSession *free_session_slot(void) {
    for (size_t index = 0; index < MAX_SESSIONS; index++) {
        if (sessions[index].master_fd < 0 && sessions[index].pid == 0) return &sessions[index];
    }
    return NULL;
}

static int process_has_uid(pid_t pid, uid_t uid) {
    char path[64];
    if (snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid) >= (int)sizeof(path)) return 0;
    FILE *status = fopen(path, "r");
    if (!status) return 0;
    char line[256];
    int found = 0;
    while (fgets(line, sizeof(line), status)) {
        if (strncmp(line, "Uid:", 4) != 0) continue;
        unsigned real_uid = 0;
        unsigned effective_uid = 0;
        if (sscanf(line + 4, "%u %u", &real_uid, &effective_uid) == 2 && effective_uid == uid) found = 1;
        break;
    }
    fclose(status);
    return found;
}

static int visit_uid_processes(uid_t uid, int signal_number) {
    DIR *directory = opendir("/proc");
    if (!directory) return -1;
    int found = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (!entry->d_name[0]) continue;
        char *end = NULL;
        errno = 0;
        long value = strtol(entry->d_name, &end, 10);
        if (errno || end == entry->d_name || *end || value <= 0 || value > INT_MAX) continue;
        pid_t pid = (pid_t)value;
        if (!process_has_uid(pid, uid)) continue;
        found++;
        if (signal_number) (void)kill(pid, signal_number);
    }
    closedir(directory);
    return found;
}

static int ensure_directory(const char *path, mode_t mode) {
    if (mkdir(path, mode) == 0 || errno == EEXIST) {
        struct stat details;
        if (lstat(path, &details) != 0 || !S_ISDIR(details.st_mode)) return -1;
        return 0;
    }
    return -1;
}

static int set_limit(int resource, rlim_t value) {
    struct rlimit limit = {.rlim_cur = value, .rlim_max = value};
    return setrlimit(resource, &limit);
}

static void initialize_pty_termios(struct termios *attributes) {
    memset(attributes, 0, sizeof(*attributes));
    cfmakeraw(attributes);
    attributes->c_iflag |= BRKINT | ICRNL | IXON;
    attributes->c_oflag |= OPOST | ONLCR;
    attributes->c_cflag |= CLOCAL | CREAD | CS8;
    attributes->c_lflag |= ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
    attributes->c_cc[VINTR] = 3;
    attributes->c_cc[VQUIT] = 28;
    attributes->c_cc[VERASE] = 127;
    attributes->c_cc[VKILL] = 21;
    attributes->c_cc[VEOF] = 4;
    attributes->c_cc[VMIN] = 1;
    attributes->c_cc[VTIME] = 0;
    (void)cfsetispeed(attributes, B38400);
    (void)cfsetospeed(attributes, B38400);
}

static int enqueue_session_input(struct GuestSession *session, const unsigned char *bytes, size_t length) {
    size_t pending = session->input_len - session->input_offset;
    if (length > MAX_INPUT_BYTES || pending > MAX_INPUT_BYTES - length) return -1;
    if (session->input_offset && session->input_len + length > MAX_INPUT_BYTES) {
        memmove(session->input, session->input + session->input_offset, pending);
        session->input_len = pending;
        session->input_offset = 0;
    }
    unsigned char *replacement = realloc(session->input, session->input_len + length);
    if (!replacement && length) return -1;
    session->input = replacement;
    if (length) memcpy(session->input + session->input_len, bytes, length);
    session->input_len += length;
    return 0;
}

static int create_session(uint32_t id, const unsigned char *payload, size_t length) {
    if (!id || length != 4) {
        send_error(id, "CREATE requires a nonzero session id and four-byte rows/columns payload");
        return -1;
    }
    if (find_session(id)) {
        send_error(id, "session already exists");
        return -1;
    }
    struct GuestSession *slot = free_session_slot();
    if (!slot) {
        send_error(id, "guest PTY session limit reached");
        return -1;
    }

    uid_t uid = (uid_t)(50000u + (id % 10000u));
    for (size_t index = 0; index < MAX_SESSIONS; index++) {
        if (sessions[index].master_fd >= 0 && sessions[index].uid == uid) {
            send_error(id, "session id collides with an active guest uid; retry with a new id");
            return -1;
        }
    }

    const char *base = "/home/dsbot/.sessions";
    char directory[PATH_MAX];
    char temporary_directory[PATH_MAX];
    if (ensure_directory("/home/dsbot", 0755) != 0
        || ensure_directory(base, 0755) != 0
        || snprintf(directory, sizeof(directory), "%s/%08x", base, id) >= (int)sizeof(directory)
        || ensure_directory(directory, 0700) != 0
        || chown(directory, uid, uid) != 0
        || chmod(directory, 0700) != 0
        || snprintf(temporary_directory, sizeof(temporary_directory), "%s/tmp", directory) >= (int)sizeof(temporary_directory)
        || ensure_directory(temporary_directory, 0700) != 0
        || chown(temporary_directory, uid, uid) != 0
        || chmod(temporary_directory, 0700) != 0) {
        send_error(id, "could not prepare the isolated guest workspace");
        return -1;
    }

    uint16_t rows = read_u16(payload);
    uint16_t columns = read_u16(payload + 2);
    if (rows < 2 || rows > 300) rows = 24;
    if (columns < 2 || columns > 500) columns = 80;
    struct winsize window = {.ws_row = rows, .ws_col = columns};
    struct termios attributes;
    initialize_pty_termios(&attributes);
    int master = -1;
    pid_t child = forkpty(&master, NULL, &attributes, &window);
    if (child < 0) {
        send_error(id, "forkpty failed while creating the guest shell");
        return -1;
    }
    if (child == 0) {
        if (serial_fd >= 0) close(serial_fd);
        if (kernel_log_fd >= 0) close(kernel_log_fd);
        (void)set_limit(RLIMIT_CORE, 0);
        (void)set_limit(RLIMIT_CPU, 3600);
        (void)set_limit(RLIMIT_FSIZE, 64u * 1024u * 1024u);
        (void)set_limit(RLIMIT_NOFILE, 64);
        (void)set_limit(RLIMIT_NPROC, 8);
        (void)set_limit(RLIMIT_AS, 128u * 1024u * 1024u);
        umask(0077);
        if (setgroups(0, NULL) != 0 || setgid(uid) != 0 || setuid(uid) != 0 || chdir(directory) != 0) _exit(126);
        (void)prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
        clearenv();
        (void)setenv("HOME", directory, 1);
        (void)setenv("USER", "dsbot", 1);
        (void)setenv("LOGNAME", "dsbot", 1);
        (void)setenv("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin", 1);
        (void)setenv("TMPDIR", temporary_directory, 1);
        (void)setenv("TMP", temporary_directory, 1);
        (void)setenv("TEMP", temporary_directory, 1);
        (void)setenv("XDG_RUNTIME_DIR", temporary_directory, 1);
        (void)setenv("TERM", "vt100", 1);
        (void)setenv("PS1", "dsbot$ ", 1);
        execl("/bin/sh", "sh", "-i", (char *)NULL);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL, 0);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0) {
        (void)kill(-child, SIGHUP);
        close(master);
        send_error(id, "could not configure nonblocking guest PTY output");
        return -1;
    }
    memset(slot, 0, sizeof(*slot));
    slot->id = id;
    slot->uid = uid;
    slot->gid = uid;
    slot->pid = child;
    slot->master_fd = master;
    if (send_frame(FRAME_READY, id, NULL, 0) != 0) {
        (void)kill(-child, SIGHUP);
        return -1;
    }
    return 0;
}

static void handle_frame(uint16_t type, uint32_t session_id, const unsigned char *payload, size_t length) {
    struct GuestSession *session = find_session(session_id);
    switch (type) {
        case FRAME_CREATE:
            (void)create_session(session_id, payload, length);
            return;
        case FRAME_INPUT:
            if (!session || session->close_requested || enqueue_session_input(session, payload, length) != 0) {
                send_error(session_id, "invalid session or input buffer is full");
            }
            return;
        case FRAME_RESIZE:
            if (!session || length != 4) {
                send_error(session_id, "RESIZE requires an active session and four-byte rows/columns payload");
                return;
            }
            {
                struct winsize window = {.ws_row = read_u16(payload), .ws_col = read_u16(payload + 2)};
                if (window.ws_row < 2 || window.ws_row > 300 || window.ws_col < 2 || window.ws_col > 500
                    || ioctl(session->master_fd, TIOCSWINSZ, &window) != 0) {
                    send_error(session_id, "invalid terminal dimensions");
                }
            }
            return;
        case FRAME_CLOSE:
            if (!session || length != 0) {
                send_error(session_id, "CLOSE requires an active session and an empty payload");
                return;
            }
            session->close_requested = 1;
            session->kill_deadline = time(NULL) + SESSION_CLOSE_GRACE_SECONDS;
            session->input_len = 0;
            session->input_offset = 0;
            (void)visit_uid_processes(session->uid, SIGHUP);
            if (!session->child_exited) (void)kill(-session->pid, SIGHUP);
            return;
        case FRAME_PING:
            (void)send_frame(FRAME_PONG, session_id, payload, length);
            return;
        default:
            send_error(session_id, "unsupported guest PTY protocol frame");
            return;
    }
}

static int consume_serial_frames(void) {
    size_t consumed = 0;
    while (serial_input_len - consumed >= HEADER_BYTES) {
        const unsigned char *header = serial_input + consumed;
        if (memcmp(header, "DSBP", 4) != 0 || read_u16(header + 4) != PROTOCOL_VERSION) {
            log_message("DS Bot PTY agent: invalid serial frame header\n");
            return -1;
        }
        uint16_t type = read_u16(header + 6);
        uint32_t session_id = read_u32(header + 8);
        uint32_t payload_length = read_u32(header + 12);
        if (payload_length > MAX_FRAME_BYTES) {
            log_message("DS Bot PTY agent: oversized serial frame\n");
            return -1;
        }
        size_t frame_length = HEADER_BYTES + payload_length;
        if (serial_input_len - consumed < frame_length) break;
        handle_frame(type, session_id, header + HEADER_BYTES, payload_length);
        consumed += frame_length;
    }
    if (consumed) {
        serial_input_len -= consumed;
        memmove(serial_input, serial_input + consumed, serial_input_len);
    }
    return 0;
}

static void reap_children(void) {
    int status = 0;
    pid_t child;
    while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
        for (size_t index = 0; index < MAX_SESSIONS; index++) {
            struct GuestSession *session = &sessions[index];
            if (session->pid == child) {
                session->child_exited = 1;
                session->wait_status = status;
                session->close_requested = 1;
                session->kill_deadline = time(NULL) + SESSION_CLOSE_GRACE_SECONDS;
                (void)visit_uid_processes(session->uid, SIGHUP);
                break;
            }
        }
    }
}

static void finish_session(struct GuestSession *session) {
    int32_t exit_status = 0;
    if (WIFEXITED(session->wait_status)) exit_status = WEXITSTATUS(session->wait_status);
    else if (WIFSIGNALED(session->wait_status)) exit_status = 128 + WTERMSIG(session->wait_status);
    unsigned char status_bytes[4];
    write_u32(status_bytes, (uint32_t)exit_status);
    if (serial_output_pending() > MAX_OUTPUT_QUEUE - HEADER_BYTES - sizeof(status_bytes)) return;
    (void)send_frame(FRAME_EXIT, session->id, status_bytes, sizeof(status_bytes));
    close(session->master_fd);
    free(session->input);
    memset(session, 0, sizeof(*session));
    session->master_fd = -1;
}

static void service_session(struct GuestSession *session, short events) {
    if (session->master_fd < 0) return;
    if ((events & POLLOUT) && session->input_offset < session->input_len) {
        ssize_t count = write(session->master_fd, session->input + session->input_offset,
                              session->input_len - session->input_offset);
        if (count > 0) {
            session->input_offset += (size_t)count;
            if (session->input_offset == session->input_len) {
                session->input_offset = 0;
                session->input_len = 0;
            }
        } else if (count < 0 && errno != EAGAIN && errno != EINTR) {
            session->pty_eof = 1;
        }
    }
    if ((events & (POLLIN | POLLHUP | POLLERR)) && serial_output_pending() < MAX_OUTPUT_QUEUE - HEADER_BYTES - PTY_READ_BYTES) {
        unsigned char bytes[PTY_READ_BYTES];
        for (;;) {
            ssize_t count = read(session->master_fd, bytes, sizeof(bytes));
            if (count > 0) {
                if (send_frame(FRAME_OUTPUT, session->id, bytes, (size_t)count) != 0) break;
                continue;
            }
            if (count == 0 || (count < 0 && errno == EIO)) session->pty_eof = 1;
            else if (count < 0 && errno != EAGAIN && errno != EINTR) session->pty_eof = 1;
            break;
        }
    }
    if (session->close_requested && time(NULL) >= session->kill_deadline) {
        (void)visit_uid_processes(session->uid, SIGKILL);
        if (!session->child_exited) (void)kill(-session->pid, SIGKILL);
        session->kill_deadline = time(NULL) + SESSION_CLOSE_GRACE_SECONDS;
        session->close_requested = 0;
    }
    if (session->child_exited && session->pty_eof && visit_uid_processes(session->uid, 0) == 0) {
        finish_session(session);
    }
}

static int configure_serial(int descriptor) {
    struct termios attributes;
    if (tcgetattr(descriptor, &attributes) != 0) return -1;
    cfmakeraw(&attributes);
    attributes.c_cflag |= CLOCAL | CREAD | CS8;
    (void)cfsetispeed(&attributes, B115200);
    (void)cfsetospeed(&attributes, B115200);
    return tcsetattr(descriptor, TCSANOW, &attributes);
}

int main(void) {
    for (size_t index = 0; index < MAX_SESSIONS; index++) sessions[index].master_fd = -1;
    (void)signal(SIGPIPE, SIG_IGN);
    kernel_log_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    serial_fd = open("/dev/ttyAMA0", O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (serial_fd < 0 || configure_serial(serial_fd) != 0) {
        log_message("DS Bot PTY agent: could not open the guest serial channel\n");
        return 1;
    }
    log_message("DS Bot PTY agent: protocol v1 ready\n");
    if (send_frame(FRAME_READY, 0, NULL, 0) != 0) return 1;

    for (;;) {
        struct pollfd descriptors[1 + MAX_SESSIONS];
        struct GuestSession *by_index[MAX_SESSIONS];
        memset(descriptors, 0, sizeof(descriptors));
        descriptors[0].fd = serial_fd;
        descriptors[0].events = POLLIN;
        if (serial_output_pending()) descriptors[0].events |= POLLOUT;
        for (size_t index = 0; index < MAX_SESSIONS; index++) {
            struct GuestSession *session = &sessions[index];
            by_index[index] = session;
            descriptors[index + 1].fd = session->master_fd;
            if (session->master_fd < 0) continue;
            if (serial_output_pending() < MAX_OUTPUT_QUEUE - HEADER_BYTES - PTY_READ_BYTES) {
                descriptors[index + 1].events |= POLLIN;
            }
            if (session->input_offset < session->input_len) descriptors[index + 1].events |= POLLOUT;
        }

        int polled = poll(descriptors, 1 + MAX_SESSIONS, 200);
        if (polled < 0 && errno != EINTR) {
            log_message("DS Bot PTY agent: poll failed\n");
            return 1;
        }
        if (descriptors[0].revents & POLLOUT) {
            size_t pending = serial_output_pending();
            ssize_t count = write(serial_fd, serial_output + serial_output_offset, pending);
            if (count > 0) {
                serial_output_offset += (size_t)count;
                if (serial_output_offset == serial_output_len) {
                    serial_output_offset = 0;
                    serial_output_len = 0;
                }
            } else if (count < 0 && errno != EAGAIN && errno != EINTR) {
                log_message("DS Bot PTY agent: serial write failed\n");
                return 1;
            }
        }
        if ((descriptors[0].revents & POLLIN) && serial_input_len < sizeof(serial_input)) {
            ssize_t count = read(serial_fd, serial_input + serial_input_len, sizeof(serial_input) - serial_input_len);
            if (count > 0) {
                serial_input_len += (size_t)count;
                if (consume_serial_frames() != 0) return 1;
            } else if (count == 0) {
                log_message("DS Bot PTY agent: serial channel closed\n");
                return 1;
            } else if (errno != EAGAIN && errno != EINTR) {
                log_message("DS Bot PTY agent: serial read failed\n");
                return 1;
            }
        }
        for (size_t index = 0; index < MAX_SESSIONS; index++) {
            if (by_index[index]->master_fd >= 0 && descriptors[index + 1].revents) {
                service_session(by_index[index], descriptors[index + 1].revents);
            }
        }
        reap_children();
        for (size_t index = 0; index < MAX_SESSIONS; index++) {
            struct GuestSession *session = &sessions[index];
            if (session->master_fd < 0 || !session->child_exited) continue;
            service_session(session, POLLIN | POLLHUP);
        }
    }
}
