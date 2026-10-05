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

## 7. 第②步：向 MCM 索取容器租约（0.7.2 起）

**只改 Bundle ID 是不够的** —— 那只是第①步（拿到特权沙盒 profile，可以写 `/private/var/mobile`）。
**别的 App 的容器**需要第②步：主动向 MCM 查询该容器的**标识**，拿到可读可写的沙盒扩展并激活。

上游 PoC（`0xjohnnydev/MobileHouseArrest-PoC`、`0xjohnnydev/FilzaSlop`）给出的请求序列：

```objc
container_query_t query = container_query_create();
container_query_set_class(query, 2);                   // 2 = App 数据容器；7 = App Group
container_query_operation_set_flags(query, 0x900000000);
container_query_set_identifiers(query, xpc_string_create("<目标 bundle id>"));
container_query_operation_set_part(query, 0);           // iOS 18 可能没有这个符号 → 跳过
container_object_t object = container_query_get_single_result(query);
container_copy_sandbox_token(object);                   // 取令牌
container_object_sandbox_extension_activate(object, false);   // 激活扩展
```

- 实现位置：`DSFile/Sources/Core/DSMCMBridge.{h,m}`（符号全部 `dlopen`/`dlsym`，不直接链接私有库）
  ＋ `DSFile/Sources/Core/DSMHAKernel.{h,m}`（枚举 → 逐个取租约并**持有** → 真实探针）；
- `DSKernel.m` 的分派点是 **MHA 优先**，失败**不阻断**，继续按用户选择的模式走；
- **租约必须持有**：`container_object_free` 会**撤销**扩展（上游文档明确写了），所以租约对象不能提前释放；
- **枚举不需要权限**：用 `flags = 0x100000000`（仅元数据）就能列出所有 App 数据容器的标识 —— 这样"没权限时怎么列出 App"就解决了；
- class 13（MobileGestalt）路线在 **18.x 不支持**（PoC 测试表），本项目不采用。

## 8. 签名要求（决定这条路径能不能生效）

PoC 原文第一句：**“MobileContainerManager trusted the caller's CodeDirectory identifier as an authorization key.”**

也就是：**除了 `CFBundleIdentifier`，签名时的 CodeDirectory identifier 也必须是 `com.apple.mobile.MobileHouseArrest`**。

| 证书类型 | CodeDirectory identifier | 结果 |
| --- | --- | --- |
| 免费 / 个人 Apple ID | 通常是 `<TeamID>.<bundleid>` | ❌ 不匹配（还可能直接报 9400/9401） |
| 付费开发者证书 / 企业证书 | 可以就是 `com.apple.mobile.MobileHouseArrest` | ✅ 可用 |

用 eSign 签名时**不要让它改写 Bundle ID**（有些工具会"顺手"加后缀），并确保 identifier 就是该值。

排查（日志里都有）：
- 所有容器 `activate` 全失败 → 多半是 **identifier 不匹配**；
- 写 `/var/mobile` 探针失败 → 多半是**特权 profile 没下来**（签名/安装方式问题）；
- 提示 `MCM 桥不可用` → 日志会直接列出缺哪个私有符号。

## 9. 怎么判断签名对不对（看日志里的「签名 identifier」）

0.7.3 起，App 会在**启动时**与 **MHA 路径开始时**各打一次签名诊断，格式固定，方便原样回报：

```text
[MHA 诊断] bundle id = com.apple.mobile.MobileHouseArrest；签名 identifier = <值>（期望 com.apple.mobile.MobileHouseArrest）→ 匹配 ✓ / 不匹配 ✗ / 无法判断
[MHA 诊断] TeamIdentifier = <值>；application-identifier = <值>
[MHA 诊断] csops 原始值：signingID = <值>；identity = <值>
```

怎么读：

| 日志现象 | 含义 | 怎么办 |
| --- | --- | --- |
| `签名 identifier = com.apple.mobile.MobileHouseArrest → 匹配 ✓` | 签名身份对了 | 若仍看不到别的容器，继续看下面的枚举/租约/探针行 |
| `签名 identifier = <TeamID>.<bundleid> → 不匹配 ✗` | 用的是 TeamID 前缀式签名（免费/个人 Apple ID，或工具自动生成） | 换付费/企业证书；把 Bundle ID 设为 `com.apple.mobile.MobileHouseArrest`，**不要用「自动生成」** |
| `→ 无法判断`（读不到值） | 两个读法都没拿到值 | 用**经验判据**：`枚举 class 2 = 1 个标识`（只有自己）+ `写探针失败` ⇒ 身份没生效 |
| `枚举 class 2：N 个标识`（N 明显大于 1） | 身份生效了（MCM 愿意给你别人的容器） | 正常，继续看租约与探针 |
| `写探针：/var/mobile/... (errno=1) → 失败` | 特权沙盒 profile 没下发 | 多半还是签名 identifier 的问题；也检查有没有用「自动生成 Bundle ID」 |
| `MCM 桥不可用，缺符号：…` | 系统里缺某个私有符号 | 把这一行原样回报即可 |

