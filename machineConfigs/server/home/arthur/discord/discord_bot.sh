#!/usr/bin/env bash

export UPTIME_WEBHOOK=https://discord.com/api/webhooks/

booted() {
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is up!" \
    --title "Server is up!" \
    --color "0x00FF00" \
    --timestamp
}

restart(){
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is Rebooting!" \
    --title "Server is Rebooting!" \
    --color "0xeed202" \
    --timestamp
}

shutdown(){
  /home/arthur/discord/discord.sh \
    --webhook-url="$UPTIME_WEBHOOK" \
    --username "Server is Shutting Down!" \
    --title "Server is Shutting Down!" \
    --color "FF0000" \
    --timestamp
}


"$@"
