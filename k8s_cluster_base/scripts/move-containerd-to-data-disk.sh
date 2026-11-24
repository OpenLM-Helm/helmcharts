#!/usr/bin/env bash
# Move containerd's storage (images + container layers) from the root disk to a data disk,
# using a bind mount so every path, tool and config keeps pointing at /var/lib/containerd.
#
# usage (on the node, as root):
#   move-containerd-to-data-disk.sh <data-disk-mountpoint>          # copy + switch
#   move-containerd-to-data-disk.sh <data-disk-mountpoint> --cleanup # delete the old copy after you verified the node
#
# Workers: drain first (kubectl drain <node> --ignore-daemonsets --delete-emptydir-data), uncordon after.
# Control-plane: no drain possible; the API server is down for the few minutes this takes.
# bash only (pipefail, ERR trap): "sh script" would run it under dash on Ubuntu
[ -n "${BASH_VERSION:-}" ] || { echo "run it with bash: sudo bash $0 ..." >&2; exit 1; }
set -euo pipefail

DATA="${1:?usage: $0 <data-disk-mountpoint> [--cleanup]}"
SRC=/var/lib/containerd
DST="$DATA/k8s/containerd"
OLD="$SRC.pre-move"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

if [ "${2:-}" = "--cleanup" ]; then
  findmnt -n "$SRC" >/dev/null || { echo "$SRC is not bind-mounted, refusing to clean up"; exit 1; }
  [ -d "$OLD" ] && rm -rf --one-file-system "$OLD" && echo "removed $OLD"
  df -h /
  exit 0
fi

mountpoint -q "$DATA" || { echo "$DATA is not a mount point"; exit 1; }
[ "$(findmnt -n -o SOURCE --target "$DATA")" != "$(findmnt -n -o SOURCE /)" ] || { echo "$DATA is on the root disk"; exit 1; }
findmnt -n "$SRC" >/dev/null && { echo "$SRC is already a mount, nothing to do"; exit 0; }
[ -e "$OLD" ] && { echo "$OLD exists from an earlier run, check it first"; exit 1; }
command -v crictl >/dev/null || { echo "crictl not found"; exit 1; }
if command -v rsync >/dev/null; then COPY="rsync"; else COPY="cp"; fi

# if anything fails after the services are stopped, bring them back up on the old data
restore() {
  echo "!! failed, restarting containerd and kubelet on the original $SRC" >&2
  findmnt -n "$SRC" >/dev/null || { [ -d "$OLD" ] && [ ! -e "$SRC/io.containerd.content.v1.content" ] && rmdir "$SRC" 2>/dev/null && mv "$OLD" "$SRC"; }
  systemctl start containerd || true
  systemctl start kubelet || true
}
trap restore ERR

echo ">> stopping kubelet and all containers"
systemctl stop kubelet
crictl pods -q | xargs -r crictl stopp >/dev/null 2>&1 || true
crictl rmp -a -f >/dev/null 2>&1 || true
systemctl stop containerd

echo ">> copying $SRC -> $DST (with $COPY)"
mkdir -p "$DST"
if [ "$COPY" = rsync ]; then
  rsync -aHAX --numeric-ids --delete "$SRC/" "$DST/"
else
  # cp -a keeps hard links, owners, modes, xattrs and timestamps within one run
  find "$DST" -mindepth 1 -delete
  cp -a --preserve=all "$SRC/." "$DST/"
fi

echo ">> switching to a bind mount"
mv "$SRC" "$OLD"
mkdir -p "$SRC"
grep -qE "^${DST}[[:space:]]+${SRC}[[:space:]]" /etc/fstab || echo "$DST $SRC none bind 0 0" >> /etc/fstab
systemctl daemon-reload
mount "$SRC"
findmnt "$SRC"

trap - ERR
echo ">> starting containerd and kubelet"
systemctl start containerd
systemctl start kubelet
sleep 20
systemctl is-active containerd kubelet
df -h / "$DATA"
echo
echo "Done. Check the node is Ready and its pods run, then free the root disk with:"
echo "  sudo $0 $DATA --cleanup"