**真机实测（0.7.2，iPhone13,4 / iOS 18.5）**：`枚举 class 2 = 1 个标识`（只有自己）＋ `激活租约 6/6 成功` ＋ `写探针失败 (errno=1)` —— 与「签名 identifier 不是 MHA」完全吻合：**租约机制本身是通的**（能拿到自己的容器），但 MCM 不肯把别人的容器给你、特权 profile 也没下发。

诊断本身是**只读**的：只用 `csops(2)` 与 Security.framework 里签名稳定的两个函数（`SecTaskCreateFromSelf` / `SecTaskCopyValueForEntitlement`，用 `dlsym` 取），全程 `@try/@catch`、`CFRelease` 配对；读不到就打印「(读取不到)」，**绝不影响激活流程、也不会因此崩溃**。

---

## 10. 两条路共存 与 自动择路（0.7.4）

同一个 App 里现在有**两条完全独立**的容器访问路径，由用户在设置页自己切换：

| 路径 | 需要什么 | 是否跑内核 |
| --- | --- | --- |
| **MHA · 零内核** | 签名 identifier 就是 `com.apple.mobile.MobileHouseArrest`（`Info.plist` 的 Bundle ID **和** 签名时的 CodeDirectory identifier 都要是它） | **完全不跑** |
| **内核 + cred 逃逸** | 无特殊签名要求（默认 FilzaJailedDS；3105 后端需在下面单独选） | 跑（`kexploit_opa334` + cred 路线逃逸） |

### 设置页三选一（用户自己切换，手动优先）

| 选项 | 行为 |
| --- | --- |
| **自动（推荐）**（默认） | 先试 MHA：只有「签名 identifier 就是 MHA」**且**真实探针通过（能写沙盒外，或能读到**别人**的容器）才采用；否则**自动回退**到你选的内核后端 |
| **仅 MHA（零内核）** | **只**走 MHA。不可用时**明确失败**并写出原因（例如「签名 identifier = `app.xxx.yyy`，不是 `com.apple.mobile.MobileHouseArrest`」），**绝不静默回退内核** |
| **仅内核（FilzaJailedDS）** | **完全跳过 MHA**（连检测都不做），直接走内核后端，行为与 0.6.2 逐字一致 |

选择持久化在 `UserDefaults`（键 `myfilza.pathMode`，值 `auto` / `mha` / `kernel`），重启后仍生效；每次激活都会把「当前选择」与「实际走的路径」写进日志。

### 成功判据（0.7.4 收紧，修掉 0.7.3 的错报）

以前把「持有租约数 > 0」当成成功 —— 真机上明明只拿到自己一个容器、写探针 `EPERM`，却打了 `沙盒逃逸成功` ✗。现在**只看真实结果**：

- ✅ **写沙盒外探针成功**（特权 profile 真的下发），**或**
- ✅ 成功激活的 **App 数据容器（class 2）多于 1 个**（= 真的能看到别人的容器）。
- ❌ 只持有租约、只读到自己那一个容器 —— **不算成功**。

另外 MHA 路径加了**签名门槛**：签名 identifier 明确不是 MHA 时，**连 MCM 都不尝试**（因为授权键不匹配，试了也只会拿到自己的容器），直接如实失败并给修复指引。

### 结果展示

激活结束时日志会写一行 `✅ 本次实际路径 = MHA · 零内核` 或 `✅ 本次实际路径 = 内核 + cred 逃逸（FilzaJailedDS）`；设置页顶部也会显示「当前生效路径」，未激活时显示「尚未激活」。失败时则会写 `❌ 激活未成功（结果码 …）；访问路径选择 = …`，并附上 MHA 的失败原因。

---

## 11. MHA 在各系统版本上的角色（0.8.0 起写进日志）

依据 3105 自己的文件（不是推断）：

- `README.3105.md` 的兼容表里 **只有 iOS 17 / 18 两行带 `(kernel exploit)`**，26/27 那几行**没有**；
- `helpers/KernelExploit.swift`：`requiresSandboxEscape = majorVersion >= 26`，且注释写明 iOS < 26 时「拿到内核 R/W 就算 Active，文件浏览退回 `LSApplicationWorkspace` + inode walk」。

所以：

| 系统 | MHA 的角色 | 说明 |
| --- | --- | --- |
| **iOS 18.x** | **可选**（不是必需） | 18.x 上内核那条路可用（3105 / FilzaSlop 都用它，我们的 cred 逃逸也验证通过）；MHA 是「零内核」的更稳替代。启用 `myfilza-mha.ipa` 且签名 identifier 正确时它就能接管；签名不匹配时自动回退内核（「自动」模式） |
| **iOS 26 / 27** | **必需**（首选） | 那两代没有可用的内核链，`bad_query` / MHA / class-13 才是主力；3105 模式的顺序是 MHA → bad_query → 内核兜底 |

真机实测（iPhone13,4 / iOS 18.5）：MCM 桥可用 ✓、租约能激活 ✓、能读到自己那个容器 ✓ —— 只因为签名 identifier 被签名工具自动生成成了别的值（`app.lemon4360.cassava3192`），MCM 才不肯给别人的容器。**机制本身是通的**，卡的是签名身份。

