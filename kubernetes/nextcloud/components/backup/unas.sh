#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/.config/rclone
cp /mnt/unas/rclone.conf /tmp/.config/rclone/rclone.conf

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

LIST_FILE="${1:-/mnt/unas/nextcloud-users.txt}"

RCLONE_BASE_OPTS=( copy --ignore-existing --stats=10s --stats-log-level NOTICE \
  --multi-thread-streams 8 --drive-chunk-size 128M --max-backlog 999999 \
  --transfers=25 --checkers=25 --buffer-size=75M )

# include --verbose when requested
if [ "${VERBOSE:-0}" -eq 1 ]; then
  RCLONE_OPTS=( --verbose "${RCLONE_BASE_OPTS[@]}" )
else
  RCLONE_OPTS=( "${RCLONE_BASE_OPTS[@]}" )
fi

EXCLUDES=( 'Trips-Events/**' 'Family, Friends and People Pictures/**' )

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

  src="nextcloud-${user}:"
  dst="unas-${user}:Personal-Drive/nextcloud"

  exclude_args=()
  if [ "$user" != "arthur" ]; then
    for p in "${EXCLUDES[@]}"; do
      exclude_args+=( --exclude "$p" )
    done
  fi

  echo "Syncing ${src} -> ${dst}"
  rclone "${RCLONE_OPTS[@]}" "${exclude_args[@]}" "$src" "$dst"
done < "$LIST_FILE"
