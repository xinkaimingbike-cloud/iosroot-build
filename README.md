# iosroot-build

在 GitHub Actions 的 Ubuntu runner 上，从 Apple 的 IPSW 造一份 **HFS+ 根镜像**，给 `hanzi123-bilp/ios-fuxi`（小米 13 / fuxi 裸机 loader）用。

## 为什么要在云端做

`mkiosroot.sh` 依赖三样 Windows 上没有的东西：

- `apfs-fuse` —— 从 IPSW 里的 APFS dmg 读文件
- `mkfs.hfsplus` —— 造 HFS+ 卷
- `mount -o loop` —— 挂载后 `rsync`

所以必须 Linux/macOS。GitHub 的 `ubuntu-22.04` runner 三样都有，还自带 `/dev/fuse`。

## 怎么用

1. 打开 **Actions** → 选 `build-hfs-root` → **Run workflow**
2. `ipsw_url` 默认已经填好 iOS 16.7.16（`20H392`，iPhone10,3）的直链，直接跑
3. 跑完会在 **Releases** 里看到 `root-<run_id>`，里面是分卷

默认参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `ipsw_url` | iOS 16.7.16 / 20H392 直链 | 必须是 Apple CDN 的 `.ipsw`；注意 URL 结尾哈希不对会 403 |
| `ipsw_sha256` | `ece1194f…68fb` | 留空则跳过校验 |
| `size` | `10G` | HFS+ 镜像大小 |

## 产物合并

分卷是 1900 MB 一片，下载后放到同一个目录：

```powershell
# Windows (PowerShell)
Get-Content iosroot.img.part00, iosroot.img.part01, ... -AsByteStream |
  Set-Content iosroot.img -AsByteStream
```

Linux/macOS：

```bash
cat iosroot.img.part* > iosroot.img
sha256sum -c iosroot.img.sha256
```

整卷 sha256 在 `iosroot.img.sha256` 里，对上了才算完整。

## 这份镜像给谁用

- 目标机型：小米 13（`fuxi` / SM8550）
- 目标固件：iOS 16.7.16（`ProductBuildVersion = 20H392`）——`tools/fuxi-stage-root.py` 会校验这个字符串
- 用法：root 后放进 `/data`，`f2fs_io pinfile set` + `fiemap` 拿到物理 extent，写进 ADT 的 `fuxi-root-extents` / `fuxi-root-blocks`，然后 `fastboot boot` 裸机 loader

## 已知的坑（脚本里已经处理）

- iOS 16 的 `BuildManifest.plist` 往往**只有 `OS` + `Cryptex1,SystemOS` 两块 dmg**，没有 `Cryptex1,AppOS`。旧脚本要求三块齐全会直接失败
- `logd` 目录必须手工建（owner 272），否则 `BUG IN LIBTRACE: Failed to migrate directory`
- `private/var/keybags/systembag.kb` 必须存在，否则 launchd 过不去
- dyld 共享缓存要做硬链接到 `System/Library/Caches/com.apple.dyld`
