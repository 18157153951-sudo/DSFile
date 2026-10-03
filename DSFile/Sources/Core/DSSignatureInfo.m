//
//  DSSignatureInfo.m — 只读诊断：本 App 的签名标识（CodeDirectory identifier）
//
//  只用两类"签名确定"的接口：
//    1) csops(2)  —— 内核 syscall，取原始标识字符串；
//    2) Security.framework 的 SecTaskCreateFromSelf / SecTaskCopyValueForEntitlement
//       （函数签名稳定，用 dlsym 取，取不到就跳过）。
//  其它私有接口一律不碰 —— 猜函数签名是崩溃来源，本文件绝不冒这个风险。
//  任何一步失败都只是"拿不到"，绝不影响激活流程。
//

#import "DSSignatureInfo.h"

#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

NSString * const DSSignatureExpectedIdentifier = @"com.apple.mobile.MobileHouseArrest";

/// XNU bsd/sys/codesign.h 的操作码。只用来"读一个原始字符串"：
/// 拿到什么就原样打进日志，拿不到就如实说拿不到，不做推断。
#define DS_CS_OPS_SIGNING_ID 8
#define DS_CS_OPS_IDENTITY   11

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#pragma mark - csops

static NSString *ds_csops_raw(unsigned int op)
{
    char buf[1024];
    memset(buf, 0, sizeof(buf));
    int r = csops(getpid(), op, buf, sizeof(buf) - 1);
    if (r != 0) return nil;

    // 只接受"纯可见 ASCII"的结果；否则视为取不到（避免把二进制塞进日志）
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < sizeof(buf) && buf[i] != 0; i++) {
        unsigned char c = (unsigned char)buf[i];
        if (c >= 0x20 && c < 0x7f) {
            [s appendFormat:@"%c", c];
        } else {
            return nil;
        }
    }
    return s.length ? s : nil;
}

#pragma mark - Security.framework（只用签名稳定的两个函数）

typedef struct __SecTask *DSSecTaskRef;
typedef DSSecTaskRef (*DSCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*DSCopyValueForEntitlementFn)(DSSecTaskRef, CFStringRef, CFErrorRef *);

static NSString *ds_entitlement_string(NSString *name)
{
    void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    if (h == NULL) return nil;

    DSCreateFromSelfFn create = (DSCreateFromSelfFn)dlsym(h, "SecTaskCreateFromSelf");
    DSCopyValueForEntitlementFn copyValue =
        (DSCopyValueForEntitlementFn)dlsym(h, "SecTaskCopyValueForEntitlement");
    if (create == NULL || copyValue == NULL) return nil;

    DSSecTaskRef task = NULL;
    @try {
        task = create(kCFAllocatorDefault);
    } @catch (__unused NSException *e) {
        task = NULL;
    }
    if (task == NULL) return nil;

    NSString *result = nil;
    @try {
        CFTypeRef value = copyValue(task, (__bridge CFStringRef)name, NULL);
        if (value != NULL) {
            id obj = CFBridgingRelease(value);
            if ([obj isKindOfClass:NSString.class]) {
                result = obj;
            } else if ([obj isKindOfClass:NSArray.class] && [obj count] > 0) {
                result = [obj componentsJoinedByString:@","];
            }
        }
    } @catch (__unused NSException *e) {
        result = nil;
    }
    CFRelease(task);
    return result;
}

#pragma mark - 取标识

/// 去掉 TeamID 前缀：`ABCDE12345.com.foo.bar` → `com.foo.bar`
static NSString *ds_strip_team_prefix(NSString *applicationIdentifier)
{
    if (applicationIdentifier.length == 0) return nil;
    NSRange dot = [applicationIdentifier rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location + 1 >= applicationIdentifier.length) return nil;
    return [applicationIdentifier substringFromIndex:dot.location + 1];
}

static BOOL ds_looks_like_identifier(NSString *s)
{
    if (s.length < 3 || s.length > 200) return NO;
    if ([s rangeOfString:@" "].location != NSNotFound) return NO;
    return [s rangeOfString:@"."].location != NSNotFound;
}

