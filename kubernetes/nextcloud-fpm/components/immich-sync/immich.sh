#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/.config/rclone
cp /mnt/immich/rclone.conf /tmp/.config/rclone/rclone.conf

# parse options
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

LIST_FILE="${1:-/mnt/immich/nextcloud-users.txt}"

RCLONE_BASE_OPTS=( copy --ignore-existing --stats=10s --stats-log-level NOTICE \
  --multi-thread-streams 8 --drive-chunk-size 128M --max-backlog 999999 \
  --transfers=25 --checkers=50 --buffer-size=75M )

# include --verbose when requested
if [ "${VERBOSE:-0}" -eq 1 ]; then
  RCLONE_OPTS=( --verbose "${RCLONE_BASE_OPTS[@]}" )
else
  RCLONE_OPTS=( "${RCLONE_BASE_OPTS[@]}" )
fi

EXCLUDES=( 'Trips/**' 'Trips-Events/**' 'Family, Friends and People Pictures/**' )

if [ ! -f "$LIST_FILE" ]; then
  echo "List file not found: $LIST_FILE" >&2
  exit 2
fi

while IFS= read -r line || [ -n "$line" ]; do
  # strip comments and trim whitespace (avoid external xargs dependency)
  user="${line%%#*}"
  # trim leading whitespace
  user="${user#"${user%%[![:space:]]*}"}"
  # trim trailing whitespace
  user="${user%"${user##*[![:space:]]}"}"
  [ -z "$user" ] && continue

  src="nextcloud-${user}-fpm:"
  dst="/mnt/nextcloud-immich/${user}"
  mkdir -p "$dst"

  exclude_args=()
  # if [ "$user" != "arthur" ]; then
    for p in "${EXCLUDES[@]}"; do
      exclude_args+=( --exclude "$p" )
    done
  # fi

  echo "Syncing ${src} -> ${dst}"
  rclone "${RCLONE_OPTS[@]}" "${exclude_args[@]}" \
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
   "$src" "$dst"
done < "$LIST_FILE"
