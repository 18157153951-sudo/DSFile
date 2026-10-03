//
//  DSMHAKernel.m — 「MHA 身份（零内核）」路径的实现
//
//  只做两件事（都由上游 PoC 原文定义，不掺推断）：
//    · 用 DSMCMBridge 枚举「App 数据容器（class 2）」与「App Group（class 7）」的标识，
//      逐个取租约并激活（拿到可读可写的沙盒扩展）；
//    · 用**真实探针**（列目录 + 写盘）验证到底有没有权限，绝不"自报成功"。
//
//  不做：不跑 kexploit、不读内核内存、不调用 proc_self/sandbox_escape。
//

#import "DSMHAKernel.h"
#import "DSMCMBridge.h"

#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>

NSString * const DSMHABundleIdentifier = @"com.apple.mobile.MobileHouseArrest";

/// 枚举上限（有界，避免在大设备上扫太久）
static const NSUInteger kMHAEnumLimitAppData = 1024;
static const NSUInteger kMHAEnumLimitAppGroup = 256;

/// 已激活的租约：**必须持有**（container_object_free 会撤销扩展）
static NSMutableArray<DSMCMLease *> *gMHALeases = nil;
static NSString *gMHALastStage = @"未开始";
static NSUInteger gMHAActivatedCount = 0;

NSString *DSMHALastStage(void) { return gMHALastStage; }
NSUInteger DSMHAActivatedLeaseCount(void) { return gMHAActivatedCount; }

static void mha_stage(NSString *stage)
{
    gMHALastStage = stage;
}

BOOL DSMHAIsHost(void)
{
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:DSMHABundleIdentifier];
}

#pragma mark - 探针（只认真实结果）

/// 写盘探针：沙盒外路径写得进去才算有权限
static BOOL mha_probe_write(NSString **where)
{
    const char *paths[] = {
        "/var/mobile/.myfilza_mha_probe",
        "/var/tmp/.myfilza_mha_probe"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
            unlink(paths[i]);
            if (where) *where = [NSString stringWithUTF8String:paths[i]];
            return YES;
        }
    }
    if (where) *where = [NSString stringWithFormat:@"%s (errno=%d)", paths[0], errno];
    return NO;
}

/// 读探针：能不能列出一个容器的根目录
static BOOL mha_probe_read_directory(NSString *path, NSUInteger *countOut)
{
    NSError *error = nil;
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path
                                                                                   error:&error];
    if (items == nil) return NO;
    if (countOut) *countOut = items.count;
    return YES;
}

#pragma mark - 激活

/// 为一个标识取租约并激活；成功则**持有**（存进 gMHALeases）
static BOOL mha_activate_identifier(NSString *identifier, uint64_t cls, NSString **errorOut)
{
    NSError *leaseError = nil;
    NSString *error = nil;
    DSMCMLease *lease = [DSMCMLease leaseForClass:cls
                                        identifier:identifier
                                             group:(cls == DSMCMClassAppGroup)
                                              part:0
                                             flags:DSMCMFlagsAppData
                                             error:&error];
    if (lease == nil) {
        if (errorOut) *errorOut = error ?: @"取租约失败";
        return NO;
    }
    NSString *activationError = nil;
    if (![lease activate:&activationError]) {
        if (errorOut) *errorOut = activationError ?: @"激活失败";
        return NO;
    }
    (void)leaseError;
    if (gMHALeases == nil) gMHALeases = [NSMutableArray array];
    [gMHALeases addObject:lease];        // 持有 → 扩展保持有效
    gMHAActivatedCount = gMHALeases.count;
    return YES;
}

