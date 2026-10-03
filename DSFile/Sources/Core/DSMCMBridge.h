//
//  DSMCMBridge.h — MobileContainerManager 容器租约桥（纯用户态）
//
//  来源（逐条照抄其请求序列，**不猜**）：
//    · 0xjohnnydev/MobileHouseArrest-PoC（README + poc.m）
//        —— MobileContainerManager 把调用方的 **CodeDirectory identifier** 当授权键：
//           签成 com.apple.mobile.MobileHouseArrest 的 App 可以查询**别的 App 的容器**，
//           拿到「可读可写」的沙盒扩展。
//           请求序列：query_create → set_class(2) → set_ids(<bundle id>) →
//                     set_flags(0x900000000) → [set_part(0) 若有] → get_single_result →
//                     object != NULL && activate(object, false)
//           class 2 = App 数据容器；class 7 = App Group；class 13 = MobileGestalt（**18.x 不支持**）。
//           注意：`container_object_free` 会**撤销**扩展 → 必须持有对象才能持续访问。
//    · 0xjohnnydev/FilzaSlop（MCMBridge.h/MCMBridge.m）
//        —— 生产版实现：符号表、枚举接口、租约生命周期管理。
//
//  本文件只做「取令牌 + 激活 + 枚举」，**不碰内核、不碰 kexploit**。
//  库：/usr/lib/system/libsystem_containermanager.dylib（全部用 dlopen/dlsym，不直接链接私有库）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 容器 class 与 flags（取自 PoC 原文，勿改）
FOUNDATION_EXPORT const uint64_t DSMCMClassAppData;    // 2  —— App 数据容器
FOUNDATION_EXPORT const uint64_t DSMCMClassAppGroup;   // 7  —— App Group
FOUNDATION_EXPORT const uint64_t DSMCMFlagsAppData;    // 0x900000000
FOUNDATION_EXPORT const uint64_t DSMCMFlagsEnumerate;  // 0x100000000（仅元数据、不创建）

typedef void (^DSMCMLogBlock)(NSString *message);

/// 日志回调（注入 App 的日志系统；不设则用 NSLog）
FOUNDATION_EXPORT void DSMCMBridgeSetLog(DSMCMLogBlock _Nullable log);

/// 必需符号是否齐全（缺符号时为 NO，用 DSMCMMissingSymbols 看缺什么）
FOUNDATION_EXPORT BOOL DSMCMBridgeAvailable(void);
FOUNDATION_EXPORT NSString *DSMCMMissingSymbols(void);

/// 枚举某个 class 下的**容器标识**（App 数据容器时为 bundle id）。
/// flags 用 DSMCMFlagsEnumerate（仅元数据，不需要任何权限，解决"没权限时怎么列出 App"）。
FOUNDATION_EXPORT NSArray<NSString *> *DSMCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit, NSString *_Nullable *_Nullable error);

/// 一条容器租约：持有它，沙盒扩展就保持激活（**不要提前释放**）。
@interface DSMCMLease : NSObject

@property (nonatomic, readonly) uint64_t containerClass;
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *rootPath;   // 已把 /var 规范成 /private/var
@property (nonatomic, readonly) BOOL tokenPresent;          // MCM 返回了非空令牌
@property (nonatomic, readonly) BOOL activated;              // sandbox_extension 已激活

+ (nullable instancetype)leaseForClass:(uint64_t)containerClass
                            identifier:(NSString *)identifier
                                 group:(BOOL)group
                                  part:(uint64_t)part
                                 flags:(uint64_t)flags
                                 error:(NSString *_Nullable *_Nullable)error;

/// 取令牌并激活（幂等）。激活后普通 POSIX/Foundation 文件 API 即可读写该容器。
- (BOOL)activate:(NSString *_Nullable *_Nullable)error;

/// 主动撤销（会释放对象 → 扩展随之失效）
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
