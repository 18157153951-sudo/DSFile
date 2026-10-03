# InjectDylib — MyfilzaReplace（注入版替换向导）

这个目录把 myfilza 的「替换」能力编成一个**动态库（dylib）**，用于注入到宿主 App
（目前针对 3105）里运行。

## 为什么这样做

宿主 App（3105）在用户的 iPhone13,4 / iOS 18.5 上**本来就能访问其它 App 的数据容器**。
把我们的替换向导注入进去后，我们的代码就运行在一个**已经有文件访问权限的进程**里，
因此：

- **不需要内核漏洞** → 没有内核 panic / 重启风险；
- **不需要沙盒逃逸** → 不用改 label / ext_set；
- 只需要 POSIX 文件操作（本目录里的 `Sources/Core/DSKernel.m` 就是为此写的替身）。

## 组成

| 路径 | 作用 |
| --- | --- |
| `Sources/Bootstrap/MyfilzaReplaceBootstrap.m` | dylib 载入点（`__attribute__((constructor))`），延迟调用 Swift 侧入口 |
| `Sources/Bootstrap/MyfilzaReplaceLauncher.swift` | 悬浮按钮（可拖动 / 长按最小化）+ 以 sheet 打开替换向导 + 文件日志 |
| `Sources/Core/DSKernel.{h,m}` | **注入版替身**：同名同 API，但内部全是 POSIX（探测 / chown / chmod），无任何内核代码 |
| `Sources/Core/*`、`Sources/Files/*`、`Sources/Replace/*`、`Sources/Scripts/*` | 从 `DSFile/Sources/` 复制的替换引擎（向导 / 配方 / 备份 / 回滚 / 任务），逻辑未改 |
| `project.yml` | XcodeGen 工程（`library.dynamic`、iOS 15、arm64、不签名） |

## 构建

见仓库根 `.github/workflows/build-inject-dylib.yml`（CI 产出 `MyfilzaReplace.dylib`）。
本地构建：

```sh
cd InjectDylib
xcodegen generate
xcodebuild build -project MyfilzaReplace.xcodeproj -target MyfilzaReplace \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
```

## 注入与使用

见 `docs/注入3105.md`（eSign 纯手机方案 + Sideloadly 电脑方案，两条都写了）。

## 数据落在哪里

备份 / 运行记录 / 自动化任务 / 导入的替换源，全部写在**宿主 App 自己的沙盒**里
（`<宿主 Home>/Documents/Backups`、`Runs`、`AutoTasks`、`ReplaceSources`），
外加一份注入日志 `<宿主 Home>/Documents/Logs/myfilza-inject.log`。
