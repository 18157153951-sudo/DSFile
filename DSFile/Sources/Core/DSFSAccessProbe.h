//
//  DSFSAccessProbe.h — 沙盒外文件访问的「逐路径 + 真实 errno」探针
//
//  为什么要有它：
//    以前只有一个笼统的「沙盒外读写探针」（成功/失败），真机上出现「没能正常获取权限」
//    时无法判断到底卡在哪 —— 是沙盒拒绝（EPERM）、权限不足（EACCES）、路径不存在
//    （ENOENT），还是只是某个特定目录不可达。
//    这里把每个关键路径、每种操作的结果与 errno 全部记下来，一次上报即可定位。
//
//  设计原则：
//    · 只用公开 POSIX 接口（opendir/readdir/open/unlink），不碰任何私有 API；
//    · 只读为主，写探针会立刻删除自己创建的文件；
//    · 不缓存（调用方自己缓存），失败不抛异常、不阻塞。
//
//  errno 速查（真机排查用）：
//    EPERM(1)  = 沙盒拒绝（本进程没有该路径的沙盒例外）
//    EACCES(13)= 权限不足（沙盒放行但属主/权限位不允许）
//    ENOENT(2) = 路径不存在（该越狱环境没有这个目录）
//    EROFS(30) = 只读文件系统（SSV / 系统卷）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSFSAccessProbeResult : NSObject

/// 被探测的路径
@property (nonatomic, copy, readonly) NSString *path;
/// 操作名：列目录 / 写探针
@property (nonatomic, copy, readonly) NSString *operation;
/// 是否成功
@property (nonatomic, readonly) BOOL ok;
/// 失败时的 errno（成功时为 0）
@property (nonatomic, readonly) int errnoValue;
/// errno 的可读名字，例如 EPERM(沙盒拒绝)；成功时为 "-"
@property (nonatomic, copy, readonly) NSString *errnoName;
/// 列目录成功时的条目数（其它操作为 -1）
@property (nonatomic, readonly) NSInteger itemCount;
/// 一行摘要，形如：列目录 /var/mobile → 失败 errno=1 EPERM(沙盒拒绝)
@property (nonatomic, copy, readonly) NSString *line;

@end

/// 逐路径探测结果（每次调用都现场跑一遍，顺序固定）
FOUNDATION_EXPORT NSArray<DSFSAccessProbeResult *> *DSFilesystemProbeResults(void);

/// 多行报告（每行一条结果），用于写日志 / 诊断导出
FOUNDATION_EXPORT NSString *DSFilesystemAccessReport(void);

/// 单行摘要，形如：可写=否 可读=否（uid 501）
FOUNDATION_EXPORT NSString *DSFilesystemAccessSummaryLine(void);

/// 关键路径里有没有「能列目录」的（/var/mobile 或数据容器根 / 包体根）
FOUNDATION_EXPORT BOOL DSFilesystemProbeReadable(void);

/// 能不能在沙盒外建文件（/var/mobile 或 /var/tmp 试写后删除）
FOUNDATION_EXPORT BOOL DSFilesystemProbeWritable(void);

/// errno → 可读名字（带中文注解）
FOUNDATION_EXPORT NSString *DSFilesystemErrnoName(int err);

NS_ASSUME_NONNULL_END
