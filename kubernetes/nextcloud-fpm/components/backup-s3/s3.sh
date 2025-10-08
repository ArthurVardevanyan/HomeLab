#!/bin/sh

mkdir -p /tmp/.config/rclone
cp /mnt/s3/rclone.conf /tmp/.config/rclone/rclone.conf
rclone --progress sync ceph:nextcloud-8bc4b121-9fea-4f92-ac9c-2a1cce320084 unas-ssd:nextcloud --ignore-existing \
	--stats=25s --stats-log-level NOTICE --fast-list \
	--multi-thread-streams=1 --drive-chunk-size 64M --max-backlog 250000 \
	--transfers=4 --checkers=1 --buffer-size=48M
