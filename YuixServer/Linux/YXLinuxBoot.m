//
//  YXLinuxBoot.m
//  YuixServer
//
//  Boots the embedded Alpine Linux (ish kernel + asbestos JIT, arm64 guest).
//

#import "YXLinuxBoot.h"
#import "YXFakefsImport.h"

#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "debug.h"
#include "fs/devices.h"
#include "fs/dev.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "fs/fake.h"   // fakefs_bind_mount

NSString *const YXLinuxBootErrorDomain = @"YXLinuxBoot";
NSString *const YXLinuxProcessExitedNotification = @"YXLinuxProcessExitedNotification";
NSString *const YXLinuxKernelDiedNotification = @"YXLinuxKernelDiedNotification";

// ============================================================ console tty

static pthread_mutex_t g_yx_console_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tty *g_yx_console_tty = NULL;
static void (*g_yx_console_output_cb)(const char *data, size_t len) = NULL;

static int yx_console_init(struct tty *tty) {
    pthread_mutex_lock(&g_yx_console_lock);
    g_yx_console_tty = tty;
    pthread_mutex_unlock(&g_yx_console_lock);
    return 0;
}

static int yx_console_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    void (*cb)(const char *, size_t) = NULL;
    pthread_mutex_lock(&g_yx_console_lock);
    cb = g_yx_console_output_cb;
    pthread_mutex_unlock(&g_yx_console_lock);
    if (cb != NULL && len > 0)
        cb((const char *) buf, len);
    return (int) len;
}

static void yx_console_cleanup(struct tty *tty) {
    pthread_mutex_lock(&g_yx_console_lock);
    if (g_yx_console_tty == tty)
        g_yx_console_tty = NULL;
    pthread_mutex_unlock(&g_yx_console_lock);
}

static struct tty_driver_ops yx_console_ops = {
    .init = yx_console_init,
    .write = yx_console_write,
    .cleanup = yx_console_cleanup,
};
DEFINE_TTY_DRIVER(yx_console_driver, &yx_console_ops, TTY_CONSOLE_MAJOR, 8);

static void yx_console_send_input(const char *data, size_t len) {
    struct tty *tty = NULL;
    pthread_mutex_lock(&g_yx_console_lock);
    tty = g_yx_console_tty;
    pthread_mutex_unlock(&g_yx_console_lock);
    if (tty != NULL)
        tty_input(tty, data, len, 0);
}

static void yx_console_set_winsize(int cols, int rows) {
    struct tty *tty = NULL;
    pthread_mutex_lock(&g_yx_console_lock);
    tty = g_yx_console_tty;
    pthread_mutex_unlock(&g_yx_console_lock);
    if (tty != NULL) {
        lock(&tty->lock);
        tty_set_winsize(tty, (struct winsize_) {.col = cols, .row = rows});
        unlock(&tty->lock);
    }
}

// ============================================================ kernel hooks

extern const char *sock_tmp_prefix;

static void yx_handle_exit(struct task *task, int code) {
    // interested in direct children of init (commands run via YXLinuxShell)
    if (task->parent == NULL || task->parent->pid != 1)
        return;
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YXLinuxProcessExitedNotification
                          object:nil
                        userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

static void yx_handle_die(const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YXLinuxKernelDiedNotification
                          object:nil
                        userInfo:@{@"message": @(msg ? msg : "kernel died")}];
    });
}

// ============================================================ guest file io

// Write a string into the guest filesystem at an absolute guest path.
// Must run with `current` == pid 1's task context (during boot).
static int yx_guest_write_file(const char *path, const char *data) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd))
        return (int) PTR_ERR(fd);
    size_t len = strlen(data);
    ssize_t w = fd->ops->write(fd, data, len);
    fd_close(fd);
    if (w < 0)
        return (int) w;
    return 0;
}

