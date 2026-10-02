# 魔改 Filza：把 FilzaJailedDS 注入进 Filza

不自己写文件管理器，而是用 **[FilzaJailedDS](https://github.com/34306/FilzaJailedDS)**
（34306 的注入型 tweak）编出一个 dylib，注入到**真正的 Filza** 里：
UI 用 Filza 的，内核权限用它的 DarkSword 漏洞 + 沙盒逃逸。

## 为什么走这条路

| | 我们自己移植内核的那套（DSFile App） | 魔改 Filza（本方案） |
| --- | --- | --- |
| 内核漏洞实现 | 移植版（ClearSword，或 lara 的实现） | **原版实现**（`kexploit_opa334.m`） |
| XPF / ChOma | lara 只给预编译 dylib，我们只能打桩 | **源码自带**（`XPF/src`、`XPF/external/ChOma/src`） |
| 文件管理 UI | 自己写的（能力有限） | **Filza 原版 UI**（你本来就要的那个） |
| 依赖注入框架 | 无 | 无（`Tweak.m` 是纯 ObjC + runtime，不需要 Cydia Substrate/ellekit） |

## 产物

- `FilzaTweak/` —— 上游源码（逐字节原样，见 [NOTICE.md](../FilzaTweak/NOTICE.md)）
- `FilzaTweak/project.yml` —— XcodeGen 工程（产出 dylib）
- `.github/workflows/build-filza-tweak.yml` —— 构建流水线，artifact 名 `FilzaTweak-dylib`
- 产物文件名：**`FilzaApplySandboxExt.dylib`**（arm64，未签名，iOS 15.0+）

最近一次成功构建：见仓库 Actions 里的 `Build Filza Tweak`，在 artifact 里下载 `FilzaApplySandboxExt.dylib`。
`otool -L` 显示它依赖 UIKit / Foundation / IOKit / CoreFoundation / IOSurface / libz / libsandbox
（都是系统库，不会缺依赖）。

### 自己重新构建

```bash
# 需要 macOS + Xcode
brew install xcodegen
cd FilzaTweak
xcodegen generate
xcodebuild build -project FilzaTweak.xcodeproj -target FilzaApplySandboxExt \
  -configuration Release -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$PWD/build/Release-iphoneos" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
# 产物：build/Release-iphoneos/FilzaApplySandboxExt.dylib
```

或者直接在 GitHub 上跑：Actions → `Build Filza Tweak` → Run workflow → 下载 artifact。

## 你需要自备的东西

1. **Filza 的 IPA**（能安装到你自己设备的那份；App Store 版**不能**注入，必须是可重签的 IPA）。
2. **签名工具**（二选一，见下）：eSign / Sideloadly / 任何支持 dylib 注入的重签工具。
3. 你自己的证书或 Apple ID（重签用）。

## 注入步骤

### 方案 A：eSign（推荐，纯手机上完成）

1. 把 `FilzaApplySandboxExt.dylib` 和 Filza 的 IPA 都导入 eSign；
2. 在 eSign 里点 Filza 的 IPA → **签名**；
3. 打开 **「注入 dylib」**（部分版本叫「注入动态库 / Inject dylib」），选择
   `FilzaApplySandboxExt.dylib`；
4. 选择证书 → 开始签名 → 安装；
5. 装好后**打开 Filza 就会自动跑漏洞**（见下面的行为说明）。

### 方案 B：Sideloadly（电脑上完成）

1. 打开 Sideloadly，把 Filza 的 IPA 拖进窗口（填好 Apple ID）；
2. 展开 **Advanced Options**，勾选 **Inject dylibs/frameworks**；
3. 出现注入目录后，把 `FilzaApplySandboxExt.dylib` 放进去
   （或使用命令行参数 `-- Inject dylib` 指定该文件）；
4. 开始安装；首次运行需要在「设置 → 通用 → VPN与设备管理」里信任描述文件。

### 方案 C：其它支持 dylib 注入的工具

Feather / Scarlet / Azule 等只要提供「注入 dylib」功能，同样把
`FilzaApplySandboxExt.dylib` 注入 Filza IPA 即可。

## 注意事项（重要）

1. **注入后 Filza 一启动就会自动执行内核漏洞 + 沙盒逃逸**（`Tweak.m` 里的
   `__attribute__((constructor))`）——这是上游的既定行为，不是可选开关。
2. **内核漏洞本身存在 panic 概率**。这个漏洞（DarkSword / CVE-2025-43520 一系）
   靠内存竞态 + 越界写，时机不对时可能把内核打崩导致**设备重启**。
   我们自己的 App（ClearSword 后端）在 iPhone13,4 / iOS 18.5 上也有同样的现象；
   lara 的实现我们在同一台机器上试过，稳定性并没有更好。
   **本方案用的是原版实现，也不改变这个固有概率。**
3. **Filza 版本差异**：tweak 通过 `class_getInstanceMethod` 动态找方法，找不到就跳过
   （代码里都是 `if (m) { ... }` 保护），所以换 Filza 版本一般不会崩，但个别 hook
   （压缩包解压、应用列表、激活页等）可能失效。
4. **权限范围**：注入成功后 Filza 拿到的是**完整文件系统访问**（这正是目的）。
   别把这个包给别人用，也别在别人的设备上装。
5. **dylib 的 install name** 是 Theos 默认的 `/usr/local/lib/FilzaApplySandboxExt.dylib`。
   eSign / Sideloadly 注入时一般会自动改成 `@executable_path/...`；
   如果启动时报 `Library not loaded: /usr/local/lib/FilzaApplySandboxExt.dylib`，用下面命令处理：

   ```bash
   install_name_tool -change /usr/local/lib/FilzaApplySandboxExt.dylib \
       @executable_path/FilzaApplySandboxExt.dylib FilzaApplySandboxExt.dylib
   ```

6. **必须重签**：产出的 dylib 是**未签名**的，注入后跟着 Filza 一起用你的证书签。
7. 许可证：上游没有附 `LICENSE`，本仓库只把它当作自用/研究材料（详见
   [FilzaTweak/NOTICE.md](../FilzaTweak/NOTICE.md)）。

## 与本仓库 DSFile App 的关系

两者互不影响：

- `main` 分支里的 `DSFile/` 是我们自己写的 App（文件管理器 + 脚本配方 + 备份回滚），
  内核后端目前是 ClearSword；
- `FilzaTweak/` 是这条「魔改 Filza」路线，独立工程、独立 workflow、独立产物；
- 两个 workflow 各自构建各自的产物，互不覆盖。
