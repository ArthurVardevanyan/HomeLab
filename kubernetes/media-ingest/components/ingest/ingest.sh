#!/usr/bin/env bash
set -o errexit -o pipefail
shopt -s failglob

# ===========================================================================
# media-ingent: GPU-accelerated video ingestion server
# ===========================================================================
# Strategy: per-source output = min(native, 4K)
# Quality: GPU AV1 8-bit (hardware ceiling; 10-bit not available on iHD 26.2.2)
#   Rate control: -rc_mode {ICQ, QVBR, AVBR, ...} — see README for measured facts
#   Default: QVBR (safe, always has a quality target; ICQ may be settable after calibration)
# GPU: xe:"4", 2 pipelines per card (8 total on node, coexists with llama-swap)
# Source: NAS SMB (unas-arthur remote)
# Dest: new folder on the same NAS, mirrored layout
# Completion: rclone move original → <source>/_ingested/<relpath> after verified upload
# Trigger: long-running pod, INGEST_INTERVAL=900 scan + dispatch loop
# Op model: VRAM-aware auto-gating — scales to LLM load; manual scale-down optional for max throughput
# VRAM gating: per-file probe-free-VRAM — skip card if insufficient; contested jobs auto-kill
# Watchdog: per-file kill timeout as safety net (context hangs while LLM active)
# NOTE: All rclone ops are per-file (never bulk-copy the import directory)
# ===========================================================================

# --- Configuration (env defaults, overridden by k8s secrets/configmap) ---

INGEST_SOURCES="${INGEST_SOURCES:-}"        # name=remote:path[:h=NNN][:qp=NNN][,...]
INGEST_DEST="${INGEST_DEST:-}"              # rclone dest path

# Rate control mode: QVBR (default, always has quality target) | ICQ (probe pending) | AVBR
RC_MODE="${RC_MODE:-QVBR}"
# Quality target for ICQ (set after calibration).
QP_TARGET="${QP_TARGET:-24}"
# B-frame reference depth (1-INT_MAX, default 1). Higher = better compression.
B_DEPTH="${B_DEPTH:-3}"
# QVBR quality target (scale similar to CRF: 22-30 is "archive" range)
QVBR_QUALITY="${QVBR_QUALITY:-24}"

INGEST_INTERVAL="${INGEST_INTERVAL:-900}"
INGEST_DISPATCH_INTERVAL="${INGEST_DISPATCH_INTERVAL:-10}"
PIPELINES_PER_CARD="${PIPELINES_PER_CARD:-4}"

MAX_HEIGHT=2160  # default cap: min(native, 4K)

# --- Watchdog: per-file kill timeout (seconds) ---
INGEST_FILE_TIMEOUT="${INGEST_FILE_TIMEOUT:-21600}"

# --- Contest & cooldown ---
INGEST_CARD_CONTEST_GRACE="${INGEST_CARD_CONTEST_GRACE:-300}"
INGEST_CARD_COOLDOWN="${INGEST_CARD_COOLDOWN:-900}"
INGEST_VRAM_PROBE_FAIL_LIMIT="${INGEST_VRAM_PROBE_FAIL_LIMIT:-12}"

# --- Globals ---
RCLONE_CONF_DIR="/tmp/.config/rclone"
RCLONE_CONF="${RCLONE_CONF_DIR}/rclone.conf"
WORK_DIR="/mnt/work"
QUEUE_FILE="/tmp/ingest-queue"
RUNNING_FILE="/tmp/ingest-running"

# --- Card VRAM budgets per pipeline type (in MB) ---
# Placeholder values — will be calibrated against actual xpu-smi measurements
COST_1440=600
COST_4K=1400
COST_53K=2000

# --- Device discovery (render node → BDF mapping) ---
RENDER_NODES=()      # e.g. /dev/dri/renderD128
CARD_BDFS=()         # e.g. 0000:06:00.0
CARD_INDEX=()        # 0, 1, ...
CARD_GPU_INDICES=()  # GPU index for xpu-smi (e.g. 0, 1, ...)

# --- Card state ---
declare -A CARD_COOL_DOWN    # epoch seconds — 0 means not in cooldown
declare -A CARD_ACTIVE_COUNT # number of active jobs on this card
declare -A CARD_CONTEST      # consecutive failed VRAM checks (contest counter)

