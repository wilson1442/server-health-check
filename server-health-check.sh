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
#        install -m 0755 server-health-check.sh /usr/local/sbin/server-health-check
#   4. Add to root crontab (crontab -e), every 4 hours:
#        0 */4 * * * env TELEGRAM_BOT_TOKEN="TOKEN" TELEGRAM_CHAT_ID="-ID" \
#              /usr/local/sbin/server-health-check >> /var/log/health-check.log 2>&1
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

# --- Helpers -----------------------------------------------------------------
add_result() {
    local severity="$1"
    local icon="$2"
    local text="$3"

    RPT+="▬${icon} ${text}"$'\n'
    printf "▬%s %s\n" "$icon" "$text"

    case "$severity" in
        CRITICAL)
            overall_status="CRITICAL"
            ;;
        WARN)
            [[ "$overall_status" == "OK" ]] && overall_status="WARN"
            ;;
    esac
}

ok_icon()   { add_result "OK" "✔" "$1"; }
warn_icon() { add_result "WARN" "◻" "$1"; }
crit_icon() { add_result "CRITICAL" "✘" "$1"; }

# --- 1. System overview ------------------------------------------------------
RPT+="🖥️ *System*"$'\n'
RPT+="_Host:_ \`${HOST}\`  |_ OS:_ ${OSVER}  |_ Uptime:_ \`${UPTIME_STR}\`"$'\n\n'

CPU_MODEL="$(grep -m1 '^model name' /proc/cpuinfo | cut -d':' -f2- | xargs 2>/dev/null || echo 'unknown')"
N_CORES="$(egrep -c '^processor' /proc/cpuinfo)"
LOAD1="$(awk '{print $1}' < /proc/loadavg)"
CUR_RATIO=$(awk "BEGIN{printf \"%.2f\", ${LOAD1}/${N_CORES}}")

RPT+="- 💻 \`${CPU_MODEL}\`"$'\n'
RPT+="- 🕹️  Cores: \`${N_CORES} | Ratio: ${CUR_RATIO}/core\`"$'\n\n'

# Check load ratio (store awk output first to avoid nested $() issues)
LOAD_HIGH=$(awk "BEGIN{v=${LOAD1}/${N_CORES}; print (v > ${LOAD_WARN_RATIO}) ? 1 : 0}")
if [ "$LOAD_HIGH" -eq 1 ]; then
    warn_icon "High load (${CUR_RATIO}/core)"
else
    ok_icon "Load OK"
fi

# --- 2. Memory ---------------------------------------------------------------
RPT+=$'\n*▸ Memory*\n'
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
    USED_H=$(awk "BEGIN{printf \"%.1fGi\", ($USED_KB/$TOTAL_KB)*${TOTAL_GIB}}")
else
    USED_H=$(awk "BEGIN{printf \"%.0fMi\", $USED_KB/1024}")
fi

RPT+="- 🧠 ${TOTAL_GIB} Gi  used: \`$USED_H (${MEM_PCT}%)\`"$'\n'

if (( MEM_PCT >= MEM_CRIT_PCT )); then
    crit_icon "Memory critical: ${MEM_PCT}%"
elif (( MEM_PCT >= MEM_WARN_PCT )); then
    warn_icon "Memory elevated: ${MEM_PCT}%"
else
    ok_icon "Memory OK"
fi

# --- 3. Filesystems (df) -----------------------------------------------------
RPT+='*▸ Filesystems*'$'\n'

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    FS_DEV=$(echo "$line" | awk '{print $1}')
    FS_MNT=$(echo "$line" | awk '{print $2}')
    FS_SIZE=$(echo "$line" | awk '{print $3}')
    FS_USED=$(echo "$line" | awk '{print $4}')
    FS_PCT=$(echo "$line" | awk '{gsub(/%/,"",$5); print $5+0}')

    if (( FS_PCT >= DISK_CRIT_PCT )); then
        crit_icon "${FS_MNT} (${FS_DEV}): ${FS_PCT}% used (\`$FS_SIZE\`)"
    elif (( FS_PCT >= DISK_WARN_PCT )); then
        warn_icon "${FS_MNT} (${FS_DEV}): ${FS_PCT}% used"
    else
        ok_icon "${FS_MNT}: ${FS_PCT}% used"
    fi
done < <(df --output=source,target,size,used,pcent 2>/dev/null | grep '/dev/' | tail -n +2)

