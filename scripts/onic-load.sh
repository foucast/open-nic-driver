#!/bin/bash
# onic-load.sh: the one way to (re)load the onic driver on a host.
#
# Usage:
#   onic-load.sh [-m MODULE.ko] [-r ROLLBACK.ko] [-s STATE] [-f] load
#   onic-load.sh [-s STATE] save
#   onic-load.sh [-s STATE] restore
#   onic-load.sh show
#
# load:    records each onic port's settings (save), removes the loaded onic module, inserts
#          MODULE with RS_FEC_ENABLED=0 copybreak=1500 (override with ONIC_PARAMS), then puts the
#          recorded settings back (restore) and waits for carrier on the ports that had it.
#          The driver picks random MAC addresses at load, so without the restore every port
#          would come back with a new MAC and no addresses.
#          With -r, if a port that had carrier does not get it back within 30 s, ROLLBACK is
#          loaded instead (with ONIC_ROLLBACK_PARAMS, default RS_FEC_ENABLED=0), the settings
#          are restored again, and the script exits 1.
# save:    writes the settings of every onic port to STATE: MAC, MTU, up/down, global addresses,
#          routes in any table except local (proto kernel routes excluded: they come back with
#          the address), and permanent neighbour entries.
# restore: applies STATE. Ports are matched by PCI address, so a renamed port is still found.
# show:    prints the module (srcversion, parameters, and the path it was loaded from) and each port's MAC, MTU,
#          carrier and addresses.
#
# MODULE defaults to onic.ko in the repository root (next to this script's directory).
# STATE defaults to /run/onic-load.state. Before removing the module, load refuses if a
# process has a socket bound to one of the ports' addresses, unless -f is given.
set -u
here=$(cd "$(dirname "$0")" && pwd)
module=$here/../onic.ko
rollback=
state=/run/onic-load.state
force=0
params=${ONIC_PARAMS:-RS_FEC_ENABLED=0 copybreak=1500}
rollback_params=${ONIC_ROLLBACK_PARAMS:-RS_FEC_ENABLED=0}

usage() { sed -n '3,7p' "$0" | sed 's/^# //' >&2; exit 2; }
while getopts "m:r:s:f" o; do
	case $o in
	m) module=$OPTARG ;;
	r) rollback=$OPTARG ;;
	s) state=$OPTARG ;;
	f) force=1 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# = 1 ] || usage
cmd=$1

log() { echo "onic-load: $*" >&2; logger -t onic-load -- "$*" 2>/dev/null || true; }