// Copy a host file into the guest at an absolute guest path.
static int yx_guest_copy_file(NSString *hostPath, const char *guestPath) {
    NSData *data = [NSData dataWithContentsOfFile:hostPath];
    if (!data)
        return -1;
    struct fd *fd = generic_open(guestPath, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd))
        return (int) PTR_ERR(fd);
    ssize_t off = 0;
    while (off < (ssize_t) data.length) {
        size_t chunk = data.length - off;
        if (chunk > 256 * 1024)
            chunk = 256 * 1024;
        ssize_t w = fd->ops->write(fd, (const char *) data.bytes + off, chunk);
        if (w < 0) {
            fd_close(fd);
            return (int) w;
        }
        off += w;
    }
    fd_close(fd);
    return 0;
}

// ============================================================ implementation

@interface YXLinuxBoot ()
@property (nonatomic, assign) YXLinuxBootState state;
@property (nonatomic, copy, nullable) NSString *stateDetail;
@property (nonatomic, assign) double importProgress;
@property (nonatomic) NSURL *rootURL;
@property (nonatomic) dispatch_queue_t outputQueue;
@property (nonatomic) NSMutableDictionary<NSNumber *, YXLinuxOutputHandler> *handlers;
@property (nonatomic) NSMutableData *pendingOutput;
@property (nonatomic) dispatch_semaphore_t bootLock;
@end

// C callback trampoline (a block literal is not a C function pointer).
static bool yx_progress_trampoline(void *cookie, double fraction, const char *message) {
    YXLinuxBoot *boot = (__bridge YXLinuxBoot *) cookie;
    boot.importProgress = fraction;
    if (message != NULL)
        boot.stateDetail = [NSString stringWithUTF8String:message];
    return true;
}

@implementation YXLinuxBoot

static const NSUInteger kMaxPendingOutput = 2 * 1024 * 1024; // 2 MiB cap

+ (instancetype)shared {
    static YXLinuxBoot *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[YXLinuxBoot alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _state = YXLinuxBootStateIdle;
        _outputQueue = dispatch_queue_create("app.yuix.linux.output", DISPATCH_QUEUE_SERIAL);
        _handlers = [NSMutableDictionary dictionary];
        _pendingOutput = [NSMutableData data];
        _bootLock = dispatch_semaphore_create(1);
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _rootURL = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"alpine-root"]];
    }
    return self;
}

- (NSString *)guestProjectsPath {
    return @"/root/projects";
}

#pragma mark - output fan-out

- (NSUInteger)addOutputHandler:(YXLinuxOutputHandler)handler {
    static NSUInteger token = 0;
    @synchronized (self.handlers) {
        token += 1;
        self.handlers[@(token)] = handler;
        return token;
    }
}

- (void)removeOutputHandler:(NSUInteger)token {
    @synchronized (self.handlers) {
        [self.handlers removeObjectForKey:@(token)];
    }
}

- (void)removeAllOutputHandlers {
    @synchronized (self.handlers) {
        [self.handlers removeAllObjects];
    }
}

// Called from kernel threads; forward into the serial queue with a cap.
static void yx_boot_output_trampoline(const char *data, size_t len) {
    YXLinuxBoot *boot = [YXLinuxBoot shared];
    dispatch_async(boot.outputQueue, ^{
        @autoreleasepool {
            if (boot.pendingOutput.length + len > kMaxPendingOutput) {
                // drop rather than grow unbounded
                size_t take = (size_t)(kMaxPendingOutput - boot.pendingOutput.length);
                if (take > 0)
                    [boot.pendingOutput appendBytes:data length:take];
            } else {
                [boot.pendingOutput appendBytes:data length:len];
            }
            NSData *chunk = [boot.pendingOutput copy];
            boot.pendingOutput = [NSMutableData data];
            NSArray<YXLinuxOutputHandler> *handlers;
            @synchronized (boot.handlers) {
                handlers = boot.handlers.allValues;
            }
            for (YXLinuxOutputHandler h in handlers)
                h(chunk);
        }
    });
}

- (void)flushOutput:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0)
        return;
    dispatch_async(self.outputQueue, ^{
        NSArray<YXLinuxOutputHandler> *handlers;
        @synchronized (self.handlers) {
            handlers = self.handlers.allValues;
        }
        for (YXLinuxOutputHandler h in handlers)
            h(data);
    });
}

#pragma mark - console io

