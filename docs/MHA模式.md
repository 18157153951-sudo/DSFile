# MHA 身份模式（零内核容器访问）

> 本文记录一条**不需要任何内核漏洞**就能读写别的 App 容器的路径，以及它在 myfilza 里的用法。

## 1. 这条路径是什么

**把 App 的 Bundle ID 伪装成 `com.apple.mobile.MobileHouseArrest`**（Apple 自己的「容器访问」守护进程）。

iOS 的沙盒系统是**按 Bundle ID 下发 profile** 的：一旦进程的 Bundle ID 等于 `com.apple.mobile.MobileHouseArrest`，它就会拿到该守护进程对应的**特权沙盒 profile** —— 可以直接写 `/private/var/mobile/...`，并且 MCM（MobileContainerManager）会把其它 App 容器的沙盒令牌发给它。拿到令牌后，**普通 POSIX `open/read/write` 就能操作别人的容器**，全程不碰内核。

## 2. 我们是怎么确认的（三条硬证据）

这条结论来自对用户提供的 **3105 本体**（`YangJiiii/3105`，GPL-3.0）的分析：

| # | 证据 | 出处 |
| --- | --- | --- |
| 1 | 上游注释自认：iOS < 26 时"拿到内核 R/W 即算 Active"，真正的容器访问走 MCM/HouseArrest 这条路 | `Vendor/ThreeOneOSFive/` 内 `sandbox_escape.m` 注释 |
| 2 | 代码**硬校验**这个 Bundle ID 才继续 | `exploit/mcm_bridge.m:289` |
| 3 | 用户那份 3105 构建产物的 `Info.plist` 里 `CFBundleIdentifier` 就是 `com.apple.mobile.MobileHouseArrest` | 用户提供的 IPA（`Payload/ThreeOneOSFive.app/Info.plist`） |

另外一个反证：3105 在用户机器（iPhone13,4 / iOS 18.5）上 `sandbox_escape` **返回 -1**（沙盒逃逸失败），但它**依然能正常访问别的 App 数据** —— 说明它的访问能力**不是**来自逃逸。

还有一条：`bad_query` 那条"用户态令牌"路在 **iOS 18.5 上必然失败**，因为 `libsystem_containermanager.dylib` 里没有 `container_query_operation_set_part` / `…_set_part_domain` 这两个符号，而 `bad_query.c` 是全有或全无校验（真机日志里 `set_part=0x0 set_part_domain=0x0` 就是证据）。

## 3. 怎么用

### 3.1 直接用 MHA 变体包（推荐）

CI 每次都会产出**两份** IPA：

| 包 | Bundle ID | 用途 |
| --- | --- | --- |
| `DSFile.ipa` | `com.dsfile.app` | 常规包：默认模式（FilzaJailedDS 内核逃逸）/ 3105 模式 |
| `myfilza-mha.ipa` | `com.apple.mobile.MobileHouseArrest` | **MHA 包**：零内核，靠身份拿容器访问 |

用 **eSign 重签 `myfilza-mha.ipa`** 安装即可（显示名是 `myfilza MHA`，方便和常规包区分）。

安装后**不需要点激活**：进「替换」页或「文件」页，只要能看到别的 App 的容器目录并正常读写，就说明特权 profile 生效了。

### 3.2 自己改 Bundle ID（不想用变体包时）

eSign 签名界面里有「Bundle ID」一栏，把它改成 `com.apple.mobile.MobileHouseArrest` 再签即可；或者用其他重签工具改 `Info.plist` 的 `CFBundleIdentifier`。

## 4. 数据迁移（重要）

**改 Bundle ID = 换了一个 App**，系统会分配**新的数据容器**，旧安装里的脚本、备份、记录都不会自动继承。

手动迁移：

1. 在**旧包**（`com.dsfile.app`）的「文件」页里，进入 `Documents/`；
2. 把需要的目录（`Scripts/`、`Backups/`、`Runs/`、`AutoTasks/`、`ReplaceSources/`）**拷到别处**（例如系统「文件」App 或共享出去）；
3. 装好 MHA 包后，再从「文件」页把内容拷回它自己的 `Documents/`。

> 因为 MHA 包有特权 profile，它**也能直接读旧容器**：旧容器路径一般是
> `/var/mobile/Containers/Data/Application/<UUID>`，可在「文件」页里找到那个 UUID 后直接把内容拷过来。

## 5. 风险与边界

- **这是身份伪装**：把 App 伪装成 Apple 的系统守护进程。请**只在自己的设备、自己的数据上**使用；不要用于分发或任何非自有环境。
- **沙盒 profile 由系统按 Bundle ID 下发**，Apple 未来版本随时可能收紧（那时这个包会退化成普通 App，不会崩，只是没有额外权限）。
- 它**不执行任何内核漏洞**，因此**没有内核 panic 风险** —— 这是它相对内核模式最大的优势。
- 仍然改不了 SSV 签名卷（`/System`、`/usr` 依旧只读）。
- 许可证：本项目包含 3105 的源码（GPL-3.0），再分发需遵守 GPL-3.0（详见 `README.md` 与 `Vendor/ThreeOneOSFive/LICENSE`）。

## 6. 与其它模式的关系

| 模式 | 需要内核漏洞 | 适用 |
| --- | --- | --- |
| FilzaJailedDS（默认） | 是 | 17.x–18.x，已在 iPhone13,4 / 18.5 实测逃逸成功 |
| 3105 | 是（可用安全模式关闭，但 18.x 上拿不到访问） | 26.x / 27 的 offset 覆盖 |
| **MHA 身份** | **否** | 只要能装 MHA 变体包，18.x 上也能直接访问容器 |

三种模式**互不影响**：MHA 走的是身份，前两种走的是内核，代码在仓库里彼此隔离。
