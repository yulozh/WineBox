//
//  YXLinuxShell.m
//  YuixServer
//

#import "YXLinuxShell.h"
#import "YXLinuxBoot.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "fs/real.h"
#include "fs/fd.h"

// fs/adhoc.c 未在任何头文件里声明它（上游只在 .c 内部使用），
// 这里补上 extern，避免 clang 16 的 implicit-declaration 错误。
extern struct fd *adhoc_fd_create(const struct fd_ops *ops);

// Per-stream cap. On overflow we keep the most recent data and prepend a
// truncation marker, so a runaway `yes` or build log can never OOM the app.
static const NSUInteger kYXMaxOutput = 1024 * 1024;

#pragma mark - Result

@interface YXLinuxShellResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) YXLinuxShellError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite) BOOL truncated;
@end

@implementation YXLinuxShellResult
@end

#pragma mark - Execution context

@interface YXLinuxShellContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy, nullable) YXLinuxShellLineCallback lineCallback;
@property (nonatomic, copy, nullable) YXLinuxShellCompletionCallback completion;
@property (nonatomic) NSMutableString *stdoutBuffer;
@property (nonatomic) NSMutableString *stderrBuffer;
@property (nonatomic) dispatch_group_t readersGroup;
@property (nonatomic, nullable) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) YXLinuxShellResult *result;
@property (atomic) BOOL isCompleted;
@property (atomic) BOOL forceDrain; // timeout path: stop readers now
- (int *)stdoutPipe;
- (int *)stderrPipe;
@end

@implementation YXLinuxShellContext

- (int *)stdoutPipe { return _stdoutPipe; }
- (int *)stderrPipe { return _stderrPipe; }

- (instancetype)init {
    if (self = [super init]) {
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
        _stdoutPipe[0] = _stdoutPipe[1] = -1;
        _stderrPipe[0] = _stderrPipe[1] = -1;
        _readersGroup = dispatch_group_create();
        _result = [[YXLinuxShellResult alloc] init];
        _result.error = YXLinuxShellErrorNone;
    }
    return self;
}

- (void)closePipe:(int *)pipeFd {
    if (pipeFd[0] >= 0) close(pipeFd[0]);
    if (pipeFd[1] >= 0) close(pipeFd[1]);
    pipeFd[0] = pipeFd[1] = -1;
}

- (void)cleanup {
    [self closePipe:_stdoutPipe];
    [self closePipe:_stderrPipe];
}

- (void)dealloc {
    [self cleanup];
}

@end

#pragma mark - Executor

@implementation YXLinuxShell

static NSMutableDictionary<NSNumber *, YXLinuxShellContext *> *YXActiveExecutions;
static dispatch_queue_t YXReaderQueue;
static dispatch_semaphore_t YXSpawnLock; // serializes kernel task creation
static dispatch_once_t YXOnceToken;

+ (void)initialize {
    if (self != [YXLinuxShell class])
        return;
    YXActiveExecutions = [NSMutableDictionary dictionary];
    YXReaderQueue = dispatch_queue_create("app.yuix.linux.shell.reader", DISPATCH_QUEUE_CONCURRENT);
    YXSpawnLock = dispatch_semaphore_create(1);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(processDidExit:)
                                                 name:YXLinuxProcessExitedNotification
                                               object:nil];
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
          lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
            completion:(nullable YXLinuxShellCompletionCallback)completion {
    return [self executeCommand:command
                workingDirectory:nil
                      environment:nil
                    lineCallback:lineCallback
                      completion:completion];
}

