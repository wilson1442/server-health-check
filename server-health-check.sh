#!/usr/bin/env bash
###############################################################################
# server-health-check.sh
# Collects system health metrics and sends a formatted report via Telegram.
#
# PREREQUISITES (run as root):
#   apt install -y curl iproute2 procps util-linux smartmontools mdadm cron
#
# SETUP:
#   1. Create a Telegram bot with @BotFather -> get BOT_TOKEN
#   2. Find your chat/group ID (CHAT_ID, numeric like -100xxxxxxxxx)
#      Send a message to the bot in the target chat, then:
#        curl "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" | \
#          grep -o '"id":[^-]*' | head -1
#   3. Install the script:
#        install -m 0755 server-health-check.sh /usr/local/sbin/server-health-check.sh
#   4. Add to root crontab (crontab -e), every 4 hours:
#        0 */4 * * * env TELEGRAM_BOT_TOKEN="TOKEN" TELEGRAM_CHAT_ID="-ID" \
#              /usr/local/sbin/server-health-check.sh >> /var/log/health-check.log 2>&1
###############################################################################

set -uo pipefail

# --- Config ------------------------------------------------------------------
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN before running}"
CHAT_ID="${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID (group/channel ID) before running}"

HOST="$(hostname -s)"
OSVER="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
UPTIME_STR="$(uptime -p 2>/dev/null || uptime | sed 's/.*,//' | xargs)"

HAS_SM=$(command -v smartctl &>/dev/null && echo 1 || echo 0)
HAS_MD=$(command -v mdadm &>/dev/null && echo 1 || echo 0)
HAS_ZPOOL=$(command -v zpool &>/dev/null && echo 1 || echo 0)
# Thresholds
TEMP_WARN_C=55
TEMP_CRIT_C=70
DISK_WARN_PCT=80
DISK_CRIT_PCT=95
MEM_WARN_PCT=80
MEM_CRIT_PCT=90
LOAD_WARN_RATIO=4   # load avg per core

overall_status="OK"

RPT=""
declare -a ISSUES=()

# --- Helpers -----------------------------------------------------------------
add_result() {
    local severity="$1"
    local icon="$2"
    local text="$3"

    RPT+="${icon} ${text}"$'\n'
    printf "%s %s\n" "$icon" "$text"

    case "$severity" in
        CRITICAL)
            overall_status="CRITICAL"
            ISSUES+=("$text")
            ;;
        WARN)
            [[ "$overall_status" == "OK" ]] && overall_status="WARN"
            ISSUES+=("$text")
            ;;
    esac
}

ok_icon()   { add_result "OK" "✅" "$1"; }
warn_icon() { add_result "WARN" "⚠️" "$1"; }
crit_icon() { add_result "CRITICAL" "🔴" "$1"; }

# --- 1. System overview ------------------------------------------------------
RPT+="SYSTEM"$'\n'
RPT+="OS: ${OSVER}"$'\n'
RPT+="Uptime: ${UPTIME_STR}"$'\n'

CPU_MODEL="$(grep -m1 '^model name' /proc/cpuinfo | cut -d':' -f2- | xargs 2>/dev/null || echo 'unknown')"
N_CORES="$(egrep -c '^processor' /proc/cpuinfo)"
LOAD1="$(awk '{print $1}' < /proc/loadavg)"
CUR_RATIO=$(awk "BEGIN{printf \"%.2f\", ${LOAD1}/${N_CORES}}")

RPT+="CPU: ${CPU_MODEL}"$'\n'
RPT+="Cores: ${N_CORES}"$'\n'

# Check load ratio (store awk output first to avoid nested $() issues)
LOAD_HIGH=$(awk "BEGIN{v=${LOAD1}/${N_CORES}; print (v > ${LOAD_WARN_RATIO}) ? 1 : 0}")
if [ "$LOAD_HIGH" -eq 1 ]; then
    warn_icon "Load: ${CUR_RATIO}/core (high)"
else
    ok_icon "Load: ${CUR_RATIO}/core"
fi

# --- 2. Memory ---------------------------------------------------------------
RPT+=$'\nMEMORY\n'
TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null \
    || awk '/^MemFree:/ && !f{ f=1; print $2 }' /proc/meminfo)
USED_KB=$(( TOTAL_KB - AVAIL_KB ))

