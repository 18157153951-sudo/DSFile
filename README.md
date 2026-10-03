# myfilza

> 类 Filza 的 iOS 文件管理器 + 脚本执行器，走 **免越狱（DarkSword 内核路线）**：用户主动点一下激活，本进程就能读写整机文件系统，然后按你自己写的配方（JSON）去替换目标 App 里的指定文件，执行前自动备份、可一键回滚。

这是一个**纯本机、用户主动触发的工具**：不联网、不常驻后台、不做任何隐蔽行为。所有写操作都会在「记录」页留下可查的记录和可用的备份。

- 显示名 / 产品名：`myfilza`（`CFBundleDisplayName` / `PRODUCT_NAME`）
- 工程名 / 可执行文件：`myfilza`
- Bundle ID：`com.dsfile.app`（**保持不变**：改名后的包是覆盖升级，设备上的脚本、备份、日志都还在）
- 版本：0.3.0
- 部署目标：iOS 15.0，架构 `arm64`

---

## 一、能做什么 / 不能做什么

### 能做

| 能力 | 说明 |
| --- | --- |
| 浏览整机文件系统 | 激活后文件页从 `/` 开始浏览（未激活时只能待在自己的沙盒 Documents 里）；支持显示隐藏文件、按名称/大小/时间排序、按关键字过滤、路径跳转、书签式面包屑 |
| 文件基本操作 | 新建文件夹、新建文件、重命名、复制一份（自动 `-1`、`-2` 避重名）、移动到目录、删除、分享、复制路径 |
| 文本编辑 | 打开文本文件编辑并保存（UTF-8 → Latin1 → 二进制可打印化三级兜底，超过 4 MB 拒绝按文本打开）；保存时自动在旁留一份 `原文件名.dsfbak`，可从菜单还原 |
| 十六进制查看 | 只读十六进制查看器，每页 8192 字节，可翻页、可跳转到偏移（支持 `0x1F40` / `1F40` / `8000` 三种写法） |
| 权限与属主 | 查看/修改八进制权限位（如 `0644`）、修改属主（`mobile`、`mobile:mobile`、`501:501`），属主支持递归 |
| 脚本执行（配方） | 声明式步骤：`replace` / `copy` / `move` / `mkdir` / `delete` / `chmod` / `chown` / `kill` / `note`；支持 `{app.*}` 占位符指向选定的目标 App |
| 备份与回滚 | 执行前把每个「将被覆盖或删除」的目标整份拷进备份会话；记录页可一键回滚 |
| 预演（dry-run） | 只做前置检查和逐步计划，**不修改任何文件** |
| Shell 脚本 | 把 `run.sh` 交给 `/bin/sh` 执行，带超时（120 秒）和输出回显（见下方「不能」第 3 条） |
| 运行历史与日志 | 每次预演/执行/Shell 运行都落盘到 `Documents/Runs/<id>.json` + `.log`；会话日志落盘到 `Documents/Logs/`，可分享导出 |
| 诊断 | 设置页可一键复制/分享诊断信息（机型、系统、芯片、支持判定、内核基址、uid、探针自检结果），可现场跑一次真实写盘自检 |

### 不能做（请务必读完）

| 限制 | 原因 |
| --- | --- |
| **写不进 iOS 的只读系统卷** | `/System`、`/usr`、`/Applications` 等被 SSV（签名系统卷）保护：沙盒逃逸解决的是「沙盒权限」问题，**不解决签名卷的只读挂载**。这些位置即使逃逸成功也写不进去，这是系统机制，不是 bug。 |
| **把别人 App 的主可执行文件改掉后，在证书自签环境下该 App 起不来** | 主可执行文件被改动后签名失效，iOS 启动时会做签名校验 → 直接拒绝启动。**唯一可能仍然运行的例外**：目标 App 是 TrollStore 安装的（ad-hoc 签名、不走常规校验链）。所以「替换主可执行文件」在自签环境下基本等于把那个 App 弄坏，请用「结束 App + 覆盖资源/配置/数据容器文件」的常规玩法；真改了就必须重装。 |
| **Shell 脚本在免越狱环境下经常起不来** | `DSShell` 用 `posix_spawn` 拉 `/bin/sh`，沙盒逃逸解决的是文件访问，**不保证放开 process-exec**。被拒时返回 `EPERM`/`EACCES`，App 会明确提示「沙盒拒绝了 process-exec」，这是预期行为。此时请改用配方脚本（配方在进程内直接做文件操作，不需要 spawn 新进程）。 |
| **每次冷启动都要重新激活** | 逃逸只作用于本进程的运行时内存状态，进程一死就没了。 |
| **内核漏洞有小概率导致设备重启（panic），不可回滚** | 见 [docs/内核与风险.md](docs/内核与风险.md)。 |
| 没有的功能 | 不做压缩/解压、不做全盘内容搜索、不做 FTP/SMB/WebDAV、不做主题换肤、不做远程/后台/定时任务。**本仓库源码里没有这些实现**，文档也不描述它们。 |

