# FilzaTweak 来源与改动说明

本目录是把 **[34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)**（注入进 Filza 的
Theos tweak）**原样**搬进来、改用 XcodeGen 编成动态库的产物。

## 上游内容（逐字节原样，未改一行）

以下文件与本地上游副本 `ds/upstream-FilzaJailedDS/` 做过逐文件 SHA256 对比：
**75 个 `.m` / `.c` / `.h` 全部一致，0 个被修改，0 个缺失。**

| 目录/文件 | 说明 |
| --- | --- |
| `Tweak.m` | tweak 主体：纯 ObjC + runtime（`method_setImplementation`），无 Logos/Substrate 依赖；`__attribute__((constructor)) TweakInit` 是入口 |
| `sandbox_escape.{m,h}` | 沙盒逃逸 |
| `apfs_own.{m,h}` | APFS 相关处理 |
| `kexploit/` | `kexploit_opa334.m`（DarkSword 内核漏洞）、`krw`、`kutils`、`offsets`、`vnode`、`xpaci.h`、`machine_info.h` |
| `kpf/` | patchfinder |
| `utils/` | `file.c`、`hexdump.c`、`process.c` |
| `XPF/src/` | XPF 本体（`xpf.c`、`common.c`、`decompress.c`、`bad_recovery.c`、`non_ppl.c`、`ppl.c`）——**源码自带，不需要预编译 dylib** |
| `XPF/external/ChOma/src/` | ChOma（Mach-O / dyld shared cache 解析）源码 |
| `control`、`FilzaApplySandboxExt.plist`、`Makefile`、`README.md` | 上游打包相关，保留备查（Makefile 是文件清单的依据） |

## 本目录新增的东西（只有 3 类）

1. **`project.yml`** —— XcodeGen 工程定义，产出一个 dylib（等价于上游 Makefile 的
   `FilzaApplySandboxExt_FILES` / `_CFLAGS` / `_FRAMEWORKS` / `_LIBRARIES` 设置）。
2. **`NOTICE.md`**（本文件）。
3. **`XPF/external/ChOma/include/choma/`（21 个头文件）** —— 结构性补齐：
   上游 `XPF/src/xpf.c` 里写的是 `#include <choma/Fat.h>`，Makefile 也带了
   `-I.../ChOma/include`，但本地这份上游副本里 `ChOma/include/choma` 是一个 **0 字节的占位文件**
   而不是目录，直接编会 `'choma/Fat.h' file not found`。
   做法：把 `ChOma/src/*.h` 复制一份到 `ChOma/include/choma/`（**内容也是逐字节原样**，
   没有改动任何头文件本身）。

> 也就是说：**没有对上游源码做过任何修改**，只补了一个头文件目录 + 加了构建描述文件。

## 许可证情况（如实说明）

本地上游副本里**没有任何 `LICENSE` / `COPYING` 文件**（递归查找只有 `README.md`），
所以上游没有声明许可证。XPF / ChOma 这些第三方组件在上游目录里同样没有附许可证文件。

因此：

- 这里把它作为**本机研究 / 自用**的构建材料；
- 不要对外分发本目录或由它编出的 dylib；
- 如果要分发，请先联系上游作者（34306）取得许可，并自行补齐 XPF / ChOma 的许可证信息。

## 我们对外部来源的引用

| 内容 | 来源 |
| --- | --- |
| 注入型 tweak + DarkSword 内核漏洞 + 沙盒逃逸 | [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS) |
| XPF（内核符号/偏移解析） | 上游 `XPF/`（随仓库一同搬入） |
| ChOma（Mach-O 解析） | 上游 `XPF/external/ChOma/`（随仓库一同搬入） |
