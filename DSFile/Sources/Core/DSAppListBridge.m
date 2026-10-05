//
//  DSAppListBridge.m — LSApplicationWorkspace（私有）取已安装 App 列表
//
//  实现要点：
//    · LSApplicationWorkspace.defaultWorkspace → 依次尝试多个列表 selector，
//      **遇到空数组也继续试下一个**（真机 iOS 16.4.1 上就是 allInstalledApplications
//      返回空数组，导致以前"可用但没有 App"的假象 ✗）；
//    · 每个元素是 LSApplicationProxy，逐个取
//      applicationIdentifier（退 bundleIdentifier）/ localizedName（退 itemName）/
//      shortVersionString / bundleURL / dataContainerURL；
//    · 类不存在时逐个 dlopen 候选路径再找一次，**每个路径的成功/失败都记诊断**；
//    · 私有调用全部包在 @try/@catch 里，缺哪个字段就少哪个字段，绝不抛到调用方。
//    · ARC 下**不用** performSelector:（选择器未声明会有所有权告警）——
//      这里给私有类声明接口后直接发消息，内存管理交给 ARC。
//
//  这条路**不需要任何文件系统权限**，所以「还没激活」时也能给用户一份 App 列表。
//  列不出来时，+lastDiagnosticsText 会写清卡在哪一步（类找不到 / 哪个 dlopen 失败 /
//  哪个 selector 不响应 / 响应了但返回空数组 / 元素缺少标识字段）。
//

#import "DSAppListBridge.h"

#import <dlfcn.h>
#import <stdarg.h>

NSString * const DSAppListKeyBundleId   = @"bundleId";
NSString * const DSAppListKeyName       = @"name";
NSString * const DSAppListKeyVersion    = @"version";
NSString * const DSAppListKeyBundlePath = @"bundlePath";
NSString * const DSAppListKeyDataPath   = @"dataPath";

#pragma mark - 私有类声明（只声明消息签名，不链接私有框架）

@interface DSAppListProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;      // 旧系统上的等价字段
- (NSString *)localizedName;
- (NSString *)itemName;              // localizedName 的兜底
- (NSString *)shortVersionString;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
@end

@interface DSAppListWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
- (NSArray *)installedApplications;
- (NSArray *)allApplicationsWithAdditionalInfo;
@end

#pragma mark - 诊断收集

static NSString *gLastFailure = nil;
static NSMutableArray<NSString *> *gDiagnostics = nil;

static void ds_diag(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (line.length == 0) return;
    if (gDiagnostics == nil) gDiagnostics = [NSMutableArray array];
    [gDiagnostics addObject:line];
}

@implementation DSAppListBridge

+ (nullable NSString *)lastFailureReason
{
    return gLastFailure;
}

+ (NSArray<NSString *> *)lastDiagnostics
{
    return gDiagnostics ? [gDiagnostics copy] : @[];
}

+ (NSString *)lastDiagnosticsText
{
    if (gDiagnostics.count == 0) return @"[LS 诊断] （本次没有记录）";
    NSMutableString *out = [NSMutableString string];
    for (NSString *line in gDiagnostics) {
        [out appendFormat:@"[LS 诊断] %@\n", line];
    }
    return out;
}

+ (BOOL)available
{
    return [self ds_workspaceClass] != Nil;
}

/// 找 LSApplicationWorkspace：先看运行时有没有，再逐个 dlopen 候选路径。
+ (Class)ds_workspaceClass
{
    static Class cachedClass = Nil;
    static BOOL looked = NO;
    if (looked) return cachedClass;
    looked = YES;

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        ds_diag(@"NSClassFromString(LSApplicationWorkspace) → 命中（运行时已加载）");
        cachedClass = cls;
        return cls;
    }
    ds_diag(@"NSClassFromString(LSApplicationWorkspace) → 未命中，开始 dlopen 候选路径");

    static const char *candidates[] = {
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *handle = dlopen(candidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (handle == NULL) {
            const char *err = dlerror();
            ds_diag(@"dlopen %s → 失败（%s）", candidates[i], err ? err : "无错误信息");
            continue;
        }
        ds_diag(@"dlopen %s → 成功", candidates[i]);
        cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) {
            ds_diag(@"  └ 该路径下找到 LSApplicationWorkspace ✓");
            cachedClass = cls;
            return cls;
        }
        ds_diag(@"  └ 该路径下没有 LSApplicationWorkspace");
    }

    ds_diag(@"所有候选路径都没找到 LSApplicationWorkspace");
    return Nil;
}

