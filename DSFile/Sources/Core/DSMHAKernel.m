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
#import "DSSignatureInfo.h"

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
/// 其中 class 2（App 数据容器）的条数：只有 1 条（=自己）说明签名 identifier 不是 MHA
static NSUInteger gMHAAppDataCount = 0;

NSString *DSMHALastStage(void) { return gMHALastStage; }
NSUInteger DSMHAActivatedLeaseCount(void) { return gMHAActivatedCount; }
NSUInteger DSMHAAppDataLeaseCount(void) { return gMHAAppDataCount; }

NSInteger DSMHASignatureIsMHA(void) { return DSSignatureIdentifierMatchesMHA(); }

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

/// 真实权限探针：在**别人**的租约容器根里写一个临时文件再删掉。
/// 注意：**必须跳过自己的容器**（自己的容器本来就可写，拿它当判据会自报成功）。
/// 只有租约（沙盒扩展）确实生效、且拿到的是别人的容器时才会返回 YES。
BOOL DSMHAAccessProbePasses(void)
{
    NSString *ownIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    for (DSMCMLease *lease in gMHALeases) {
        if (lease.rootPath.length == 0) continue;
        if (lease.containerClass == DSMCMClassAppData &&
            [lease.identifier isEqualToString:ownIdentifier]) {
            continue;   // 自己的容器：不作为判据
        }
        NSString *probe = [lease.rootPath stringByAppendingPathComponent:@".myfilza_mha_lease_probe"];
        const char *p = probe.fileSystemRepresentation;
        int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
            unlink(p);
            return YES;
        }
    }
    return NO;
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
    if (cls == DSMCMClassAppData) gMHAAppDataCount++;
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
                        "（用 myfilza-mha.ipa，或在 eSign 里把 Bundle ID 指定为该值，且不要让它被改写）。\n%@",
                       NSBundle.mainBundle.bundleIdentifier ?: @"(nil)", DSMHABundleIdentifier,
                       DSSignatureDiagnosticReport()];
        }
        return 1020;
    }

    // 签名 identifier 门槛（必须做）：
    //   MCM 的授权键是**签名里的 CodeDirectory identifier**（上游 MobileHouseArrest-PoC 原文）。
    //   它如果不是 MHA，MCM 只会给"自己的容器"、特权 profile 也不会下发 ——
    //   此时尝试毫无意义，直接如实失败（避免像 0.7.3 那样"持有租约就自报成功"）。
    //   读不到签名信息（-1）时不拦，交给下面的**严格探针**判定，绝不猜。
    NSInteger sigMatch = DSSignatureIdentifierMatchesMHA();
    if (sigMatch == 0) {
        mha_stage(@"签名 identifier 不是 MHA");
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"签名 identifier 不是 %@（MCM 只认签名里的 CodeDirectory identifier，"
                        "所以拿不到别的 App 容器、特权 profile 也不会下发）。\n%@",
                       DSMHABundleIdentifier, DSSignatureDiagnosticReport()];
        }
        return 1024;
    }

    if (!DSMCMBridgeAvailable()) {
        mha_stage(@"MCM 桥不可用");
        if (detail) *detail = [NSString stringWithFormat:@"ContainerManager 桥不可用，缺符号：%@\n%@",
                               DSMCMMissingSymbols(), DSSignatureDiagnosticReport()];
        return 1021;
    }

    NSMutableString *report = [NSMutableString string];
    // 签名标识诊断放在最前面：MCM 的授权键是签名里的 CodeDirectory identifier，
    // 它是不是 MHA，直接决定了下面"能枚举到几个容器""写探针能不能过"。
    [report appendString:DSSignatureDiagnosticReport()];
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

    // 成功判据（收紧，绝不"自报成功"）：
    //   · 写沙盒外探针成功（= 特权 profile 真的下发了），**或**
    //   · 成功激活了 **多于 1 个** App 数据容器（= 真的能看到别人的容器）。
    //   只持有租约、只读到自己那一个容器，都**不算**成功。
    BOOL sawOtherAppContainers = (okData > 1);
    [report appendFormat:@"判定：写沙盒外探针=%@；成功激活的 App 数据容器=%lu 个（>1 才算看到别人的容器）\n",
        writeOK ? @"通过" : @"未通过", (unsigned long)okData];
    (void)readOK;

    if (!writeOK && !sawOtherAppContainers) {
        mha_stage(@"权限不足（没拿到别人的容器）");
        // 经验判据：只拿到自己一个数据容器 + 沙盒外写失败 ⇒ 身份没生效（签名 identifier 不是 MHA）。
        // 依据：上游 MobileHouseArrest-PoC 原文 —— MCM 把调用方的 CodeDirectory identifier 当授权键。
        if (okData <= 1) {
            [report appendString:
                @"结论（经验判据）：只能枚举到 1 个 App 数据容器（=自己）+ 沙盒外写探针失败 —— "
                @"这正是「签名 identifier 不是 MHA」的指纹（MCM 只给你自己的容器，特权 profile 未下发）。"
                @"请把签名工具里的 Bundle ID / Signing Identifier 设为 com.apple.mobile.MobileHouseArrest，"
                @"并确认没有使用「自动生成 Bundle ID」。\n"];
        }
        if (detail) *detail = report;
        return 1023;
    }

    mha_stage(@"完成");
    [report appendString:@"MHA 路径完成：沙盒扩展已生效，可直接读写这些容器。\n"];
    [report appendString:DSSignatureSummaryLine()];
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