+ (int)executeCommand:(NSString *)command
       workingDirectory:(nullable NSString *)guestWorkingDirectory
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
           lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
             completion:(nullable YXLinuxShellCompletionCallback)completion {
    if (command.length == 0)
        return YXLinuxShellErrorInvalidArguments;
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", command]
                        environment:environment
                   workingDirectory:guestWorkingDirectory
                       lineCallback:lineCallback
                         completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
              environment:(nullable NSDictionary<NSString *, NSString *> *)environment
          workingDirectory:(nullable NSString *)guestWorkingDirectory
             lineCallback:(nullable YXLinuxShellLineCallback)lineCallback
               completion:(nullable YXLinuxShellCompletionCallback)completion {

    if (executable.length == 0)
        return YXLinuxShellErrorInvalidArguments;

    NSError *bootError = nil;
    if (![[YXLinuxBoot shared] bootWithError:&bootError]) {
        NSLog(@"YXLinuxShell: boot failed: %@", bootError.localizedDescription);
        return YXLinuxShellErrorNotBooted;
    }

    YXLinuxShellContext *ctx = [[YXLinuxShellContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];

    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"YXLinuxShell: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return YXLinuxShellErrorProcessCreationFailed;
    }
    // non-blocking read ends; readers use poll(2)
    fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK);
    fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK);

    // ---- spawn under a lock: become_new_init_child mutates global task state
    dispatch_semaphore_wait(YXSpawnLock, DISPATCH_TIME_FOREVER);
    @try {
        struct task *savedCurrent = current;

        int err = become_new_init_child();
        if (err < 0) {
            current = savedCurrent;
            [ctx cleanup];
            NSLog(@"YXLinuxShell: become_new_init_child failed: %d", err);
            return YXLinuxShellErrorProcessCreationFailed;
        }

        struct task *task = current;

        // stdin <- /dev/null
        struct fd *stdinFd = adhoc_fd_create(&realfs_fdops);
        if (stdinFd != NULL) {
            stdinFd->real_fd = open("/dev/null", O_RDONLY);
            task->files->files[0] = stdinFd;
        }
        // stdout -> pipe
        struct fd *stdoutFd = adhoc_fd_create(&realfs_fdops);
        if (stdoutFd != NULL) {
            stdoutFd->real_fd = dup([ctx stdoutPipe][1]);
            task->files->files[1] = stdoutFd;
        }
        // stderr -> pipe
        struct fd *stderrFd = adhoc_fd_create(&realfs_fdops);
        if (stderrFd != NULL) {
            stderrFd->real_fd = dup([ctx stderrPipe][1]);
            task->files->files[2] = stderrFd;
        }

        // close write ends in the parent
        close([ctx stdoutPipe][1]);
        close([ctx stderrPipe][1]);
        [ctx stdoutPipe][1] = -1;
        [ctx stderrPipe][1] = -1;

        // optional guest cwd
        if (guestWorkingDirectory.length > 0) {
            struct fd *cwdFd = generic_open(guestWorkingDirectory.UTF8String, O_RDONLY_, 0);
            if (!IS_ERR(cwdFd)) {
                fd_close(task->fs->pwd);
                task->fs->pwd = cwdFd;
            }
        }

        // ---- argv（node 时注入 V8 兼容标志）----
        // 引擎的 sys_execve 会对每个 execve 的进程注入环境变量与 V8 标志
        // （kernel/exec.c），但本类直接调 do_execve 会绕过那段逻辑。
        // 这里 1:1 复刻，否则 node 会因 V8 JIT 与 asbestos 冲突而崩溃、
        // python 会因 pymalloc 环形分配器跑挂。
        NSString *execBase = executable.lastPathComponent;
        BOOL isNode = [execBase isEqualToString:@"node"];

        NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
        if (isNode) {
            // 与 kernel/exec.c inject_args_base 完全一致
            [fullArgs addObjectsFromArray:@[
                @"--jitless",
                @"--no-lazy",
                @"--max-old-space-size=512",
                @"--no-concurrent-marking",
                @"--no-concurrent-recompilation",
                @"--no-lazy-compile-dispatcher",
                @"--predictable",
            ]];
            // polyfill 存在才注入 --require（引擎同款存在性检查）
            static NSString *const kRequires[] = {
                @"/lib/wasm-polyfill.js",
                @"/lib/fetch-polyfill.js",
            };
            for (size_t ri = 0; ri < sizeof(kRequires) / sizeof(kRequires[0]); ri++) {
                struct fd *pfd = generic_open(kRequires[ri].UTF8String, O_RDONLY_, 0);
                if (!IS_ERR(pfd)) {
                    fd_close(pfd);
                    [fullArgs addObject:[NSString stringWithFormat:@"--require=%@", kRequires[ri]]];
                }
            }
        }
        if (arguments.count > 0)
            [fullArgs addObjectsFromArray:arguments];

        char argvBuf[8192];
        size_t pos = 0;
        for (NSString *arg in fullArgs) {
            const char *str = arg.UTF8String;
            size_t len = strlen(str) + 1;
            if (pos + len + 1 >= sizeof(argvBuf)) {
                current = savedCurrent;
                [ctx cleanup];
                return YXLinuxShellErrorInvalidArguments;
            }
            memcpy(argvBuf + pos, str, len);
            pos += len;
        }
        argvBuf[pos] = '\0'; // final NUL

        // ---- envp（KEY=VALUE\0...\0\0，含引擎强制注入项）----
        // 先按「后写覆盖先写」合成字典，再序列化为 C 缓冲区，
        // 天然实现引擎的 mode=0（不存在才注入）与 mode=1（强制替换）语义。
        NSMutableDictionary<NSString *, NSString *> *envDict = [NSMutableDictionary dictionary];
        envDict[@"TERM"] = @"xterm-256color";
        envDict[@"HOME"] = @"/root";
        envDict[@"PATH"] = @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        envDict[@"LANG"] = @"C.UTF-8";
        if (environment.count > 0)
            [envDict addEntriesFromDictionary:environment];
        // 引擎强制注入（kernel/exec.c inject_envs）
        envDict[@"PYTHONMALLOC"] = @"malloc";            // mode=1 强制替换
        envDict[@"NO_COLOR"] = @"1";
        envDict[@"PIP_PROGRESS_BAR"] = @"off";
        envDict[@"PYTHONDONTWRITEBYTECODE"] = @"1";
        envDict[@"GODEBUG"] = @"asyncpreemptoff=1";
        envDict[@"GOMAXPROCS"] = @"2";
        envDict[@"UV_THREADPOOL_SIZE"] = @"1";
        if (isNode && envDict[@"LD_PRELOAD"] == nil) {
            // 引擎注入 LD_PRELOAD=/lib/zero_free.so；rootfs 里没有该文件时
            // 跳过（musl 对缺失的 preload 库仅告警，但保持输出干净）。
            struct fd *zfd = generic_open("/lib/zero_free.so", O_RDONLY_, 0);
            if (!IS_ERR(zfd)) {
                fd_close(zfd);
                envDict[@"LD_PRELOAD"] = @"/lib/zero_free.so";
            }
        }

        char envpBuf[8192];
        size_t epos = 0;
        for (NSString *key in envDict) {
            NSString *pair = [NSString stringWithFormat:@"%@=%@", key, envDict[key]];
            const char *str = pair.UTF8String;
            size_t len = strlen(str) + 1;
            if (epos + len + 1 >= sizeof(envpBuf))
                break;
            memcpy(envpBuf + epos, str, len);
            epos += len;
        }
        envpBuf[epos] = '\0'; // final NUL terminates envp

        err = do_execve(executable.UTF8String, fullArgs.count, argvBuf, envpBuf);
        if (err < 0) {
            current = savedCurrent;
            [ctx cleanup];
            NSLog(@"YXLinuxShell: do_execve(%@) failed: %d", executable, err);
            return YXLinuxShellErrorExecFailed;
        }

        ctx.guestPid = task->pid;
        ctx.result.pid = ctx.guestPid;
        task_start(task);
        current = savedCurrent;
    } @finally {
        dispatch_semaphore_signal(YXSpawnLock);
    }

    @synchronized(YXActiveExecutions) {
        YXActiveExecutions[@(ctx.guestPid)] = ctx;
    }

    // readers: EOF-driven, tracked in a group so completion can wait for them
    dispatch_group_enter(ctx.readersGroup);
    dispatch_async(YXReaderQueue, ^{
        [self readPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
        dispatch_group_leave(ctx.readersGroup);
    });
    dispatch_group_enter(ctx.readersGroup);
    dispatch_async(YXReaderQueue, ^{
        [self readPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];
        dispatch_group_leave(ctx.readersGroup);
    });

    return ctx.guestPid;
}

