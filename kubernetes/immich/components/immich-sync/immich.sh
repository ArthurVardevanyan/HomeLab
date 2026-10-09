#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/.config/rclone
cp /mnt/immich/rclone.conf /tmp/.config/rclone/rclone.conf

# parse options
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

RCLONE_BASE_OPTS=( sync --ignore-existing \
	--stats=25s --stats-log-level NOTICE --fast-list \
	--multi-thread-streams=4 --drive-chunk-size 96M --max-backlog 400000 \
	--transfers=4 --checkers=4 --buffer-size=64M
)

# include --verbose when requested
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  RCLONE_OPTS=( --verbose "${RCLONE_BASE_OPTS[@]}" )
else
  RCLONE_OPTS=( "${RCLONE_BASE_OPTS[@]}" )
fi

EXCLUDES=( 'raw/**' )

SRC="nextcloud-arthur-fpm:"
DST="/mnt/media/nextcloud"
mkdir -p "${DST}"

echo "Syncing ${SRC} -> ${DST}"
rclone "${RCLONE_OPTS[@]}" \
--filter "+ *.jpg" \
--filter "+ *.jpeg" \
--filter "+ *.png" \
--filter "+ *.gif" \
--filter "+ *.tiff" \
--filter "+ *.bmp" \
--filter "+ *.raw" \
--filter "+ *.cr2" \
--filter "+ *.nef" \
--filter "+ *.arw" \
--filter "+ *.orf" \
--filter "+ *.dng" \
--filter "+ *.heic" \
--filter "+ *.heif" \
--filter "+ *.aae" \
--filter "+ *.mp4" \
--filter "+ *.mov" \
--filter "+ *.avi" \
--filter "+ *.mkv" \
--filter "+ *.wmv" \
--filter "+ *.flv" \
--filter "+ *.webm" \
--filter "+ *.mts" \
--filter "+ *.m2ts" \
--filter "+ *.3gp" \
--filter "+ *.3g2" \
--filter "+ *.m4v" \
--filter "- *" \
--exclude "${EXCLUDES[@]}" \
  "${SRC}" "${DST}"
