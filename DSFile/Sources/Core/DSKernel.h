//
//  DSKernel.h — Swift 与 DarkSword 逃逸/内核读写之间的唯一桥梁
//
//  设计原则：
//  1. 内核漏洞只在用户主动点「激活」时执行一次，重复执行会被拦下（二次利用极易 panic）；
//  2. 漏洞成功但沙盒改写失败时，允许只重试沙盒改写这一步，不重跑漏洞；
//  3. 所有能力都有自检（探针写文件 + getuid），不做「装作成功」。
//

#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSKernelResult) {
    DSKernelResultOK                =  0,
    DSKernelResultAlreadyActive     =  1,
    DSKernelResultUnsupportedSystem = -1,
    DSKernelResultExploitFailed     = -2,
    DSKernelResultEscapeFailed      = -3,
    DSKernelResultBusy              = -4,
    DSKernelResultInternalError     = -5,
};

typedef void (^DSKernelLogBlock)(NSString *line);

@interface DSKernel : NSObject

#pragma mark - 设备 / 系统

/// 机型标识，例如 iPhone15,2
+ (NSString *)deviceModelIdentifier NS_SWIFT_NAME(deviceModelIdentifier());
/// 系统版本，例如 18.5
+ (NSString *)systemVersion NS_SWIFT_NAME(systemVersion());
/// 芯片家族名，例如 A15 / A17 / M2；未知返回 CPU family 十六进制
+ (NSString *)cpuFamilyName NS_SWIFT_NAME(cpuFamilyName());
/// DarkSword 覆盖面：17.0 <= 版本 < 26.1
+ (BOOL)isSystemVersionSupported NS_SWIFT_NAME(isSystemVersionSupported());
/// 供设置页直接展示的一句话结论
+ (NSString *)supportSummary NS_SWIFT_NAME(supportSummary());

#pragma mark - 运行时状态

/// 本次进程是否已经逃逸成功（每次 App 冷启动都会重置）
+ (BOOL)isEscaped NS_SWIFT_NAME(isEscaped());
/// 内核漏洞（KRW）是否已经在本进程里拿到
+ (BOOL)isExploitDone NS_SWIFT_NAME(isExploitDone());
/// 当前是否 uid=0
+ (BOOL)isRunningAsRoot NS_SWIFT_NAME(isRunningAsRoot());
/// 不依赖缓存，现场做一次探针写盘
+ (BOOL)probeFilesystemAccess NS_SWIFT_NAME(probeFilesystemAccess());

#pragma mark - 统一访问判定（0.9.5）
//
//  isEscaped 只是「内核逃逸标志」，它**不能**代表"现在能不能操作沙盒外文件"：
//  越狱 App（.deb 装进 <jbroot>/Applications/）、MHA/MCM 租约（26/27 零内核）、
//  TrollStore 带 platform-application 的只读可达 —— 这些路径都不经过内核逃逸，
//  用 isEscaped() 当门槛会把已经具备权限的用户误拦（0.9.4 真机就是这个问题）。
//
//  所以凡是"能否读写沙盒外"的语义，一律走下面这个统一入口。

/// 统一入口：本进程**现在**能不能操作沙盒外文件。判据全部基于真实探针（不看标志位）：
///   ① 现场写沙盒外成功（内核逃逸 / 越狱 App 直写）；
///   ② MHA/MCM 容器租约真的生效（零内核）；
///   ③ TrollStore 安装且沙盒外**只读**可达；
///   ④ 越狱环境且沙盒外**只读**可达。
+ (BOOL)hasFileSystemAccess NS_SWIFT_NAME(hasFileSystemAccess());

/// 人话版诊断（越狱类型 / 本次生效路径 / 内核逃逸 / 沙盒外探针 + `/var/mobile` 的真实 errno）。
/// 失败提示里直接带上它，用户一次上报就能定位，不用来回猜。
+ (NSString *)fileSystemAccessDiagnosis NS_SWIFT_NAME(fileSystemAccessDiagnosis());
/// 内核基址（0 表示还没拿到）
+ (unsigned long long)kernelBase NS_SWIFT_NAME(kernelBase());
/// 本次进程**实际走通**的是哪条路，例如「MHA · 零内核」/「内核 + cred 逃逸（FilzaJailedDS）」；
/// 还没成功时返回 nil。界面上用它标注当前生效的路径。
+ (nullable NSString *)activePathDescription NS_SWIFT_NAME(activePathDescription());
/// 现场把关键诊断信息打成文本，方便用户回传日志
+ (NSString *)diagnosticsText NS_SWIFT_NAME(diagnosticsText());

#pragma mark - 激活

/// 执行内核漏洞 + 沙盒改写（同步、可能耗时数秒，切勿在主线程调用）
+ (DSKernelResult)activateWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(activate(log:));
/// 只重试沙盒改写（漏洞已成功时可用）
+ (DSKernelResult)retrySandboxEscapeWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(retrySandboxEscape(log:));
/// 提权到 uid=0（把本进程 ucred 的 posix_cred uid/gid 改成 0），失败不影响已获得的沙盒逃逸
+ (DSKernelResult)elevateToRootWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(elevateToRoot(log:));

#pragma mark - 内核级文件属性

/// 直接改内核里的 apfs_fsnode，绕过 DAC（root 拥有的文件也能改成 mobile）
+ (BOOL)setOwnerOfPath:(NSString *)path
                   uid:(uid_t)uid
                   gid:(gid_t)gid
             recursive:(BOOL)recursive NS_SWIFT_NAME(setOwner(path:uid:gid:recursive:));
/// 同上，改模式位
+ (BOOL)setModeOfPath:(NSString *)path mode:(mode_t)mode NS_SWIFT_NAME(setMode(path:mode:));

@end

NS_ASSUME_NONNULL_END
