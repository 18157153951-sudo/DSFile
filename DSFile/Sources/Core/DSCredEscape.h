//
//  DSCredEscape.h — 只用「已被真机验证过的 cred 路线」做沙盒逃逸与提权
//
//  为什么不用上游的 sandbox_escape()/proc_self()：
//  上游 `kutils.m` 的 proc_self() 走
//      rw_pcb → inp_socket → socket + off_socket_so_background_thread → thread + thread_t_tro
//  而本机（iPhone13,4 / iOS 18.5）实测 socket+0x2b0（so_background_thread）**恒为 0**，
//  于是它会拿 0x378 当内核地址去读 → 撞进上游 FAILURE() 宏（sleep(2); exit(c)）→ App 直接退出。
//
//  本文件改用另一条已经在本机 4/4 命中过的路线定位本进程 ucred：
//      两个 socket 对象（rw_pcb / control_pcb 各自的 inp_socket）
//      在 0x1f0~0x230 内相同偏移处指向同一个内核对象，且该对象 +0x18 处的 cr_uid == getuid()
//  之后照上游 sandbox_escape.m 的三步改写扩展表；每一步解引用前都先校验地址。
//

#ifndef DSCredEscape_h
#define DSCredEscape_h

#import <Foundation/Foundation.h>

/// 逃逸日志回调（接到 App 的界面日志）；可为 NULL，内部始终同时 NSLog。
typedef void (*DSCredEscapeLogFn)(const char *message);
void DSCredEscapeSetLogCallback(DSCredEscapeLogFn callback);

/// 只做沙盒逃逸：定位 cred → label → sandbox → ext_set → 改写扩展。
/// 返回 0 = 成功；负数 = 失败（**失败路径绝不写内核内存**）。
int DSCredEscapeSandbox(void);

/// 把本进程凭据改成 root（改写 ucred 里的 posix_cred uid/gid 字段）。
/// 返回 0 = 成功（getuid()==0），负数 = 失败。
int DSCredEscapeElevateToRoot(void);

/// 诊断用：最近一次成功定位到的对象地址（0 表示还没定位到）
unsigned long long DSCredEscapeLastCred(void);
unsigned long long DSCredEscapeLastLabel(void);
unsigned long long DSCredEscapeLastSandbox(void);
unsigned long long DSCredEscapeLastExtSet(void);

#endif /* DSCredEscape_h */
