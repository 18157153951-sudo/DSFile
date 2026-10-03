//
//  DSKernel.m — 注入版（dylib）的 POSIX 实现，**不含任何内核代码**
//
//  设计要点：
//   1. 「有没有沙盒外访问」不靠标志位，靠真实探测：列容器根目录 + 往 /var/mobile 写探针；
//   2. 探测结果缓存 5 秒（宿主进程权限不会频繁变化，但也不能永久缓存）；
//   3. setOwner / setMode 走 POSIX；失败只记日志、返回 NO，绝不抛异常、绝不阻塞；
//   4. activate 直接返回「已可用」——注入版运行在已经有权限的宿主进程里，不需要内核漏洞。
//

#import "DSKernel.h"

#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <dirent.h>

#pragma mark - 探测

static const NSTimeInterval kProbeCacheSeconds = 5.0;
static BOOL      gProbeCached = NO;
static BOOL      gProbeValue  = NO;
static NSDate   *gProbeAt     = nil;

/// 能列出一个容器根目录 → 说明宿主进程确实有沙盒外读权限
static BOOL ds_can_list_container_roots(void)
{
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Library",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSArray *names = [fm contentsOfDirectoryAtPath:root error:NULL];
        if (names.count > 0) return YES;
    }
    return NO;
}

/// 往沙盒外写一个探针文件（写完立刻删）
static BOOL ds_can_write_outside(void)
{
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/.myfilza_inject_probe",
        @"/var/tmp/.myfilza_inject_probe",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        NSData *payload = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];
        if ([fm createFileAtPath:path contents:payload attributes:nil]) {
            [fm removeItemAtPath:path error:NULL];
            return YES;
        }
    }
    return NO;
}

static BOOL ds_has_outside_access_now(void)
{
    return ds_can_list_container_roots() || ds_can_write_outside();
}

static BOOL ds_has_outside_access_cached(void)
{
    @synchronized (DSKernel.class) {
        if (gProbeCached && gProbeAt && -[gProbeAt timeIntervalSinceNow] < kProbeCacheSeconds) {
            return gProbeValue;
        }
        BOOL value = ds_has_outside_access_now();
        gProbeCached = YES;
        gProbeValue  = value;
        gProbeAt     = [NSDate date];
        return value;
    }
}

#pragma mark - 递归改属主

static void ds_chown_recursive(NSString *path, uid_t uid, gid_t gid)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return;

    if (lchown(path.fileSystemRepresentation, uid, gid) != 0) {
        NSLog(@"[MyfilzaReplace] lchown 失败 %@: %s", path, strerror(errno));
    }
    if (!isDir) return;

    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:NULL];
    for (NSString *child in children) {
        ds_chown_recursive([path stringByAppendingPathComponent:child], uid, gid);
    }
}

#pragma mark - DSKernel

@implementation DSKernel

#pragma mark 设备 / 系统

+ (NSString *)deviceModelIdentifier
{
    struct utsname uts;
    if (uname(&uts) != 0) return @"未知机型";
    return [NSString stringWithUTF8String:uts.machine] ?: @"未知机型";
}

+ (NSString *)systemVersion
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.patchVersion > 0) {
        return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    }
    return [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
}

+ (NSString *)cpuFamilyName
{
    int family = 0;
    size_t size = sizeof(family);
    if (sysctlbyname("hw.cpufamily", &family, &size, NULL, 0) != 0) return @"未知芯片";
    return [NSString stringWithFormat:@"CPU family 0x%x", family];
}

+ (BOOL)isSystemVersionSupported
{
    // 注入版不跑内核漏洞，因此没有「系统版本不支持」这回事；能不能用只看宿主有没有权限。
    return YES;
}

+ (NSString *)supportSummary
{
    return [NSString stringWithFormat:@"注入模式（%@ / iOS %@）：不跑内核漏洞，直接使用宿主进程已有的文件访问权限",
            [self deviceModelIdentifier], [self systemVersion]];
}

#pragma mark 运行时状态

+ (BOOL)isEscaped
{
    return ds_has_outside_access_cached();
}

+ (BOOL)isExploitDone
{
    // 注入版没有内核读写；这里与 isEscaped 同义，让向导/文件操作里的前置检查通过。
    return ds_has_outside_access_cached();
}

+ (BOOL)isRunningAsRoot
{
    return getuid() == 0;
}

+ (BOOL)probeFilesystemAccess
{
    // 强制现场探测（不吃缓存）
    @synchronized (DSKernel.class) {
        gProbeCached = NO;
        gProbeAt = nil;
    }
    return ds_has_outside_access_now();
}

+ (unsigned long long)kernelBase
{
    return 0;   // 注入版没有内核读写
}

+ (NSString *)diagnosticsText
{
    BOOL canRead  = ds_can_list_container_roots();
    BOOL canWrite = ds_can_write_outside();
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"模式: 注入版（dylib，无内核漏洞）\n"];
    [text appendFormat:@"机型: %@\n", [self deviceModelIdentifier]];
    [text appendFormat:@"系统: iOS %@\n", [self systemVersion]];
    [text appendFormat:@"芯片: %@\n", [self cpuFamilyName]];
    [text appendFormat:@"进程 uid: %u\n", (unsigned)getuid()];
    [text appendFormat:@"可读容器目录: %@\n", canRead ? @"是" : @"否"];
    [text appendFormat:@"可写沙盒外: %@\n", canWrite ? @"是" : @"否"];
    [text appendFormat:@"内核读写: 不适用（注入版不执行内核漏洞）\n"];
    [text appendFormat:@"宿主 Home: %@\n", NSHomeDirectory()];
    return text;
}

#pragma mark 激活

+ (DSKernelResult)activateWithLog:(DSKernelLogBlock)log
{
    BOOL access = ds_has_outside_access_now();
    if (log) {
        log([NSString stringWithFormat:@"[注入版] 不需要内核漏洞：宿主进程访问权限 = %@", access ? @"已具备" : @"不具备"]);
        if (!access) {
            log(@"[注入版] 宿主没有沙盒外访问权限：请确认宿主 App（3105）本身能正常浏览其它 App 的数据，或改用带内核漏洞的模式。");
        }
    }
    return access ? DSKernelResultAlreadyActive : DSKernelResultEscapeFailed;
}

+ (DSKernelResult)retrySandboxEscapeWithLog:(DSKernelLogBlock)log
{
    return [self activateWithLog:log];
}

+ (DSKernelResult)elevateToRootWithLog:(DSKernelLogBlock)log
{
    if (log) {
        log(@"[注入版] 提权不可用：注入版没有内核读写，只能使用宿主进程本身的身份（通常 uid=501）。");
    }
    return DSKernelResultUnsupportedSystem;
}

#pragma mark 文件属性

+ (BOOL)setOwnerOfPath:(NSString *)path uid:(uid_t)uid gid:(gid_t)gid recursive:(BOOL)recursive
{
    if (path.length == 0) return NO;
    if (recursive) {
        ds_chown_recursive(path, uid, gid);
        return YES;
    }
    if (lchown(path.fileSystemRepresentation, uid, gid) == 0) return YES;
    NSLog(@"[MyfilzaReplace] lchown 失败 %@: %s", path, strerror(errno));
    return NO;
}

+ (BOOL)setModeOfPath:(NSString *)path mode:(mode_t)mode
{
    if (path.length == 0) return NO;
    if (chmod(path.fileSystemRepresentation, mode) == 0) return YES;
    NSLog(@"[MyfilzaReplace] chmod 失败 %@: %s", path, strerror(errno));
    return NO;
}

@end