# --- 4. SMART / drive health & temperatures ------------------------------------
RPT+=$'\n*▸ Drives (SMART)*\n'

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
RPT+=$'\n*▸ RAID (mdadm)*\n'

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

        # Square brackets start a link entity in Telegram's Markdown parser.
        msg="\\[${level:-?}\\] ${state}"

        if echo "${state} ${mdstat_state}" | grep -Eqi 'degraded|failed|faulty|\[[U_]*_[U_]*\]'; then
            crit_icon "RAID ${mdname}: ${msg}"
        elif echo "${state} ${mdstat_state}" | grep -Eqi 'rebuild|resync|recover|reshape|check|repair'; then
            warn_icon "RAID ${mdname}: maintenance in progress — ${msg}"
        else
            ok_icon "RAID ${mdname}: ${msg}"
        fi

        # Show sync progress if applicable
        if [[ -n "${sync:-}" ]]; then
            RPT+="   ▬🔧 Sync: \`${sync}\`"$'\n'
        fi
    done < <(grep '^md' /proc/mdstat 2>/dev/null | awk '{print $1}')

    # If no arrays found, mention it
    if ! grep -q '^md' /proc/mdstat 2>/dev/null; then
        warn_icon "No active md arrays — using software? Or LVM/HBA card?"
    fi
fi

# --- 6. Network ------------------------------------------------------------
RPT+=$'\n*▸ Network*\n'

DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -1)"
GW="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$DEFAULT_ROUTE")"
if [[ -n "$GW" ]]; then
    ok_icon "Gateway: \`${GW}\`"
elif [[ -n "$DEFAULT_ROUTE" ]]; then
    ok_icon "Default route: \`${DEFAULT_ROUTE}\`"
else
    warn_icon "No default route"
fi

# Active LAN interfaces with IP
while IFS= read -r iface; do
    ip=$(ip -4 addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -c 32)
    [[ -n "$ip" ]] && RPT+="- \`${iface}\` → ${ip}"$'\n'
done < <(ip route show default 2>/dev/null | awk '{print $5}' | sort -u)

# DNS check
DNS_SERVERS="$(grep 'nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -c 128)"
[[ -n "${DNS_SERVERS:-}" ]] && RPT+="- DNS: \`${DNS_SERVERS}\`"$'\n' 

# External IP (optional, skip on failure)
EXT_IP=$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
[[ -n "$EXT_IP" ]] && RPT+="_External:_ \`${EXT_IP}\`_"$'\n'

# --- 7. Swap ---------------------------------------------------------------
RPT+=$'\n*▸ Swap*\n'
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))

if (( SWAP_TOTAL > 0 )); then
    SWAP_PCT=$(awk "BEGIN{printf \"%.0f\", ($SWAP_USED/$SWAP_TOTAL)*100}")
else
    SWAP_PCT=0
fi

if (( SWAP_PCT >= 80 )); then
    crit_icon "Swap: \`${SWAP_USED} KiB\` (${SWAP_PCT}%)"
elif (( SWAP_PCT >= 30 )); then
    warn_icon "Swap: \`${SWAP_USED} KiB\` ($SWAP_PCT%)"
else
    ok_icon "Swap OK"
fi

# --- 8. Last reboot --------------------------------------------------------
RPT+=$'\n*▸ Boot time*\n'
LAST_REBOOT=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo 'unknown')
RPT+="🔃 \`${LAST_REBOOT}\`"$'\n'

# --- Final status line -----------------------------------------------------
declare -A STATUS_EMOJI=( [OK]="✅" [WARN]="⚠️" [CRITICAL]="🔴" )
emoji="${STATUS_EMOJI[$overall_status]:-✅}"

RPT+=$'\n'
RPT+="${emoji} *Overall Status:* \`${overall_status}\`"$'\n'

# --- Send to Telegram -------------------------------------------------------
message="$RPT"

# Telegram has a 4096 char limit
if (( ${#message} > 4000 )); then
    message="${message:0:3997}"$'\n'"... (truncated)"
fi

telegram_request() {
    local parse_mode="${1:-}"
    local -a form_args=(
        -F "chat_id=${CHAT_ID}"
        -F "text=${message}"
    )

    if [[ -n "$parse_mode" ]]; then
        form_args+=( -F "parse_mode=${parse_mode}" )
    fi

    curl -sS --connect-timeout 5 --max-time 15 \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        "${form_args[@]}"
}

send_tg() {
    local resp
    local parse_mode="Markdown"

    resp=$(telegram_request "$parse_mode")
    
    if echo "$resp" | grep -q '"ok":true'; then
        return 0
    fi
    
    # A machine-provided value may contain Telegram Markdown control characters.
    # Deliver as plain text rather than dropping the entire health report.
    if echo "$resp" | grep -qi "can't parse entities"; then
        parse_mode=""
        resp=$(telegram_request "$parse_mode")
        if echo "$resp" | grep -q '"ok":true'; then
            printf 'Telegram rejected Markdown; report sent as plain text.\n' >&2
            return 0
        fi
    fi

    # Rate-limit / network fallback (429 Too Many Requests)
    if echo "$resp" | grep -qi 'retry'; then
        sleep 15
        resp=$(telegram_request "$parse_mode")
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
