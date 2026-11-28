#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSBotISHOutputHandler)(NSData *data);
typedef void (^DSBotISHExitHandler)(int32_t status);

/// Minimal host bridge for the pinned iSH engine. It exposes only an app-owned
/// persistent fakefs, a shared authorized workspace bind mount, and bounded
/// owner-issued PTY sessions. It does not expose iOS host paths to guest input.
@interface ISHKernelBridge : NSObject

+ (instancetype)shared;

- (nullable NSError *)bootWithRootPath:(NSString *)rootPath
                         workspacePath:(NSString *)workspacePath
                        timeoutSeconds:(NSTimeInterval)timeoutSeconds
    NS_SWIFT_NAME(boot(rootPath:workspacePath:timeoutSeconds:));

- (nullable NSError *)openSessionWithID:(NSString *)sessionID
                                   rows:(NSUInteger)rows
                                columns:(NSUInteger)columns
                          outputHandler:(DSBotISHOutputHandler)outputHandler
                            exitHandler:(DSBotISHExitHandler)exitHandler
    NS_SWIFT_NAME(openSession(id:rows:columns:outputHandler:exitHandler:));

- (nullable NSError *)writeInput:(NSData *)data sessionID:(NSString *)sessionID
    NS_SWIFT_NAME(writeInput(_:sessionID:));
- (BOOL)resizeSessionID:(NSString *)sessionID rows:(NSUInteger)rows columns:(NSUInteger)columns
    NS_SWIFT_NAME(resize(id:rows:columns:));
- (BOOL)closeSessionID:(NSString *)sessionID NS_SWIFT_NAME(close(id:));
- (void)closeAllSessions;

@end

NS_ASSUME_NONNULL_END