if (( TOTAL_KB > 0 )); then
    MEM_PCT=$(awk "BEGIN{printf \"%.0f\", (${USED_KB}/${TOTAL_KB})*100}")
else
    MEM_PCT=0
fi

TOTAL_GIB=$(awk "BEGIN{printf \"%.1f\", ${TOTAL_KB}/1024/1024}")

if (( TOTAL_KB >= 8 * 1024 * 1024 )); then
    USED_H=$(awk "BEGIN{printf \"%.1f GiB\", $USED_KB/1024/1024}")
else
    USED_H=$(awk "BEGIN{printf \"%.0f MiB\", $USED_KB/1024}")
fi

MEMORY_TEXT="Memory: ${USED_H} of ${TOTAL_GIB} GiB used (${MEM_PCT}%)"

if (( MEM_PCT >= MEM_CRIT_PCT )); then
    crit_icon "${MEMORY_TEXT} — critical"
elif (( MEM_PCT >= MEM_WARN_PCT )); then
    warn_icon "${MEMORY_TEXT} — elevated"
else
    ok_icon "$MEMORY_TEXT"
fi

# --- 3. Filesystems (df) -----------------------------------------------------
RPT+=$'\nFILESYSTEMS\n'

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    FS_DEV=$(echo "$line" | awk '{print $1}')
    FS_MNT=$(echo "$line" | awk '{print $2}')
    FS_SIZE=$(echo "$line" | awk '{print $3}')
    FS_USED=$(echo "$line" | awk '{print $4}')
    FS_PCT=$(echo "$line" | awk '{gsub(/%/,"",$5); print $5+0}')

    if (( FS_PCT >= DISK_CRIT_PCT )); then
        crit_icon "${FS_MNT} (${FS_DEV}): ${FS_PCT}% used (${FS_USED} of ${FS_SIZE})"
    elif (( FS_PCT >= DISK_WARN_PCT )); then
        warn_icon "${FS_MNT} (${FS_DEV}): ${FS_PCT}% used (${FS_USED} of ${FS_SIZE})"
    else
        ok_icon "${FS_MNT}: ${FS_PCT}% used"
    fi
done < <(df -h --output=source,target,size,used,pcent 2>/dev/null | grep '/dev/' | tail -n +2)

# --- 4. SMART / drive health & temperatures ------------------------------------
RPT+=$'\nDRIVES\n'

if (( HAS_SM == 0 )); then
    warn_icon "smartctl not installed"
