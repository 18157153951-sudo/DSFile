//
//  DSMCMBridge.m — MobileContainerManager 容器租约桥（纯用户态）
//
//  实现按上游两份权威代码逐条照抄（见 DSMCMBridge.h 顶部注释里的来源）：
//    · MobileHouseArrest-PoC：请求序列与 class/flags 取值
//    · FilzaSlop/MCMBridge.m：符号表、枚举接口、租约生命周期
//  只做重命名与日志接入，**逻辑不改**。
//

#import "DSMCMBridge.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <xpc/xpc.h>

const uint64_t DSMCMClassAppData = 2;                  // PoC: app-data container
const uint64_t DSMCMClassAppGroup = 7;                 // PoC: app-group container
const uint64_t DSMCMFlagsAppData = UINT64_C(0x900000000);
const uint64_t DSMCMFlagsEnumerate = UINT64_C(0x100000000);   // metadata-only, no-create

#pragma mark - 符号表

typedef void *(*MCMQueryCreate)(void);
typedef void (*MCMQuerySetU64)(void *, uint64_t);
typedef void (*MCMQuerySetXPC)(void *, xpc_object_t);
typedef void (*MCMQuerySetCString)(void *, const char *);
typedef void *(*MCMQueryGetPointer)(void *);
typedef bool (*MCMQueryIterate)(void *, bool (^)(void *));
typedef void (*MCMQueryFree)(void *);
typedef const char *(*MCMObjectGetPath)(void *);
typedef const char *(*MCMObjectGetIdentifier)(void *);
typedef void *(*MCMObjectCopy)(void *);
typedef char *(*MCMObjectCopyToken)(void *);
typedef bool (*MCMObjectActivate)(void *, bool);
typedef void (*MCMObjectFree)(void *);
typedef int (*MCMErrorGetInt)(void *);
typedef const char *(*MCMErrorGetString)(void *);

typedef struct {
    void *handle;
    MCMQueryCreate queryCreate;
    MCMQuerySetU64 querySetClass;
    MCMQuerySetXPC querySetIdentifiers;
    MCMQuerySetXPC querySetGroupIdentifiers;
    MCMQuerySetU64 querySetFlags;
    MCMQuerySetU64 querySetPart;
    MCMQuerySetCString querySetPartDomain;
    MCMQueryGetPointer queryGetSingle;
    MCMQueryGetPointer queryGetLastError;
    MCMQueryIterate queryIterate;
    MCMQueryFree queryFree;
    MCMObjectGetPath objectGetPath;
    MCMObjectGetIdentifier objectGetIdentifier;
    MCMObjectCopy objectCopy;
    MCMObjectCopyToken objectCopyToken;
    MCMObjectActivate objectActivate;
    MCMObjectFree objectFree;
    MCMErrorGetInt errorGetPOSIX;
    MCMErrorGetString errorGetMessage;
} DSMCMAPI;

static DSMCMLogBlock gDSMCMLog = nil;

void DSMCMBridgeSetLog(DSMCMLogBlock log)
{
    gDSMCMLog = [log copy];
}

static void dsmcm_log(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    if (gDSMCMLog) gDSMCMLog(message);
    else NSLog(@"[MCM] %@", message);
}

static DSMCMAPI *DSMCMSharedAPI(void)
{
    static DSMCMAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                            RTLD_NOW | RTLD_LOCAL);
        void *handle = api.handle != NULL ? api.handle : RTLD_DEFAULT;
        dsmcm_log(@"dlopen libsystem_containermanager: %s", api.handle ? "ok" : dlerror());
#define DSMCM_LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        DSMCM_LOAD(queryCreate, "container_query_create");
        DSMCM_LOAD(querySetClass, "container_query_set_class");
        DSMCM_LOAD(querySetIdentifiers, "container_query_set_identifiers");
        DSMCM_LOAD(querySetGroupIdentifiers, "container_query_set_group_identifiers");
        DSMCM_LOAD(querySetFlags, "container_query_operation_set_flags");
        DSMCM_LOAD(querySetPart, "container_query_operation_set_part");
        DSMCM_LOAD(querySetPartDomain, "container_query_operation_set_part_domain");
        DSMCM_LOAD(queryGetSingle, "container_query_get_single_result");
        DSMCM_LOAD(queryGetLastError, "container_query_get_last_error");
        DSMCM_LOAD(queryIterate, "container_query_iterate_results_sync");
        DSMCM_LOAD(queryFree, "container_query_free");
        DSMCM_LOAD(objectGetPath, "container_object_get_path");
        DSMCM_LOAD(objectGetIdentifier, "container_object_get_identifier");
        DSMCM_LOAD(objectCopy, "container_object_copy");
        DSMCM_LOAD(objectCopyToken, "container_copy_sandbox_token");
        DSMCM_LOAD(objectActivate, "container_object_sandbox_extension_activate");
        DSMCM_LOAD(objectFree, "container_object_free");
        DSMCM_LOAD(errorGetPOSIX, "container_error_get_posix_errno");
        DSMCM_LOAD(errorGetMessage, "container_error_get_message");