+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)installedAppsFromLaunchServices
{
    gLastFailure = nil;
    gDiagnostics = [NSMutableArray array];

    Class workspaceClass = [self ds_workspaceClass];
    if (!workspaceClass) {
        gLastFailure = @"LSApplicationWorkspace 类不存在（私有框架未加载且所有 dlopen 候选都失败）";
        ds_diag(@"结论：类不存在 → 这条路不可用");
        return nil;
    }

    DSAppListWorkspace *workspace = nil;
    @try {
        if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
            ds_diag(@"defaultWorkspace → 不响应");
            gLastFailure = @"LSApplicationWorkspace 不响应 defaultWorkspace";
            return nil;
        }
        ds_diag(@"defaultWorkspace → 响应，调用中");
        workspace = [workspaceClass defaultWorkspace];
    } @catch (NSException *e) {
        gLastFailure = [NSString stringWithFormat:@"defaultWorkspace 抛异常：%@", e.reason];
        ds_diag(@"defaultWorkspace → 抛异常：%@", e.reason);
        return nil;
    }
    if (!workspace) {
        gLastFailure = @"defaultWorkspace 返回 nil";
        ds_diag(@"defaultWorkspace → 返回 nil");
        return nil;
    }
    ds_diag(@"defaultWorkspace → 拿到实例 %@", NSStringFromClass([workspace class]));

    // 依次尝试多个列表 selector：**空数组不算成功**，继续试下一个（iOS 16 真机教训）
    NSArray *proxies = nil;
    NSString *usedSelector = nil;
    BOOL sawEmptyArray = NO;

    // 只探测存在性、不调用：块签名不确定，猜签名有崩溃风险（本项目原则：不猜私有函数签名）
    if ([workspace respondsToSelector:NSSelectorFromString(@"enumerateInstalledApplications:")]) {
        ds_diag(@"enumerateInstalledApplications: → 存在（本实现不调用：块签名不确定，避免猜签名导致崩溃）");
    } else {
        ds_diag(@"enumerateInstalledApplications: → 不存在");
    }

    SEL selectors[] = {
        @selector(allInstalledApplications),
        @selector(allApplications),
        @selector(installedApplications),
        @selector(allApplicationsWithAdditionalInfo),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        NSString *name = NSStringFromSelector(sel);

        if (![workspace respondsToSelector:sel]) {
            ds_diag(@"%@ → 不响应（跳过）", name);
            continue;
        }

        NSArray *candidate = nil;
        @try {
            // 显式调用（不用 performSelector: —— ARC 下未知选择器会有所有权告警）
            if (sel == @selector(allInstalledApplications)) {
                candidate = [workspace allInstalledApplications];
            } else if (sel == @selector(allApplications)) {
                candidate = [workspace allApplications];
            } else if (sel == @selector(installedApplications)) {
                candidate = [workspace installedApplications];
            } else if (sel == @selector(allApplicationsWithAdditionalInfo)) {
                candidate = [workspace allApplicationsWithAdditionalInfo];
            }
        } @catch (NSException *e) {
            ds_diag(@"%@ → 抛异常：%@", name, e.reason);
            continue;
        }

        if (![candidate isKindOfClass:[NSArray class]]) {
            ds_diag(@"%@ → 返回值不是数组（%@）", name,
                    candidate ? NSStringFromClass([candidate class]) : @"nil");
            continue;
        }

        ds_diag(@"%@ → 返回数组，%lu 项", name, (unsigned long)candidate.count);
        if (candidate.count == 0) {
            sawEmptyArray = YES;
            continue;   // 空数组：继续试下一个 selector（这就是以前 iOS 16 上的坑）
        }
        proxies = candidate;
        usedSelector = name;
        break;
    }

    if (proxies == nil) {
        if (sawEmptyArray) {
            gLastFailure = @"LaunchServices 可用但所有列表接口都返回空数组"
                           @"（常见原因：本进程缺少 com.apple.private.mobileinstall.allowedSPI 权限；"
                           @"TrollStore 安装时应带 platform-application）";
            ds_diag(@"结论：所有 selector 都是空数组 → 列表为空");
        } else {
            gLastFailure = @"所有列表接口都不可用（不响应或返回值异常）";
            ds_diag(@"结论：没有可用的列表 selector");
        }
        return nil;
    }
    ds_diag(@"采用列表接口：%@", usedSelector);

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    NSInteger skipped = 0;
    NSInteger missingIdentifierField = 0;
    for (id item in proxies) {
        if (![item isKindOfClass:[NSObject class]]) continue;

        DSAppListProxy *proxy = (DSAppListProxy *)item;

        NSString *bundleId = [self ds_stringFrom:proxy selector:@selector(applicationIdentifier)];
        if (bundleId.length == 0) {
            bundleId = [self ds_stringFrom:proxy selector:@selector(bundleIdentifier)];
            if (bundleId.length > 0) missingIdentifierField++;
        }
        if (bundleId.length == 0) {
            skipped++;
            continue;
        }

        NSMutableDictionary<NSString *, NSString *> *entry = [NSMutableDictionary dictionary];
        entry[DSAppListKeyBundleId] = bundleId;

        NSString *name = [self ds_stringFrom:proxy selector:@selector(localizedName)];
        if (name.length == 0) name = [self ds_stringFrom:proxy selector:@selector(itemName)];
        if (name.length > 0) entry[DSAppListKeyName] = name;

        NSString *version = [self ds_stringFrom:proxy selector:@selector(shortVersionString)];
        if (version.length > 0) entry[DSAppListKeyVersion] = version;

        NSString *bundlePath = [self ds_pathFrom:proxy selector:@selector(bundleURL)];
        if (bundlePath.length > 0) entry[DSAppListKeyBundlePath] = bundlePath;

        NSString *dataPath = [self ds_pathFrom:proxy selector:@selector(dataContainerURL)];
        if (dataPath.length > 0) entry[DSAppListKeyDataPath] = dataPath;

        [out addObject:entry];
    }

    ds_diag(@"解析完成：%lu 条可用，跳过 %ld 条（缺标识字段），其中 %ld 条用了 bundleIdentifier 兜底",
            (unsigned long)out.count, (long)skipped, (long)missingIdentifierField);

    if (out.count == 0) {
        gLastFailure = [NSString stringWithFormat:
            @"LaunchServices 返回了 %lu 个对象，但都取不到标识字段（applicationIdentifier/bundleIdentifier 都不响应）",
            (unsigned long)proxies.count];
    }

    return out;
}