+ (nullable YXLinuxShellResult *)executeCommandSync:(NSString *)command
                                            timeout:(NSTimeInterval)timeout
                                        lineCallback:(nullable YXLinuxShellLineCallback)lineCallback {
    if (command.length == 0)
        return nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block YXLinuxShellResult *result = nil;

    int pid = [self executeCommand:command
                      lineCallback:lineCallback
                        completion:^(YXLinuxShellResult *r) {
        result = r;
        dispatch_semaphore_signal(sem);
    }];
    if (pid < 0) {
        YXLinuxShellResult *r = [[YXLinuxShellResult alloc] init];
        r.error = (YXLinuxShellError)pid;
        r.exitCode = -1;
        return r;
    }

    dispatch_time_t when = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    if (dispatch_semaphore_wait(sem, when) != 0) {
        // timeout: kill and fabricate a result
        [self killProcess:pid withSignal:SIGKILL_];
        YXLinuxShellResult *r = [[YXLinuxShellResult alloc] init];
        r.error = YXLinuxShellErrorTimeout;
        r.pid = pid;
        r.exitCode = -1;
        r.output = @"";
        r.errorOutput = @"";
        return r;
    }
    return result;
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signalNumber {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task != NULL)
        send_signal(task, signalNumber, info);
    unlock(&pids_lock);
    return task != NULL;
}