- (BOOL)sendConsoleInput:(NSData *)data {
    if (self.state != YXLinuxBootStateReady || data.length == 0)
        return NO;
    yx_console_send_input((const char *) data.bytes, data.length);
    return YES;
}

- (BOOL)setConsoleSize:(int)cols rows:(int)rows {
    if (self.state != YXLinuxBootStateReady)
        return NO;
    if (cols < 1 || cols > 1024 || rows < 1 || rows > 256)
        return NO;
    yx_console_set_winsize(cols, rows);
    return YES;
}

#pragma mark - boot

- (BOOL)bootWithError:(NSError **)error {
    dispatch_semaphore_wait(self.bootLock, DISPATCH_TIME_FOREVER);
    BOOL ok = [self bootLockedWithError:error];
    dispatch_semaphore_signal(self.bootLock);
    return ok;
}

// Swift-friendly variant: NSError** gets imported by Swift as a `throws`
// method, which callers can't invoke with `&nsError` semantics. NSString**
// imports cleanly as an optional-inout, so Swift uses this one.
- (BOOL)bootWithFailureMessage:(NSString **)failureMessage {
    NSError *error = nil;
    BOOL ok = [self bootWithError:&error];
    if (!ok && failureMessage != NULL) {
        *failureMessage = error.localizedDescription ?: @"启动失败";
    }
    return ok;
}

