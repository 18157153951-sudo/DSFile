# Vendor/Lara — 内核栈来源与本地改动

本目录是 [rooootdev/lara](https://github.com/rooootdev/lara) 的内核部分（`lara/kexploit/` 与
`lara/headers/`、`lara/lib/`）搬进 DSFile 后的产物。漏洞（DarkSword）与沙盒逃逸现在都走 lara。

## 原样搬入（未改动）

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `darksword.m` / `darksword.h` | `lara/kexploit/darksword.m` | 内核漏洞本体：`ds_run()` + `ds_kread64/ds_kwrite64/ds_kread/ds_kwrite` |
| `offsets.m` / `offsets.h` | `lara/kexploit/offsets.m` | 按 iOS 版本 + CPU 家族分档的 offset 表（`init_offsets()` / `offsets_init()`） |
| `utils.m` / `utils.h` | `lara/kexploit/utils.m` | `ourproc()` / `procbypid()` / `procbysock*()` / `is_kptr` / `S()` |
| `pe/sbx.m` / `pe/sbx.h` | `lara/kexploit/pe/sbx.m` | 沙盒逃逸 `sbx_escape(proc)`、`sbx_elevate()`、`sbx_gettoken()` 等 |
| `pe/xpaci.h` | `lara/kexploit/pe/xpaci.h` | PAC 剥离（`S()` 宏用到） |
| `machine_info.h` | `lara/kexploit/machine_info.h` | CPU 家族常量 |
| `persistence.h` | `lara/kexploit/persistence.h` | 只用到声明；实现在 `xpf_stub.m` 打桩 |
| `compat.h` | `lara/kexploit/compat.h` | 原样带上（当前没有文件 include 它） |
| `Shims/sys/fileport.h` | 同 ClearSword 的一份 shim | 让 `sys/fileport.h` 在无 SDK 头时可用 |
| `libgrabkernel2.h` | `lara/headers/libgrabkernel2.h` | 声明；`grab_kernelcache()` 在 `xpf_stub.m` 打桩 |
| `vnode.h` | `lara/kexploit/pe/vnode.h` | 声明（本构建没有调用方） |

## 新增（本仓库自己写的）

| 文件 | 为什么 |
| --- | --- |
| `xpf.h` | **XPF 打桩头**。lara 把 XPF 编成预编译 `libxpf.dylib` 随 App 分发；我们出的是未签名 IPA（靠证书重签），带不了这个 dylib。`offsets.m`/`utils.m` 只用 XPF 的一小部分接口，且都在「拿不到 XPF 就用自带版本表」的容错分支里，所以给出能编译的最小声明（含 ChOma 的 `PFSection`/`PFMetric` 等不透明类型）。 |
| `xpf_stub.m` | 上述桩的实现：`xpf_start_with_kernel_path()` 返回非 0（调用方立刻走容错分支）、`xpf_construct_offset_dictionary()` 返回 NULL、`xpf_item_resolve()`/`xpf_gett1szboot()` 返回 0、ChOma 的 `pfmetric_*`/`pfsec_*` 空实现；另外打桩 `grab_kernelcache()`（`offsets.m` 唯一用到的 libgrabkernel2 函数）与 `transfer_krw_to_launchd()`/`recover_krw_primitives()`（`persistence.m` 未搬入；只在 `NSUserDefaults` 的 `stashKRW` 为真时才会被调用，我们从不设置它）。 |
| `DSEscape.m` / `DSEscape.h` | **回退逃逸路线**（来自 `Vendor/attic-DSEscape/`，那是最早自己写的一版）。仅当 lara 的 `ds_get_our_proc()` 取不到 proc 时启用：用「两个 socket 的 `so_cred` 指向同一对象 + `cr_uid` 校验」定位本进程 cred，再走 lara 的 offsets/`S()` 链路（`cr_label=0x78` → `label→sandbox=0x10` → `sandbox→ext_set=0x10`）改写沙盒扩展。**改动只有两处**：顶部把 ClearSword 的 `early_kread64/early_kwrite64/g_ctx.*` 换成 lara 的 `ds_kread64/ds_kwrite64/ds_get_rw_socket_pcb()/ds_get_kernel_base()`（兼容层），入口处填一次上下文；逃逸逻辑本身照原样。 |

## 不参与编译（保留在仓库做对照）

| 目录 | 为什么留着 |
| --- | --- |
| `Vendor/ClearSword/` | 上一版用的 DarkSword C 移植。保留作对照/回退，**不在 `project.yml` 的 sources 里**。 |
| `Vendor/attic-DSEscape/` | 上面 `DSEscape.m` 的原始副本（面向 ClearSword 原语，直接编译会缺符号），作为「改了什么」的对照保留。 |

## 本地集成要点

* `DSKernel.m` 在调用 `ds_run()` **之前**必须先跑 `init_offsets()` 与 `offsets_init()` —— lara 的
  `off_*` / `PROC_PID_OFFSET` / `TASK_TNEXT_OFFSET` 等全局量都由这两个函数填，缺了它们漏洞代码会拿到 0 偏移。
* 逃逸顺序：`ds_get_our_proc()` 非 0 → `sbx_escape(proc)`；否则 → `DSEscapeSandbox()`。
* 提权：`sbx_elevate()`（lara 自己标注 broken，失败不影响已获得的沙盒逃逸）。
* 日志：`ds_set_log_callback()` / `sbx_setlogcallback()` 接到 `DSKernel` 的桥接函数，统一进 App 日志。