int DSMHAKernelActivate(NSString **detail)
{
    if (!DSMHAIsHost()) {
        mha_stage(@"身份不匹配");
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"当前 bundle id 是 %@，不是 %@。MHA 路径要求：签名时的 Bundle ID 与 "
                        "CodeDirectory identifier 都是 com.apple.mobile.MobileHouseArrest"
                        "（用 myfilza-mha.ipa，或在 eSign 里把 Bundle ID 指定为该值，且不要让它被改写）。",
                       NSBundle.mainBundle.bundleIdentifier ?: @"(nil)", DSMHABundleIdentifier];
        }
        return 1020;
    }

    if (!DSMCMBridgeAvailable()) {
        mha_stage(@"MCM 桥不可用");
        if (detail) *detail = [NSString stringWithFormat:@"ContainerManager 桥不可用，缺符号：%@",
                               DSMCMMissingSymbols()];
        return 1021;
    }

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"自身 bundle id = %@；MCM 桥可用 ✓\n", NSBundle.mainBundle.bundleIdentifier];

    // ---- 枚举：仅元数据、不申请扩展（这样"没权限"也能列出 App）----
    mha_stage(@"枚举容器标识");
    NSString *enumError = nil;
    NSArray<NSString *> *dataIdentifiers =
        DSMCMEnumerateIdentifiersForClass(DSMCMClassAppData, kMHAEnumLimitAppData, &enumError);
    [report appendFormat:@"枚举 class 2（App 数据容器）：%lu 个标识%@\n",
        (unsigned long)dataIdentifiers.count,
        enumError.length ? [NSString stringWithFormat:@"（%@）", enumError] : @""];

    enumError = nil;
    NSArray<NSString *> *groupIdentifiers =
        DSMCMEnumerateIdentifiersForClass(DSMCMClassAppGroup, kMHAEnumLimitAppGroup, &enumError);
    [report appendFormat:@"枚举 class 7（App Group）：%lu 个标识%@\n",
        (unsigned long)groupIdentifiers.count,
        enumError.length ? [NSString stringWithFormat:@"（%@）", enumError] : @""];

    // ---- 逐个取租约并激活（持有！）----
    mha_stage(@"取租约并激活");
    NSUInteger okData = 0, failData = 0;
    NSMutableArray<NSString *> *firstFailures = [NSMutableArray array];
    for (NSString *identifier in dataIdentifiers) {
        NSString *error = nil;
        if (mha_activate_identifier(identifier, DSMCMClassAppData, &error)) {
            okData++;
        } else {
            failData++;
            if (firstFailures.count < 5)
                [firstFailures addObject:[NSString stringWithFormat:@"%@ → %@", identifier, error]];
        }
    }
    NSUInteger okGroup = 0, failGroup = 0;
    for (NSString *identifier in groupIdentifiers) {
        NSString *error = nil;
        if (mha_activate_identifier(identifier, DSMCMClassAppGroup, &error)) {
            okGroup++;
        } else {
            failGroup++;
            if (firstFailures.count < 5)
                [firstFailures addObject:[NSString stringWithFormat:@"group %@ → %@", identifier, error]];
        }
    }
    [report appendFormat:@"激活租约：class2 成功 %lu / 失败 %lu；class7 成功 %lu / 失败 %lu；"
                         @"当前持有 %lu 条租约\n",
        (unsigned long)okData, (unsigned long)failData,
        (unsigned long)okGroup, (unsigned long)failGroup,
        (unsigned long)DSMHAActivatedLeaseCount()];
    if (firstFailures.count) {
        [report appendFormat:@"前几个失败样本：\n  - %@\n", [firstFailures componentsJoinedByString:@"\n  - "]];
    }

    if (DSMHAActivatedLeaseCount() == 0) {
        mha_stage(@"没有任何容器租约被激活");
        if (detail) *detail = report;
        return 1022;
    }

    // ---- 真实探针：读一个租约的容器根 + 写沙盒外路径 ----
    mha_stage(@"读写探针");
    DSMCMLease *sample = gMHALeases.firstObject;
    NSUInteger itemCount = 0;
    BOOL readOK = mha_probe_read_directory(sample.rootPath, &itemCount);
    [report appendFormat:@"读探针：%@（%@）→ %@（%lu 项）\n",
        sample.identifier, sample.rootPath, readOK ? @"成功" : @"失败", (unsigned long)itemCount];

    NSString *writeWhere = nil;
    BOOL writeOK = mha_probe_write(&writeWhere);
    [report appendFormat:@"写探针：%@ → %@\n", writeWhere ?: @"(未知)", writeOK ? @"成功" : @"失败"];

    if (!writeOK && !readOK) {
        mha_stage(@"探针全部失败");
        if (detail) *detail = report;
        return 1023;
    }

    mha_stage(@"完成");
    [report appendString:@"MHA 路径完成：容器租约已激活并持有，普通文件 API 可直接读写这些容器。"];
    if (detail) *detail = report;
    return 0;
}

BOOL DSMHAKernelEnsureAccessForPath(NSString *path)
{
    if (path.length == 0) return NO;
    // 已经能读就返回 YES（不重复折腾）
    if (access(path.fileSystemRepresentation, R_OK) == 0) return YES;

    NSString *detail = nil;
    (void)DSMHAKernelActivate(&detail);

    if (access(path.fileSystemRepresentation, R_OK) == 0) return YES;
    // 再按容器根匹配一次：租约是按「容器根」生效的，子路径应当随之可读
    for (DSMCMLease *lease in gMHALeases) {
        if ([path hasPrefix:lease.rootPath] &&
            access(path.fileSystemRepresentation, R_OK) == 0) {
            return YES;
        }
    }
    return NO;
}
