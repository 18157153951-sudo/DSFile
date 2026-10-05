#!/bin/sh
# ============================================================
#  myfilza 越狱版 —— 手动安装 / 自检脚本（roothide / rootless / 经典越狱）
#
#  为什么有这个脚本：
#    在 roothide 上，只有装进**越狱根**（<jbroot>/Applications/）并带上越狱
#    entitlements 的 App 才能读写全盘；用 TrollStore 或普通证书装的 App 仍然
#    受沙盒限制。Sileo/Zebra 装 .deb 就是走这条路，如果 deb 装不上（例如
#    dpkg 报 “./rootfs/... Read-only file system”），用本脚本手动装即可。
#
#  用法（把 myfilza.app、entitlements.plist、install.sh 放同一个目录）：
#      sh install.sh            # 安装（幂等，可重复运行）
#      sh install.sh --check    # 只体检、不改任何东西，输出中文报告
#
#  设计原则：**每一步都打印命令与退出码，绝不静默失败**。
# ============================================================

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/myfilza.app"
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
step() { printf '\n== %s ==\n' "$*"; }
# 执行并打印命令 + 退出码（不静默）
run() {
  printf '   $ %s\n' "$*"
  "$@"; rc=$?
  printf '     ↳ 退出码 %s\n' "$rc"
  return $rc
}
FAIL=0

# ------------------------------------------------------------
# 0) 文件检查
# ------------------------------------------------------------
step "0/6 检查安装文件"
if [ -d "$APP" ]; then ok "App 目录: $APP"; else bad "找不到 myfilza.app（应与本脚本同目录: $HERE）"; FAIL=1; fi
if [ -f "$ENT" ]; then ok "entitlements.plist: $ENT"; else bad "找不到 entitlements.plist（应在 $HERE）"; FAIL=1; fi
if [ -f "$APP/myfilza" ]; then ok "可执行文件: myfilza.app/myfilza"; else bad "myfilza.app 里没有可执行文件 myfilza"; FAIL=1; fi
[ "$MODE" = "check" ] && [ "$FAIL" = "1" ] && { say ""; say "体检中止：先把上面缺的文件补齐（把三个文件放在同一目录）。"; exit 1; }

# ------------------------------------------------------------
# 1) 定位越狱根 jbroot
# ------------------------------------------------------------
step "1/6 定位越狱根（jbroot）"
JB=""
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
  for D in "$HERE" /Applications /usr/bin /usr/lib /usr/local/bin; do
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
  bad "没找到越狱根。请确认：① 设备已越狱且 bootstrap 已安装；② 在**越狱环境的终端**（NewTerm / SSH）里运行本脚本。"
  exit 1
fi
if [ ! -d "$JB/usr" ] && [ ! -d "$JB/bin" ]; then
  bad "越狱根 $JB 看起来不对（既没有 usr/ 也没有 bin/），为避免装错位置已中止。"
  exit 1
fi
ok "采用越狱根: $JB"

DEST="$JB/Applications/myfilza.app"

# ------------------------------------------------------------
# --check 模式：只体检
# ------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  step "体检报告（--check，不改任何东西）"
  if [ -d "$DEST" ]; then ok "已安装: $DEST"; else bad "尚未安装（$DEST 不存在）"; fi
  if [ -d "$DEST" ]; then
    if [ -L "$DEST/.jbroot" ]; then
      ok ".jbroot 符号链接: $(readlink "$DEST/.jbroot" 2>/dev/null)"
      [ "$(readlink "$DEST/.jbroot" 2>/dev/null)" = "$JB" ] || bad "  …但指向的不是当前越狱根 $JB（App 内可能解析失败）"
    else
      bad "缺少 .jbroot 符号链接（App 内越狱模式可能解析不到 jbroot）→ 重跑一次 sh install.sh 会自动创建"
    fi
    if [ -f "$DEST/myfilza" ]; then
      if command -v ldid >/dev/null 2>&1; then
        for K in platform-application com.apple.private.security.storage.AppDataContainers; do
          if ldid -e "$DEST/myfilza" 2>/dev/null | grep -q "$K"; then ok "签名含 $K"; else bad "签名缺 $K"; fi
        done
      else
        bad "找不到 ldid，无法校验签名（请在 Sileo/Zebra 装 ldid）"
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
    if [ -x "$U" ]; then ok "uicache 可用: $U"; else bad "uicache 不可用: $U"; fi
  done
  say ""
  say "如果「已安装 + 签名 OK + .jbroot OK」但桌面仍无图标：执行 sbreload（或 killall -9 SpringBoard）后重看。"
  exit 0
fi

# ------------------------------------------------------------
# 2) 复制 + 权限
# ------------------------------------------------------------
step "2/6 安装到 $DEST"
run mkdir -p "$JB/Applications" || FAIL=1
run rm -rf "$DEST" || FAIL=1                      # 幂等：重复运行即覆盖安装
run cp -R "$APP" "$DEST" || FAIL=1
if [ -d "$DEST" ]; then ok "已复制"; else bad "复制失败"; FAIL=1; fi