else
    mapfile -t smart_devices < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')

    if (( ${#smart_devices[@]} == 0 )); then
        warn_icon "No physical disks found"
    fi

    for real_dev in "${smart_devices[@]}"; do
        [[ -b "$real_dev" ]] || continue

        # SMART overall health ("PASSED" or "FAILURE")
        smart_out=$(smartctl -H "$real_dev" 2>/dev/null || true)
        if echo "$smart_out" | grep -qi 'PASSED'; then
            ok_icon "${real_dev}: SMART passed"
        elif echo "$smart_out" | grep -Eqi 'FAILED|FAILURE|Failing'; then
            crit_icon "${real_dev}: SMART FAILED — replace drive!"
        else
            warn_icon "${real_dev}: SMART status unavailable"
        fi

        # NVMe reports "Temperature: 35 Celsius". ATA SMART attributes 190/194
        # store the current temperature in the raw value near the end of the row.
        smart_attrs=$(smartctl -A "$real_dev" 2>/dev/null || true)
        temp=$(awk '
            /^[[:space:]]*Temperature:[[:space:]]*[0-9]+/ {
                print $2
                exit
            }
            /^[[:space:]]*(190|194)[[:space:]]/ || /Temperature_Celsius|Airflow_Temperature_Cel/ {
                for (i = NF; i >= 1; i--) {
                    if ($i ~ /^[0-9]+$/) {
                        print $i
                        exit
                    }
                }
            }
        ' <<< "$smart_attrs")

        if [[ "$temp" =~ ^[0-9]+$ ]]; then
            if (( temp >= TEMP_CRIT_C )); then
                crit_icon "🌡️ ${real_dev}: ${temp}°C"
            elif (( temp >= TEMP_WARN_C )); then
                warn_icon "🌡️ ${real_dev}: ${temp}°C"
            else
                ok_icon "🌡️ ${real_dev}: ${temp}°C"
            fi
        fi
    done
fi

# --- 5. mdadm RAID status ----------------------------------------------------
RPT+=$'\nRAID\n'

if (( HAS_MD == 0 )); then
    warn_icon "mdadm not installed"
else
    # Read current arrays from /proc/mdstat
    while IFS= read -r mdname; do
        [[ "$mdname" =~ ^md ]] || continue
        dev="/dev/${mdname}"
        [[ -e "$dev" ]] || continue

        level=$(mdadm --detail "$dev" 2>/dev/null | grep 'Raid Level'   | sed 's/.*: *//')
        state=$(mdadm --detail "$dev" 2>/dev/null | grep 'State :'      | sed 's/.*: //')
        sync=$(mdadm --detail "$dev" 2>/dev/null | grep 'Rebuild Stat'  | sed 's/.*: //')
        mdstat_state=$(awk -v name="$mdname" '
            $1 == name { found=1; next }
            found && /^[[:space:]]/ { print; next }
            found { exit }
        ' /proc/mdstat 2>/dev/null)

        msg="[${level:-?}] ${state}"

        if echo "${state} ${mdstat_state}" | grep -Eqi 'degraded|failed|faulty|\[[U_]*_[U_]*\]'; then
            crit_icon "RAID ${mdname}: ${msg}"
        elif echo "${state} ${mdstat_state}" | grep -Eqi 'rebuild|resync|recover|reshape|check|repair'; then
            warn_icon "RAID ${mdname}: maintenance in progress — ${msg}"
        else
            ok_icon "RAID ${mdname}: ${msg}"
        fi

        # Show sync progress if applicable
        if [[ -n "${sync:-}" ]]; then
            RPT+="   🔧 Sync: ${sync}"$'\n'
        fi
    done < <(grep '^md' /proc/mdstat 2>/dev/null | awk '{print $1}')

    # If no arrays found, mention it
    if ! grep -q '^md' /proc/mdstat 2>/dev/null; then
        warn_icon "No active md arrays — using software? Or LVM/HBA card?"
    fi
fi

# --- 6. ZFS pool status -----------------------------------------------------
RPT+=$'\nZFS POOLS\n'

if (( HAS_ZPOOL == 0 )); then
    RPT+="ℹ️ zpool not installed — skipped"$'\n'
else
    zpool_count=0

    while IFS=$'\t' read -r pool health size alloc free capacity; do
        [[ -n "$pool" ]] || continue
        (( zpool_count += 1 ))

        capacity_pct="${capacity%%%}"
        [[ "$capacity_pct" =~ ^[0-9]+$ ]] || capacity_pct=0
        pool_result="${pool}: ${health}, ${capacity_pct}% used (${alloc} of ${size})"

        if [[ "$health" != "ONLINE" ]]; then
            crit_icon "$pool_result"
        elif (( capacity_pct >= DISK_CRIT_PCT )); then
            crit_icon "$pool_result"
        elif (( capacity_pct >= DISK_WARN_PCT )); then
            warn_icon "$pool_result"
        else
            ok_icon "$pool_result"
        fi

        pool_status=$(zpool status "$pool" 2>/dev/null || true)
        if [[ -z "$pool_status" ]]; then
            warn_icon "${pool}: unable to read detailed zpool status"
            continue
        fi

        scan_status=$(awk '
            /^[[:space:]]*scan:/ {
                sub(/^[[:space:]]*scan:[[:space:]]*/, "")
                print
                exit
            }
        ' <<< "$pool_status")

        if echo "$scan_status" | grep -Eqi 'resilver.*in progress'; then
            warn_icon "${pool}: ${scan_status}"
        elif [[ -n "$scan_status" ]]; then
            RPT+="   🔍 Scan: ${scan_status}"$'\n'
        fi

        data_errors=$(awk '
            /^[[:space:]]*errors:/ {
                sub(/^[[:space:]]*errors:[[:space:]]*/, "")
                print
                exit
            }
        ' <<< "$pool_status")

        if [[ -n "$data_errors" ]] && ! echo "$data_errors" | grep -qi 'No known data errors'; then
            crit_icon "${pool}: ${data_errors}"
        fi
    done < <(zpool list -H -o name,health,size,alloc,free,capacity 2>/dev/null)

    if (( zpool_count == 0 )); then
        RPT+="ℹ️ No imported ZFS pools found"$'\n'
    fi
fi

# --- 7. Network ------------------------------------------------------------
RPT+=$'\nNETWORK\n'

DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -1)"
GW="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$DEFAULT_ROUTE")"
if [[ -n "$GW" ]]; then
    ok_icon "Gateway: ${GW}"
elif [[ -n "$DEFAULT_ROUTE" ]]; then
    ok_icon "Default route: ${DEFAULT_ROUTE}"
else
    warn_icon "No default route"
fi

# Active LAN interfaces with IP
while IFS= read -r iface; do
    ip=$(ip -4 addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -c 32)
    [[ -n "$ip" ]] && RPT+="Interface: ${iface} → ${ip}"$'\n'
done < <(ip route show default 2>/dev/null | awk '{print $5}' | sort -u)

# DNS check
DNS_SERVERS="$(grep 'nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -c 128)"
if [[ -n "${DNS_SERVERS:-}" ]]; then
    while IFS= read -r dns_server; do
        [[ -n "$dns_server" ]] && RPT+="DNS: ${dns_server}"$'\n'
    done <<< "$DNS_SERVERS"
fi

# External IP (optional, skip on failure)
EXT_IP=$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
[[ -n "$EXT_IP" ]] && RPT+="External IP: ${EXT_IP}"$'\n'

# --- 8. Swap ---------------------------------------------------------------
RPT+=$'\nSWAP\n'
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))

if (( SWAP_TOTAL > 0 )); then
    SWAP_PCT=$(awk "BEGIN{printf \"%.0f\", ($SWAP_USED/$SWAP_TOTAL)*100}")
else
    SWAP_PCT=0
fi

if (( SWAP_PCT >= 80 )); then
    crit_icon "Swap: ${SWAP_USED} KiB used (${SWAP_PCT}%)"
elif (( SWAP_PCT >= 30 )); then
    warn_icon "Swap: ${SWAP_USED} KiB used (${SWAP_PCT}%)"
else
    ok_icon "Swap OK"
fi

# --- 9. Last reboot --------------------------------------------------------
RPT+=$'\nBOOT\n'
LAST_REBOOT=$(uptime -s 2>/dev/null || who -b 2>/dev/null | awk '{print $3, $4}')
RPT+="Last reboot: ${LAST_REBOOT:-unknown}"$'\n'

# --- Final status line -----------------------------------------------------
case "$overall_status" in
    CRITICAL)
        emoji="🔴"
        status_label="CRITICAL"
        ;;
    WARN)
        emoji="⚠️"
        status_label="WARNING"
        ;;
    *)
        emoji="✅"
        status_label="GOOD"
        ;;
