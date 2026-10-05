#!/bin/sh
# ============================================================
#  myfilza 越狱版 —— 一条命令装好（roothide / rootless / 经典越狱）
#
#  用法（把 myfilza.app、entitlements.plist、install.sh 放在同一个目录）：
#      sh install.sh            # 全自动：体检 → 自动修复 → 安装 → 校验 → 刷新桌面
#      sh install.sh --check    # 只体检、不改动任何东西（排错用）
#
#  为什么需要这个脚本：
#    在 roothide 上，只有装进**越狱根**（<jbroot>/Applications/）并带上越狱
#    entitlements 的 App 才能读写全盘；TrollStore / 普通证书装的 App 仍然受沙盒
#    限制。Sileo/Zebra 装 .deb 就是走这条路；deb 装不上时（例如 dpkg 报
#    “./rootfs/... Read-only file system”）用本脚本，效果完全一样。
#
#  设计原则：**全自动、每一步都打印命令与退出码、失败绝不静默**。
# ============================================================

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENT="$HERE/entitlements.plist"
PKG_ID="com.dsfile.app.jb"
DISP="myfilza JB"

MODE="install"
case "${1:-}" in
  --check|-c|check) MODE="check" ;;
  "" ) ;;
  * ) echo "用法: sh install.sh [--check]"; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