+ (void)cancelAll {
    NSArray<NSNumber *> *pids;
    @synchronized(YXActiveExecutions) {
        pids = YXActiveExecutions.allKeys;
    }
    for (NSNumber *pid in pids)
        [self killProcess:pid.intValue withSignal:SIGKILL_];
}

#pragma mark - Process exit

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    YXLinuxShellContext *ctx;
    @synchronized(YXActiveExecutions) {
        ctx = YXActiveExecutions[@(pid)];
        if (ctx == nil)
            return;
        [YXActiveExecutions removeObjectForKey:@(pid)];
    }
    if (ctx.isCompleted)
        return;
    ctx.isCompleted = YES;

    ctx.result.exitCode = exitCode;
    ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];

    // Finalize off the main thread: waiting for the readers to drain can take
    // up to 500ms and must never block UI.
    dispatch_async(YXReaderQueue, ^{
        // Wait (bounded) for readers to drain what's still in the pipes so no
        // output written right before exit is lost.
        dispatch_group_wait(ctx.readersGroup, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        ctx.forceDrain = YES;

        ctx.result.output = [ctx.stdoutBuffer copy];
        ctx.result.errorOutput = [ctx.stderrBuffer copy];
        ctx.result.truncated = ctx.result.output.length >= kYXMaxOutput
                            || ctx.result.errorOutput.length >= kYXMaxOutput;

        dispatch_async(dispatch_get_main_queue(), ^{
            [ctx cleanup];
            if (ctx.completion != nil)
                ctx.completion(ctx.result);
            if (ctx.waitSemaphore != nil)
                dispatch_semaphore_signal(ctx.waitSemaphore);
        });
    });
}

#pragma mark - Pipe reading

// 返回 data 前缀中「完整 UTF-8 序列」的字节长度。
// 多字节字符可能跨 read() 块边界，只有完整的部分才能交给 NSString 解码，
// 否则会触发 Latin-1 回退造成乱码。
static NSUInteger yx_complete_utf8_length(const uint8_t *bytes, NSUInteger length) {
    if (length == 0)
        return 0;
    NSUInteger i = length - 1;
    for (NSUInteger back = 0; back < 3 && i > 0; back++, i--) {
        uint8_t b = bytes[i];
        if (b < 0x80)
            return length;              // 尾部是 ASCII：全部完整
        if (b >= 0xC0) {                // 序列首字节
            NSUInteger need = (b >= 0xF0) ? 4 : (b >= 0xE0) ? 3 : 2;
            return (length - i >= need) ? length : i;
        }
        // 继续字节（0x80-0xBF）：继续向前找首字节
    }
    if (i == 0) {
        uint8_t b = bytes[0];
        if (b >= 0xC0) {
            NSUInteger need = (b >= 0xF0) ? 4 : (b >= 0xE0) ? 3 : 2;
            return (length >= need) ? length : 0;
        }
    }
    return length; // 连续 4+ 个继续字节：非法序列，交给回退路径处理
}

