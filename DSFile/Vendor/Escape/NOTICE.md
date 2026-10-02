# Vendor/Escape — 第三方来源与许可说明

本目录内的 C / Objective-C 源码**不是本项目原创**，是把公开的 DarkSword 沙盒逃逸实现
搬进来供 DSFile 内嵌使用。它们只做一件事：让 DSFile 自己的进程获得完整文件系统读写能力
（用户主动点「激活」才会执行）。

## 来源

| 文件 | 来源 | 作者 |
| --- | --- | --- |
| `kexploit/*`（kexploit_opa334 / krw / kutils / offsets / vnode / machine_info / xpaci） | [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS) → 源自 [wh1te4ever/darksword-kexploit-fun](https://github.com/wh1te4ever/darksword-kexploit-fun) 与 [opa334](https://github.com/opa334/) 的 XPF/krw | wh1te4ever, opa334 |
| `sandbox_escape.{h,m}` | 同上（基于 CrazyMind90 的 `18.3_sandbox/root.m`，root 提权部分来自 [rooootdev/lara](https://github.com/rooootdev/lara)） | CrazyMind90, rooootdev, 34306 |
| `apfs_own.{h,m}` | 同上（lara 的 `kexploit/pe/apfs.m`） | rooootdev, 34306 |
| `utils/*` | 同上 | 34306 |

上游仓库 **没有附带开源许可证**。这里的副本仅用于你自己的设备上自行构建、自行安装，
不随任何公开分发。如果你打算再分发这个 App，请先联系上游作者取得许可，或者把
`Vendor/Escape` 换成你自己实现的等价模块。

## 相对上游做的改动（只有这些）

1. 去掉了 `Tweak.m`（那是给 Filza 做注入用的 hooks，DSFile 不需要）。
2. 去掉了 `kpf/`、`XPF/`、`ChOma`（`xpf_*` / `grab_kernelcache` 在这条逃逸路径上根本没有被调用，
   删掉可以显著降低编译面和二进制体积）。
3. 新增 `Shims/`：`sys/fileport.h` 与 `IOSurface/IOSurfaceRef.h` 的兼容声明 +
   `DSIOShim.c`（用 `dlopen`/`dlsym` 绑定 IOSurface，避免依赖私有 framework 能否链接）。
4. 未改动任何逃逸 / 内核读写逻辑本身。

## 风险

内核漏洞利用本身有概率导致**设备重启（内核 panic）**，也可能因为系统版本、机型不在
offset 表里而直接失败。DSFile 里所有会写盘的脚本操作都带 dry-run、自动备份和回滚；
但内核层面的失败没法回滚——请在跑之前确认重要数据已备份。