# onic ports as "name pci" lines
ports() {
	local n d
	for n in /sys/class/net/*; do
		d=$(readlink -f "$n/device/driver" 2>/dev/null) || continue
		[ "$(basename "$d")" = onic ] || continue
		echo "$(basename "$n") $(basename "$(readlink -f "$n/device")")"
	done
}

port_by_pci() {
	local n p
	while read -r n p; do [ "$p" = "$1" ] && echo "$n"; done < <(ports)
}

do_save() {
	local n p tmp
	tmp=$(mktemp)
	while read -r n p; do
		echo "port $p $n $(cat /sys/class/net/$n/address) $(cat /sys/class/net/$n/mtu)" \
			"$( [ $(( $(cat /sys/class/net/$n/flags) & 1 )) = 1 ] && echo up || echo down)" \
			"$(cat /sys/class/net/$n/carrier 2>/dev/null || echo 0)"
		ip -o addr show dev "$n" scope global | awk -v p="$p" '{print "addr", p, $3, $4}'
		for f in -4 -6; do
			ip $f -o route show table all dev "$n" |
				grep -vE '(^| )table local( |$)|(^| )proto kernel( |$)|^(multicast |fe80::|ff00::)' |
				sed "s/^/route $p $f /"
		done
		ip -o neigh show dev "$n" nud permanent | awk -v p="$p" '{print "neigh", p, $1, $3}'
	done < <(ports) > "$tmp"
	if ! grep -q '^port ' "$tmp"; then
		rm -f "$tmp"
		log "no onic ports; nothing saved"
		return 1
	fi
	mv "$tmp" "$state"
	log "saved $(grep -c '^port ' "$state") port(s) to $state"
}

# wait up to $1 s for every onic port listed in STATE to exist
wait_ports() {
	local i p ok
	for i in $(seq 1 $(($1 * 2))); do
		ok=1
		for p in $(awk '$1 == "port" {print $2}' "$state"); do
			[ -n "$(port_by_pci "$p")" ] || ok=0
		done
		[ $ok = 1 ] && return 0
		sleep 0.5
	done
	return 1
}

do_restore() {
	local kind p a b c d e n rc=0
	[ -r "$state" ] || { log "no state file $state"; return 1; }
	wait_ports 20 || { log "not every recorded port is present"; rc=1; }
	while read -r kind p a b c d e; do
		[ "$kind" = port ] || continue
		n=$(port_by_pci "$p"); [ -n "$n" ] || continue
		ip link set dev "$n" down
		ip link set dev "$n" address "$b" mtu "$c" || rc=1
		[ "$d" = up ] && { ip link set dev "$n" up || rc=1; }
	done < "$state"
	while read -r kind p rest; do
		n=$(port_by_pci "$p"); [ -n "$n" ] || continue
		case $kind in
		addr) set -- $rest
			if [ "$1" = inet6 ]; then ip -6 addr replace "$2" dev "$n" || rc=1
			else ip -4 addr replace "$2" brd + dev "$n" || rc=1; fi ;;
		route) set -- $rest; f=$1; shift; ip $f route replace "$@" dev "$n" || rc=1 ;;
		neigh) set -- $rest; ip neigh replace "$1" lladdr "$2" nud permanent dev "$n" || rc=1 ;;
		esac
	done < "$state"
	return $rc
}

# wait up to $1 s for carrier on every port that had it when saved
wait_carrier() {
	local i p n ok
	for i in $(seq 1 $(($1 * 2))); do
		ok=1
		for p in $(awk '$1 == "port" && $7 == 1 {print $2}' "$state"); do
			n=$(port_by_pci "$p")
			[ -n "$n" ] && [ "$(cat /sys/class/net/$n/carrier 2>/dev/null)" = 1 ] || ok=0
		done
		[ $ok = 1 ] && return 0
		sleep 0.5
	done
	return 1
}

do_show() {
	local n p q
	if [ -d /sys/module/onic ]; then
		local path=
		# insmod leaves no path behind; load records it, keyed by srcversion
		[ -r /run/onic-load.module ] && read -r q path < /run/onic-load.module &&
			[ "$q" = "$(cat /sys/module/onic/srcversion)" ] || path=$(modinfo -n onic 2>/dev/null)
		echo "module ${path:-(path unknown)} srcversion $(cat /sys/module/onic/srcversion)"
		echo -n "params"
		for q in /sys/module/onic/parameters/*; do echo -n " $(basename "$q")=$(cat "$q")"; done
		echo
	else
		echo "module onic not loaded"
	fi
	while read -r n p; do
		echo "$n ($p) mac $(cat /sys/class/net/$n/address) mtu $(cat /sys/class/net/$n/mtu)" \
			"carrier $(cat /sys/class/net/$n/carrier 2>/dev/null || echo -)" \
			"addrs $(ip -o addr show dev "$n" scope global | awk '{printf "%s ", $4}')"
	done < <(ports)
}

insert() {
	# shellcheck disable=SC2086
	insmod "$1" $2 && echo "$(cat /sys/module/onic/srcversion) $(readlink -f "$1")" > /run/onic-load.module
}

do_load() {
	local addrs users t0 t1
	[ -r "$module" ] || { log "no module $module"; exit 1; }
	[ -z "$rollback" ] || [ -r "$rollback" ] || { log "no rollback module $rollback"; exit 1; }
	if [ -d /sys/module/onic ]; then
		do_save || exit 1
		addrs=$(awk '$1 == "addr" {sub(/\/.*/, "", $4); print $4}' "$state")
		users=
		for a in $addrs; do
			users+=$(ss -Hanp 2>/dev/null | awk -v a="$a" 'index($5, a ":") == 1 || index($5, "[" a "]:") == 1')$'\n'
		done
		if [ -n "${users//[$'\n']/}" ] && [ $force = 0 ]; then
			log "sockets bound to an onic address; not reloading (use -f to override):"
			echo "$users" >&2
			exit 1
		fi
		log "removing onic (srcversion $(cat /sys/module/onic/srcversion))"
		t0=$(date +%s.%N)
		rmmod onic || exit 1
	else
		[ -r "$state" ] || log "onic not loaded and no state file: ports will keep the driver's random MACs"
		t0=$(date +%s.%N)
	fi
	log "inserting $module $params"
	if insert "$module" "$params" && { [ ! -r "$state" ] || { do_restore && wait_carrier 30; }; }; then
		t1=$(date +%s.%N)
		log "loaded srcversion $(cat /sys/module/onic/srcversion); ports back after $(awk "BEGIN {printf \"%.1f\", $t1 - $t0}") s"
		do_show
		return 0
	fi
	log "load or restore failed"
	if [ -n "$rollback" ]; then
		log "rolling back to $rollback $rollback_params"
		[ -d /sys/module/onic ] && rmmod onic
		insert "$rollback" "$rollback_params" && do_restore && wait_carrier 30
		log "rollback rc=$?"
	fi
	do_show
	exit 1
}

case $cmd in
load) do_load ;;
save) do_save ;;
restore) do_restore && wait_carrier 30 ;;
show) do_show ;;
*) usage ;;
esac
