#!/bin/bash
# 在 Linux（Ubuntu 22.04+，root）上从 IPSW 造 ios-fuxi 要的 HFS+ 根镜像
# 用法: sudo ./mkiosroot-linux.sh <IPSW> <输出.img> [大小=10G]
#
# 与旧版差异：
#   * iOS 16 的 BuildManifest 里可能没有 Cryptex1,AppOS，只有 OS + Cryptex1,SystemOS，
#     旧版要求三块齐全会直接失败；这里改成"OS 必需、另外两块有就拷"。
#   * 打印 ProductBuildVersion，便于核对 20H392。
#   * 每一步都打日志，失败时能定位到具体阶段。
set -euo pipefail

ipsw=${1:?用法: mkiosroot-linux.sh <IPSW> <OUT.img> [SIZE]}
out=${2:?缺输出路径}
size=${3:-10G}

[[ -f $ipsw ]] || { echo "IPSW 不存在: $ipsw" >&2; exit 1; }
[[ ! -e $out ]] || { echo "拒绝覆盖: $out" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "必须 root 运行" >&2; exit 1; }
[[ -e /dev/fuse ]] || { echo "没有 /dev/fuse，apfs-fuse 无法工作" >&2; exit 1; }

# 安全边界：本脚本只处理"新建的普通文件镜像"，绝不碰任何块设备/已有分区。
# 目标必须是 /tmp 或 $RUNNER_TEMP 下的、事先不存在的普通文件。
case "$out" in
  /dev/*) echo "拒绝对设备节点操作: $out" >&2; exit 1;;
esac
if [[ -b $out ]]; then echo "目标 $out 是块设备，拒绝格式化" >&2; exit 1; fi
case "$out" in
  /tmp/*|"${RUNNER_TEMP:-/nonexistent}"/*) ;;
  *) echo "目标 $out 不在临时目录内，为防误伤真实磁盘，拒绝执行" >&2; exit 1;;
esac

echo "== 0/5 环境 =="
df -h /
nproc; free -g | head -2

echo "== 1/5 依赖 =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq hfsprogs rsync python3 unzip cmake g++ git make \
    libfuse3-dev libbz2-dev zlib1g-dev libssl-dev pkg-config >/dev/null
modprobe hfsplus 2>/dev/null || true
if ! command -v apfs-fuse >/dev/null; then
  echo "  编译 apfs-fuse（含 lzfse 子模块）"
  T=$(mktemp -d)
  git clone --depth 1 https://github.com/sgan81/apfs-fuse.git "$T/a"
  # apfs-fuse 把 lzfse 当子模块放在 3rdparty/lzfse，不初始化子模块 CMake 直接报缺 lzfse.h
  git -C "$T/a" submodule update --init --recursive
  # CMake 4.x 已移除对 cmake_minimum_required(<3.5) 的兼容，apfs-fuse 的 CMakeLists 很老，
  # 必须显式把策略版本最低值降到 3.5，否则直接 CMake Error 退出。
  # GCC 15 不再隐式提供 <cstdint>/<stdint.h>，apfs-fuse 的 PList.cpp 等文件因此报 uint8_t/uint32_t
  # 未声明；用 -include 强制预包含，避免去改上游源码。
  cmake -S "$T/a" -B "$T/b" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_CXX_FLAGS="-include cstdint" \
    -DCMAKE_C_FLAGS="-include stdint.h"
  cmake --build "$T/b" -j"$(nproc)"
  install -m755 "$T/b/apfs-fuse" /usr/local/bin/apfs-fuse
  rm -rf "$T"
fi
apfs-fuse --help >/dev/null 2>&1 || true
echo "apfs-fuse: $(command -v apfs-fuse)"

echo "== 2/5 读 BuildManifest =="
W=$(mktemp -d)
trap 'set +e; for m in $(mount | awk "{print \$3}" | grep "^$W" | tac); do umount "$m"; done; echo "临时目录 $W 保留"' EXIT

python3 - "$ipsw" <<'PY' > "$W/names.txt"
import plistlib, sys, zipfile

KEYS = ("OS", "Cryptex1,SystemOS", "Cryptex1,AppOS")
with zipfile.ZipFile(sys.argv[1]) as z:
    man = plistlib.loads(z.read('BuildManifest.plist'))


def path_of(entry):
    """iOS 16+ 的路径在 Manifest[key]['Info']['Path']；老结构在 identity['Info'][key]['Path']。"""
    if not isinstance(entry, dict):
        return None
    info = entry.get('Info')
    if isinstance(info, dict) and info.get('Path'):
        return info['Path']
    if entry.get('Path'):          # 兼容老结构
        return entry['Path']
    return None


# 取第一个带 OS 的 identity
pick = None
for ident in man.get('BuildIdentities', []):
    m = ident.get('Manifest')
    src = m if isinstance(m, dict) else ident.get('Info', {})
    if path_of(src.get('OS')):
        pick = src
        break
if pick is None:
    raise SystemExit("BuildManifest 里找不到 OS 条目（Manifest/Info 两种结构都试过了）")

print("# ProductBuildVersion=%s ProductVersion=%s" %
      (man.get('ProductBuildVersion'), man.get('ProductVersion')))
missing = []
for k in KEYS:
    p = path_of(pick.get(k))
    if p:
        print("%s=%s" % (k, p))
    else:
        missing.append(k)
print("# missing=%s" % ",".join(missing))
PY
cat "$W/names.txt"
grep -q '^OS=' "$W/names.txt" || { echo "缺 OS dmg" >&2; exit 1; }
grep -q '# missing=Cryptex1,SystemOS' "$W/names.txt" && { echo "缺 Cryptex1,SystemOS，不完整" >&2; exit 1; }

echo "== 3/5 解出 dmg =="
while IFS='=' read -r k v; do
  case "$k" in \#*|"") continue;; esac
  echo "  unzip $k -> $v"
  unzip -o "$ipsw" "$v" -d "$W/dmg" >/dev/null
done < "$W/names.txt"
ls -l "$W/dmg" || true
# 解出 dmg 后立刻删 IPSW，把峰值压下来（runner 磁盘只有 ~30G 可用）
sync
rm -f "$ipsw"
df -h /

echo "== 4/5 造 HFS+ 卷并拷贝 =="
truncate -s "$size" "$out"
mkfs.hfsplus -s -J -v iOSRoot "$out"
mkdir -p "$W/root"
mount -t hfsplus -o loop,force "$out" "$W/root"
df -h "$W/root"

mnt() {  # mnt <dmg名> <挂载点名>
  local d="$W/dmg/$1" p="$W/$2"
  mkdir -p "$p"
  echo "  apfs-fuse $1 -> $2"
  apfs-fuse -o allow_other "$d" "$p" || apfs-fuse "$d" "$p"
}

cp_() {  # cp_ <源> <目标>
  if [[ ! -d "$1" ]]; then
    echo "  !! 跳过（源目录不存在）: $1"
    return 0
  fi
  # 目标卷剩余空间先算一遍，不够就立刻报错并给出建议大小（避免 rsync 跑到一半 ENOSPC）
  local need avail
  need=$(du -sb "$1" | cut -f1)
  avail=$(df -B1 --output=avail "$W/root" | tail -1 | tr -d ' ')
  echo "  源约 $((need/1024/1024)) MiB，卷剩余 $((avail/1024/1024)) MiB"
  if (( need > avail )); then
    echo "  !! 卷不够大：$(basename "$1") 需要 $((need/1024/1024)) MiB，只剩 $((avail/1024/1024)) MiB" >&2
    echo "  !! 请用更大的 size 重跑（建议 >= $(((need/1024/1024/1024)+3))G）" >&2
    return 1
  fi
  echo "  -> ${2#"$W/root"}"
  mkdir -p "$2"
  rsync -aH --numeric-ids "$1/" "$2/"
}

OS=$(awk -F= '/^OS=/{print $2}' "$W/names.txt")
SYSOS=$(awk -F= '/^Cryptex1,SystemOS=/{print $2}' "$W/names.txt")
APPOS=$(awk -F= '/^Cryptex1,AppOS=/{print $2}' "$W/names.txt" || true)

mnt "$OS" os
cp_ "$W/os/root" "$W/root"

if [[ -n "${SYSOS:-}" ]]; then
  mkdir -p "$W/root/private/preboot/Cryptexes/OS"
  mnt "$SYSOS" sysos
  cp_ "$W/sysos/root" "$W/root/private/preboot/Cryptexes/OS"
fi
if [[ -n "${APPOS:-}" ]]; then
  mkdir -p "$W/root/private/preboot/Cryptexes/App"
  mnt "$APPOS" appos
  cp_ "$W/appos/root" "$W/root/private/preboot/Cryptexes/App"
fi

echo "  dyld 共享缓存硬链接"
DSC=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$W/root/System/Library/Caches/com.apple.dyld"
for f in "$W/root/$DSC"/*; do
  [ -e "$f" ] || continue
  ln "$f" "$W/root/System/Library/Caches/com.apple.dyld/${f##*/}" 2>/dev/null || true
