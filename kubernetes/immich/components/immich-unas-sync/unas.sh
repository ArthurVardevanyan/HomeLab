#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/.config/rclone
cp /mnt/unas/rclone.conf /tmp/.config/rclone/rclone.conf

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

RCLONE_BASE_OPTS=( sync \
  --stats=25s --stats-log-level NOTICE --fast-list \
  --multi-thread-streams=4 --drive-chunk-size 96M --max-backlog 400000 \
  --transfers=4 --checkers=4 --buffer-size=64M
)

if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  RCLONE_OPTS=( --verbose "${RCLONE_BASE_OPTS[@]}" )
else
  RCLONE_OPTS=( "${RCLONE_BASE_OPTS[@]}" )
fi

LIST_FILE="${1:-/mnt/unas/users}"

if [[ ! -f "${LIST_FILE}" ]]; then
  echo "Users file not found: ${LIST_FILE}" >&2
  exit 2
fi

while IFS= read -r line || [[ -n "${line}" ]]; do
  # strip comments and trim whitespace
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "${line}" ]] && continue

  # parse "folder:rclone_user" mapping
  folder="${line%%:*}"
  rclone_user="${line##*:}"

  src="/mnt/library/library/${folder}"
  dst="unas-${rclone_user}:Personal-Drive/immich"

  if [[ ! -d "${src}" ]]; then
    echo "Skipping ${folder}: ${src} does not exist" >&2
    continue
  fi

  echo "Syncing ${folder} -> ${rclone_user}"
  rclone "${RCLONE_OPTS[@]}" "${src}" "${dst}"
done < "${LIST_FILE}"
