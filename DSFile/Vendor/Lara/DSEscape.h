//
//  DSEscape.h — 在 ClearSword 拿到内核读写之后，做两件事：
//    1) 改写本进程的沙盒扩展数据（逃出沙盒，能读写整机文件）
//    2) 把本进程的凭据 uid/gid 改成 0（写 root 拥有的文件时不用再折腾属主）
//
//  与上游 FilzaJailedDS / lara 的差别（也是我们上一版崩掉的地方）：
//   * 每一步读之前都先判断地址是不是内核地址，绝不把非法地址喂给 early_kread
//     （上游 early_kread 在地址非法时会 `*(int*)1 = 0` 故意崩进程，ClearSword 则是 `while(1)` 卡死）；
//   * thread_t_tro 这种「按机型不同」的 offset 不写死，改成运行时扫描 + getpid() 自校验；
//   * 指针可能是 PAC / SMR 形态，用「多种候选还原 + 结构自校验」挑出真正能走通链路的那个。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志回调（C 函数指针，避免在 C 层用 block）
typedef void (*ds_escape_log_fn)(const char *message);

/// 逃逸沙盒。返回 0 成功；-1 内核读写不可用；-2 找不到关键结构；-3 改写后自检失败
int DSEscapeSandbox(ds_escape_log_fn _Nullable log);

/// 把本进程凭据改成 root。返回 0 成功，其它失败
int DSEscapeElevateToRoot(ds_escape_log_fn _Nullable log);

/// 诊断用：内核基址 / 本进程 proc / 扫出来的 thread_t_tro
unsigned long long DSEscapeKernelBase(void);
unsigned long long DSEscapeSelfProc(void);
unsigned long long DSEscapeThreadTroOffset(void);

NS_ASSUME_NONNULL_END
