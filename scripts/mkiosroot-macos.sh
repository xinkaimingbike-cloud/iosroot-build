#!/bin/bash
# 在 macOS 上从 IPSW 造 ios-fuxi 要的 HFS+ 根镜像
# 用法: sudo ./mkiosroot-macos.sh <IPSW> <输出.img> [大小=9G]
#
# macOS 比 Linux 简单：hdiutil 原生读 DMG/APFS，不需要 apfs-fuse、不需要内核 hfsplus 模块。
# 为了在 GitHub 的 macOS runner（可用空间只有 ~14 GB）上跑得下，解出的 dmg 用完即删：
#   峰值 = 三块 dmg(6.97G) + 稀疏镜像实际占用(约 6.5G) ≈ 13.5G
set -euo pipefail

ipsw=${1:?用法: mkiosroot-macos.sh <IPSW> <OUT.img> [SIZE]}
out=${2:?缺输出路径}
size=${3:-9G}
[[ -f $ipsw ]] || { echo "IPSW 不存在: $ipsw" >&2; exit 1; }
[[ ! -e $out ]] || { echo "拒绝覆盖: $out" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "必须 sudo 运行" >&2; exit 1; }
[[ $(uname) == Darwin ]] || { echo "这是 macOS 脚本" >&2; exit 1; }

W=$(mktemp -d /tmp/mkiosroot.XXXXXX)
cleanup() {
  set +e
  for m in "$W/root" "$W/mnt" "$W/os"; do hdiutil detach "$m" -force >/dev/null 2>&1; done
  echo "临时目录: $W"
}
trap cleanup EXIT

echo "== 0/6 环境 =="
df -h / | tail -2
uname -a

echo "== 1/6 读 BuildManifest =="
python3 - "$ipsw" <<'PY' > "$W/names.txt"
import plistlib, sys, zipfile

KEYS = ("OS", "Cryptex1,SystemOS", "Cryptex1,AppOS")


def path_of(entry):
    """iOS 16+ 路径在 Manifest[key]['Info']['Path']；老结构在 identity['Info'][key]['Path']。"""
    if not isinstance(entry, dict):
        return None
    info = entry.get('Info')
    if isinstance(info, dict) and info.get('Path'):
        return info['Path']
    return entry.get('Path')


with zipfile.ZipFile(sys.argv[1]) as z:
    man = plistlib.loads(z.read('BuildManifest.plist'))

pick = None
for ident in man.get('BuildIdentities', []):
    m = ident.get('Manifest')
    src = m if isinstance(m, dict) else ident.get('Info', {})
    if path_of(src.get('OS')):
        pick = src
        break
if pick is None:
    raise SystemExit("BuildManifest 里找不到 OS 条目")

print("# ProductBuildVersion=%s ProductVersion=%s" %
      (man.get('ProductBuildVersion'), man.get('ProductVersion')))
for k in KEYS:
    p = path_of(pick.get(k))
    print("%s=%s" % (k, p or "MISSING"))
PY
cat "$W/names.txt"
grep -q '^OS=' "$W/names.txt" || { echo "缺 OS dmg" >&2; exit 1; }

echo "== 2/6 解出 dmg（AppOS 常常只有几 MB）=="
mkdir -p "$W/dmg"
while IFS='=' read -r k v; do
  case "$k" in \#*|"") continue;; esac
  [[ "$v" == "MISSING" ]] && continue
  echo "  unzip $k <- $v"
  unzip -o "$ipsw" "$v" -d "$W/dmg" >/dev/null
done < "$W/names.txt"
ls -l "$W/dmg"
echo "  删掉 IPSW 腾空间"
rm -f "$ipsw"
df -h / | tail -1

echo "== 3/6 造 HFS+（case-sensitive + journaled）=="
# 稀疏文件：mkfile -n 只占元数据，写入时才增长
mkfile -n "$size" "$out"
newfs_hfs -s -J -v iOSRoot "$out"
mkdir -p "$W/root"
hdiutil attach -noverify -noautoopen -mountpoint "$W/root" \
  -imagekey diskimage-class=CRawDiskImage "$out" >/dev/null
echo "  挂载: $(df -h "$W/root" | tail -1)"

echo "== 4/6 拷贝三块卷 =="
put() {  # put <key> <目标子路径> ; 目标为空表示镜像根
  local key="$1" dest="$2"
  local dmg
  dmg=$(awk -F= -v k="$key" '$1==k{print $2}' "$W/names.txt")
  [[ -n "$dmg" && "$dmg" != "MISSING" ]] || { echo "  跳过 $key（无对应 dmg）"; return 0; }
  mkdir -p "$W/mnt"
  echo "  attach $key ($dmg)"
  hdiutil attach -noverify -noautoopen -mountpoint "$W/mnt" "$W/dmg/$dmg" >/dev/null
  local src="$W/mnt"
  [[ -d "$W/mnt/root" ]] && src="$W/mnt/root"     # apfs 卷有时多一层 root
  if [[ -z "$dest" ]]; then
    rsync -aH --numeric-ids "$src/" "$W/root/"
  else
    mkdir -p "$W/root/$dest"
    rsync -aH --numeric-ids "$src/" "$W/root/$dest/"
  fi
  hdiutil detach "$W/mnt" -force >/dev/null || hdiutil detach "$W/mnt" >/dev/null
  rmdir "$W/mnt" 2>/dev/null || true
  echo "  删掉 $dmg"
  rm -f "$W/dmg/$dmg"
  df -h / | tail -1
}
put "OS" ""
put "Cryptex1,SystemOS" "private/preboot/Cryptexes/OS"
put "Cryptex1,AppOS" "private/preboot/Cryptexes/App"

echo "== 5/6 打补丁（dyld 硬链接 / logd / keybag）=="
DSC=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$W/root/System/Library/Caches/com.apple.dyld"
if [[ -d "$W/root/$DSC" ]]; then
  find "$W/root/$DSC" -maxdepth 1 -type f | while read -r f; do
    ln "$f" "$W/root/System/Library/Caches/com.apple.dyld/$(basename "$f")" 2>/dev/null || true
  done
fi

DB="$W/root/private/var/db"
mkdir -p "$DB/diagnostics" "$DB/uuidtext" "$DB/diagnostics/timesync"
chown 272:272 "$DB/diagnostics" "$DB/uuidtext" "$DB/diagnostics/timesync"
chmod 0751 "$DB/diagnostics"
chmod 0755 "$DB/uuidtext" "$DB/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
  : > "$DB/$d/.migrated"
  chown 272:272 "$DB/$d/.migrated"
done

mkdir -p "$W/root/private/var/keybags"
chmod 700 "$W/root/private/var/keybags"
chown 0:0 "$W/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
 '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
 '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
 > "$W/root/private/var/keybags/systembag.kb"
chmod 600 "$W/root/private/var/keybags/systembag.kb"
chown 0:0 "$W/root/private/var/keybags/systembag.kb"

echo "  内容占用: $(du -sh "$W/root" | cut -f1)"
sync
df -h "$W/root" | tail -1
hdiutil detach "$W/root" >/dev/null

echo "== 6/6 校验 =="
fsck_hfs -f -n "$out" 2>&1 | tail -5 || true
ls -l "$out"
shasum -a 256 "$out"