#undef DSMCM_LOAD
    });
    return &api;
}

/// 逐个列出必需符号，缺哪个一目了然（诊断用）
NSString *DSMCMMissingSymbols(void)
{
    DSMCMAPI *api = DSMCMSharedAPI();
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
#define DSMCM_CHECK(field, name) if (api->field == NULL) [missing addObject:@name]
    DSMCM_CHECK(queryCreate, @"container_query_create");
    DSMCM_CHECK(querySetClass, @"container_query_set_class");
    DSMCM_CHECK(querySetIdentifiers, @"container_query_set_identifiers");
    DSMCM_CHECK(querySetGroupIdentifiers, @"container_query_set_group_identifiers");
    DSMCM_CHECK(querySetFlags, @"container_query_operation_set_flags");
    DSMCM_CHECK(queryGetSingle, @"container_query_get_single_result");
    DSMCM_CHECK(queryGetLastError, @"container_query_get_last_error");
    DSMCM_CHECK(queryFree, @"container_query_free");
    DSMCM_CHECK(objectGetPath, @"container_object_get_path");
    DSMCM_CHECK(objectCopy, @"container_object_copy");
    DSMCM_CHECK(objectCopyToken, @"container_copy_sandbox_token");
    DSMCM_CHECK(objectActivate, @"container_object_sandbox_extension_activate");
    DSMCM_CHECK(objectFree, @"container_object_free");
#undef DSMCM_CHECK
    if (api->queryIterate == NULL) [missing addObject:@"container_query_iterate_results_sync(枚举用)"];
    if (api->objectGetIdentifier == NULL) [missing addObject:@"container_object_get_identifier(枚举用)"];
    return missing.count ? [missing componentsJoinedByString:@", "] : @"（无，符号齐全）";
}

BOOL DSMCMBridgeAvailable(void)
{
    DSMCMAPI *api = DSMCMSharedAPI();
    // 与 FilzaSlop 的判定一致；part / part_domain / error_* 为可选（iOS 18 上可能没有 part 系列）
    return api->queryCreate != NULL && api->querySetClass != NULL &&
           api->querySetIdentifiers != NULL && api->querySetGroupIdentifiers != NULL &&
           api->querySetFlags != NULL &&
           api->queryGetSingle != NULL && api->queryGetLastError != NULL &&
           api->queryFree != NULL && api->objectGetPath != NULL &&
           api->objectCopy != NULL && api->objectCopyToken != NULL &&
           api->objectActivate != NULL && api->objectFree != NULL;
}

/// 从 query 上取「最后一次错误」的可读描述
static NSString *DSMCMQueryErrorString(void *query)
{
    DSMCMAPI *api = DSMCMSharedAPI();
    if (query == NULL || api->queryGetLastError == NULL) return @"（无错误详情）";
    void *queryError = api->queryGetLastError(query);
    if (queryError == NULL) return @"（无错误对象）";
    int posix = api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
    const char *message = api->errorGetMessage ? api->errorGetMessage(queryError) : NULL;
    return [NSString stringWithFormat:@"posix=%d message=%s", posix, message ?: "unknown"];
}

#pragma mark - 枚举

NSArray<NSString *> *DSMCMEnumerateIdentifiersForClass(uint64_t containerClass,
                                                       NSUInteger limit,
                                                       NSString **error)
{
    DSMCMAPI *api = DSMCMSharedAPI();
    if (!DSMCMBridgeAvailable() || api->queryIterate == NULL || api->objectGetIdentifier == NULL) {
        if (error) *error = [NSString stringWithFormat:@"枚举接口不可用（缺符号：%@）", DSMCMMissingSymbols()];
        return @[];
    }
    if (limit == 0) {
        if (error) *error = @"limit 为 0";
        return @[];
    }
    void *query = api->queryCreate();
    if (query == NULL) {
        if (error) *error = @"container_query_create 返回 NULL";
        return @[];
    }
    api->querySetClass(query, containerClass);
    // 仅元数据、不创建：枚举阶段**不申请任何扩展**
    api->querySetFlags(query, DSMCMFlagsEnumerate);
    // iOS 18 没有 part API；新 query 默认就是 part 0，所以只在符号存在时才设置
    if (api->querySetPart) api->querySetPart(query, 0);

    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    BOOL iterated = api->queryIterate(query, ^bool(void *object) {
        const char *raw = object ? api->objectGetIdentifier(object) : NULL;
        NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (identifier.length) [identifiers addObject:identifier];
        return identifiers.count < limit;
    });
    if (!iterated && identifiers.count < limit) {
        if (error) *error = [NSString stringWithFormat:@"枚举被拒：%@", DSMCMQueryErrorString(query)];
    }
    api->queryFree(query);
    dsmcm_log(@"枚举 class=%llu → %lu 个标识%@", (unsigned long long)containerClass,
              (unsigned long)identifiers.count,
              (error && *error) ? [NSString stringWithFormat:@"（%@）", *error] : @"");
    return identifiers.array;
}

