myfilza 越狱版 —— 手动安装包
================================

这个压缩包里有三样东西：
  myfilza.app           越狱版 App（bundle id = com.dsfile.app.jb，桌面名 myfilza JB）
  entitlements.plist    越狱 entitlements（roothide 官方文档列的基础四件套 + 两个附加）
  install.sh            自动安装脚本（定位越狱根 → 复制 → ldid 签名 → uicache → 校验）

为什么要用它
------------
在 roothide 上，App 默认被沙盒关着（这是 roothide 的设计：对 App 隐藏越狱）。
用 TrollStore 或普通证书安装的 App **不会**获得越狱权限，读不到 /var/mobile 等路径。
只有装进越狱根（<jbroot>/Applications/）并带上越狱 entitlements 的 App 才能读写全盘。
Sileo/Zebra 装 .deb 走的就是这条路；如果 deb 装不上（例如 dpkg 报
“error creating directory "./rootfs/Applications/...": Read-only file system”），
就用这个手动包。

怎么装（三选一，推荐第 1 种）
----------------------------
1) 终端运行脚本（最省事，需要越狱环境里的终端 / SSH）
   把三样东西放进同一个目录，然后：
       cd 该目录
       sh install.sh
   脚本每一步都会打印中文说明；失败会明确告诉你缺什么。
   需要 bootstrap 里已有 ldid 与 uicache（一般都有；缺了脚本会提示怎么装）。

2) 用 Filza 手动放（没有终端时）
   a. 用 Filza 进入越狱根（roothide 里形如
      /var/containers/Bundle/Application/.jbroot-XXXXXXXX/，
      或直接看根目录下的 .jbroot-* 目录）；
   b. 把 myfilza.app 整个复制到 <越狱根>/Applications/ 下；
   c. 用 Filza 的「属性/权限」把 myfilza 可执行文件设为 root:wheel、权限 0755；
   d. 这一步无法省：需要用 ldid 注入 entitlements（Filza 里若有「签名」功能可用，
      否则请回到第 1 种方式）；
   e. respring 一次让图标出现。

3) 如果你只是想先用起来
   越狱模式只在**越狱版**上生效。侧载版（com.dsfile.app）请用「仅内核」或「自动」
   走内核那条路（在那台未越狱的 iPhone 上已验证可用）。

装完怎么验
----------
打开 myfilza JB → 设置 →「访问路径」选「仅越狱」（或「自动」）。日志里应出现：
  [启动] myfilza ... · 版本形态 = 越狱版(.deb)（bundle id = com.dsfile.app.jb）
  [越狱诊断] ... jbroot 解析 ...
  ✅ 本次实际路径 = 越狱 · 直接 POSIX（可读写）
并且「应用管理器」里能看到设备上的 App 列表。

失败了怎么回报
--------------
把这几样发给开发者，一次就能定位：
  1) install.sh 的完整输出（或 Filza 操作到哪一步失败）；
  2) App 里 Documents/Logs/ 最新那份日志；
  3) 「设置 → 环境 → 探测细节」展开后的截图（含逐路径 errno 与 entitlements 清单）。
常见 errno 含义：EPERM = 沙盒拒绝（entitlements 没生效）；
EACCES = 权限不足；ENOENT = 该路径在这个越狱环境里不存在。
