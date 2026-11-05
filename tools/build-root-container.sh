#!/usr/bin/env bash
# Build the iOS 16.7.16 root image for ios-fajita inside a throwaway privileged
# container (needs loop mounts + FUSE as root; nothing is installed on the host).
#
#   sudo bash tools/build-root-container.sh IPSW OUTDIR   (or: pkexec bash /abs/path/... )
#
# Output: OUTDIR/ios16-root-20H392.img (16 GiB HFS+) and OUTDIR/ios16-root-20H392.simg
# (sparse, for `fastboot -S 512M flash userdata ...simg`), owned by the invoking user.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo or pkexec" >&2; exit 1; }
[ $# = 2 ] || { sed -n '2,8p' "$0"; exit 2; }
IPSW=$(realpath "$1"); OUT=$(realpath -m "$2"); REPO=$(realpath "$(dirname "$0")/..")
# sudo sets SUDO_UID/GID, pkexec sets PKEXEC_UID; fall back to 1000.
uid=${SUDO_UID:-${PKEXEC_UID:-1000}}
OWNER=$uid:$(id -g "$uid" 2>/dev/null || echo "$uid")
mkdir -p "$OUT"
# A previous failed run leaves a half-built image (mkiosroot refuses to overwrite); replace it.
rm -f "$OUT/ios16-root-20H392.img" "$OUT/ios16-root-20H392.simg"
modprobe hfsplus loop

# -v /dev:/dev: podman gives the container a snapshot of /dev, so loop devices the
# kernel creates on demand (losetup -f) would be missing inside it.
# Fedora's apfs-fuse is a 2020 snapshot without LZBITMAP (iOS 16 files then fail with
# EIO). APFS_FUSE points at an upstream build (sgan81/apfs-fuse >= 8a9bad3, 2023).
APFS_FUSE=${APFS_FUSE:-$(dirname "$REPO")/ios-fajita-firmware/tools/apfs-fuse-src/build/apfs-fuse}
[ -x "$APFS_FUSE" ] || { echo "missing upstream apfs-fuse: $APFS_FUSE" >&2; exit 1; }
podman run --rm --privileged -v /dev:/dev \
	-v "$REPO:/repo:ro" -v "$IPSW:/in.ipsw:ro" -v "$OUT:/out" \
	-v "$APFS_FUSE:/usr/local/bin/apfs-fuse:ro" \
	-e OWNER="$OWNER" registry.fedoraproject.org/fedora:latest bash -euo pipefail -c '
# fuse3-libs etc. for the upstream apfs-fuse (mounted at /usr/local/bin, first in PATH)
dnf install -y -q hfsplus-tools fuse3 fuse3-libs fuse rsync sudo python3 android-tools unzip util-linux bzip2-libs libattr >/dev/null
echo "apfs-fuse: $(command -v apfs-fuse)"; apfs-fuse 2>&1 | head -1 || true
w=/out/work; mkdir -p $w
# DMG names from the iPhone X (d22ap) erase build identity of BuildManifest.plist
unzip -o -q /in.ipsw BuildManifest.plist -d $w
read -r OS SYS APP < <(python3 -I - $w/BuildManifest.plist <<EOF
import plistlib,sys
m=plistlib.load(open(sys.argv[1],"rb"))
for bi in m["BuildIdentities"]:
    i=bi["Info"]
    if i.get("DeviceClass")=="d22ap" and "Erase" in i.get("RestoreBehavior",""):
        mf=bi["Manifest"]; print(mf["OS"]["Info"]["Path"], mf["Cryptex1,SystemOS"]["Info"]["Path"], mf["Cryptex1,AppOS"]["Info"]["Path"]); break
EOF
)
echo "OS=$OS SystemOS=$SYS AppOS=$APP"
# -n: keep DMGs already extracted by an earlier run
unzip -n -q /in.ipsw "$OS" "$SYS" "$APP" -d $w
img=/out/ios16-root-20H392.img
bash /repo/tools/mkiosroot.sh "$w/$OS" "$w/$SYS" "$w/$APP" "$img" 16G
fsck.hfsplus -fy "$img" || true
mkdir -p /mnt/iosroot
mount -t hfsplus -o loop,force "$img" /mnt/iosroot
python3 /repo/tools/sweet-root-tweaks.py /mnt/iosroot
umount /mnt/iosroot
fsck.hfsplus -fy "$img" || true
img2simg "$img" /out/ios16-root-20H392.simg
rm -rf $w
chown $OWNER "$img" /out/ios16-root-20H392.simg
sha256sum /out/ios16-root-20H392.simg
echo DONE
'
