#!/usr/bin/env bash

# https://github.com/ChaoticWeg/discord.sh

export UPTIME_WEBHOOK=https://discord.com/api/webhooks/REPLACE_ME
export HOSTNAME=$(cat /etc/hostname)

booted() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "$HOSTNAME is up!" \
    --title "$HOSTNAME is up!" \
    --color "0x00FF00" \
    --timestamp
}

reboot() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "$HOSTNAME is Rebooting!" \
    --title "$HOSTNAME is Rebooting!" \
    --color "0xeed202" \
    --timestamp
}

shutdown() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "$HOSTNAME is Shutting Down!" \
    --title "$HOSTNAME is Shutting Down!" \
    --color "FF0000" \
    --timestamp
}

"$@"
