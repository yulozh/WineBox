//
//  YXLinuxShell.h
//  YuixServer
//
//  Runs commands inside the booted Alpine Linux (via YXLinuxBoot).
//  Ported from the engine's ISHShellExecutor with hardening:
//  - no AppDelegate dependency (uses YXLinuxProcessExitedNotification)
//  - serialized task spawning (the kernel task tree is not thread-safe)
//  - per-stream output caps (1 MiB) with tail retention
//  - EOF-driven pipe readers (no data loss, no busy waiting)
//  - optional guest working directory
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YXLinuxShellError) {
    YXLinuxShellErrorNone = 0,
    YXLinuxShellErrorNotBooted = -1,
    YXLinuxShellErrorProcessCreationFailed = -2,
    YXLinuxShellErrorExecFailed = -3,
    YXLinuxShellErrorTimeout = -4,
    YXLinuxShellErrorInvalidArguments = -5,
};

@class YXLinuxShellResult;

typedef void (^YXLinuxShellLineCallback)(NSString *line, BOOL isError);
typedef void (^YXLinuxShellCompletionCallback)(YXLinuxShellResult *result);

@interface YXLinuxShellResult : NSObject

@property (nonatomic, readonly) int exitCode;
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) YXLinuxShellError error;
/// Combined stdout (capped at 1 MiB, tail kept on overflow).
@property (nonatomic, readonly, copy) NSString *output;
/// Combined stderr (capped at 1 MiB, tail kept on overflow).
@property (nonatomic, readonly, copy) NSString *errorOutput;
@property (nonatomic, readonly) NSTimeInterval duration;
/// YES when output/errorOutput was truncated at the cap.
@property (nonatomic, readonly) BOOL truncated;

@end

@interface YXLinuxShell : NSObject

/// Execute `sh -c command` in the guest. Returns the guest pid (>0),
/// or a negative YXLinuxShellError. completion is called on the main queue.
+ (int)executeCommand:(NSString *)command
          lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
            completion:(nullable YXLinuxShellCompletionCallback)completion;

+ (int)executeCommand:(NSString *)command
       workingDirectory:(nullable NSString *)guestWorkingDirectory
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
           lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
             completion:(nullable YXLinuxShellCompletionCallback)completion;

/// Execute an arbitrary guest binary with arguments.
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
              environment:(nullable NSDictionary<NSString *, NSString *> *)environment
          workingDirectory:(nullable NSString *)guestWorkingDirectory
             lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
               completion:(nullable YXLinuxShellCompletionCallback)completion;

/// Synchronous variant. timeout <= 0 means wait forever.
+ (nullable YXLinuxShellResult *)executeCommandSync:(NSString *)command
                                            timeout:(NSTimeInterval)timeout
                                        lineCallback:(nullable YXLinuxShellLineCallback)lineCallback;

/// Send a signal to a guest pid. Returns NO if the pid is gone.
+ (BOOL)killProcess:(int)pid withSignal:(int)signalNumber;

/// SIGKILL every execution still tracked by this executor.
+ (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