- (BOOL)bootLockedWithError:(NSError **)error {
    if (self.state == YXLinuxBootStateReady)
        return YES;
    if (self.state == YXLinuxBootStateFailed) {
        if (error)
            *error = [NSError errorWithDomain:YXLinuxBootErrorDomain code:-1
                                      userInfo:@{NSLocalizedDescriptionKey: self.stateDetail ?: @"previous boot failed"}];
        return NO;
    }

    // ---- rootfs import (first launch) ----
    NSString *dataDir = [self.rootURL.path stringByAppendingPathComponent:@"data"];
    NSString *metaDB = [self.rootURL.path stringByAppendingPathComponent:@"meta.db"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:metaDB]) {
        self.state = YXLinuxBootStateImportingRootfs;
        self.importProgress = 0;
        self.stateDetail = @"正在解压 Alpine rootfs";
        NSURL *archiveURL = [[NSBundle mainBundle] URLForResource:@"root" withExtension:@"tar.gz"];
        if (!archiveURL) {
            // CFBundle 按「最后一个点」切分文件名：root.tar.gz 被索引为
            // name="root.tar" ext="gz"，两种切法都试一遍
            archiveURL = [[NSBundle mainBundle] URLForResource:@"root.tar" withExtension:@"gz"];
        }
        if (!archiveURL) {
            return [self fail:@"缺少内置 rootfs (root.tar.gz)" error:error];
        }

        // SHA256 integrity check against bundled digest
        NSURL *hashURL = [[NSBundle mainBundle] URLForResource:@"rootfs" withExtension:@"sha256"];
        if (hashURL) {
            NSString *expected = [[NSString stringWithContentsOfURL:hashURL
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            char hex[65];
            if (yx_sha256_file(archiveURL.fileSystemRepresentation, hex, sizeof(hex))) {
                if (expected.length == 64 && ![expected isEqualToString:[NSString stringWithUTF8String:hex]]) {
                    return [self fail:@"rootfs 校验失败(SHA256 不匹配)，拒绝导入" error:error];
                }
            } else {
                return [self fail:@"无法计算 rootfs 摘要" error:error];
            }
        }

        // remove partial state from a previous failed import
        [[NSFileManager defaultManager] removeItemAtPath:self.rootURL.path error:nil];

        struct yx_import_error ierr;
        struct yx_import_progress cprog = {
            .cookie = (__bridge void *) self,
            .callback = yx_progress_trampoline,
        };
        if (!yx_fakefs_import(archiveURL.fileSystemRepresentation,
                              self.rootURL.fileSystemRepresentation,
                              &ierr, cprog)) {
            NSString *msg = [NSString stringWithFormat:@"rootfs 导入失败(line %d, type %d, code %d): %s",
                             ierr.line, ierr.type, ierr.code, ierr.message];
            [[NSFileManager defaultManager] removeItemAtPath:self.rootURL.path error:nil];
            return [self fail:msg error:error];
        }
        self.importProgress = 1;
    }

    // ---- kernel boot ----
    self.state = YXLinuxBootStateBootingKernel;
    self.stateDetail = @"正在启动 Linux 内核";

    // unix socket tmp prefix (guest abstract sockets map to host temp files)
    {
        static char sockPrefix[PATH_MAX];
        snprintf(sockPrefix, sizeof(sockPrefix), "%s/",
                 [NSTemporaryDirectory() fileSystemRepresentation]);
        sock_tmp_prefix = sockPrefix;
    }

    int err = mount_root(&fakefs, dataDir.fileSystemRepresentation);
    if (err < 0)
        return [self fail:[NSString stringWithFormat:@"mount_root 失败: errno %d", err] error:error];

    err = become_first_process();
    if (err < 0)
        return [self fail:[NSString stringWithFormat:@"become_first_process 失败: %d", err] error:error];
    // 上游 iSH（xX_main_Xx.h）在 become_first_process 之后立即设置：
    // pid 1 的宿主线程就是当前调用线程。内核在投递信号时会
    // pthread_kill(task->thread, SIGUSR1)，thread 为 NULL 会直接崩。
    current->thread = pthread_self();

    // device nodes
    do {
        int e = 0;
        e |= generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 1));
        e |= generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
        e |= generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
        (void) e;
    } while (0);

    // pseudo terminal dir
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    // fix root permissions
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // DNS
    [self configureDNS];

    // apk repositories + polyfills + profile
    [self setupGuestConfig];

    exit_hook = yx_handle_exit;
    die_handler = yx_handle_die;

    // console
    g_yx_console_output_cb = yx_boot_output_trampoline;
    tty_drivers[TTY_CONSOLE_MAJOR] = &yx_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        return [self fail:[NSString stringWithFormat:@"create_stdio 失败: %d", err] error:error];

    // bind host Documents dir into the guest at /root/projects (read-write)
    {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        generic_mkdirat(AT_PWD, "/root", 0755);
        generic_mkdirat(AT_PWD, "/root/projects", 0755);
        int e = fakefs_bind_mount("/root/projects", docs.fileSystemRepresentation, false);
        if (e < 0)
            NSLog(@"YXLinuxBoot: bind mount /root/projects failed: %d", e);
    }

    // pid 1: supervisor loop around an interactive shell.
    // - inner `sh -il` gives the Terminal UI a real shell (reads /etc/profile)
    // - ash reaps ALL children (WAIT_ANY), including YXLinuxShell tasks that
    //   become init's children in the kernel task tree
    // - if the user exits the shell, the loop restarts it instead of letting
    //   pid 1 die (pid 1 death would halt the whole kernel)
    {
        const char *argv =
            "/bin/sh\0-c\0"
            "while :; do /bin/sh -il; echo '[shell 已退出，1 秒后重启]'; sleep 1; done"
            "\0";
        const char *envp =
            "TERM=xterm-256color\0"
            "HOME=/root\0"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
            "LANG=C.UTF-8\0";
        err = do_execve("/bin/sh", 3, argv, envp);
        if (err < 0)
            return [self fail:[NSString stringWithFormat:@"do_execve(/bin/sh) 失败: %d", err] error:error];
        task_start(current);
    }

    self.state = YXLinuxBootStateReady;
    self.stateDetail = nil;
    [self flushOutput:@"\r\n\x1b[1;34m[YuixServer]\x1b[0m Alpine Linux 已就绪。\r\n\r\n"];
    return YES;
}