### 支持范围

| 项目 | 值 | 依据 |
| --- | --- | --- |
| 系统版本 | **iOS / iPadOS 17.0 – 26.0.x** | `offsets_init()` 的门槛写死为 `>= 17.0 && < 26.1`，`DSKernel.isSystemVersionSupported()` 与之一致 |
| 架构 | `arm64` | `project.yml` 里 `ARCHS: arm64` |
| 芯片 | 除 A19 / A19 Pro / M5 外的已列出芯片 | `DSKernel.supportSummary` 对 A19 / A19 Pro / M5 明确提示「该芯片暂未被漏洞覆盖，激活大概率失败」 |
| 机型 | 与系统版本匹配的 iPhone / iPad | `offsets.m` 里按版本区间 + CPU family 组选 offset |

芯片家族识别表（`DSKernel.cpuFamilyName`）：

| CPU family | 显示 |
| --- | --- |
| `CPUFAMILY_ARM_HURRICANE` | A10 |
| `CPUFAMILY_ARM_MONSOON_MISTRAL` | A11 |
| `CPUFAMILY_ARM_VORTEX_TEMPEST` | A12 |
| `CPUFAMILY_ARM_LIGHTNING_THUNDER` | A13 |
| `CPUFAMILY_ARM_FIRESTORM_ICESTORM` | A14 / M1 |
| `CPUFAMILY_ARM_BLIZZARD_AVALANCHE` | A15 / M2 |
| `CPUFAMILY_ARM_EVEREST_SAWTOOTH` | A16 |
| `CPUFAMILY_ARM_COLL` | A17 Pro |
| `CPUFAMILY_ARM_IBIZA` | M3 |
| `CPUFAMILY_ARM_TUPAI` | A18 |
| `CPUFAMILY_ARM_TAHITI` | A18 Pro |
| `CPUFAMILY_ARM_DONAN` | M4 |
| `CPUFAMILY_ARM_TILOS` | A19 |
| `CPUFAMILY_ARM_THERA` | A19 Pro |
| 其它 | `未知 (0x........)` |

**不在范围内时 App 会直接告诉你「不支持」**：设置页的「支持情况」一行会用红字给出 `xxx 不在 DarkSword 覆盖范围内（支持 17.0 – 26.0.x）`，点「激活内核访问」也不会去跑漏洞——`KernelCenter.activate()` 在版本判定失败时立刻置为 `.unsupported` 并返回，不会乱试。

---

## 二、安装

CI 出的是**未签名 IPA**，需要你自己用证书重签后安装：

1. 从 GitHub Actions 下载 artifact `DSFile-ipa`（里面是 `DSFile.ipa`），或本地按 [docs/构建与安装.md](docs/构建与安装.md) 自己编一个。
2. 用 **eSign / 轻松签 / Sideloadly / AltStore** 之类工具，套上你自己的开发者证书或企业证书重签，再安装到设备。
3. **entitlements 保持干净**：不要注入 `platform-application`、`com.apple.private.*`、`no-sandbox` 之类的私有权限。原因有两个：
   - 它们本来就不是这个 App 需要的（逃逸是运行时通过内核读写完成的，不靠 entitlements）；
   - 带私有权限的签名在别的系统版本/面板上反而容易出问题（装上打不开、被系统杀掉、证书面板不认）。

`project.yml` 里已经为「未签名产物」做好了配置：`CODE_SIGN_IDENTITY: ""`、`CODE_SIGNING_REQUIRED: NO`、`CODE_SIGNING_ALLOWED: NO`。

---

## 三、快速上手（5 步）

1. **装 App**：用重签后的 IPA 安装（见上一节）。
2. **打开 App**：**不会**自动跑内核漏洞。要读写沙盒外的文件，得自己到设置页点一次「激活内核访问」（每次冷启动都要点一次）。
3. **设置页点激活**：看「内核访问」一栏。
   - 嫌每次点麻烦：打开「启动时自动激活」，之后 App 启动后会自己尝试一次；
   - 状态显示「已激活」→ 整个文件系统可读写；
   - 状态显示「内核已就绪（沙盒未通）」→ 点「重试沙盒改写」（**不会重跑内核漏洞**）；
   - 写 root 拥有的文件被拒 → 再试一次「提权到 root」；
   - 随时可点「现场自检文件系统」做一次不读缓存的真实写盘探针。