NSString *DSSignatureIdentifier(void)
{
    static NSString *cached = nil;
    static BOOL done = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *candidate = nil;

        // 1) csops 原始标识（两个候选操作码都试，谁像标识就用谁）
        for (unsigned int op = 0; op < 2 && candidate == nil; op++) {
            unsigned int code = (op == 0) ? DS_CS_OPS_SIGNING_ID : DS_CS_OPS_IDENTITY;
            NSString *raw = ds_csops_raw(code);
            if (ds_looks_like_identifier(raw)) candidate = raw;
        }

        // 2) application-identifier（去掉 TeamID 前缀后即 bundle 标识）
        if (candidate == nil) {
            NSString *appID = ds_entitlement_string(@"application-identifier");
            NSString *stripped = ds_strip_team_prefix(appID);
            if (ds_looks_like_identifier(stripped)) candidate = stripped;
        }

        cached = candidate;
        done = YES;
    });
    (void)done;
    return cached;
}

NSInteger DSSignatureIdentifierMatchesMHA(void)
{
    NSString *identifier = DSSignatureIdentifier();
    if (identifier.length == 0) return -1;   // 无法判断
    return [identifier isEqualToString:DSSignatureExpectedIdentifier] ? 1 : 0;
}

#pragma mark - 报告

NSString *DSSignatureSummaryLine(void)
{
    NSString *identifier = DSSignatureIdentifier();
    NSInteger match = DSSignatureIdentifierMatchesMHA();

    NSString *verdict = @"无法判断";
    if (match == 1) verdict = @"匹配 ✓";
    else if (match == 0) verdict = @"不匹配 ✗";

    NSString *shown = identifier.length ? identifier : @"(读取不到)";
    return [NSString stringWithFormat:@"[MHA 诊断] 签名 identifier = %@（期望 %@）→ %@",
            shown, DSSignatureExpectedIdentifier, verdict];
}

NSString *DSSignatureDiagnosticReport(void)
{
    NSMutableString *out = [NSMutableString string];
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";

    NSString *rawSigningID = ds_csops_raw(DS_CS_OPS_SIGNING_ID);
    NSString *rawIdentity  = ds_csops_raw(DS_CS_OPS_IDENTITY);
    NSString *applicationIdentifier = ds_entitlement_string(@"application-identifier");
    NSString *teamIdentifier = ds_entitlement_string(@"com.apple.developer.team-identifier");
    NSString *identifier = DSSignatureIdentifier();
    NSInteger match = DSSignatureIdentifierMatchesMHA();

    [out appendFormat:@"[MHA 诊断] bundle id = %@；签名 identifier = %@（期望 %@）→ %@\n",
        bundleID,
        identifier.length ? identifier : @"(读取不到)",
        DSSignatureExpectedIdentifier,
        (match == 1 ? @"匹配 ✓" : (match == 0 ? @"不匹配 ✗" : @"无法判断"))];
    [out appendFormat:@"[MHA 诊断] TeamIdentifier = %@；application-identifier = %@\n",
        teamIdentifier.length ? teamIdentifier : @"(读取不到)",
        applicationIdentifier.length ? applicationIdentifier : @"(读取不到)"];
    [out appendFormat:@"[MHA 诊断] csops 原始值：signingID = %@；identity = %@\n",
        rawSigningID.length ? rawSigningID : @"(取不到)",
        rawIdentity.length ? rawIdentity : @"(取不到)"];

    if (match == 0) {
        [out appendString:
            @"[MHA 诊断] 结论：签名 identifier 不是 MHA —— MCM 只会给你自己的容器、"
            @"特权沙盒 profile 也不会下发。请在签名工具里把 Bundle ID / Signing Identifier 设为 "
            @"com.apple.mobile.MobileHouseArrest，且**不要使用「自动生成 Bundle ID」**。\n"];
    } else if (match < 0) {
        [out appendString:
            @"[MHA 诊断] 结论：读不到签名 identifier（不作为激活依据）—— "
            @"请用「是否只能枚举到自己的容器 + 写探针是否失败」来判断身份是否生效，"
            @"并确认签名工具没有改写 Bundle ID、也没有用「自动生成」。\n"];
    }

    return out;
}