#pragma mark - 逐字段取值（每一步都容错）

+ (nullable NSString *)ds_stringFrom:(id)object selector:(SEL)selector
{
    if (![object respondsToSelector:selector]) return nil;
    @try {
        NSString *value = nil;
        if (selector == @selector(applicationIdentifier)) {
            value = [(DSAppListProxy *)object applicationIdentifier];
        } else if (selector == @selector(bundleIdentifier)) {
            value = [(DSAppListProxy *)object bundleIdentifier];
        } else if (selector == @selector(localizedName)) {
            value = [(DSAppListProxy *)object localizedName];
        } else if (selector == @selector(itemName)) {
            value = [(DSAppListProxy *)object itemName];
        } else if (selector == @selector(shortVersionString)) {
            value = [(DSAppListProxy *)object shortVersionString];
        } else {
            return nil;
        }
        if ([value isKindOfClass:[NSString class]] && value.length > 0) return value;
        return nil;
    } @catch (NSException *e) {
        return nil;
    }
}

+ (nullable NSString *)ds_pathFrom:(id)object selector:(SEL)selector
{
    if (![object respondsToSelector:selector]) return nil;
    @try {
        NSURL *url = nil;
        if (selector == @selector(bundleURL)) {
            url = [(DSAppListProxy *)object bundleURL];
        } else if (selector == @selector(dataContainerURL)) {
            url = [(DSAppListProxy *)object dataContainerURL];
        } else {
            return nil;
        }
        if ([url isKindOfClass:[NSURL class]]) {
            NSString *path = url.path;
            if (path.length > 0) return path;
        }
        return nil;
    } @catch (NSException *e) {
        return nil;
    }
}

@end