4. **文件页逛一逛**：点右上角可以在 `/` 里导航；长按/左滑看属性、文本编辑、十六进制、权限与属主。
5. **脚本页导入/新建配方 → 预演 → 执行 → 记录页回滚**：
   - 「脚本」页 → 右上角 `+` → 导入脚本文件（`.json` / `.sh` / `.txt`）、导入脚本包（文件夹）或新建脚本（会生成官方模板）；
   - 进脚本详情 → 选目标 App → 点「预演（不改任何文件）」确认每一步都符合预期 → 点「执行替换」并确认；
   - 「记录」页 → 「备份」分段 → 进备份详情 → 「回滚这次改动」。

> 提示：配方里用 `{app.bundle}` / `{app.data}` 这类占位符时，必须先在脚本详情页选定目标 App；不选或找不到，预演会直接报错拦住你。

---

## 四、目录结构

```
dsfile/
├── .github/workflows/build-app.yml     # CI：生成工程 → 编译 → nm 符号校验 → 打未签名 IPA → 上传 artifact
├── .gitignore
├── README.md                           # 本文件
├── docs/
│   ├── 脚本格式.md                     # 配方 JSON / Shell / 备份回滚 的完整格式说明
│   ├── 构建与安装.md                   # 本地与 CI 构建、重签安装、改名换图标、升级 Vendor
│   └── 内核与风险.md                   # DarkSword 激活流程的通俗解释与风险清单
└── DSFile/
    ├── project.yml                     # XcodeGen 工程定义（target / bundle id / 部署目标 / 头文件路径）
    ├── Sources/
    │   ├── App/DSFileApp.swift         # @main 入口 + 四个 Tab（文件 / 脚本 / 记录 / 设置）
    │   ├── Assets.xcassets/            # AppIcon.appiconset（icon1024.png）+ Contents.json
    │   ├── Core/
    │   │   ├── DSKernel.{h,m}          # 激活状态机：漏洞只跑一次 / 沙盒改写可单独重试 / 探针自检 / 提权
    │   │   ├── KernelCenter.swift      # Swift 侧激活状态机（谁都不许绕过它直接调漏洞）
    │   │   ├── AppScanner.swift        # 已安装 App 枚举（包体 + 数据容器对应）
    │   │   ├── DSShell.{h,m}           # posix_spawn /bin/sh 执行 + 超时 + 输出捕获
    │   │   ├── DSProcess.{h,m}         # 按可执行文件名结束目标进程
    │   │   ├── DSPickers.{h,m}         # UIKit 文件选择器 / 文件夹选择器 / 分享面板
    │   │   ├── DSLog.swift             # 界面日志 + 会话日志落盘 Documents/Logs/
    │   │   ├── FileSystemService.swift # 目录列举、路径拼接、体积统计、卷信息
    │   │   ├── PathItem.swift          # 单个路径的属性快照（名称/大小/权限/属主/时间）
    │   │   ├── BuildInfo.swift         # 版本与构建标记（CI 会把 stamp 写进去）
    │   │   └── DSFile-Bridging-Header.h# Swift ↔ ObjC 混编桥
    │   ├── Files/
    │   │   ├── FilesView.swift         # 文件页（浏览 / 排序 / 过滤 / 新建 / 删除 / 打开）
    │   │   ├── FileViewers.swift       # 文本编辑器 / 十六进制查看器 / 属性面板
    │   │   └── FileOperations.swift    # 增删改 + 权限自愈（被拒 → 内核改属主 → 重试）
    │   ├── Scripts/
    │   │   ├── Recipe.swift            # 配方模型 + 占位符解析 + 官方模板
    │   │   ├── RecipeRunner.swift      # 预演 / 执行 / 逐步操作 / Shell 运行器 / 目标解析
    │   │   ├── RunStore.swift          # 备份会话、manifest、运行历史、回滚
    │   │   ├── ScriptLibrary.swift     # 脚本库（导入 / 新建 / payload 管理 / Shell 模板）
    │   │   └── ScriptsView.swift       # 脚本页（列表 / 详情 / 目标选择 / 预演 / 执行）
    │   ├── Tasks/TasksView.swift       # 记录页（运行历史 + 备份 + 一键回滚）
    │   └── Settings/SettingsView.swift # 设置页（内核访问 / 诊断 / 更新日志 / 日志 / 关于）
    └── Vendor/Escape/                  # 第三方 DarkSword 逃逸代码（见 NOTICE.md，非本项目原创）
        ├── NOTICE.md                   # 来源、许可、相对上游的改动、风险
        ├── kexploit/                   # kexploit_opa334 / krw / kutils / offsets / vnode / machine_info / xpaci
        ├── sandbox_escape.{h,m}        # 沙盒逃逸 + 提权到 root
        ├── apfs_own.{h,m}              # 直接改内核 apfs_fsnode 的属主/模式
        ├── utils/                      # file / process / hexdump 工具
        └── Shims/                      # sys/fileport.h、IOSurface 兼容声明 + DSIOShim.c
```

