//
//  DSFSAccessProbe.m — 逐路径 + 真实 errno 的文件访问探针（纯 POSIX）
//

#import "DSFSAccessProbe.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

#pragma mark - 结果对象

@interface DSFSAccessProbeResult ()
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, copy, readwrite) NSString *operation;
@property (nonatomic, assign, readwrite) BOOL ok;
@property (nonatomic, assign, readwrite) int errnoValue;
@property (nonatomic, copy, readwrite) NSString *errnoName;
@property (nonatomic, assign, readwrite) NSInteger itemCount;
@end

@implementation DSFSAccessProbeResult

/// line 用计算属性（避免"先赋值后拼串"的顺序问题）
- (NSString *)line
{
    if (self.ok) {
        if (self.itemCount >= 0) {
            return [NSString stringWithFormat:@"%@ %@ → 成功（%ld 项）",
                    self.operation, self.path, (long)self.itemCount];
        }
        return [NSString stringWithFormat:@"%@ %@ → 成功", self.operation, self.path];
    }
    return [NSString stringWithFormat:@"%@ %@ → 失败 errno=%d %@",
            self.operation, self.path, self.errnoValue, self.errnoName];
}

@end

#pragma mark - errno 名字

NSString *DSFilesystemErrnoName(int err)
{
    switch (err) {
        case 0:            return @"-";
        case EPERM:        return @"EPERM(沙盒拒绝)";
        case EACCES:       return @"EACCES(权限不足)";
        case ENOENT:       return @"ENOENT(不存在)";
        case EROFS:        return @"EROFS(只读文件系统)";
        case ENOTDIR:      return @"ENOTDIR(不是目录)";
        case ELOOP:        return @"ELOOP(符号链接过多)";
        case ENAMETOOLONG: return @"ENAMETOOLONG(路径过长)";
        case ENOSPC:       return @"ENOSPC(空间不足)";
        case EIO:          return @"EIO(IO 错误)";
        default: break;
    }
    const char *text = strerror(err);
    if (text == NULL) return [NSString stringWithFormat:@"errno %d", err];
    return [NSString stringWithFormat:@"errno %d(%s)", err, text];
}

#pragma mark - 具体探测

/// 列目录：opendir 失败就记 errno（这是区分"沙盒拒绝"与"路径不存在"的关键）
static DSFSAccessProbeResult *ds_list_probe(NSString *path)
{
    DSFSAccessProbeResult *result = [DSFSAccessProbeResult new];
    result.path = path;
    result.operation = @"列目录";
    result.itemCount = -1;

    errno = 0;
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (dir == NULL) {
        int err = errno;
        result.ok = NO;
        result.errnoValue = err;
        result.errnoName = DSFilesystemErrnoName(err);
        return result;
    }

    NSInteger count = 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(dir)) != NULL) {
        count++;
    }
    closedir(dir);

    result.ok = YES;
    result.errnoValue = 0;
    result.errnoName = @"-";
    result.itemCount = count;
    return result;
}

/// 写探针：建文件 → 写 5 字节 → 关闭 → 立刻删除自己创建的文件
static DSFSAccessProbeResult *ds_write_probe(NSString *path)
{
    DSFSAccessProbeResult *result = [DSFSAccessProbeResult new];
    result.path = path;
    result.operation = @"写探针";
    result.itemCount = -1;

    errno = 0;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        int err = errno;
        result.ok = NO;
        result.errnoValue = err;
        result.errnoName = DSFilesystemErrnoName(err);
        return result;
    }

    const char *payload = "probe";
    ssize_t written = write(fd, payload, strlen(payload));
    int writeError = (written < 0) ? errno : 0;
    close(fd);
    unlink(path.fileSystemRepresentation);

    if (writeError != 0) {
        result.ok = NO;
        result.errnoValue = writeError;
        result.errnoName = DSFilesystemErrnoName(writeError);
    } else {
        result.ok = YES;
        result.errnoValue = 0;
        result.errnoName = @"-";
    }
    return result;
}

#pragma mark - 对外接口

NSArray<DSFSAccessProbeResult *> *DSFilesystemProbeResults(void)
{
    // 顺序固定，方便真机日志对照（前三条是"能不能看到别人的 App"的关键路径）
    static NSString *const listPaths[] = {
        @"/var/mobile",
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Bundle/Application",
        @"/var/jb",
        @"/private/var/mobile",
    };

    NSMutableArray<DSFSAccessProbeResult *> *out = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(listPaths) / sizeof(listPaths[0]); i++) {
        [out addObject:ds_list_probe(listPaths[i])];
    }
    [out addObject:ds_write_probe(@"/var/mobile/.myfilza_fs_probe")];
    [out addObject:ds_write_probe(@"/var/tmp/.myfilza_fs_probe")];
    return out;
}

NSString *DSFilesystemAccessReport(void)
{
    NSMutableString *out = [NSMutableString string];
    for (DSFSAccessProbeResult *result in DSFilesystemProbeResults()) {
        [out appendFormat:@"[文件访问探针] %@\n", result.line];
    }
    [out appendFormat:@"[文件访问探针] 结论：可写=%@ 可读=%@（uid %d）\n",
        DSFilesystemProbeWritable() ? @"是" : @"否",
        DSFilesystemProbeReadable() ? @"是" : @"否",
        getuid()];
    [out appendString:@"[文件访问探针] 读法：EPERM=沙盒拒绝（本进程没有该路径的沙盒例外）；"
                       @"EACCES=权限不足；ENOENT=路径不存在（该越狱环境没有此目录）\n"];
    return out;
}

NSString *DSFilesystemAccessSummaryLine(void)
{
    return [NSString stringWithFormat:@"[文件访问探针] 可写=%@ 可读=%@（uid %d）",
            DSFilesystemProbeWritable() ? @"是" : @"否",
            DSFilesystemProbeReadable() ? @"是" : @"否",
            getuid()];
}

BOOL DSFilesystemProbeReadable(void)
{
    for (DSFSAccessProbeResult *result in DSFilesystemProbeResults()) {
        if (!result.ok) continue;
        if (![result.operation isEqualToString:@"列目录"]) continue;
        if ([result.path isEqualToString:@"/var/mobile"] ||
            [result.path isEqualToString:@"/var/mobile/Containers/Data/Application"] ||
            [result.path isEqualToString:@"/var/containers/Bundle/Application"]) {
            return YES;
        }
    }
    return NO;
}

BOOL DSFilesystemProbeWritable(void)
{
    for (DSFSAccessProbeResult *result in DSFilesystemProbeResults()) {
        if (result.ok && [result.operation isEqualToString:@"写探针"]) return YES;
    }
    return NO;
}