# --- Log dir for ffmpeg per-job logs ---
LOG_DIR="/tmp/ffmpeg-logs"

# ===========================================================================
# Functions
# ===========================================================================

log() {
  local level="${1:-INFO}"; shift
  printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

# ------------------------------------------------------------------
# Device discovery: map /dev/dri/renderD* → PCI BDF via by-path
# ------------------------------------------------------------------
discover_devices() {
  # Debug: list all files in /dev/dri/by-path/
  log DEBUG "=== /dev/dri/by-path/ contents ==="
  if [ -d "/dev/dri/by-path" ]; then
    find /dev/dri/by-path/ -maxdepth 1 | while IFS= read -r line; do log DEBUG "  $line"; done
  else
    log DEBUG "  /dev/dri/by-path/ does not exist"
  fi
  log DEBUG "=== /dev/dri/ contents ==="
  find /dev/dri/ -maxdepth 1 | while IFS= read -r line; do log DEBUG "  $line"; done

  # Try by-path discovery first
  # Note: on this system, by-path entries are character device files (not symlinks),
  # so we match by comparing minor numbers against renderD nodes.
  for by_path_file in /dev/dri/by-path/*-render; do
    [ -e "$by_path_file" ] || continue
    [ -c "$by_path_file" ] || continue

    # Extract BDF from by-path filename: pci-0000:06:00.0-render -> 0000:06:00.0
    local bdf
    bdf=$(basename "$by_path_file")
    bdf="${bdf#pci-}"
    bdf="${bdf%-render}"

    # Get minor number from by-path file
    local by_path_minor
    by_path_minor=$(stat -c '%t:%T' "$by_path_file")
    by_path_minor="${by_path_minor##*:}"  # hex minor
    by_path_minor=$((16#${by_path_minor}))  # convert hex to decimal

    for render_node in /dev/dri/renderD*; do
      [ -c "$render_node" ] || continue
      local rd_minor
      rd_minor=$(stat -c '%t:%T' "$render_node")
      rd_minor="${rd_minor##*:}"
      rd_minor=$((16#${rd_minor}))

      if [ "$by_path_minor" = "$rd_minor" ]; then
        # Check we haven't already added this render node
        local already=false
        for existing in "${RENDER_NODES[@]}"; do
          [ "$existing" = "$render_node" ] && { already=true; break; }
        done
        if ! $already; then
          RENDER_NODES+=("$render_node")
          CARD_BDFS+=("$bdf")
        fi
        break
      fi
    done
  done

  # Fallback: if by-path found nothing, enumerate /dev/dri/renderD* directly
  if [ ${#CARD_BDFS[@]} -eq 0 ]; then
    log WARN "by-path discovery found 0 cards — falling back to direct renderD enumeration"
    local idx=0
    local sorted_nodes=()
    for node in /dev/dri/renderD*; do
      [ -c "$node" ] && sorted_nodes+=("$node")
    done
    IFS=$'\n' read -r -d '' -a sorted_nodes < <(printf '%s\n' "${sorted_nodes[@]}" | sort); IFS=$' '
    [ ${#sorted_nodes[@]} -eq 0 ] && sorted_nodes=()
    for render_node in "${sorted_nodes[@]}"; do
      RENDER_NODES+=("$render_node")
      # Try to derive BDF from sysfs symlink: /sys/class/drm/renderD128/device -> ../../../../devices/pci0000:06/0000:06:00.0
      local dev_link
      dev_link=$(readlink -f "/sys/class/drm/$(basename "$render_node")/device" 2>/dev/null || true)
      local bdf_from_sysfs=""
      if [ -n "$dev_link" ]; then
        if [[ "$dev_link" =~ /([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9])$ ]]; then
          bdf_from_sysfs="${BASH_REMATCH[1]}"
        fi
      fi
      if [ -n "$bdf_from_sysfs" ]; then
        CARD_BDFS+=("$bdf_from_sysfs")
      else
        CARD_BDFS+=("idx:${idx}")
      fi
      idx=$((idx + 1))
    done
  fi

  for i in "${!CARD_BDFS[@]}"; do
    CARD_INDEX+=("$i")
  done

  # Map discovered BDFs to GPU indices via xpu-smi --list-gpus
  # The UUID encodes the BDF: e.g. "0600" (4th segment) → bus=06, dev=00, func=0 → BDF 0000:06:00.0
  if [ ${#CARD_BDFS[@]} -gt 0 ] && command -v xpu-smi &>/dev/null; then
    local gpu_idx=0
    local uuid_field=""
    local bdf_hex=""
    while IFS= read -r uuid_line; do
      uuid_field="${uuid_line#*UUID: }"
      # Extract 5th segment from UUID (index 4): e.g. "0600" from "GPU-868023e2-0000-0000-0600-000000000000"
      bdf_hex=$(echo "$uuid_field" | awk -F- '{print $5}' | head -c 4)
      # Parse UUID segment: first 2 hex = bus, last 2 hex = dev<<4 | func
      if [ ${#bdf_hex} -eq 4 ] && [[ "$bdf_hex" =~ ^[0-9a-fA-F]{4}$ ]]; then
        local bus_hex="${bdf_hex:0:2}"
        local dev_func_hex="${bdf_hex:2:2}"
        local bus=$((16#${bus_hex}))
        local dev_func=$((16#${dev_func_hex}))
        local dev=$(( (dev_func >> 4) & 0xF ))
        local func=$(( dev_func & 0xF ))
        local uuid_bdf
        uuid_bdf=$(printf "0000:%02x:%02x.%s" "$bus" "$dev" "$func")

        # Match against discovered BDFs
        local matched=false
        for i in "${!CARD_BDFS[@]}"; do
          if [ "${CARD_BDFS[$i]}" = "$uuid_bdf" ]; then
            CARD_GPU_INDICES+=("$gpu_idx")
            matched=true
            break
          fi
        done
        if ! $matched; then
          # BDF from UUID not found — try GPU index fallback
          CARD_GPU_INDICES+=("$gpu_idx")
        fi
      fi
      gpu_idx=$((gpu_idx + 1))
    done < <(xpu-smi --list-gpus 2>/dev/null | grep "^GPU ")
  fi

  # Fallback: if any GPU index is missing, use sequential indices
  for i in "${!CARD_BDFS[@]}"; do
    if [ -z "${CARD_GPU_INDICES[$i]:-}" ]; then
      CARD_GPU_INDICES+=("$i")
    fi
  done

  log INFO "Discovered ${#CARD_BDFS[@]} GPU card(s):"
  for i in "${!CARD_BDFS[@]}"; do
    log INFO "  Card $i: ${RENDER_NODES[$i]} (${CARD_BDFS[$i]})"
  done
}

# ------------------------------------------------------------------
# Probe VRAM for a single card (by BDF)
# Returns: total used free (in MB)
# ------------------------------------------------------------------
probe_card_vram() {
  local gpu_idx="$1"
  local out
  out=$(xpu-smi --query-gpu=memory.total,memory.used,memory.free --id="$gpu_idx" \
        --format=csv,noheader,nounits 2>/dev/null) || true

  if [ -n "$out" ]; then
    local total used free
    total=$(echo "$out" | awk -F',' '{print $1}' | tr -d ' ')
    used=$(echo "$out" | awk -F',' '{print $2}' | tr -d ' ')
    free=$(echo "$out" | awk -F',' '{print $3}' | tr -d ' ')
    log DEBUG "Card $gpu_idx: total=${total}MB used=${used}MB free=${free}MB"
    echo "${free}"
  else
    log WARN "xpu-smi failed for card $gpu_idx — assuming full VRAM"
    echo "32656"
  fi
}

# ------------------------------------------------------------------
# Probe all cards; return per-card free MB space
# Fills: CARD_FREE (array), updates probe failure tracking
# ------------------------------------------------------------------
probe_all_cards() {
  CARD_FREE=()
  local all_failed=true

  for i in "${!CARD_BDFS[@]}"; do
    local bdf="${CARD_BDFS[$i]}"
    local free
    free=$(probe_card_vram "${CARD_GPU_INDICES[$i]}")
    CARD_FREE+=("$free")

    if [ "$free" = "32656" ]; then
      all_failed=true
    else
      all_failed=false
    fi
  done

  if $all_failed; then
    log WARN "xpu-smi failed on all cards (probe limit=${INGEST_VRAM_PROBE_FAIL_LIMIT})"
    PROBE_FAIL_COUNT=$((PROBE_FAIL_COUNT + 1))
    if [ "$PROBE_FAIL_COUNT" -ge "$INGEST_VRAM_PROBE_FAIL_LIMIT" ]; then
      log WARN "Probe failure limit reached — degrading to assume-full VRAM"
      for i in "${!CARD_BDFS[@]}"; do
        CARD_FREE[i]=32656
      done
      PROBE_FAIL_COUNT=0
    fi
  else
    PROBE_FAIL_COUNT=0
  fi

  echo "${CARD_FREE[@]}"
}

# ------------------------------------------------------------------
# Get cost class from output height
# ------------------------------------------------------------------
get_cost_class() {
  local output_h="$1"
  if [ "$output_h" -le 1440 ] 2>/dev/null; then
    echo "$COST_1440"
  elif [ "$output_h" -le 2160 ] 2>/dev/null; then
    echo "$COST_4K"
  else
    echo "$COST_53K"
  fi
}

# ------------------------------------------------------------------
# Get target height (min(probed, MAX_HEIGHT))
# ------------------------------------------------------------------
get_target_height() {
  local probed_height="$1"
  local override="$2"
  if [ -n "$override" ] && [ "$override" -gt 0 ] 2>/dev/null; then
    echo "$override"
  elif [ -n "$probed_height" ] && [ "$probed_height" -gt 0 ] 2>/dev/null; then
    if [ "$probed_height" -gt "$MAX_HEIGHT" ]; then
      echo "$MAX_HEIGHT"
    else
      echo "$probed_height"
    fi
  else
    echo "$MAX_HEIGHT"
  fi
}

# ------------------------------------------------------------------
# Parse INGEST_SOURCES — format: name=remote:path[:h=NNN][:qp=NNN][,...]
# Outputs: name|remote|path|h_override|qp_override
# ------------------------------------------------------------------
parse_sources() {
  if [ -z "$INGEST_SOURCES" ]; then
    log WARN "INGEST_SOURCES is not set — no sources configured"
    return
  fi

  IFS=',' read -ra SOURCES <<< "$INGEST_SOURCES"
  for entry in "${SOURCES[@]}"; do
    local name remote path h_override qp_override
    name=$(echo "$entry" | cut -d'=' -f1)
    remote=$(echo "$entry" | sed 's/^[^=]*=//;s/:.*//')
    local remainder
    remainder="${entry#*=}"
    path="${remainder#*:}"
    path="${path#\*/}"
    h_override="${entry##*:h=}"
    h_override="${h_override%%:*}"
    qp_override="${entry##*:qp=}"

    echo "${name}|${remote}|${path}|${h_override}|${qp_override}"
  done
}

# ------------------------------------------------------------------
# Enumerate video files from rclone lsf (remote scan — read-only)
# ------------------------------------------------------------------
enumerate_files() {
  local remote="$1"
  local path="$2"
  rclone lsf "${remote}:${path}" --include "*.[mM][pP]4" --include "*.[mM][oO][vV]" --include "*.[wW][mM][vV]" --include "*.[fF][lL][vV]" --include "*.[aA][vV][iI]" --include "*.[gG][oO][pP][rR][oO]*" 2>/dev/null || true
}

# ------------------------------------------------------------------
# Install rclone configuration from secret mount
# ------------------------------------------------------------------
install_rclone_conf() {
  if [ -f "$SECRET_MOUNT/rclone.conf" ]; then
    mkdir -p "$RCLONE_CONF_DIR"
    cp "$SECRET_MOUNT/rclone.conf" "$RCLONE_CONF"
    log INFO "rclone.conf installed"
  fi
}

# ===========================================================================
# Cleanup / shutdown handling
# ===========================================================================
cleanup() {
  log INFO "Shutting down media-ingest..."
  # Kill contest watcher
  if [ -n "${CONTEST_WATCHER_PID:-}" ]; then
    kill "$CONTEST_WATCHER_PID" 2>/dev/null || true
    wait "$CONTEST_WATCHER_PID" 2>/dev/null || true
  fi
  # Kill any remaining ffmpeg processes
  if [ -f "$RUNNING_FILE" ]; then
    while IFS='|' read -r pid _ _ _ _; do
      if kill -0 "$pid" 2>/dev/null; then
        log WARN "Killing PID $pid (shutdown)"
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done < "$RUNNING_FILE"
    rm -f "$RUNNING_FILE"
  fi
  rm -f "$QUEUE_FILE" "$RUNNING_FILE"
  log INFO "Cleanup complete."
}

trap cleanup EXIT INT TERM

# ===========================================================================
# Dispatch: download + dispatch one file to an eligible card
# Arguments: source_name|remote|path|filename|h_override|qp_override|relpath
# Returns: 0 = dispatched, 1 = no card available (will retry)
# ===========================================================================
dispatch_one_file() {
  local line="$1"

  local source_name remote source_path filename h_override qp_override relpath
  IFS='|' read -r source_name remote source_path filename h_override qp_override relpath <<< "$line"

  # Get target height
  local output_h
  output_h=$(get_target_height 0 "$h_override")

  # Cost class based on output height
  local pipeline_cost
  pipeline_cost=$(get_cost_class "$output_h")

  # Check which card (if any) has enough free VRAM
  local best_card=-1
  local best_free=-1
  local i
  for i in "${!CARD_BDFS[@]}"; do
    local bdf="${CARD_BDFS[$i]}"
    local free="${CARD_FREE[$i]:-0}"
    local active="${CARD_ACTIVE_COUNT[$i]:-0}"
    local cooldown_until="${CARD_COOL_DOWN[$i]:-0}"
    local now
    now=$(date +%s)

    # Skip if in cooldown
    if [ "$cooldown_until" -gt "$now" ] 2>/dev/null; then
      log DEBUG "Card $i ($bdf) in cooldown (until $cooldown_until), skipping"
      continue
    fi

    # Skip if at capacity
    if [ "$active" -ge "$PIPELINES_PER_CARD" ] 2>/dev/null; then
      log DEBUG "Card $i ($bdf) at capacity ($active >= $PIPELINES_PER_CARD), skipping"
      continue
    fi

    # Check if free VRAM is sufficient for this file (awk for float comparison)
    if awk "BEGIN {exit !($free >= $pipeline_cost)}"; then
      if awk "BEGIN {exit !($free > $best_free)}"; then
        best_card=$i
        best_free=$free
      fi
    fi
  done

  if [ "$best_card" -eq -1 ]; then
    log INFO "No card has enough VRAM for ${filename} (cost=${pipeline_cost}MB) — waiting (card0_free=${CARD_FREE[0]:-0}, card1_free=${CARD_FREE[1]:-0})"
    sleep "$INGEST_DISPATCH_INTERVAL"
    return 1
  fi

  local bdf="${CARD_BDFS[$best_card]}"
  local device="${RENDER_NODES[$best_card]}"

  # Effective quality: per-source qp_override or global default
  local effective_qp
  if [ -n "$qp_override" ] && [ "$qp_override" -gt 0 ] 2>/dev/null; then
    effective_qp="$qp_override"
  else
    effective_qp="$QP_TARGET"
  fi

  log INFO "Processing: $source_name / $filename → card $best_card ($bdf, device=$device) cost=${pipeline_cost}MB free=${best_free}MB"

  # Download ONLY the working file to work dir (per-file operation)
  local input_file="${WORK_DIR}/${filename}"
  mkdir -p "$WORK_DIR"
  log DEBUG "Downloading: ${remote}:${source_path}/${filename}"
  rclone copyto "${remote}:${source_path}/${filename}" "$input_file" 2>&1 | tail -5 || {
    log ERROR "Failed to download $filename"
    return 1
  }

  # FFmpeg GPU encode — log to file (not pipe) so we track the real ffmpeg PID
  local output_file="${WORK_DIR}/${filename}.av1.mp4"
  local log_file="${LOG_DIR}/${filename}.log"


  ffmpeg -hide_banner \
    -vaapi_device "vaapi=${device}" \
    -hwaccel vaapi -hwaccel_device "$device" -hwaccel_output_format vaapi \
    -i "$input_file" \
    -vf "scale=-2:${output_h}" \
    -rc_mode "$RC_MODE" \
    -c:v av1_vaapi \
    -b_depth "$B_DEPTH" \
    -qp "$effective_qp" \
    -c:a copy \
    -y "$output_file" 2>>"$log_file" &

  local ffmpeg_pid=$!

  # Record in RUNNING_FILE: pid|card_idx|source_name|filename|relpath|remote|source_path|pipeline_cost|output_file
  echo "${ffmpeg_pid}|${best_card}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}" >> "$RUNNING_FILE"

  # Increment active count for this card
  CARD_ACTIVE_COUNT[$best_card]=$(( ${CARD_ACTIVE_COUNT[$best_card]:-0} + 1 ))

  log DEBUG "Launched PID $ffmpeg_pid on card $best_card (cost=${pipeline_cost}MB)"
  return 0
}

# ===========================================================================
# Reap completed jobs from RUNNING_FILE
# Arguments: optional — pass "all" to reap all completed, or omit to reap one
# Updates: CARD_ACTIVE_COUNT, RUNNING_FILE, queue requeues on failure
# Returns: count of jobs reaped
# ===========================================================================
reap_completed_jobs() {
  local reaped=0
  local tmp_running_file="/tmp/ingest-running.tmp"

  if [ ! -f "$RUNNING_FILE" ] || [ ! -s "$RUNNING_FILE" ]; then
    return 0
  fi

  true > "$tmp_running_file"

  while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file; do
    # Check if process is still alive
    if kill -0 "$pid" 2>/dev/null; then
      # Process still running — keep it in RUNNING_FILE
      echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}" >> "$tmp_running_file"
      continue
    fi

    # Process finished — check output file
    local success=false
    if [ -s "$output_file" ]; then
      success=true
    fi

    # Decrement active count
    CARD_ACTIVE_COUNT[$card_idx]=$(( ${CARD_ACTIVE_COUNT[$card_idx]:-1} - 1 ))
    if [ "${CARD_ACTIVE_COUNT[$card_idx]}" -lt 0 ] 2>/dev/null; then
      CARD_ACTIVE_COUNT[$card_idx]=0
    fi

    if $success; then
      # --- Success path: upload + move ---
      log INFO "Upload: ${output_file} → ${INGEST_DEST}/${source_name}/${filename}"
      rclone copyto "$output_file" "${INGEST_DEST}/${source_name}/${filename}" 2>&1 | tail -5

      log INFO "Move to _ingested: ${remote}:${source_path}/${filename} → ${remote}:${source_path}/_ingested/${relpath}/${filename}"
      rclone moveto "${remote}:${source_path}/${filename}" "${remote}:${source_path}/_ingested/${relpath}/${filename}" 2>&1 | tail -5

      log INFO "Completed: $filename (card $card_idx)"
    else
      # --- Failure path: requeue ---
      log ERROR "Encode failed or output empty for $filename (PID $pid)"
      # Requeue: put back at end of queue
      echo "${source_name}|${remote}|${source_path}|${filename}" >> "$QUEUE_FILE"
      log INFO "Re-queued: $filename"
    fi

    rm -f "$output_file" "${LOG_DIR}/${filename}.log"
    reaped=$((reaped + 1))
  done < "$RUNNING_FILE"

  # Replace RUNNING_FILE with trimmed version
  mv "$tmp_running_file" "$RUNNING_FILE"
  return $reaped
}

