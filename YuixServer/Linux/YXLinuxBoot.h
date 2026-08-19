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
- (BOOL)bootWithError:(NSError *_Nullable *_Nullable)error;

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