App 在设备上的数据目录（都是 App 自己的 Documents，可以在「文件」App 里看到，因为 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 都开了）：

| 路径 | 内容 |
| --- | --- |
| `Documents/Scripts/index.json` | 脚本清单 |
| `Documents/Scripts/<脚本目录>/recipe.json` 或 `run.sh` | 脚本本体 |
| `Documents/Scripts/<脚本目录>/payload/` | 要替换进去的文件 |
| `Documents/Backups/<时间戳-脚本名>/manifest.json` + `files/` | 备份会话 |
| `Documents/Runs/<id>.json` + `Documents/Runs/<id>.log` | 运行历史与日志 |
| `Documents/Logs/session-<时间戳>.log` | 界面日志的落盘副本 |

---

## 五、常见问题（FAQ）

**Q1：激活失败怎么办？**

先看设置页「内核访问」的状态灯，它只有这几种：

| 状态 | 含义 | 怎么办 |
| --- | --- | --- |
| 未激活 | 还没试过 | 点「激活内核访问」 |
| 激活中… | 正在跑漏洞，界面卡住是正常的 | 等，别退出 App |
| 已激活 | 沙盒外读写可用 | 直接干活 |
| 内核已就绪（沙盒未通） | 内核读写拿到了，沙盒改写没通过 | 点「重试沙盒改写」；还不行就试一次「提权到 root」 |
| 不支持 | 系统版本不在 17.0 – 26.0.x | 换设备/系统，或自己移植 offset（见 docs/内核与风险.md） |
| 激活失败 | 漏洞执行失败，通常是机型/系统不在 offset 表内 | 确认系统版本与芯片；没有重启就已经是好结果，可以再试一次 |

另外：内核漏洞**只在本次进程里跑一次**（`gExploitDone`），重复点激活不会重跑漏洞（重跑极易 panic）；已经是逃逸状态时再点也只会告诉你「已经是逃逸状态」。

**Q2：为什么读不到某个目录？**

按可能性排序：

1. **没激活**——未激活时文件页默认落在 App 自己的 Documents 里，`/var/containers/...` 一律读不到。
2. **激活了但沙盒改写没通过**——状态是「内核已就绪（沙盒未通）」，此时沙盒外路径依然被拒；去点「重试沙盒改写」或「提权到 root」。
3. **目录本身是只读系统卷**（`/System`、`/usr`、`/Applications` 等）——**能读到、写不进去**，`SSV` 决定，无解。
4. **那是个共享缓存/受 SIP 类保护的位置**——部分路径即使逃逸 + root 也不能写；这类情况按实际报错为准，App 会显示 `error.localizedDescription`。
5. 想确认到底行不行：设置页 → 诊断 → 「现场自检文件系统」，它会在 `/var/mobile/` 或 `/var/tmp/` 真写一个探针文件再删掉，不读缓存。

**Q3：Shell 脚本为什么起不来？**

免越狱环境下沙盒经常仍然拒绝 `process-exec`，这时 `posix_spawn` 直接返回 `EPERM`/`EACCES`，App 会明确提示：

> 沙盒拒绝了 process-exec。免越狱 + DarkSword 环境下这是预期行为：shell 脚本需要越狱 / TrollStore 环境，或改用配方脚本。

如果连 `/bin/sh` 都不可执行（`access("/bin/sh", X_OK) != 0`），会先提示 `/bin/sh 不存在或不可执行，这个环境跑不了 shell 脚本`。
**结论：能不用 Shell 就别用，配方脚本是主推路径**（它在 App 进程内直接读写文件，不需要 spawn 任何进程）。

**Q4：替换后 App 起不来怎么办？**

1. **先回滚**：「记录」页 → 「备份」→ 找到这次执行对应的备份 → 「回滚这次改动」。回滚会把覆盖前的原件拷回原路径并恢复 `mode` / `uid:gid`；脚本新建的文件会被删除。
2. **回滚不了就重装那个 App**：备份是在你的操作范围内做的，如果被改的是主可执行文件/签名相关内容，最干净的解法是卸载重装。
3. **记住这条**：自签环境下改动他人 App 的主可执行文件 → 必然启动失败。这不是本工具的 bug。

