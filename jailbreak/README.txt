myfilza 越狱版 —— 装上即用
================================

【最快的一条命令】
  把 myfilza.app、entitlements.plist、install.sh 放到同一个目录，然后在越狱终端里执行：

      sh install.sh

  剩下的它全自动做完：
      找越狱根 → 装进 <jbroot>/Applications/ → ldid 注入越狱 entitlements
      → uicache 注册图标 → 自动刷新桌面 → 打印结论
  装完直接去桌面点「myfilza JB」即可（默认「自动」模式会优先走越狱路径，不用改任何设置）。

【如果 Sileo/Zebra 装 deb 报错】
  dpkg 报 “error creating directory "./rootfs/Applications/...": Read-only file system”
  说明包被当成"要写只读系统卷"了 → 直接用上面的 sh install.sh，效果完全一样，不经过 dpkg。

【只想看现状、不改动任何东西】
      sh install.sh --check

【为什么需要它】
  roothide 的设计是"对 App 隐藏越狱"：用 TrollStore 或普通证书安装的 App 仍然被沙盒关着，
  读不到 /var/mobile 等路径。只有装进越狱根（<jbroot>/Applications/）并带上越狱
  entitlements 的越狱 App 才能读写全盘。Sileo/Zebra 装 .deb 走的就是这条路。

【装完怎么验】
  打开 myfilza JB，日志前几行应有：
      [启动] ... 版本形态 = 越狱版(.deb)（bundle id = com.dsfile.app.jb）
      [越狱诊断] platform-application = true
      ✅ 本次实际路径 = 越狱 · 直接 POSIX（可读写）

【出问题怎么回报】
  把 install.sh 的整段输出（每一步都打印命令与退出码）+ App 里 Documents/Logs/ 最新那份日志
  发回即可，一次就能定位。
  常见 errno：EPERM = 沙盒拒绝（entitlements 没生效）；EACCES = 权限不足；ENOENT = 路径不存在。
