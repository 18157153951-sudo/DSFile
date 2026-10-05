#!/bin/sh
# ============================================================
#  myfilza 越狱版 —— 手动安装脚本（roothide / rootless / 经典越狱）
#
#  为什么有这个脚本：
#    在 roothide 上，只有装进**越狱根**（<jbroot>/Applications/）并带上越狱
#    entitlements 的 App 才能读写全盘；用 TrollStore 或普通证书装的 App 仍然
#    受沙盒限制。Sileo/Zebra 装 .deb 就是走这条路，如果 deb 装不上（例如
#    dpkg 报 “./rootfs/... Read-only file system”），用本脚本手动装即可。
#
#  用法（把 myfilza.app、entitlements.plist、install.sh 放同一个目录）：
#      sh install.sh
#  需要：越狱环境里已经有 ldid 与 uicache（bootstrap 自带；缺了脚本会告诉你）。
# ============================================================

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/myfilza.app"
ENT="$HERE/entitlements.plist"
PKG_ID="com.dsfile.app.jb"

echo "== 0/5 检查文件 =="
[ -d "$APP" ] || { echo "❌ 找不到 myfilza.app（请把它和本脚本放在同一目录：$HERE）"; exit 1; }
[ -f "$ENT" ] || { echo "❌ 找不到 entitlements.plist（应在 $HERE）"; exit 1; }
[ -f "$APP/myfilza" ] || { echo "❌ myfilza.app 里没有可执行文件 myfilza"; exit 1; }
echo "   · App 目录: $APP"

echo "== 1/5 定位越狱根（jbroot）=="
JB=""
# ① 最权威：bootstrap 自带的 jbroot 命令行工具
if command -v jbroot >/dev/null 2>&1; then
  CAND="$(jbroot / 2>/dev/null || true)"
  if [ -n "$CAND" ] && [ -d "$CAND" ]; then JB="$CAND"; echo "   · 来自 jbroot 命令: $JB"; fi
fi
# ② 环境变量
if [ -z "$JB" ]; then
  for V in "$JBROOT" "$ROOTHIDE"; do
    if [ -n "$V" ] && [ -d "$V" ]; then JB="$V"; echo "   · 来自环境变量: $JB"; break; fi
  done
fi
# ③ roothide 官方机制：含 mach-o 的目录里会有一个 .jbroot 符号链接指向越狱根
if [ -z "$JB" ]; then
  for D in "$HERE" /Applications /usr/bin /usr/lib /usr/local/bin; do
    if [ -L "$D/.jbroot" ]; then
      CAND="$(readlink "$D/.jbroot" 2>/dev/null || true)"
      if [ -n "$CAND" ] && [ -d "$CAND" ]; then JB="$CAND"; echo "   · 来自 .jbroot 符号链接（$D）: $JB"; break; fi
    fi
  done
fi
# ④ 扫描 .jbroot-* 目录
#    注意：roothide 的 /var/containers 与 /var/mobile/Containers 是指向真实
#    rootfs 的镜像（见 roothide filemirror.md），所以这里扫得到真实越狱根。
if [ -z "$JB" ]; then
  for BASE in /var/containers/Bundle/Application /var/mobile/Library/roothide /var/containers/Bundle /; do
    for D in "$BASE"/.jbroot-*; do
      [ -d "$D" ] || continue
      if [ -d "$D/usr" ] || [ -d "$D/bin" ]; then JB="$D"; echo "   · 扫描到: $JB"; break; fi
    done
    [ -n "$JB" ] && break
  done
fi
# ⑤ rootless（Dopamine / palera1n rootless）固定路径
if [ -z "$JB" ] && [ -d /var/jb/usr ]; then JB="/var/jb"; echo "   · rootless 固定路径: $JB"; fi

[ -n "$JB" ] || {
  echo "❌ 没找到越狱根。请确认：① 设备已越狱且已安装 bootstrap；② 在越狱环境的终端里运行本脚本。"
  exit 1
}
if [ ! -d "$JB/usr" ] && [ ! -d "$JB/bin" ]; then
  echo "❌ 越狱根 $JB 看起来不对（既没有 usr/ 也没有 bin/），为避免装错位置已中止。"
  exit 1
fi
echo "   · 采用越狱根: $JB"

DEST="$JB/Applications/myfilza.app"
echo "== 2/5 安装到 $DEST =="
mkdir -p "$JB/Applications"
rm -rf "$DEST"                      # 幂等：重复运行就是覆盖安装
cp -R "$APP" "$DEST"
chown -R 0:0 "$DEST" 2>/dev/null || true
echo "   · 已复制"

echo "== 3/5 用 ldid 签名（注入越狱 entitlements）=="
if ! command -v ldid >/dev/null 2>&1; then
  echo "❌ 找不到 ldid。请先安装：在 Sileo/Zebra 里装 ldid（或终端执行 apt install ldid）"
  exit 1
fi
ldid -S"$ENT" "$DEST/myfilza" || { echo "❌ ldid 签名失败"; exit 1; }
find "$DEST" -type f \( -name '*.dylib' -o -path '*.framework/*' \) -print0 2>/dev/null \
  | xargs -0 -I{} ldid -S"$ENT" "{}" 2>/dev/null || true
echo "   · 已签名，签名里的 entitlements："
ldid -e "$DEST/myfilza" | sed 's/^/     /'

echo "== 4/5 刷新桌面图标（uicache）=="
if command -v uicache >/dev/null 2>&1; then
  uicache -a >/dev/null 2>&1 || uicache -p /Applications/myfilza.app >/dev/null 2>&1 || true
  echo "   · uicache 已执行"
else
  echo "   ⚠️ 找不到 uicache：请手动 respring 一次，图标才会出现"
fi

echo "== 5/5 校验 =="
ls -ld "$DEST" | sed 's/^/   /'
ls -l "$DEST/myfilza" | sed 's/^/   /'
OK=1
for K in platform-application com.apple.private.security.storage.AppDataContainers; do
  if ldid -e "$DEST/myfilza" | grep -q "$K"; then
    echo "   ✓ $K"
  else
    echo "   ✗ $K 缺失"
    OK=0
  fi
done
[ "$OK" = "1" ] || { echo "❌ entitlements 不完整，装上去可能仍然读不到系统路径。"; exit 1; }

echo ""
echo "✅ 安装完成。桌面上应出现 myfilza JB（越狱版）。"
echo "   打开它 → 设置 →「访问路径」选「仅越狱」（或「自动」）。"
echo "   期望日志：版本形态 = 越狱版(.deb)（bundle id = $PKG_ID）"
echo "             ✅ 本次实际路径 = 越狱 · 直接 POSIX（可读写）"