# ===========================================================================
# Contest watcher (background) — kills jobs on contended cards
# Runs every INGEST_DISPATCH_INTERVAL, checks if active jobs are on
# cards with insufficient VRAM for that job's cost class.
# ===========================================================================
contest_watcher() {
  log INFO "Contest watcher started (grace=${INGEST_CARD_CONTEST_GRACE}s, cooldown=${INGEST_CARD_COOLDOWN}s)"

  while true; do
    sleep "$INGEST_DISPATCH_INTERVAL"

    if [ ! -f "$RUNNING_FILE" ] || [ ! -s "$RUNNING_FILE" ]; then
      continue
    fi

    # Clear contest counters
    for i in "${!CARD_BDFS[@]}"; do
      CARD_CONTEST[$i]=0
    done

    # Probe VRAM
    probe_all_cards

    # Check each active job for contention
    local tmp_running="/tmp/ingest-running.tmp"
    true > "$tmp_running"

    local reaped=0
    while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file; do
      local bdf="${CARD_BDFS[$card_idx]:-}"
      local free="${CARD_FREE[$card_idx]:-0}"
      local now
      now=$(date +%s)

      if awk "BEGIN {exit !($free < $pipeline_cost)}"; then
        # Card has insufficient VRAM for this job — it's contended
        local contested=${CARD_CONTEST[$card_idx]:-0}
        contested=$((contested + 1))
        CARD_CONTEST[$card_idx]=$contested

        if [ "$contested" -ge $((INGEST_CARD_CONTEST_GRACE / INGEST_DISPATCH_INTERVAL)) ]; then
          # Contest grace exceeded — kill the job
          log WARN "Contest kill: PID $pid ($source_name/$filename) on card $card_idx (free=${free}MB < cost=${pipeline_cost}MB)"
          kill -TERM "$pid" 2>/dev/null || true
          rm -f "$output_file" "${LOG_DIR}/${filename}.log"

          # Decrement active count
          CARD_ACTIVE_COUNT[$card_idx]=$(( ${CARD_ACTIVE_COUNT[$card_idx]:-1} - 1 ))
          if [ "${CARD_ACTIVE_COUNT[$card_idx]}" -lt 0 ] 2>/dev/null; then
            CARD_ACTIVE_COUNT[$card_idx]=0
          fi

          # Requeue
          echo "${source_name}|${remote}|${source_path}|${filename}" >> "$QUEUE_FILE"
          log INFO "Re-queued: $filename (card $card_idx contended, free=${free}MB)"

          # Set cooldown on card
          CARD_COOL_DOWN[$card_idx]=$((now + INGEST_CARD_COOLDOWN))
          CARD_CONTEST[$card_idx]=0
          reaped=$((reaped + 1))
          continue
        fi
      else
        # Card has enough VRAM — reset contest counter
        CARD_CONTEST[$card_idx]=0
      fi

      # Keep the job in RUNNING_FILE
      echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}" >> "$tmp_running"
    done < "$RUNNING_FILE"

    if [ "$reaped" -gt 0 ]; then
      mv "$tmp_running" "$RUNNING_FILE"
    else
      mv "$tmp_running" "$RUNNING_FILE"
    fi
  done
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  # Discover GPU devices
  discover_devices
  if [ ${#CARD_BDFS[@]} -eq 0 ]; then
    log ERROR "No GPU devices found — cannot proceed"
    exit 1
  fi

  # Install rclone config
  install_rclone_conf
  export RCLONE_CONFIG="$RCLONE_CONF"

  # Initialize state files
  true > "$QUEUE_FILE"
  true > "$RUNNING_FILE"
  mkdir -p "$LOG_DIR"

  log INFO "Starting media-ingest pipeline (GPU: ${#CARD_BDFS[@]} card(s))"
  log INFO "Sources: ${INGEST_SOURCES:-<not set>}, Dest: ${INGEST_DEST:-<not set>}"
  log INFO "RC_MODE=$RC_MODE, QP_TARGET=$QP_TARGET, B_DEPTH=$B_DEPTH, Pipelines per card: $PIPELINES_PER_CARD"
  log INFO "Watchdog: per-file timeout=${INGEST_FILE_TIMEOUT}s"
  log INFO "VRAM budgets: 1440p=${COST_1440}MB 4K=${COST_4K}MB 5.3K=${COST_53K}MB"
  log INFO "Card cooldown: ${INGEST_CARD_COOLDOWN}s, Contest grace: ${INGEST_CARD_CONTEST_GRACE}s"

  # Start contest watcher (background)
  contest_watcher &
  CONTEST_WATCHER_PID=$!

  PROBE_FAIL_COUNT=0

  while true; do
    # --- Scan phase: refresh queue ---
    log INFO "Refreshing file queue..."
    true > "$QUEUE_FILE"

    if [ -n "$INGEST_SOURCES" ] && [ -n "$INGEST_DEST" ]; then
      while IFS='|' read -r source_name remote source_path h_override qp_override; do
        [ -z "$source_name" ] && continue
        [ -z "$remote" ] && continue
        [ -z "$source_path" ] && continue

        log INFO "Scanning: $source_name (${remote}:${source_path})"

        while IFS= read -r filename; do
          [ -z "$filename" ] && continue
          local relpath="${source_path%/}/${filename}";

          # Skip if already at dest (idempotency — check per file, not bulk)
          if rclone lsf "${INGEST_DEST}/${source_name}/" --include "$filename" 2>/dev/null | grep -q "^${filename}$"; then
            log INFO "SKIP (dest exists): $source_name / $filename"
            continue
          fi

          # Queue line: name|remote|path|filename|h_override|qp_override|relpath
          # NOTE: source_name is field 1 (fixed from previous bug where it was missing)
          echo "${source_name}|${remote}|${source_path}|${filename}|${h_override}|${qp_override}|${relpath}" >> "$QUEUE_FILE"
        done < <(enumerate_files "$remote" "$source_path")

      done < <(parse_sources)
    fi

    # --- Dispatch loop: concurrent dispatch + reaping ---
    while [ -s "$QUEUE_FILE" ] 2>/dev/null; do
      # Reap completed jobs first (non-blocking: only processes that have exited)
      local reaped=0
      if [ -s "$RUNNING_FILE" ]; then
        local tmp_running="/tmp/ingest-running.reap.tmp"
      true > "$tmp_running"

        while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file; do
          if kill -0 "$pid" 2>/dev/null; then
            # Still running — keep in RUNNING_FILE
            echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}" >> "$tmp_running"
          else
            # Process finished — handle success/failure
            local success=false
            if [ -s "$output_file" ]; then
              success=true
            fi

            # Decrement active count
            CARD_ACTIVE_COUNT[$card_idx]=$(( ${CARD_ACTIVE_COUNT[$card_idx]:-1} - 1 ))
            if [ "${CARD_ACTIVE_COUNT[$card_idx]}" -lt 0 ] 2>/dev/null; then
              CARD_ACTIVE_COUNT[$card_idx]=0
            fi

            if $success; then
              log INFO "Upload: ${output_file} → ${INGEST_DEST}/${source_name}/${filename}"
              rclone copyto "$output_file" "${INGEST_DEST}/${source_name}/${filename}" 2>&1 | tail -5

              log INFO "Move to _ingested: ${remote}:${source_path}/${filename} → ${remote}:${source_path}/_ingested/${relpath}/${filename}"
              rclone moveto "${remote}:${source_path}/${filename}" "${remote}:${source_path}/_ingested/${relpath}/${filename}" 2>&1 | tail -5

              log INFO "Completed: $filename (card $card_idx)"
            else
              log ERROR "Encode failed or output empty for $filename (PID $pid)"
              echo "${source_name}|${remote}|${source_path}|${filename}" >> "$QUEUE_FILE"
              log INFO "Re-queued: $filename"
            fi

            rm -f "$output_file" "${LOG_DIR}/${filename}.log"
            reaped=$((reaped + 1))
          fi
        done < "$RUNNING_FILE"

        if [ "$reaped" -gt 0 ]; then
          mv "$tmp_running" "$RUNNING_FILE"
        else
          rm -f "$tmp_running"
        fi
      fi

      # Try to dispatch one file
      if [ -s "$QUEUE_FILE" ]; then
        # Probe VRAM before dispatch
        probe_all_cards

        # Pick next line from queue
        local line
        line=$(head -n 1 "$QUEUE_FILE")
        if [ -n "$line" ]; then
          if dispatch_one_file "$line"; then
            # Dispatched — remove from queue
            sed -i "1d" "$QUEUE_FILE"
          else
            # Dispatch failed (no card available) — wait before retry
            log DEBUG "Dispatch failed for ${filename} — retrying after ${INGEST_DISPATCH_INTERVAL}s"
          fi
        fi
      fi

      # If no jobs running and queue is empty, break
      if [ ! -s "$RUNNING_FILE" ] && [ ! -s "$QUEUE_FILE" ]; then
        break
      fi

      sleep "$INGEST_DISPATCH_INTERVAL"
    done

    # Brief sleep between scan cycles
    sleep "$INGEST_INTERVAL"
  done
}

main "$@"
