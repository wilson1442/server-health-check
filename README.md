# Server Health Check

Automated server health monitoring for Ubuntu/Proxmox — sends formatted reports to Telegram.

## What it checks

- **System**: hostname, OS version, uptime, CPU model, core count, load ratio
- **Memory**: usage percentage (warning ≥80%, critical ≥90%)
- **Filesystems**: all `/dev/*` mounts — percentage used with capacity
- **Drives (SMART)**: per-drive health status, temperature (warn ≥55°C, critical ≥70°C)
- **RAID (mdadm)**: array health, state (failed/degraded/rebuilding), sync progress
- **Network**: gateway IP, LAN interfaces + IPs, DNS servers, external IP
- **Swap**: usage percentage
- **Boot time**: last system reboot

## Setup

### Clone the repo

```bash
git clone https://github.com/wilson1442/server-health-check.git
cd server-health-check
```

### 1. Install prerequisites (as root)

```bash
apt install -y smartmontools mdadm lm-sensors cron curl procps
```

### 2. Create a Telegram bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow prompts, get your **BOT_TOKEN**
3. Add the bot to your group/channel

### 3. Get your chat/group ID

Send a message in the target chat, then:

```bash
curl "https://api.telegram.org/bot<YOUR TOKEN>/getUpdates" | grep -o '"id":[^-]*' | head -1
```

"The chat ID will look like `-100xxxxxxxxx` for groups/channels."

### 4. Deploy the script

Copy `server-health-check.sh` to your server:

```bash
cp server-health-check.sh /usr/local/sbin/
chmod +x /usr/local/sbin/server-health-check.sh
```

Set up in root crontab (run every 4 hours):

```bash
crontab -e
# Add the following line:
0 */4 * * * env TELEGRAM_BOT_TOKEN="<TOKEN>" TELEGRAM_CHAT_ID="-<ID>"     /usr/local/sbin/server-health-check.sh >> /var/log/health-check.log 2>&1
```

Or run manually for testing:

```bash
env TELEGRAM_BOT_TOKEN="your_bot_token" TELEGRAM_CHAT_ID="-your_chat_id"     bash /usr/local/sbin/server-health-check.sh
```

## Telegram Report Format

The script sends a formatted Markdown message to your Telegram channel every 4 hours, showing:

- ✅ OK — everything normal
- ⚠️ WARNING — something needs attention (elevated load, memory, temperatures, etc.)
- 🔴 CRITICAL — urgent issue (SMART failure, high temperatures, full disks, RAID degraded)

The message includes all metrics with color-coded status icons per item.

## Thresholds

| Check | Warning | Critical |
|-------|---------|----------|
| Drive temp | 55°C | 70°C |
| Disk usage | 80% | 95% |
| Memory | 80% | 90% |
| Load/ core ratio | >4.0 | — |
| Swap | 30% | 80% |

## License

MIT