**Q5：怎么把日志给我？**

优先给这三样（都在设置页 → 诊断）：

1. **诊断信息**：「复制诊断信息」直接进剪贴板，或「分享诊断信息」导成 `myfilza-诊断.txt`。内容是机型、系统、芯片、支持判定、漏洞是否执行、沙盒是否逃逸、当前 uid、内核基址、探针写盘结果、上一次错误。
2. **会话日志**：「分享日志文件」，对应 `Documents/Logs/session-<时间戳>.log`，里面包含 DarkSword 的 `printf`/`NSLog` 输出（内核漏洞的日志被重定向捕获后写进来了，这是排查激活问题唯一有效的材料）。
3. **当次运行日志**：「记录」页 → 进那次运行 → 底部「分享日志」。也可以直接去导出 `Documents/Runs/<id>.log`。

> 提醒：诊断信息里有你的机型、系统版本和内核基址，发到公开场合前自己判断一下。

---

## 六、免责声明

- 本项目**仅用于管理你自己设备上的数据**。
- 替换他人 App 的文件之前，**请确认你有权这么做**（软件许可、你与权利人的约定、以及你所在地区的法律）。
- 内核漏洞利用本身有概率导致**设备重启（内核 panic）**，这类后果**无法回滚**；所有会写盘的操作虽然都带预演、自动备份和回滚，但请你自己先确认重要数据有备份。
- 使用本工具产生的**任何后果由使用者自负**。
- `FilzaTweak/` 内的代码不是本项目原创（34306/FilzaJailedDS，本仓库锁定上游 tag 2.2），来源与改动清单见 [FilzaTweak/NOTICE.md](FilzaTweak/NOTICE.md)；上游仓库**没有附带开源许可证**，这份副本仅用于在你自己的设备上自行构建、自行安装，不随任何公开分发。要再分发请先联系上游作者取得许可。

---

## 七、越狱环境同样可用

除了免越狱（内核漏洞 + 沙盒逃逸）这条路，本 App 也适配 **经典越狱 / rootless（`/var/jb`）/ roothide / TrollStore**：

- 启动时探测环境（`EnvironmentProbe`），只要**实际能读写沙盒外路径**（真的建探针文件、真的列目录）就不要求先跑内核漏洞，文件操作直接走 POSIX；
- Shell 脚本优先使用越狱根里的 `sh`（`/var/jb/bin/sh`、jbroot 下的 `bin/sh`），回退 `/bin/sh`；
- 设置页新增「环境」区块，显示：越狱类型 / 内核逃逸状态 / 是否已具备 root / 沙盒外读写能力 / 越狱根，并可一键「重新探测环境」；
- 越狱环境下不做任何路径翻译（rootless 的绝对路径就是 `/var/jb/...`）。

未越狱时行为与之前完全一致：仍然需要手动「激活内核访问」。

---

## 八、「替换」页的两个进阶能力（0.3.2 起）

### 文件夹模式（镜像替换 + 整棵递归备份）

替换页顶部可切换 **文件模式 / 文件夹模式**：

- 源文件夹从「文件」App 选，选完整份拷进 `Documents/ReplaceSources/`；
- 目标文件夹在「浏览目标 App 目录」里进到对应目录后点 **「选择此文件夹」**；
- 语义是**镜像替换**：替换前把整个目标文件夹**递归备份**，然后把目标整体替换成源的内容 —— 目标里源没有的旧文件会被移除；
- 文件夹模式下「执行前自动备份」**强制开启**；回滚仍然只有一套（`RunStore.restore`）。

配方里对应的 op 是 `replaceDir`（见 [docs/脚本格式.md](docs/脚本格式.md)）。

### 自动化（两个触发点）

替换页新增「自动化」Section：**启动时自动执行**、**激活成功后自动执行**、**现在运行一次**。

- 你在页面上选好的目标与替换内容会**自动保存**成 `Documents/AutoTasks/auto.json`；
- 自动执行**强制备份**、写运行记录，可在「最近的替换」或「记录」页一键回滚；
- 没有沙盒外读写权限时**跳过并写明原因**（不静默）；已经有一次替换在跑时也不重复触发；
- 只做「启动时」「激活成功后」两个触发点 —— iOS 上定时后台任务不可靠，所以不做定时。

用法细节见 [docs/一键替换.md](docs/一键替换.md)。

作者：端木awa
