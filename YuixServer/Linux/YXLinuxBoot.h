//
//  YXLinuxBoot.h
//  YuixServer
//
//  Boots the embedded Alpine Linux (ish kernel + asbestos JIT).
//  First launch imports the bundled rootfs (with SHA256 verification),
//  then mounts fakefs, creates device nodes, configures DNS, and starts
//  pid 1 as a zombie-reaping keepalive shell on the console tty.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const YXLinuxBootErrorDomain;

/// 通知：guest 内进程退出。userInfo: {pid: NSNumber, code: NSNumber}
extern NSString *const YXLinuxProcessExitedNotification;
/// 通知：内核异常死亡。userInfo: {message: NSString}
extern NSString *const YXLinuxKernelDiedNotification;

typedef NS_ENUM(NSInteger, YXLinuxBootState) {
    YXLinuxBootStateIdle = 0,
    YXLinuxBootStateImportingRootfs,
    YXLinuxBootStateBootingKernel,
    YXLinuxBootStateReady,
    YXLinuxBootStateFailed,
};

typedef void (^YXLinuxOutputHandler)(NSData *data);

@interface YXLinuxBoot : NSObject

+ (instancetype)shared;

/// Current boot state (KVO-observable through stateDetail notifications).
@property (nonatomic, readonly) YXLinuxBootState state;
@property (nonatomic, readonly, nullable) NSString *stateDetail;
/// Rootfs import progress in [0,1], valid while importing.
@property (nonatomic, readonly) double importProgress;

/// Root filesystem location (Documents/alpine-root).
@property (nonatomic, readonly) NSURL *rootURL;

/// Boot synchronously (idempotent). Safe to call from any thread.
/// Returns YES when the kernel is ready. On NO, error is filled.
/// 注意：NSError** 变体会被 Swift 导入器按 Cocoa 错误约定转换成
/// `throws` 方法；Swift 侧请改用下面的 bootWithFailureMessage:。
- (BOOL)bootWithError:(NSError *_Nullable *_Nullable)error;

/// Swift-friendly sync boot (NSString** 不触发错误约定转换)。
/// Returns YES when the kernel is ready. On NO, *failureMessage (if non-NULL)
/// receives a short human-readable description.
- (BOOL)bootWithFailureMessage:(NSString *_Nullable *_Nullable)failureMessage;

/// 内核是否已在本进程内启动过。一旦为 YES，引导失败只能重启 App 重试
/// （内核无法在进程内卸载）；为 NO 时可安全重试/重装。
@property (nonatomic, readonly) BOOL kernelStarted;

/// 卸载并清除已安装的 rootfs（仅在内核未启动时可用，否则返回 NO）。
/// 成功后状态回到 Idle，随后再次 boot 会完整重装。
/// rootfs 安装是原子三段式：临时目录导入 → sqlite 完整性校验 → 原子上线；
/// 任何一步被打断（杀进程/磁盘满/崩溃）都不会留下半成品系统。
- (BOOL)resetFilesystemWithFailureMessage:(NSString *_Nullable *_Nullable)failureMessage;

/// Register a console output listener. Returns a token for removal.
/// The handler is called on a private serial queue.
- (NSUInteger)addOutputHandler:(YXLinuxOutputHandler)handler;
- (void)removeOutputHandler:(NSUInteger)token;
- (void)removeAllOutputHandlers;

/// Send raw bytes to the console tty (guest stdin). Must be booted.
- (BOOL)sendConsoleInput:(NSData *)data;

/// Resize the console tty.
- (BOOL)setConsoleSize:(int)cols rows:(int)rows;

/// Bind a host (iOS) directory into the guest at a Linux path.
/// Must be called after boot. read_only rejects guest writes with EROFS.
- (BOOL)bindMountHost:(NSString *)hostPath atLinuxPath:(NSString *)linuxPath
             readOnly:(BOOL)readOnly;

/// Guest-side home directory for projects (bind-mounted from Documents).
@property (nonatomic, readonly) NSString *guestProjectsPath;

@end

NS_ASSUME_NONNULL_END
