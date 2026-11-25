#!/bin/sh
# iSER Enabler - make QTS / QuTS hero enable iSER on non-QNAP Mellanox ConnectX-4+ cards.
#
# The Advanced Network Driver QPKG only loads mlx5_ib (and so only offers RDMA / iSER) for
# QNAP-branded cards or cards listed in /etc/nic_third_party.conf. /etc is rebuilt on every boot,
# so this service re-adds the cards that are present on each start, then waits for the RDMA
# device and turns iSER on in the iSCSI target. Nothing outside /etc/nic_third_party.conf and
# this package's own directory is modified.
#
# Usage: iser-enabler.sh {start|stop|restart|status|remove}

CONF=/etc/config/qpkg.conf
QPKG_NAME=iSEREnabler
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")
[ -n "$QPKG_ROOT" ] || QPKG_ROOT=$(cd "$(dirname "$0")" && pwd)

NIC_CONF=/etc/nic_third_party.conf
MARK="# added by iSEREnabler"
LOG="$QPKG_ROOT/iser-enabler.log"
USER_CONF="$QPKG_ROOT/iser-enabler.conf"
PIDFILE=/var/run/iser-enabler.pid
ADN_INIT=/etc/init.d/AdvancedNetDriver.sh
ADN_LOG=/tmp/AdvNetDriver.log
ISCSIADMIN=/usr/local/sbin/iscsiadmin

WAIT_MAX=600       # seconds to wait for an mlx5 RDMA device
POLL=2             # seconds between checks
ADN_RETRY_SEEN=20  # restart Advanced Network Driver after this many seconds if it already ran this boot
ADN_RETRY_ANY=180  # ... or after this many seconds in any case

# Optional user settings (space-separated vid:did:svid:sdid, lower-case hex, no 0x):
#   EXTRA_IDS="15b3:1017:15b3:0007"   add cards that are not bound to mlx5_core at start time
#   EXCLUDE_IDS="15b3:1015:15b3:0003" never add these
EXTRA_IDS=""
EXCLUDE_IDS=""
# shellcheck disable=SC1090
[ -f "$USER_CONF" ] && . "$USER_CONF"

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
}

trim_log() {
    [ -f "$LOG" ] || return 0
    if [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
        tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

hex() {
    v=$(cat "$1" 2>/dev/null)
    v=${v#0x}
    echo "$v" | tr 'A-F' 'a-f'
}

# PCI ids (vid:did:svid:sdid) of non-QNAP physical functions driven by mlx5_core.
present_ids() {
    for d in /sys/bus/pci/devices/*; do
        [ -e "$d/driver" ] || continue
        [ "$(basename "$(readlink "$d/driver")")" = mlx5_core ] || continue
        [ -e "$d/physfn" ] && continue
        svid=$(hex "$d/subsystem_vendor")
        [ "$svid" = 1baa ] && continue   # QNAP-branded: already supported
        echo "$(hex "$d/vendor"):$(hex "$d/device"):$svid:$(hex "$d/subsystem_device")"
    done
}

wanted_ids() {
    { present_ids; for id in $EXTRA_IDS; do echo "$id"; done; } | sort -u | while read -r id; do
        [ -n "$id" ] || continue
        case " $EXCLUDE_IDS " in *" $id "*) continue ;; esac
        echo "$id"
    done
}

add_ids() {
    [ -f "$NIC_CONF" ] || : > "$NIC_CONF"
    for id in $(wanted_ids); do
        if grep -qF "[$id]" "$NIC_CONF"; then
            log "already listed: $id"
            continue
        fi
        printf '\n%s\n[%s]\nSUPPORT_MODEL=ALL\n' "$MARK" "$id" >> "$NIC_CONF"
        log "added to $NIC_CONF: $id"
    done
}

# Remove only the blocks this package added (the marker line, the section line, SUPPORT_MODEL).
remove_ids() {
    [ -f "$NIC_CONF" ] || return 0
    grep -qF "$MARK" "$NIC_CONF" || return 0
    awk -v mark="$MARK" '
        $0 == mark { skip = 2; next }
        skip > 0 { skip--; next }
        { print }
    ' "$NIC_CONF" > "$NIC_CONF.tmp" && cat "$NIC_CONF.tmp" > "$NIC_CONF" && rm -f "$NIC_CONF.tmp"
    log "removed own entries from $NIC_CONF"
}

rdma_devices() {
    ls -d /sys/class/infiniband/mlx5_* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' '
}

waiter_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# Wait for the RDMA device, restarting Advanced Network Driver once if it already ran without
# seeing our ids (this service started after it), then enable iSER.
waiter() {
    i=0
    retried=0
    while [ $i -lt $WAIT_MAX ]; do
        [ -n "$(rdma_devices)" ] && break
        if [ $retried -eq 0 ] && [ -x "$ADN_INIT" ]; then
            if { [ -f "$ADN_LOG" ] && [ $i -ge $ADN_RETRY_SEEN ]; } || [ $i -ge $ADN_RETRY_ANY ]; then
                log "no mlx5 RDMA device after ${i}s, starting Advanced Network Driver again"
                "$ADN_INIT" start >> "$LOG" 2>&1
                retried=1
            fi
        fi
        sleep $POLL
        i=$((i + POLL))
    done
    if [ -z "$(rdma_devices)" ]; then
        log "no mlx5 RDMA device after ${WAIT_MAX}s; iSER not enabled (is Advanced Network Driver installed?)"
        return 1
    fi
    sleep 5
    if "$ISCSIADMIN" enable_iser 1 >> "$LOG" 2>&1; then
        log "iSER enabled (rdma: $(rdma_devices)waited ${i}s)"
    else
        log "iscsiadmin enable_iser 1 failed"
        return 1
    fi
}

start() {
    trim_log
    log "start"
    ids=$(wanted_ids)
    if [ -z "$ids" ]; then
        log "no non-QNAP mlx5 (ConnectX-4 or later) card found; nothing to do"
        return 0
    fi
    add_ids
    if waiter_running; then
        log "waiter already running (pid $(cat "$PIDFILE"))"
        return 0
    fi
    ( waiter; rm -f "$PIDFILE" ) > /dev/null 2>&1 &
    echo $! > "$PIDFILE"
}

stop() {
    if waiter_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    remove_ids
    log "stop (iSER stays enabled until the next reboot)"
}

status() {
    echo "cards:  $(wanted_ids | tr '\n' ' ')"
    echo "listed: $(grep -cF "$MARK" "$NIC_CONF" 2>/dev/null || echo 0) entr(y/ies) in $NIC_CONF"
    echo "rdma:   $(rdma_devices)"
    if waiter_running; then echo "waiter: running (pid $(cat "$PIDFILE"))"; else echo "waiter: not running"; fi
    [ -f "$LOG" ] && tail -n 5 "$LOG"
}

case "$1" in
    start)
        ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
        if [ "$ENABLED" != "TRUE" ]; then
            echo "$QPKG_NAME is disabled."
            exit 1
        fi
        start
        ;;
    stop | remove)
        stop
        ;;
    restart)
        stop
        start
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|remove}"
        exit 1
        ;;
esac
exit 0
