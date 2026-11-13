#!/bin/bash
# onic-install.sh: install onic on a host, the same way everywhere.
#
# Usage:
#   onic-install.sh [SRC]      install from SRC (default: this script's repository root)
#   onic-install.sh version    print the VERSION text for this tree's onic.ko
#
# install: copies SRC/onic.ko, SRC/scripts/onic-load.sh, onic-install.sh, onic-load.service
#          and SRC/VERSION into /root/onic (VERSION is written from git if SRC is a checkout
#          and has none), installs the unit as /etc/systemd/system/onic-load.service, writes
#          /etc/onic/params (RS_FEC_ENABLED=0 copybreak=1500) if it does not exist, and enables
#          the unit. It does not load anything: run `systemctl start onic-load.service`, or
#          `/root/onic/scripts/onic-load.sh ... load`, for that.
#          The module stays in /root/onic, not /lib/modules, so udev never autoloads it with the
#          source defaults (RS_FEC_ENABLED=1, copybreak=256).
# version: commit, srcversion, sha256 and vermagic of SRC/onic.ko.
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
dest=/root/onic

version() {
	local s=$1 c
	c=$(git -C "$s" rev-parse --short HEAD 2>/dev/null) || c=unknown
	git -C "$s" diff --quiet HEAD -- . ':!onic.ko' 2>/dev/null || c="$c (modified)"
	echo "commit $c (foucast/open-nic-driver)"
	echo "srcversion $(modinfo -F srcversion "$s/onic.ko")"
	echo "sha256 $(sha256sum "$s/onic.ko" | cut -d' ' -f1)"
	echo "vermagic $(modinfo -F vermagic "$s/onic.ko")"
}

if [ "${1:-}" = version ]; then
	version "$src"
	exit 0
fi
[ $# -le 1 ] || { sed -n '3,6p' "$0" | sed 's/^# //' >&2; exit 2; }
[ $# = 1 ] && src=$(cd "$1" && pwd)
[ -r "$src/onic.ko" ] || { echo "onic-install: no $src/onic.ko (run make first)" >&2; exit 1; }
for f in onic-load.sh onic-install.sh onic-load.service; do
	[ -r "$src/scripts/$f" ] || { echo "onic-install: no $src/scripts/$f" >&2; exit 1; }
done
if [ "$(modinfo -F vermagic "$src/onic.ko" | cut -d' ' -f1)" != "$(uname -r)" ]; then
	echo "onic-install: onic.ko is built for $(modinfo -F vermagic "$src/onic.ko" | cut -d' ' -f1), this host runs $(uname -r)" >&2
	exit 1
fi

mkdir -p "$dest/scripts" /etc/onic
if [ -r "$src/VERSION" ]; then v=$(cat "$src/VERSION"); else v=$(version "$src"); fi
# write next to the target and rename, so a loaded module's file is never half-written
install -m 0644 "$src/onic.ko" "$dest/.onic.ko.new" && mv "$dest/.onic.ko.new" "$dest/onic.ko"
for f in onic-load.sh onic-install.sh; do install -m 0755 "$src/scripts/$f" "$dest/scripts/$f"; done
install -m 0644 "$src/scripts/onic-load.service" "$dest/scripts/onic-load.service"
echo "$v" > "$dest/VERSION"
[ -e /etc/onic/params ] || echo "RS_FEC_ENABLED=0 copybreak=1500" > /etc/onic/params
install -m 0644 "$src/scripts/onic-load.service" /etc/systemd/system/onic-load.service
systemctl daemon-reload
systemctl enable onic-load.service
echo "onic-install: installed in $dest; onic-load.service enabled (not started)"
cat "$dest/VERSION"
