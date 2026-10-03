//
//  DSAppListBridge.m — LSApplicationWorkspace（私有）取已安装 App 列表
//
//  实现要点（照 3105 在 iOS 18 上的做法，见 DSAppListBridge.h 顶部说明）：
//    · LSApplicationWorkspace.defaultWorkspace → allInstalledApplications
//      （取不到时退回 allApplications）；
//    · 每个元素是 LSApplicationProxy，逐个取
//      applicationIdentifier / localizedName / shortVersionString /
//      bundleURL / dataContainerURL；
//    · 类不存在时先尝试 dlopen CoreServices / MobileCoreServices 再找一次；
//    · 私有调用全部包在 @try/@catch 里，缺哪个字段就少哪个字段，绝不抛到调用方。
//    · ARC 下**不用** performSelector:（选择器未声明会有所有权告警）——
//      这里给私有类声明接口后直接发消息，内存管理交给 ARC。
//
//  这条路**不需要任何文件系统权限**，所以「还没激活」时也能给用户一份 App 列表。
//

#import "DSAppListBridge.h"

#import <dlfcn.h>

NSString * const DSAppListKeyBundleId   = @"bundleId";
NSString * const DSAppListKeyName       = @"name";
NSString * const DSAppListKeyVersion    = @"version";
NSString * const DSAppListKeyBundlePath = @"bundlePath";
NSString * const DSAppListKeyDataPath   = @"dataPath";

#pragma mark - 私有类声明（只声明消息签名，不链接私有框架）

@interface DSAppListProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)shortVersionString;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
@end

@interface DSAppListWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end

#pragma mark -

static NSString *gLastFailure = nil;

@implementation DSAppListBridge

+ (nullable NSString *)lastFailureReason
{
    return gLastFailure;
}

+ (BOOL)available
{
    return [self ds_workspaceClass] != Nil;
}

/// 找 LSApplicationWorkspace：先看运行时有没有，再试着 dlopen 两个可能的位置。
+ (Class)ds_workspaceClass
{
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) return cls;

    static const char *candidates[] = {
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *handle = dlopen(candidates[i], RTLD_NOW | RTLD_GLOBAL);
        if (!handle) continue;
        cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) return cls;
    }
    return Nil;
}

+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)installedAppsFromLaunchServices
{
    gLastFailure = nil;

    Class workspaceClass = [self ds_workspaceClass];
    if (!workspaceClass) {
        gLastFailure = @"LSApplicationWorkspace 类不存在（私有框架未加载且 dlopen 失败）";
        return nil;
    }

    DSAppListWorkspace *workspace = nil;
    @try {
        workspace = [workspaceClass defaultWorkspace];
    } @catch (NSException *e) {
        gLastFailure = [NSString stringWithFormat:@"defaultWorkspace 抛异常：%@", e.reason];
        return nil;
    }
    if (!workspace) {
        gLastFailure = @"defaultWorkspace 返回 nil";
        return nil;
    }

    NSArray *proxies = nil;
    @try {
        if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
            proxies = [workspace allInstalledApplications];
        }
    } @catch (NSException *e) {
        gLastFailure = [NSString stringWithFormat:@"allInstalledApplications 抛异常：%@", e.reason];
    }
    if (![proxies isKindOfClass:[NSArray class]]) {
        @try {
            if ([workspace respondsToSelector:@selector(allApplications)]) {
                proxies = [workspace allApplications];
            }
        } @catch (NSException *e) {
            if (gLastFailure.length == 0) {
                gLastFailure = [NSString stringWithFormat:@"allApplications 抛异常：%@", e.reason];
            }
        }
    }
    if (![proxies isKindOfClass:[NSArray class]]) {
        if (gLastFailure.length == 0) gLastFailure = @"两个列表接口都拿不到数组";
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    for (id item in proxies) {
        if (![item isKindOfClass:[NSObject class]]) continue;

        DSAppListProxy *proxy = (DSAppListProxy *)item;

        NSString *bundleId = [self ds_stringFrom:proxy selector:@selector(applicationIdentifier)];
        if (bundleId.length == 0) continue;

        NSMutableDictionary<NSString *, NSString *> *entry = [NSMutableDictionary dictionary];
        entry[DSAppListKeyBundleId] = bundleId;

        NSString *name = [self ds_stringFrom:proxy selector:@selector(localizedName)];
        if (name.length > 0) entry[DSAppListKeyName] = name;

        NSString *version = [self ds_stringFrom:proxy selector:@selector(shortVersionString)];
        if (version.length > 0) entry[DSAppListKeyVersion] = version;

        NSString *bundlePath = [self ds_pathFrom:proxy selector:@selector(bundleURL)];
        if (bundlePath.length > 0) entry[DSAppListKeyBundlePath] = bundlePath;

        NSString *dataPath = [self ds_pathFrom:proxy selector:@selector(dataContainerURL)];
        if (dataPath.length > 0) entry[DSAppListKeyDataPath] = dataPath;

        [out addObject:entry];
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
        } else if (selector == @selector(localizedName)) {
            value = [(DSAppListProxy *)object localizedName];
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