done

echo "  logd 目录（漏了 launchd 起不来）"
DB="$W/root/private/var/db"
install -d -o 272 -g 272 -m 0751 "$DB/diagnostics"
install -d -o 272 -g 272 -m 0755 "$DB/uuidtext" "$DB/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
  install -o 272 -g 272 -m 0644 /dev/null "$DB/$d/.migrated"
done

echo "  system keybag"
install -d -m 0700 -o 0 -g 0 "$W/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
 '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
 '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
 | install -m 0600 -o 0 -g 0 /dev/stdin "$W/root/private/var/keybags/systembag.kb"

echo "  已拷贝内容占用:"
du -sh "$W/root" | cut -f1
sync
umount "$W/root"

echo "== 5/5 校验 =="
# Linux 的 hfsplus 驱动 rw 支持是实验性的，大量写入后卷里留下不一致的 catalog 很正常
# （典型：HasFolderCount 标志未设、目录计数为 0）。fsck_hfs -y 修一轮不够，要修到干净。
# fsck_hfs 退出码：0=无问题，1/2/8 等=发现问题或已修复，因此循环跑到 0 为止。
frc=1
ok=0
for i in 1 2 3 4 5 6; do
  set +e
  fsck.hfsplus -f -y "$out" > "$W/fsck-y-$i.log" 2>&1
  frc=$?
  fsck.hfsplus -f -n "$out" > "$W/fsck-n-$i.log" 2>&1
  nrc=$?
  set -e
  echo "  轮 $i：-y rc=$frc；只读校验 rc=$nrc"
  tail -4 "$W/fsck-n-$i.log" | sed 's/^/    /'
  if [ $nrc -eq 0 ] && grep -q 'appears to be OK' "$W/fsck-n-$i.log"; then ok=1; break; fi
done
if [ $ok -ne 1 ]; then
  echo "!! 多轮修复后卷仍不一致，镜像不可用" >&2
  exit 1
fi
echo "  只读校验通过（appears to be OK）"
ls -l "$out"
sha256sum "$out"
echo "可用: split -b 2G -d $out ${out}.part && sha256sum ${out}.part* > ${out}.parts.sha256"