+ (void)readPipe:(int)fd context:(YXLinuxShellContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[8192];
    NSMutableData *pendingBytes = [NSMutableData data]; // 跨块的半截 UTF-8 序列
    NSMutableString *lineBuffer = [NSMutableString string];
    NSMutableString *outputBuffer = isStdErr ? ctx.stderrBuffer : ctx.stdoutBuffer;

    for (;;) {
        if (ctx.forceDrain)
            break;

        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int ready = poll(&pfd, 1, 200);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ready == 0)
            continue; // timeout: re-check forceDrain

        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            [pendingBytes appendBytes:buffer length:(NSUInteger)n];
            NSUInteger take = yx_complete_utf8_length(pendingBytes.bytes, pendingBytes.length);
            if (take == 0)
                continue; // 连一个完整字符都没凑齐，等下一块
            NSString *chunk = [[NSString alloc] initWithData:[pendingBytes subdataWithRange:NSMakeRange(0, take)]
                                                     encoding:NSUTF8StringEncoding];
            if (chunk == nil)
                chunk = [[NSString alloc] initWithData:[pendingBytes subdataWithRange:NSMakeRange(0, take)]
                                               encoding:NSISOLatin1StringEncoding];
            [pendingBytes replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
            [lineBuffer appendString:chunk];
            [self drainCompleteLines:lineBuffer outputBuffer:outputBuffer context:ctx isStdErr:isStdErr];
        } else if (n == 0) {
            break; // EOF: all write ends closed
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            break;
        }
    }

    // EOF：把残留的半个序列按 Latin-1 兜底解码，保证不丢字节
    if (pendingBytes.length > 0) {
        NSString *chunk = [[NSString alloc] initWithData:pendingBytes
                                                 encoding:NSUTF8StringEncoding];
        if (chunk == nil)
            chunk = [[NSString alloc] initWithData:pendingBytes
                                          encoding:NSISOLatin1StringEncoding];
        [lineBuffer appendString:chunk];
    }

    // flush any partial line
    if (lineBuffer.length > 0) {
        @synchronized(outputBuffer) {
            [self appendLine:lineBuffer toBuffer:outputBuffer];
        }
        if (ctx.lineCallback != nil) {
            NSString *line = [lineBuffer copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                ctx.lineCallback(line, isStdErr);
            });
        }
    }
}

+ (void)drainCompleteLines:(NSMutableString *)lineBuffer
              outputBuffer:(NSMutableString *)outputBuffer
                   context:(YXLinuxShellContext *)ctx
                    isStdErr:(BOOL)isStdErr {
    for (;;) {
        NSRange nl = [lineBuffer rangeOfString:@"\n"];
        if (nl.location == NSNotFound)
            break;
        NSString *line = [lineBuffer substringToIndex:nl.location];
        [lineBuffer deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
        @synchronized(outputBuffer) {
            [self appendLine:line toBuffer:outputBuffer];
        }
        if (ctx.lineCallback != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ctx.lineCallback(line, isStdErr);
            });
        }
    }
}

// Append with the 1 MiB cap; keeps the tail, prepends a marker once.
+ (void)appendLine:(NSString *)line toBuffer:(NSMutableString *)buffer {
    static NSString *const marker = @"\n…[输出超过 1 MiB，已截断，仅保留末尾部分]\n";
    if (buffer.length >= kYXMaxOutput) {
        NSRange keep = [buffer rangeOfString:marker options:NSBackwardsSearch];
        NSUInteger dropLen = line.length + 1;
        if (keep.location == NSNotFound) {
            // first truncation: drop half the buffer to amortize, then mark
            NSUInteger drop = buffer.length / 2;
            [buffer deleteCharactersInRange:NSMakeRange(0, drop)];
            [buffer insertString:marker atIndex:0];
        }
        if (buffer.length + dropLen > kYXMaxOutput) {
            NSUInteger drop = buffer.length + dropLen - kYXMaxOutput;
            [buffer deleteCharactersInRange:NSMakeRange(0, drop)];
        }
    }
    [buffer appendString:line];
    [buffer appendString:@"\n"];
}

@end