// Mirror the host's DNS configuration into the guest by parsing /etc/resolv.conf.
// iOS keeps /etc/resolv.conf in sync with the active network configuration.
// This deliberately avoids libresolv: the iOS SDK ships no libresolv.tbd and
// the res_9_* symbols are not exported by libSystem on device, so linking
// them fails. No-link parsing is also one less dependency to audit.
- (void)configureDNS {
    NSMutableString *conf = [NSMutableString new];
    NSUInteger nameservers = 0;
    NSString *hostResolv = [NSString stringWithContentsOfFile:@"/etc/resolv.conf"
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    if (hostResolv.length > 0) {
        NSArray<NSString *> *lines = [hostResolv
            componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        // 只看前 64 行：resolv.conf 正常只有几行，防御异常大文件拖慢引导
        NSUInteger limit = MIN(lines.count, (NSUInteger) 64);
        for (NSUInteger i = 0; i < limit; i++) {
            NSArray<NSString *> *tokens = [[lines objectAtIndex:i]
                componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            tokens = [tokens filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"length > 0"]];
            if (tokens.count < 2)
                continue;
            NSString *directive = tokens[0].lowercaseString;
            if ([directive isEqualToString:@"nameserver"]) {
                [conf appendFormat:@"nameserver %@\n", tokens[1]];
                nameservers++;
            } else if ([directive isEqualToString:@"search"] ||
                       [directive isEqualToString:@"domain"]) {
                // 最多 6 个域，与 musl 解析器的 resolv.conf 习惯一致
                NSArray<NSString *> *domains =
                    [tokens subarrayWithRange:NSMakeRange(1, MIN(tokens.count - 1, (NSUInteger) 6))];
                [conf appendFormat:@"search %@\n",
                    [domains componentsJoinedByString:@" "]];
            }
        }
    }
    if (nameservers == 0)
        [conf appendString:@"nameserver 8.8.8.8\nnameserver 1.1.1.1\n"];
    current = pid_get_task(1);
    yx_guest_write_file("/etc/resolv.conf", conf.UTF8String);
}

- (void)setupGuestConfig {
    current = pid_get_task(1);

    // apk repositories (Alpine 3.21)
    yx_guest_write_file("/etc/apk/repositories",
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/main\n"
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/community\n");

    // node polyfills (conditionally --require'd by the kernel for node)
    NSURL *wasm = [[NSBundle mainBundle] URLForResource:@"wasm-polyfill" withExtension:@"js"];
    if (wasm)
        yx_guest_copy_file(wasm.path, "/lib/wasm-polyfill.js");
    NSURL *fetch = [[NSBundle mainBundle] URLForResource:@"fetch-polyfill" withExtension:@"js"];
    if (fetch)
        yx_guest_copy_file(fetch.path, "/lib/fetch-polyfill.js");

    // hostname
    yx_guest_write_file("/etc/hostname", "yuixserver\n");

    // prompt + motd
    yx_guest_write_file("/etc/profile",
        "export PS1='\\[\\e[1;32m\\]\\u@yuix\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]$ '\n"
        "export TERM=xterm-256color\n"
        "export LANG=C.UTF-8\n"
        "alias ll='ls -la'\n"
        "alias ls='ls --color=auto'\n"
        "cd /root/projects 2>/dev/null || cd /root\n");
    yx_guest_write_file("/etc/motd",
        "\n"
        "  ╭──────────────────────────────────────╮\n"
        "  │  YuixServer · Alpine Linux (aarch64) │\n"
        "  │  apk add python3 nodejs php ...      │\n"
        "  ╰──────────────────────────────────────╯\n"
        "\n");
}

- (BOOL)bindMountHost:(NSString *)hostPath atLinuxPath:(NSString *)linuxPath readOnly:(BOOL)readOnly {
    if (self.state != YXLinuxBootStateReady)
        return NO;
    const char *lp = linuxPath.fileSystemRepresentation;
    // ensure the guest dir exists before binding
    generic_mkdirat(AT_PWD, lp, 0755);
    int e = fakefs_bind_mount(lp, hostPath.fileSystemRepresentation, readOnly);
    return e == 0;
}

- (BOOL)fail:(NSString *)msg error:(NSError **)error {
    self.state = YXLinuxBootStateFailed;
    self.stateDetail = msg;
    NSLog(@"YXLinuxBoot failed: %@", msg);
    if (error)
        *error = [NSError errorWithDomain:YXLinuxBootErrorDomain code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: msg}];
    return NO;
}

@end
