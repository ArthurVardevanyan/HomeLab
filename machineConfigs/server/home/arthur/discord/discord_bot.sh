#!/usr/bin/env bash

# https://github.com/ChaoticWeg/discord.sh

export UPTIME_WEBHOOK=https://discord.com/api/webhooks/REPLACE_ME

booted() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is up!" \
    --title "Server is up!" \
    --color "0x00FF00" \
    --timestamp
}

reboot() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is Rebooting!" \
    --title "Server is Rebooting!" \
    --color "0xeed202" \
    --timestamp
}

shutdown() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is Shutting Down!" \
    --title "Server is Shutting Down!" \
    --color "FF0000" \
    --timestamp
}

"$@"
