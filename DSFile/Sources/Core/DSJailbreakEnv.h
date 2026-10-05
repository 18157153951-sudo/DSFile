//
//  DSJailbreakEnv.h — 「越狱模式」：不跑任何漏洞，直接用越狱环境给的 POSIX 权限
//
//  为什么需要它（真机依据）：
//    在 roothide 上，**TrollStore 安装的 App 仍然受沙盒限制** —— roothide 的设计目标
//    就是「对 App 隐藏越狱」，普通 App 拿不到越狱权限；只有通过 Sileo / Zebra 装进
//    越狱根（<jbroot>/Applications/）的**越狱 App**（带 platform-application、无沙盒）
//    才能读写全盘。所以本模式做的事只有一件：**如实判断本进程到底有没有权限**，
//    并把「为什么没有」写清楚，绝不假装成功、也绝不偷偷去跑内核漏洞。
//
//  jbroot 解析（按 roothide / rootless 的实际做法，逐条尝试、每条都记结果）：
//    ① getenv("JBROOT") / getenv("ROOTHIDE")；
//    ② **本 App 自己容器内的 `.jbroot-*` 标记** —— roothide 就是靠它让沙盒内的 App
//       找到越狱根（沙盒内看不到真正的越狱目录，只看得见自己容器里的标记）；
//    ③ /var/mobile/Library/roothide（roothide 存在的标志）+ 可见的 `.jbroot-*`；
//    ④ /var/jb（rootless：Dopamine / palera1n rootless）。
//
//  设计原则（与全项目一致）：
//    · 只读、只诊断；失败干净返回并写明阶段与原因；
//    · 只用公开 POSIX 接口 + 签名确定的 Security 接口，不猜任何私有函数签名。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析出的越狱根（best effort）。没有越狱特征时返回 nil。
FOUNDATION_EXPORT NSString * _Nullable DSJailbreakRootPath(void);

/// jbroot 解析的逐条尝试与结果（多行，直接写日志 / 设置页展示）
FOUNDATION_EXPORT NSString *DSJailbreakRootResolutionReport(void);

/// 本 App 自己 entitlements 的逐条诊断（多行）。这是判断
/// 「权限没给」还是「roothide 沙盒在拦」的决定性依据。
FOUNDATION_EXPORT NSString *DSJailbreakEntitlementReport(void);

/// 单行摘要，形如：
///   越狱模式：roothide · jbroot=<路径或(未解析到)> · 可读=是/否 · 可写=是/否
FOUNDATION_EXPORT NSString *DSJailbreakEnvironmentSummaryLine(void);

/// 有没有越狱 / TrollStore 特征（**不需要任何文件系统权限**就能判断：
/// 签名里的 TROLLTROLL 标记 + 环境变量 + 越狱库 + 路径痕迹）。
/// 自动模式用它决定「要不要先试越狱模式」。
FOUNDATION_EXPORT BOOL DSJailbreakLooksJailbroken(void);

/// 越狱模式的激活入口：**完全不执行任何漏洞**，只做
/// 「解析 jbroot → 逐路径 errno 探针 → 如实给结论」。
///
/// 返回码：
///   0    = 已具备沙盒外访问（能写最好；只读可达也算，界面会标注「只读可达」）
///   1030 = 有越狱 / TrollStore 特征，但本进程仍被沙盒拦（**权限没给**）
///   1031 = 没有检测到越狱特征（这不是越狱环境）
FOUNDATION_EXPORT int DSJailbreakActivate(NSString *_Nullable *_Nullable detail);

/// 最近一次执行到哪个阶段（失败时用于定位）
FOUNDATION_EXPORT NSString *DSJailbreakLastStage(void);

NS_ASSUME_NONNULL_END
