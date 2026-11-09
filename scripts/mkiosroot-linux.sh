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
  cmake -S "$T/a" -B "$T/b" -DCMAKE_BUILD_TYPE=Release
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
fsck.hfsplus -f -y "$out" 2>&1 | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$out" 2>&1 | tail -3
ls -l "$out"
sha256sum "$out"
echo "可用: split -b 2G -d $out ${out}.part && sha256sum ${out}.part* > ${out}.parts.sha256"
