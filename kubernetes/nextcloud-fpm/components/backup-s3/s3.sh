#!/bin/sh

mkdir -p /tmp/.config/rclone
cp /mnt/s3/rclone.conf /tmp/.config/rclone/rclone.conf
rclone --progress sync ceph:nextcloud-8bc4b121-9fea-4f92-ac9c-2a1cce320084 unas:nextcloud --ignore-existing \
--stats=10s --stats-log-level NOTICE --fast-list \
--multi-thread-streams 8 --drive-chunk-size 128M --max-backlog 999999 \
--transfers=25 --checkers=25 --buffer-size=75M