bad()  { printf '   ✗ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
# 执行并打印命令 + 退出码（绝不静默）
run() {
  printf '   $ %s\n' "$*"
  "$@"; rc=$?
  printf '     ↳ 退出码 %s\n' "$rc"
  return $rc
}
FAIL=0
JB=""
DEST=""

# ------------------------------------------------------------
# 0) 找 App 与 entitlements（自动在常见位置里找，省得用户摆文件）
# ------------------------------------------------------------
step "0/7 检查安装文件"

APP=""
for C in "$HERE/myfilza.app" /var/mobile/Documents/myfilza.app /var/mobile/myfilza.app \
         "$HERE"/myfilza*/myfilza.app; do
  if [ -d "$C" ] && [ -f "$C/myfilza" ]; then APP="$C"; break; fi
done
if [ -n "$APP" ]; then ok "App: $APP"; else
  bad "找不到 myfilza.app（应把 myfilza.app / entitlements.plist / install.sh 放在同一目录）"
  FAIL=1
fi
if [ -f "$ENT" ]; then ok "entitlements.plist: $ENT"; else bad "找不到 entitlements.plist（应在 $HERE）"; FAIL=1; fi
if [ "$FAIL" = "1" ]; then
  say ""
  say "❌ 安装文件不全，先按上面提示补齐（三个文件放同一目录），再重跑本脚本。"
  exit 1
fi

# ------------------------------------------------------------
# 1) 定位越狱根 jbroot
# ------------------------------------------------------------
step "1/7 定位越狱根（jbroot）"
# ① 最权威：bootstrap 自带的 jbroot 命令行工具
if command -v jbroot >/dev/null 2>&1; then
  CAND="$(jbroot / 2>/dev/null || true)"
  if [ -n "$CAND" ] && [ -d "$CAND" ]; then JB="$CAND"; ok "来自 jbroot 命令: $JB"; fi
fi
# ② 环境变量
if [ -z "$JB" ]; then
  for V in "${JBROOT:-}" "${ROOTHIDE:-}"; do
    if [ -n "$V" ] && [ -d "$V" ]; then JB="$V"; ok "来自环境变量: $JB"; break; fi
  done
fi
# ③ roothide 官方机制：含 mach-o 的目录里有 .jbroot 符号链接指向越狱根
if [ -z "$JB" ]; then
  for D in "$HERE" /Applications /usr/bin /usr/lib /usr/local/bin "$HERE/myfilza.app"; do
    if [ -L "$D/.jbroot" ]; then
      CAND="$(readlink "$D/.jbroot" 2>/dev/null || true)"
      if [ -n "$CAND" ] && [ -d "$CAND" ]; then JB="$CAND"; ok "来自 .jbroot 符号链接（$D）: $JB"; break; fi
    fi
  done
fi
# ④ 扫描 .jbroot-* 目录（roothide 的 /var/containers 是真实 rootfs 的镜像，扫得到）
if [ -z "$JB" ]; then
  for BASE in /var/containers/Bundle/Application /var/mobile/Library/roothide /var/containers/Bundle /; do
    for D in "$BASE"/.jbroot-*; do
      [ -d "$D" ] || continue
      if [ -d "$D/usr" ] || [ -d "$D/bin" ]; then JB="$D"; ok "扫描到: $JB"; break; fi
    done
    [ -n "$JB" ] && break
  done
fi
# ⑤ rootless（Dopamine / palera1n rootless）固定路径
if [ -z "$JB" ] && [ -d /var/jb/usr ]; then JB="/var/jb"; ok "rootless 固定路径: $JB"; fi

if [ -z "$JB" ]; then
  bad "没找到越狱根。请确认：① 设备已越狱且 bootstrap 已安装；② 在**越狱环境的终端**（NewTerm / SSH，建议 root）里运行本脚本。"
  exit 1
fi
if [ ! -d "$JB/usr" ] && [ ! -d "$JB/bin" ]; then
  bad "越狱根 $JB 看起来不对（既没有 usr/ 也没有 bin/），为避免装错位置已中止。"
  exit 1
fi
ok "采用越狱根: $JB"
DEST="$JB/Applications/myfilza.app"

# ------------------------------------------------------------
# --check 模式：只体检、不改动
# ------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  step "体检报告（--check，不改任何东西）"
  if [ -d "$DEST" ]; then ok "已安装: $DEST"; else bad "尚未安装（$DEST 不存在）→ 直接运行 sh install.sh 即可自动安装"; fi
  if [ -d "$DEST" ]; then
    if [ -L "$DEST/.jbroot" ]; then
      ok ".jbroot 符号链接: $(readlink "$DEST/.jbroot" 2>/dev/null)"
      [ "$(readlink "$DEST/.jbroot" 2>/dev/null)" = "$JB" ] || bad "  …但指向的不是当前越狱根 $JB（App 内可能解析失败）→ 重跑 sh install.sh 会自动修正"
    else
      bad "缺少 .jbroot 符号链接 → 重跑 sh install.sh 会自动创建"
    fi
    if [ -f "$DEST/myfilza" ]; then
      if command -v ldid >/dev/null 2>&1; then
        for K in platform-application com.apple.private.security.storage.AppDataContainers; do
          if ldid -e "$DEST/myfilza" 2>/dev/null | grep -q "$K"; then ok "签名含 $K"; else bad "签名缺 $K → 重跑 sh install.sh 会自动重签"; fi
        done
      else
        bad "找不到 ldid（重跑 sh install.sh 会尝试自动安装）"
      fi
      ls -l "$DEST/myfilza" | sed 's/^/     /'
    else
      bad "缺少可执行文件 $DEST/myfilza"
    fi
    if command -v plutil >/dev/null 2>&1; then
      plutil -p "$DEST/Info.plist" 2>/dev/null | grep -E 'CFBundleIdentifier|CFBundleDisplayName' | sed 's/^/     /'
    fi
  fi
  for U in "$JB/usr/bin/uicache" /usr/bin/uicache; do
    if [ -x "$U" ]; then ok "uicache 可用: $U"; else warn "uicache 不可用: $U"; fi
  done
  say ""
  say "结论：直接运行 sh install.sh 即可自动完成安装 + 刷新桌面（无需其他操作）。"
  exit 0
fi

# ------------------------------------------------------------
# 2) ldid（缺了就自动装）
# ------------------------------------------------------------
step "2/7 检查签名工具 ldid"
if command -v ldid >/dev/null 2>&1; then
  ok "ldid: $(command -v ldid)"
else
  warn "没找到 ldid，尝试自动安装…"
  LDO=0
  for A in "$JB/usr/bin/apt-get" /usr/bin/apt-get "$(command -v apt-get 2>/dev/null || true)"; do
    [ -n "$A" ] || continue
    [ -x "$A" ] || continue
    if run "$A" install -y ldid; then LDO=1; break; fi
  done
  if [ "$LDO" = "1" ] && command -v ldid >/dev/null 2>&1; then
    ok "ldid 安装成功: $(command -v ldid)"
  else
    bad "自动安装 ldid 失败。请在 Sileo/Zebra 里安装 ldid 后重跑本脚本（或终端执行 apt-get install -y ldid）。"
    exit 1
  fi
fi

# ------------------------------------------------------------
# 3) 安装（复制 + .jbroot 链接 + 权限）
# ------------------------------------------------------------
step "3/7 安装到 $DEST"
run mkdir -p "$JB/Applications" || FAIL=1
run rm -rf "$DEST" || FAIL=1                      # 幂等：重复运行即覆盖安装
run cp -R "$APP" "$DEST" || FAIL=1
if [ -d "$DEST" ] && [ -f "$DEST/myfilza" ]; then ok "已复制"; else bad "复制失败"; FAIL=1; fi

# roothide 官方机制：含 mach-o 的目录里要有 .jbroot 符号链接指向越狱根。
# dpkg 安装时由 bootstrap 自动生成；手动安装必须我们自己建，否则 App 内的
# 越狱模式解析不到 jbroot。
if [ -L "$DEST/.jbroot" ]; then
  ok ".jbroot 已存在: $(readlink "$DEST/.jbroot" 2>/dev/null)"
  if [ "$(readlink "$DEST/.jbroot" 2>/dev/null)" != "$JB" ]; then
    run rm -f "$DEST/.jbroot" && run ln -s "$JB" "$DEST/.jbroot" && ok ".jbroot 已修正 -> $JB"
  fi
else
  run ln -s "$JB" "$DEST/.jbroot" && ok ".jbroot -> $JB" || { bad "创建 .jbroot 失败"; FAIL=1; }
fi

run chown -R 0:0 "$DEST" 2>/dev/null || warn "chown 失败（可能不是 root，继续，但权限/图标可能异常）"
run chmod 755 "$DEST" || FAIL=1
run chmod 755 "$DEST/myfilza" || FAIL=1
find "$DEST" -type d -exec chmod 755 {} \; 2>/dev/null || true

# ------------------------------------------------------------
# 4) 签名（注入越狱 entitlements）
# ------------------------------------------------------------
step "4/7 用 ldid 签名（注入越狱 entitlements）"
run ldid -S"$ENT" "$DEST/myfilza" || { bad "ldid 签名失败"; exit 1; }
find "$DEST" -type f \( -name '*.dylib' -o -path '*.framework/*' \) -print0 2>/dev/null \
  | xargs -0 -I{} ldid -S"$ENT" "{}" 2>/dev/null || true

SIGOK=1
for K in platform-application \
         com.apple.private.security.no-sandbox \
         com.apple.private.security.storage.AppBundles \
         com.apple.private.security.storage.AppDataContainers; do
  if ldid -e "$DEST/myfilza" | grep -q "$K"; then ok "签名含 $K"; else bad "签名缺 $K"; SIGOK=0; fi
done
[ "$SIGOK" = "1" ] || { say ""; say "❌ entitlements 不完整，装上去可能仍读不到系统路径。请把上面输出发回排查。"; exit 1; }

# ------------------------------------------------------------
# 5) 刷新图标（uicache，绝对路径 + 多路尝试，全部打印）
# ------------------------------------------------------------
step "5/7 刷新桌面图标（uicache）"
UICOK=0
for U in "$JB/usr/bin/uicache" /usr/bin/uicache /bin/uicache "$(command -v uicache 2>/dev/null || true)"; do
  [ -n "$U" ] || continue
  [ -x "$U" ] || { warn "$U 不存在或不可执行"; continue; }
  for A in -a --all; do
    if run "$U" "$A"; then UICOK=1; break; fi
  done
  [ "$UICOK" = "1" ] && break
  if run "$U" -p "$DEST"; then UICOK=1; break; fi
done
if [ "$UICOK" = "1" ]; then ok "uicache 成功"; else bad "uicache 全部失败 —— 图标可能不出现（下一步会自动刷新桌面再试）"; fi

# ------------------------------------------------------------
# 6) 自动刷新桌面（respring）：装上即用的关键
# ------------------------------------------------------------
step "6/7 刷新桌面（respring）"
say "   即将刷新桌面（图标会立刻出现；屏幕闪一下属正常）…"
RESPRUNG=0
for C in sbreload; do
  if command -v "$C" >/dev/null 2>&1; then
    if run "$C"; then RESPRUNG=1; break; fi
  else
    warn "没有 $C，换下一种方式"
  fi
done
if [ "$RESPRUNG" = "0" ] && command -v killall >/dev/null 2>&1; then
  if run killall -9 SpringBoard; then RESPRUNG=1; fi
fi
if [ "$RESPRUNG" = "0" ]; then
  if run launchctl kickstart -k system/com.apple.SpringBoard; then RESPRUNG=1; fi
fi
if [ "$RESPRUNG" = "1" ]; then ok "桌面已刷新"; else warn "自动刷新未成功（不影响安装）—— 手动执行 sbreload 或 killall -9 SpringBoard 即可"; fi

# ------------------------------------------------------------
# 7) 结论（给人看的一段）
# ------------------------------------------------------------
step "7/7 结论"
say "   安装位置：$DEST"
say "   bundle id：$PKG_ID（显示名 $DISP，与侧载版 $PKG_ID 不同，两个可共存）"
if [ "$SIGOK" = "1" ]; then say "   越狱 entitlements：✓ 四件套齐全（含读写 App 包体/数据容器）"; else say "   越狱 entitlements：✗ 不完整"; fi
if [ "$UICOK" = "1" ]; then say "   uicache 注册：✓ 成功"; else say "   uicache 注册：✗ 失败（桌面可能暂时看不到图标，重启桌面后会出现）"; fi
if [ "$RESPRUNG" = "1" ]; then say "   桌面刷新：✓ 已完成"; else say "   桌面刷新：✗ 未成功（手动 sbreload 即可）"; fi
say ""
if [ "$FAIL" = "0" ] && [ "$SIGOK" = "1" ]; then
  say "✅ 装好了 —— 现在去桌面点「$DISP」即可（默认「自动」模式会优先走越狱路径，无需任何设置）。"
else
  say "⚠️ 安装完成但有步骤失败（见上面 ✗）。把整段输出发回即可排查。"
fi
say ""
say "   期望启动日志（打开 App 第一行/前几行）："
say "     版本形态 = 越狱版(.deb)（bundle id = $PKG_ID）"
say "     [越狱诊断] platform-application = true"
say "     ✅ 本次实际路径 = 越狱 · 直接 POSIX（可读写）"
say ""
say "   桌面仍无图标：重启桌面（sbreload / killall -9 SpringBoard）后重看；"
say "   仍不行就运行 sh install.sh --check 并把报告发回。"