# roothide 官方机制：含 mach-o 的目录里要有 .jbroot 符号链接指向越狱根。
# dpkg 安装时由 bootstrap 自动生成；手动安装必须我们自己建，否则 App 内的
# 越狱模式解析不到 jbroot。
step "3/6 创建 .jbroot 符号链接（roothide 机制）"
if [ -L "$DEST/.jbroot" ]; then
  ok "已存在: $(readlink "$DEST/.jbroot" 2>/dev/null)"
else
  run ln -s "$JB" "$DEST/.jbroot" && ok ".jbroot -> $JB" || { bad "创建 .jbroot 失败"; FAIL=1; }
fi

step "4/6 设置所有权与权限"
run chown -R 0:0 "$DEST" 2>/dev/null || bad "chown 失败（可能不是 root，继续但图标/权限可能异常）"
run chmod 755 "$DEST" || FAIL=1
if [ -f "$DEST/myfilza" ]; then run chmod 755 "$DEST/myfilza" || FAIL=1; fi
find "$DEST" -type d -exec chmod 755 {} \; 2>/dev/null || true
run ls -ld "$DEST" || true

# ------------------------------------------------------------
# 5) 签名
# ------------------------------------------------------------
step "5/6 用 ldid 签名（注入越狱 entitlements）"
if ! command -v ldid >/dev/null 2>&1; then
  bad "找不到 ldid。请先在 Sileo/Zebra 里安装 ldid（或终端执行 apt install ldid），然后重跑本脚本。"
  exit 1
fi
run ldid -S"$ENT" "$DEST/myfilza" || { bad "ldid 签名失败"; exit 1; }
find "$DEST" -type f \( -name '*.dylib' -o -path '*.framework/*' \) -print0 2>/dev/null \
  | xargs -0 -I{} ldid -S"$ENT" "{}" 2>/dev/null || true
say "   签名里的 entitlements："
ldid -e "$DEST/myfilza" | sed 's/^/     /'

SIGOK=1
for K in platform-application com.apple.private.security.storage.AppDataContainers; do
  if ldid -e "$DEST/myfilza" | grep -q "$K"; then ok "签名含 $K"; else bad "签名缺 $K"; SIGOK=0; fi
done
[ "$SIGOK" = "1" ] || { say ""; say "❌ entitlements 不完整，装上去可能仍读不到系统路径。请把上面输出发回排查。"; exit 1; }

# ------------------------------------------------------------
# 6) 刷新桌面图标（uicache，绝对路径 + 多路尝试，全部打印）
# ------------------------------------------------------------
step "6/6 刷新桌面图标（uicache）"
UICOK=0
for U in "$JB/usr/bin/uicache" /usr/bin/uicache "$(command -v uicache 2>/dev/null || true)"; do
  [ -n "$U" ] || continue
  [ -x "$U" ] || { bad "$U 不存在或不可执行"; continue; }
  for A in -a --all; do
    if run "$U" "$A"; then UICOK=1; break; fi
  done
  [ "$UICOK" = "1" ] && break
  if run "$U" -p "$JB/Applications/myfilza.app"; then UICOK=1; break; fi
done
if [ "$UICOK" = "1" ]; then
  ok "uicache 成功（桌面应出现 $DISP）"
else
  bad "uicache 全部失败 —— 图标可能不出现。请执行 sbreload（或 killall -9 SpringBoard）后重看。"
fi

# ------------------------------------------------------------
# 自检
# ------------------------------------------------------------
step "自检"
ls -l "$DEST/" 2>/dev/null | sed 's/^/     /'
if [ -L "$DEST/.jbroot" ]; then ok ".jbroot -> $(readlink "$DEST/.jbroot" 2>/dev/null)"; else bad ".jbroot 缺失"; fi
if command -v plutil >/dev/null 2>&1; then
  plutil -p "$DEST/Info.plist" 2>/dev/null | grep -E 'CFBundleIdentifier|CFBundleDisplayName' | sed 's/^/     /'
fi
ls -l "$DEST/myfilza" 2>/dev/null | sed 's/^/     /'

say ""
if [ "$FAIL" = "0" ]; then
  say "✅ 安装完成。桌面应出现 $DISP（越狱版）。"
else
  say "⚠️ 安装完成但有步骤失败（见上面 ✗）。先把整段输出发回排查。"
fi
say "   打开它 → 设置 →「访问路径」选「仅越狱」（或「自动」）。"
say "   期望日志：版本形态 = 越狱版(.deb)（bundle id = $PKG_ID）"
say "             [越狱诊断] platform-application = true"
say "             ✅ 本次实际路径 = 越狱 · 直接 POSIX（可读写）"
say ""
say "   桌面仍无图标时：执行 sbreload（或 killall -9 SpringBoard）后重看；"
say "   仍不行就运行 sh install.sh --check 并把报告发回。"
