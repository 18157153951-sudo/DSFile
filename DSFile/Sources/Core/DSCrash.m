//
//  DSCrash.m
//

#import "DSCrash.h"

#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <time.h>
#import <limits.h>
#import <sys/stat.h>

static char gCrashDirectory[PATH_MAX] = {0};

static const int gHandledSignals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
static const int gHandledSignalCount = 6;

static const char *ds_signal_name(int sig)
{
    switch (sig) {
        case SIGSEGV: return "SIGSEGV 段错误（多半是内核内存读写把本进程搞挂了）";
        case SIGBUS:  return "SIGBUS 总线错误";
        case SIGABRT: return "SIGABRT 主动中止（断言/异常）";
        case SIGILL:  return "SIGILL 非法指令";
        case SIGTRAP: return "SIGTRAP 断点陷阱";
        case SIGFPE:  return "SIGFPE 算术异常";
        default:      return "未知信号";
    }
}

static void ds_write_all(int fd, const char *text)
{
    if (!text) return;
    size_t length = strlen(text);
    size_t written = 0;
    while (written < length) {
        ssize_t n = write(fd, text + written, length - written);
        if (n <= 0) break;
        written += (size_t)n;
    }
}

/// 信号处理器里只能干最保守的事：open / write / backtrace_symbols_fd
static void ds_signal_handler(int sig)
{
    if (gCrashDirectory[0] != 0) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/crash-%ld.log", gCrashDirectory, (long)time(NULL));

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            char header[512];
            int n = snprintf(header, sizeof(header),
                             "=== myfilza 崩溃报告 ===\n"
                             "时间戳: %ld\n"
                             "信号: %s (%d)\n"
                             "回溯:\n",
                             (long)time(NULL), ds_signal_name(sig), sig);
            if (n > 0) ds_write_all(fd, header);

            void *frames[96];
            int count = backtrace(frames, 96);
            if (count > 0) backtrace_symbols_fd(frames, count, fd);

            ds_write_all(fd, "\n提示：同目录下 session-*.log 是崩溃前的完整会话日志（同步落盘，尾巴不会丢）。\n");
            close(fd);
        }
    }

    // 恢复默认处理再抛一次，保持系统原本的崩溃行为（也方便系统生成 .ips）
    signal(sig, SIG_DFL);
    raise(sig);
}

static void ds_exception_handler(NSException *exception)
{
    // 未捕获 ObjC 异常发生在正常上下文里，可以放心用 Foundation
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"=== myfilza 未捕获异常 ===\n"];
    [text appendFormat:@"名称: %@\n", exception.name];
    [text appendFormat:@"原因: %@\n", exception.reason];
    [text appendString:@"调用栈:\n"];
    [text appendString:[exception.callStackSymbols componentsJoinedByString:@"\n"]];
    [text appendString:@"\n"];

    NSString *directory = [DSCrash crashReportDirectory];
    if (directory) {
        NSString *path = [directory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"crash-exception-%ld.log", (long)time(NULL)]];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSLog(@"[DSCrash] 未捕获异常：%@", text);
}

@implementation DSCrash

+ (void)install
{
    NSString *directory = [self crashReportDirectory];
    if (directory) {
        strlcpy(gCrashDirectory, directory.fileSystemRepresentation, sizeof(gCrashDirectory));
    }

    // 我们的 stdout 捕获管道如果对端关掉，SIGPIPE 会把 App 直接打死，这里忽略掉
    signal(SIGPIPE, SIG_IGN);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = ds_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;

    for (int i = 0; i < gHandledSignalCount; i++) {
        sigaction(gHandledSignals[i], &action, NULL);
    }

    NSSetUncaughtExceptionHandler(&ds_exception_handler);

    NSLog(@"[DSCrash] 崩溃记录已启用，目录：%@", directory ?: @"(不可用)");
}

+ (NSString *)crashReportDirectory
{
    NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (documents.count == 0) return nil;
    NSString *directory = [documents.firstObject stringByAppendingPathComponent:@"Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return directory;
}

+ (NSString *)latestCrashReportPath
{
    NSString *directory = [self crashReportDirectory];
    if (!directory) return nil;

    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    NSString *latest = nil;
    NSDate *latestDate = [NSDate distantPast];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:@"crash-"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!latest || [date compare:latestDate] == NSOrderedDescending) {
            latest = path;
            latestDate = date;
        }
    }
    return latest;
}

@end