esac

# --- Send to Telegram -------------------------------------------------------
SUMMARY="🖥️ SERVER HEALTH — ${HOST}"$'\n'
SUMMARY+="${emoji} Overall status: ${status_label}"$'\n'

if (( ${#ISSUES[@]} > 0 )); then
    SUMMARY+="Why:"$'\n'
    for issue in "${ISSUES[@]}"; do
        SUMMARY+="• ${issue}"$'\n'
    done
fi

SUMMARY+=$'\n'
message="${SUMMARY}${RPT}"

# Telegram has a 4096 char limit
if (( ${#message} > 4000 )); then
    message="${message:0:3997}"$'\n'"... (truncated)"
fi

telegram_request() {
    local -a form_args=(
        -F "chat_id=${CHAT_ID}"
        -F "text=${message}"
    )

    curl -sS --connect-timeout 5 --max-time 15 \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        "${form_args[@]}"
}

send_tg() {
    local resp

    resp=$(telegram_request)
    
    if echo "$resp" | grep -q '"ok":true'; then
        return 0
    fi
    
    # Rate-limit / network fallback (429 Too Many Requests)
    if echo "$resp" | grep -qi 'retry'; then
        sleep 15
        resp=$(telegram_request)
    fi
    
    if echo "$resp" | grep -q '"ok":true'; then
        return 0
    fi

    printf 'Telegram API response: %s\n' "${resp:-<empty response>}" >&2
    return 1
}

if ! send_tg; then
    printf 'Failed to send health report to Telegram.\n' >&2
    exit 1
fi

exit 0