#pragma mark - 租约

@interface DSMCMLease () {
    void *_query;        // 保留 query：activate 时再取一次结果对象
    void *_activation;   // 保留 container_object：**它活着扩展才有效**（free 即撤销）
}
@property (nonatomic, readwrite) uint64_t containerClass;
@property (nonatomic, readwrite, copy) NSString *identifier;
@property (nonatomic, readwrite, copy) NSString *rootPath;
@property (nonatomic, readwrite) BOOL tokenPresent;
@property (nonatomic, readwrite) BOOL activated;
@end

@implementation DSMCMLease

+ (instancetype)leaseForClass:(uint64_t)containerClass
                   identifier:(NSString *)identifier
                        group:(BOOL)group
                         part:(uint64_t)part
                        flags:(uint64_t)flags
                        error:(NSString **)error
{
    if (!DSMCMBridgeAvailable() || identifier.length == 0) {
        if (error) *error = [NSString stringWithFormat:@"MCM 桥不可用或标识为空（缺符号：%@）", DSMCMMissingSymbols()];
        return nil;
    }
    DSMCMAPI *api = DSMCMSharedAPI();
    void *query = api->queryCreate();
    if (query == NULL) {
        if (error) *error = @"container_query_create 返回 NULL";
        return nil;
    }
    api->querySetClass(query, containerClass);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group) api->querySetGroupIdentifiers(query, value);
    else api->querySetIdentifiers(query, value);
    api->querySetFlags(query, flags);
    if (part != 0 && api->querySetPart == NULL) {
        if (error) *error = @"part API 在本系统上不可用";
        api->queryFree(query);
        return nil;
    }
    if (api->querySetPart) api->querySetPart(query, part);

    void *object = api->queryGetSingle(query);
    if (object == NULL) {
        if (error) *error = [NSString stringWithFormat:@"查询被拒：%@", DSMCMQueryErrorString(query)];
        api->queryFree(query);
        return nil;
    }
    const char *rawPath = api->objectGetPath(object);
    NSString *root = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if (root.length == 0 || !root.isAbsolutePath) {
        if (error) *error = @"MCM 未返回绝对路径";
        api->queryFree(query);
        return nil;
    }
    // /var → /private/var（PoC 的同款规范化）
    if ([root isEqualToString:@"/var"] || [root hasPrefix:@"/var/"])
        root = [@"/private" stringByAppendingString:root];

    DSMCMLease *lease = [DSMCMLease new];
    lease->_query = query;
    lease.containerClass = containerClass;
    lease.identifier = identifier;
    lease.rootPath = root;
    return lease;
}

- (BOOL)activate:(NSString **)error
{
    if (self.activated) return YES;
    if (_query == NULL) {
        if (error) *error = @"租约已失效";
        return NO;
    }
    DSMCMAPI *api = DSMCMSharedAPI();
    void *object = api->queryGetSingle(_query);
    if (object == NULL) {
        if (error) *error = [NSString stringWithFormat:@"激活时查询失败：%@", DSMCMQueryErrorString(_query)];
        return NO;
    }
    _activation = api->objectCopy(object);           // 必须持有一份，扩展才持续有效
    char *token = _activation ? api->objectCopyToken(_activation) : NULL;
    NSUInteger tokenLength = (token != NULL) ? strlen(token) : 0;
    self.tokenPresent = (tokenLength > 0);
    if (token) free(token);
    self.activated = self.tokenPresent && api->objectActivate(_activation, false);
    if (!self.activated && error) {
        *error = self.tokenPresent ? @"sandbox extension 激活失败"
                                   : @"MCM 对象里没有沙盒令牌";
    }
    return self.activated;
}

- (void)invalidate
{
    DSMCMAPI *api = DSMCMSharedAPI();
    if (_activation) { api->objectFree(_activation); _activation = NULL; }
    if (_query) { api->queryFree(_query); _query = NULL; }
    self.activated = NO;
}

- (void)dealloc
{
    [self invalidate];
}

@end
