# Server Health Check

A lightweight Bash script for Ubuntu and Proxmox hosts. It checks the server's
health and sends one summary to Telegram.

## Checks

- CPU load and memory use
- Mounted filesystem usage
- SMART health and disk temperature
- Linux software RAID (`mdadm`)
- Default route, local addresses, DNS, and external IP
- Swap use and last boot time

Each result is marked OK, warning, or critical. The final status reflects the
most severe result in the report. Warning and critical reports list the reasons
at the top so the problem is immediately visible.

## Install

These commands require root access.

```bash
apt update
apt install -y curl iproute2 procps util-linux smartmontools mdadm cron

git clone https://github.com/wilson1442/server-health-check.git
cd server-health-check
install -m 0755 server-health-check.sh /usr/local/sbin/server-health-check
```

`smartmontools` and `mdadm` are optional if the server does not use those
features. Their absence is reported as a warning.

## Configure Telegram

1. Message [@BotFather](https://t.me/BotFather), run `/newbot`, and save the bot
   token.
2. Add the bot to the destination chat and send a message there.
3. Open the URL below with your token and find the destination's `chat.id`:

```text
https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
```

Group and channel IDs are usually negative, such as `-1001234567890`.

## Test it

```bash
TELEGRAM_BOT_TOKEN="<YOUR_TOKEN>" \
TELEGRAM_CHAT_ID="<YOUR_CHAT_ID>" \
/usr/local/sbin/server-health-check
```

The command exits with a non-zero status if Telegram delivery fails.

## Schedule it

Open root's crontab:

```bash
crontab -e
```

Add this line to run the check every four hours:

```cron
0 */4 * * * TELEGRAM_BOT_TOKEN="<YOUR_TOKEN>" TELEGRAM_CHAT_ID="<YOUR_CHAT_ID>" /usr/local/sbin/server-health-check >> /var/log/health-check.log 2>&1
```

## Update

Pull the latest version from the cloned repository, then reinstall the script:

```bash
cd ~/server-health-check
git pull --ff-only origin main
install -m 0755 server-health-check.sh /usr/local/sbin/server-health-check.sh
```

## Default thresholds

| Check | Warning | Critical |
|---|---:|---:|
| Disk temperature | 55°C | 70°C |
| Filesystem usage | 80% | 95% |
| Memory usage | 80% | 90% |
| Load per CPU core | Above 4.0 | — |
| Swap usage | 30% | 80% |

Edit the threshold variables near the top of `server-health-check.sh` to change
these values.

## License

[MIT](LICENSE)
