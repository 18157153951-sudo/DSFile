# Vendor/ClearSword — 第三方来源与许可说明

本目录内的 C 源码**不是本项目原创**，是把公开的 DarkSword 内核漏洞移植搬进来，
给 DSFile 提供内核读写原语。它只服务一件事：让 DSFile 自己的进程逃出沙盒
（用户主动点「激活」才会执行）。

## 来源

| 文件 | 来源 |
| --- | --- |
| `common.h` `krw.c/h` `kmem.c/h` `phys_oob.c/h` `poc.c/h` `socket.c/h` `surface.c/h` `utils.c/h` | [TheRealClarity/ClearSword](https://github.com/TheRealClarity/ClearSword) — DarkSword（CVE-2025-43520，`cluster_write_contig`/`cluster_read_contig` 竞态）的 C 移植 |
| `machine_info.h` | 从 [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS) 取来（CPU 家族宏，纯常量定义） |
| `Shims/sys/fileport.h` | 本项目补的兼容声明（XNU 的 `bsd/sys/fileport.h` 不在公开 iOS SDK 里） |

ClearSword 源码里保留了作者自己的注释与 `NOTE` 标记。上游仓库未见开源许可证；
这里仅用于你自己的设备上自行构建、自行安装，不随任何公开分发分发。

## 我们相对上游改了什么（只有下面这些，全部有注释标记）

1. **`poc.c`：把「失败也当成功」改成如实报错。**
   上游 `pe_v1()` 无论 race 成败都 `return KERN_SUCCESS`，于是失败后会拿无效的
   `rw_socket_pcb` 继续读内核，而 `krw.c` 在非法地址上的处理是 `while(1)` 死循环。
   现在：race 失败直接 `return KERN_FAILURE`；`pe()` 接住 `pe_v1()` 的返回值；
   用 `early_kread64` 之前先校验 `rw_socket_pcb` 是否落在内核段。
2. **`poc.c`：跳过上游结尾那三行「额外演示」**（`find_self_proc` / `task_from_proc` /
   `pmap_from_task`）。它们依赖 `thread_t_tro`，而这个 offset 是**按机型不同**的
   （ClearSword 硬编码 0x378，A14 上应为 0x388 一类），值不对就会拿垃圾地址去读，
   直接卡死。我们改用自己的、带 `getpid()` 自校验的扫描（见 `Sources/Core/DSEscape.m`）。
3. **新增 `Sources/Core/DSEscape.{h,m}`**：沙盒扩展改写 + root 凭据改写。
   和上游 FilzaJailedDS 的 `sandbox_escape.m` 同一套链路常量，但每一步读之前都先验地址合法性，
   并且 `thread_t_tro` 靠运行时扫描 + `p_pid == getpid()` 反向校验得到，不依赖版本表。

## 为什么换掉上一版后端

上一版用的是 [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS) 里的 opa334 风格
`kexploit`。实测（iPhone13,4 / iOS 18.5 / A14）出现的现象是：race 没抓到 rw socket，
但漏洞函数仍然返回成功，紧接着 `proc_self()` 踩到非法内核地址，触发上游
`early_kread` 里那句 `*(int *)1 = 0;  // make crash intentionally` —— 应用直接闪退。
换后端 + 加体检之后，同样的失败会变成一条可读的错误信息，App 不会崩。

## 风险

内核漏洞本身有概率导致**设备重启（内核 panic）**，也可能因为系统版本、机型不在 offset
覆盖范围内而直接失败。DSFile 里所有会写盘的操作都带预演、自动备份和回滚；
但内核层面的失败没法回滚——请在跑之前确认重要数据已备份。
