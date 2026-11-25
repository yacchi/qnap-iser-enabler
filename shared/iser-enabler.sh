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
ADN_NAME=AdvancedNetDriver
ADN_INIT=/etc/init.d/AdvancedNetDriver.sh
ADN_LOG=/tmp/AdvNetDriver.log            # written by Advanced Network Driver on each start (tmpfs: this boot only)
ADN_CONF=/etc/config.local/qpkg.conf     # where it records Sys_App = 0 when no supported card was found
ISCSIADMIN=/usr/local/sbin/iscsiadmin
# QTS starts QPKGs in the order of their sections in qpkg.conf (/etc/rcS.d/QS100.. follows it),
# and a newly installed QPKG is appended. This package must start before Advanced Network Driver.
QPKG_CONFS="/etc/config/qpkg.conf /etc/config.local/qpkg.conf"
REORDER_DELAY=60   # seconds after start before touching qpkg.conf (let boot-time writers finish)

WAIT_MAX=600       # seconds to wait for an mlx5 RDMA device
POLL=1             # seconds between checks
ADN_RETRY_ANY=180  # restart Advanced Network Driver after this many seconds even without a failure sign

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
    for d in /sys/bus/pci/drivers/mlx5_core/*:*:*.*; do
        [ -e "$d/vendor" ] || continue
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

section_list() {
    grep -E '^\[.*\]$' "$1"
}

# 0 if [$QPKG_NAME] comes before [$ADN_NAME] in $1, or either is missing (nothing to do).
order_ok() {
    grep -qxF "[$QPKG_NAME]" "$1" || return 0
    grep -qxF "[$ADN_NAME]" "$1" || return 0
    first=$(section_list "$1" | grep -xE "\[($QPKG_NAME|$ADN_NAME)\]" | head -n 1)
    [ "$first" = "[$QPKG_NAME]" ]
}

# Move the [$QPKG_NAME] section to just before [$ADN_NAME]. Nothing else changes: the result
# must hold the same non-blank lines and the same sections in the same order apart from ours,
# or the file is left untouched. The previous file is kept as $1.iser-enabler.bak.
reorder_conf() {
    f=$1
    [ -f "$f" ] || return 0
    order_ok "$f" && return 0
    tmp="$f.iser-enabler.tmp"
    awk -v me="[$QPKG_NAME]" -v before="[$ADN_NAME]" '
        /^\[.*\]$/ { insec = ($0 == me) }
        insec { blk[++m] = $0; next }
        { line[++n] = $0 }
        END {
            for (i = 1; i <= n; i++) {
                if (line[i] == before && !done) {
                    for (j = 1; j <= m; j++) print blk[j]
                    if (blk[m] != "") print ""
                    done = 1
                }
                print line[i]
            }
        }
    ' "$f" > "$tmp" || { rm -f "$tmp"; log "reorder: awk failed for $f"; return 1; }
    if [ "$(grep -v '^$' "$f" | sort | cksum)" != "$(grep -v '^$' "$tmp" | sort | cksum)" ] ||
        [ "$(section_list "$f" | grep -vxF "[$QPKG_NAME]")" != "$(section_list "$tmp" | grep -vxF "[$QPKG_NAME]")" ] ||
        ! order_ok "$tmp"; then
        rm -f "$tmp"
        log "reorder: verification failed for $f, left untouched"
        return 1
    fi
    cp -p "$f" "$f.iser-enabler.bak" && cat "$tmp" > "$f"
    rm -f "$tmp"
    log "reorder: moved [$QPKG_NAME] before [$ADN_NAME] in $f (takes effect at next boot)"
}

reorder_all() {
    for f in $QPKG_CONFS; do
        reorder_conf "$f"
    done
}

rdma_devices() {
    for d in /sys/class/infiniband/mlx5_*; do
        [ -e "$d" ] && printf '%s ' "${d##*/}"
    done
}

waiter_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# True when Advanced Network Driver has already run this boot and found no supported card,
# i.e. it checked before our entries were in /etc/nic_third_party.conf.
adn_missed_card() {
    [ -f "$ADN_LOG" ] && [ "$(/sbin/getcfg "$ADN_NAME" Sys_App -d '' -f "$ADN_CONF")" = 0 ]
}

# Wait for the RDMA device. QTS starts QPKGs without waiting for the previous one to finish, so
# Advanced Network Driver can still check the card list before start() has added our entries.
# When that happened (it records Sys_App = 0), start it once more right away. Then enable iSER.
waiter() {
    i=0
    retried=0
    while [ $i -lt $WAIT_MAX ]; do
        [ -n "$(rdma_devices)" ] && break
        if [ $retried -eq 0 ] && [ -x "$ADN_INIT" ]; then
            if adn_missed_card || [ $i -ge $ADN_RETRY_ANY ]; then
                log "no mlx5 RDMA device after ${i}s (Advanced Network Driver missed the card), starting it again"
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
    # First thing: Advanced Network Driver may be checking the card list at this very moment.
    add_ids
    trim_log
    log "start"
    if [ -z "$(wanted_ids)" ]; then
        log "no non-QNAP mlx5 (ConnectX-4 or later) card found; nothing to do"
        return 0
    fi
    if waiter_running; then
        log "waiter already running (pid $(cat "$PIDFILE"))"
        return 0
    fi
    (
        waiter
        sleep $REORDER_DELAY
        reorder_all
        rm -f "$PIDFILE"
    ) > /dev/null 2>&1 &
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
    n=$(grep -cF "$MARK" "$NIC_CONF" 2>/dev/null)
    echo "listed: ${n:-0} entr(y/ies) added by this package in $NIC_CONF"
    echo "rdma:   $(rdma_devices)"
    for f in $QPKG_CONFS; do
        [ -f "$f" ] || continue
        if order_ok "$f"; then echo "order:  ok in $f"; else echo "order:  after $ADN_NAME in $f (fixed in the background after start)"; fi
    done
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
