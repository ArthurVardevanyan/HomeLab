#!/usr/bin/env bash
set -o errexit -o pipefail -o nounset
shopt -s failglob

# ===========================================================================
# media-ingent: GPU-accelerated video ingestion server
# ===========================================================================
# Strategy: per-source output = min(native, 4K)
# Quality: GPU AV1 8-bit (hardware ceiling; 10-bit not available on iHD 25.4.6)
#   Rate control: -rc_mode {ICQ, CQP, CBR, VBR} — see README for measured facts
#   Default: ICQ, resolution-tiered ICQ_QUALITY_1440/ICQ_QUALITY_2160,
#   plus GoPro-specific ICQ_QUALITY_GOPRO (no size gating)
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

log() {
  local level="${1:-INFO}"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s %s\n' "${ts}" "${level}" "$*" >&2
}

INGEST_SOURCES="${INGEST_SOURCES:-}"        # name=remote:path[:h=NNN][:qp=NNN][,...]
INGEST_DEST="${INGEST_DEST:-}"              # rclone dest path
SECRET_MOUNT="${SECRET_MOUNT:-/etc/secret}" # rclone.conf secret mount path

# Rate control mode for av1_vaapi. Driver-supported modes only:
#   ICQ (default) | CQP | CBR | VBR
# QVBR/AVBR are REJECTED by this driver at encoder-open time:
#   "Driver does not support QVBR RC mode (supported modes: CQP, CBR, VBR, ICQ)"
# CQP is BROKEN on this driver: it ignores both -qp and -global_quality
# ("No quality level set; using default (25)") and emits 319-403 Mbps
# regardless of the value passed. Do not use CQP for quality targeting.
RC_MODE="${RC_MODE:-ICQ}"

# ICQ quality target ("Intelligent Constant Quality" — Intel's adaptive,
# content-aware quality mode; the closest VAAPI analogue to software x264/
# libsvtav1 CRF). Applied via -global_quality. NOTE: this is NOT a literal
# QP — av1_vaapi has no fixed-QP mode that actually works (see CQP note
# above), so the old name "QP_TARGET" was misleading and has been retired
# in favor of ICQ_QUALITY.
#
# Resolution-tiered (by OUTPUT height) plus GoPro-specific tier:
# the ICQ scale does not behave the same across source resolutions, so a
# single flat value cannot serve all cameras well.
#
# Height tiers: tier is selected by OUTPUT height (post MAX_HEIGHT downscale),
# so the 5.3K GoPro — which downscales to 2160p — gets the 4K tier, not an
# undefined "above 4K" tier.
#
# GoPro tier: selected by GoPro filename pattern (GX*/GH* prefix), not
# resolution. This ensures GoPro's HEVC codec, dynamic-range profile, and
# codec behavior get a quality target calibrated for GoPro content rather
# than generic 4K h264 content. Falls through to the 2160 height tier only
# if the filename does not match a GoPro pattern.
#
# Calibrated 2026-09:
#   1440p (2560x1440@30, 27.0 Mbps h264 source):
#     GQ=26 -> 26.5 Mbps (98% of source, SSIM 0.9872)
#     GQ=29 -> 19.3 Mbps (71% of source, SSIM 0.9850)
#     GQ=30 -> 16.8 Mbps (62% of source, SSIM 0.9839)
#     GQ=33 ->  9.7 Mbps (36% of source, SSIM 0.9786)
#     GQ=34 -> ~8.3 Mbps (~31% of source, interpolated)  <- chosen
#     GQ=36 ->  4.7 Mbps (18% of source, SSIM 0.9709)
#   4K60 (3840x2160@60, 65.8 Mbps h264 source):
#     GQ=26 -> 141 Mbps (214% of source)
#     GQ=27 -> ~125-130 Mbps (~190% of source, interpolated)
#     GQ=30 ->  94 Mbps (143% of source, SSIM 0.9881)
#     GQ=34 ->  62 Mbps  (94% of source, SSIM 0.9855)
#     GQ=35 -> ~53 Mbps (~80% of source, interpolated)  <- chosen
#     GQ=36 ->  44 Mbps  (67% of source, SSIM 0.9830)
#     GQ=38 ->  29 Mbps  (44% of source, SSIM 0.9794)
#     GQ=40 ->  20 Mbps  (30% of source, SSIM 0.9746)
# Break-even vs source is ~GQ 26 at 1440p but ~GQ 33 at 4K — a ~7-point
# offset, which is why the tiers exist. GQ=35 at 4K is just above break-even
# and produces ~80% of the h264 source size (measured QA); the pre-QA value
# of GQ=27 was below break-even and inflated output above the source. See
# README for the current rationale.
# VBR (-b:v/-maxrate, matched) measured marginally more efficient than ICQ
# at equal quality (27.1 Mbps @ SSIM 0.9794 vs ICQ 29.2 Mbps @ SSIM 0.9794)
# and adds a hard bitrate ceiling ICQ cannot provide — a documented
# alternative for later, not the current default. See README.
#
# QP_TARGET is a DEPRECATED alias for the flat (pre-tiering) value; if set,
# it seeds ALL tiers below. ICQ_QUALITY (flat) is likewise deprecated in
# favor of the per-tier vars but still seeds all tiers if set. ingest.env
# is the authoritative source for these values — the in-script defaults
# below must be kept in sync with ingest.env. A mismatch is not an error
# (env always wins) but is loud in the log, precisely because a silent
# env/script split is what caused a prior mistuned encode to go unnoticed
# (script default was edited, env value — the one actually in effect —
# was not).
_ICQ_QUALITY_1440_DEFAULT=33
_ICQ_QUALITY_2160_DEFAULT=35
_ICQ_QUALITY_GOPRO_DEFAULT=24
if [[ -n "${ICQ_QUALITY:-}" ]] && [[ -n "${QP_TARGET:-}" ]] && [[ "${ICQ_QUALITY}" != "${QP_TARGET}" ]]; then
  log WARN "Both ICQ_QUALITY=${ICQ_QUALITY} and deprecated QP_TARGET=${QP_TARGET} are set and disagree; ICQ_QUALITY wins. Remove QP_TARGET from config."
fi
_ICQ_QUALITY_FLAT="${ICQ_QUALITY:-${QP_TARGET:-}}"
if [[ -n "${_ICQ_QUALITY_FLAT}" ]]; then
  log WARN "ICQ_QUALITY/QP_TARGET (flat, deprecated) is set to ${_ICQ_QUALITY_FLAT}; seeding ICQ_QUALITY_1440, ICQ_QUALITY_2160, and ICQ_QUALITY_GOPRO unless overridden. Rename to the per-tier vars in ingest.env."
fi
ICQ_QUALITY_1440="${ICQ_QUALITY_1440:-${_ICQ_QUALITY_FLAT:-${_ICQ_QUALITY_1440_DEFAULT}}}"
ICQ_QUALITY_2160="${ICQ_QUALITY_2160:-${_ICQ_QUALITY_FLAT:-${_ICQ_QUALITY_2160_DEFAULT}}}"
ICQ_QUALITY_GOPRO="${ICQ_QUALITY_GOPRO:-${_ICQ_QUALITY_FLAT:-${_ICQ_QUALITY_GOPRO_DEFAULT}}}"
if [[ "${ICQ_QUALITY_1440}" != "${_ICQ_QUALITY_1440_DEFAULT}" ]]; then
  log WARN "Effective ICQ_QUALITY_1440=${ICQ_QUALITY_1440} differs from in-script default=${_ICQ_QUALITY_1440_DEFAULT} (env/config wins; expected if intentionally overridden in ingest.env)."
fi
if [[ "${ICQ_QUALITY_2160}" != "${_ICQ_QUALITY_2160_DEFAULT}" ]]; then
  log WARN "Effective ICQ_QUALITY_2160=${ICQ_QUALITY_2160} differs from in-script default=${_ICQ_QUALITY_2160_DEFAULT} (env/config wins; expected if intentionally overridden in ingest.env)."
fi
if [[ "${ICQ_QUALITY_GOPRO}" != "${_ICQ_QUALITY_GOPRO_DEFAULT}" ]]; then
  log WARN "Effective ICQ_QUALITY_GOPRO=${ICQ_QUALITY_GOPRO} differs from in-script default=${_ICQ_QUALITY_GOPRO_DEFAULT} (env/config wins; expected if intentionally overridden in ingest.env)."
fi

# B-frame reference depth. NOTE: measured INERT on this driver — verbose
# logging reports "Using intra, P- and B-frames (supported references: 3 /
# 1)" regardless of this value, and 300-frame test encodes at 1, 3, and 5
# produced byte-identical output. Kept as a passthrough in case a future
# driver honors it; do not rely on it for compression tuning.
B_DEPTH="${B_DEPTH:-3}"

INGEST_INTERVAL="${INGEST_INTERVAL:-900}"
INGEST_DISPATCH_INTERVAL="${INGEST_DISPATCH_INTERVAL:-30}"
PIPELINES_PER_CARD="${PIPELINES_PER_CARD:-4}"

MAX_HEIGHT=2160  # default cap: min(native, 4K)

# --- Watchdog: per-file kill timeout (seconds) ---
INGEST_FILE_TIMEOUT="${INGEST_FILE_TIMEOUT:-21600}"

# --- Contest & cooldown ---
INGEST_CARD_CONTEST_GRACE="${INGEST_CARD_CONTEST_GRACE:-300}"
INGEST_CARD_COOLDOWN="${INGEST_CARD_COOLDOWN:-900}"
  # --- Contention guard: max re-attempts per file before dropping ---
  INGEST_MAX_ATTEMPTS="${INGEST_MAX_ATTEMPTS:-3}"
  INGEST_VRAM_PROBE_FAIL_LIMIT="${INGEST_VRAM_PROBE_FAIL_LIMIT:-12}"

  # --- Globals ---
RCLONE_CONF_DIR="/tmp/.config/rclone"
RCLONE_CONF="${RCLONE_CONF_DIR}/rclone.conf"
WORK_DIR="/mnt/work"
 QUEUE_FILE="/tmp/ingest-queue"
 RUNNING_FILE="/tmp/ingest-running"
 INGEST_RETRY_FILE="/tmp/ingest-retry-counter"

# --- Card VRAM budgets per pipeline type (in MB) ---
# Placeholder values — will be calibrated against actual xpu-smi measurements
COST_1440=500
COST_4K=1000
COST_53K=1000

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

# ------------------------------------------------------------------
# Device discovery: map /dev/dri/renderD* → PCI BDF via by-path
# ------------------------------------------------------------------
discover_devices() {
  # Debug: list all files in /dev/dri/by-path/
  log DEBUG "=== /dev/dri/by-path/ contents ==="
  if [[ -d "/dev/dri/by-path" ]]; then
    find /dev/dri/by-path/ -maxdepth 1 | while IFS= read -r line; do log DEBUG "  ${line}"; done
  else
    log DEBUG "  /dev/dri/by-path/ does not exist"
  fi
  log DEBUG "=== /dev/dri/ contents ==="
  find /dev/dri/ -maxdepth 1 | while IFS= read -r line; do log DEBUG "  ${line}"; done

  # Try by-path discovery first
  # Note: on this system, by-path entries are character device files (not symlinks),
  # so we match by comparing minor numbers against renderD nodes.
  for by_path_file in /dev/dri/by-path/*-render; do
    [[ -e "${by_path_file}" ]] || continue
    [[ -c "${by_path_file}" ]] || continue

    # Extract BDF from by-path filename: pci-0000:06:00.0-render -> 0000:06:00.0
    local bdf
    bdf=$(basename "${by_path_file}")
    bdf="${bdf#pci-}"
    bdf="${bdf%-render}"

    # Get minor number from by-path file
    local by_path_minor
    by_path_minor=$(stat -c '%t:%T' "${by_path_file}")
    by_path_minor="${by_path_minor##*:}"  # hex minor
    by_path_minor=$((16#${by_path_minor}))  # convert hex to decimal

    for render_node in /dev/dri/renderD*; do
      [[ -c "${render_node}" ]] || continue
      local rd_minor
      rd_minor=$(stat -c '%t:%T' "${render_node}")
      rd_minor="${rd_minor##*:}"
      rd_minor=$((16#${rd_minor}))

      if [[ "${by_path_minor}" = "${rd_minor}" ]]; then
        # Check we haven't already added this render node
        local already=false
        for existing in "${RENDER_NODES[@]}"; do
          [[ "${existing}" = "${render_node}" ]] && { already=true; break; }
        done
        if ! ${already}; then
          RENDER_NODES+=("${render_node}")
          CARD_BDFS+=("${bdf}")
        fi
        break
      fi
    done
  done

  # Fallback: if by-path found nothing, enumerate /dev/dri/renderD* directly
  if [[ ${#CARD_BDFS[@]} -eq 0 ]]; then
    log WARN "by-path discovery found 0 cards — falling back to direct renderD enumeration"
    local idx=0
    local sorted_nodes=()
    for node in /dev/dri/renderD*; do
      [[ -c "${node}" ]] && sorted_nodes+=("${node}")
    done
    IFS=$'\n' read -r -d '' -a sorted_nodes < <(printf '%s\n' "${sorted_nodes[@]}" | sort) || true
    IFS=$' '
    [[ ${#sorted_nodes[@]} -eq 0 ]] && sorted_nodes=()
    for render_node in "${sorted_nodes[@]}"; do
      RENDER_NODES+=("${render_node}")
      # Try to derive BDF from sysfs symlink: /sys/class/drm/renderD128/device -> ../../../../devices/pci0000:06/0000:06:00.0
      local dev_link
      dev_link=$(readlink -f "/sys/class/drm/$(basename "${render_node}")/device" 2>/dev/null || true)
      local bdf_from_sysfs=""
      if [[ -n "${dev_link}" ]]; then
        if [[ "${dev_link}" =~ /([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9])$ ]]; then
          bdf_from_sysfs="${BASH_REMATCH[1]}"
        fi
      fi
      if [[ -n "${bdf_from_sysfs}" ]]; then
        CARD_BDFS+=("${bdf_from_sysfs}")
      else
        CARD_BDFS+=("idx:${idx}")
      fi
      idx=$((idx + 1))
    done
  fi

  for i in "${!CARD_BDFS[@]}"; do
    CARD_INDEX+=("${i}")
  done

  # Map discovered BDFs to GPU indices via xpu-smi --list-gpus
  # The UUID encodes the BDF: e.g. "0600" (4th segment) → bus=06, dev=00, func=0 → BDF 0000:06:00.0
  if [[ ${#CARD_BDFS[@]} -gt 0 ]] && command -v xpu-smi &>/dev/null; then
    local gpu_idx=0
    local uuid_field=""
    local bdf_hex=""
    while IFS= read -r uuid_line; do
      uuid_field="${uuid_line#*UUID: }"
      # Extract 5th segment from UUID (index 4): e.g. "0600" from "GPU-868023e2-0000-0000-0600-000000000000"
      bdf_hex=$(echo "${uuid_field}" | awk -F- '{print $5}' | head -c 4)
      # Parse UUID segment: first 2 hex = bus, last 2 hex = dev<<4 | func
      if [[ ${#bdf_hex} -eq 4 ]] && [[ "${bdf_hex}" =~ ^[0-9a-fA-F]{4}$ ]]; then
        local bus_hex="${bdf_hex:0:2}"
        local dev_func_hex="${bdf_hex:2:2}"
        local bus=$((16#${bus_hex}))
        local dev_func=$((16#${dev_func_hex}))
        local dev=$(( (dev_func >> 4) & 0xF ))
        local func=$(( dev_func & 0xF ))
        local uuid_bdf
        uuid_bdf=$(printf "0000:%02x:%02x.%s" "${bus}" "${dev}" "${func}")

        # Match against discovered BDFs
        local matched=false
        for i in "${!CARD_BDFS[@]}"; do
          if [[ "${CARD_BDFS[${i}]}" = "${uuid_bdf}" ]]; then
            CARD_GPU_INDICES+=("${gpu_idx}")
            matched=true
            break
          fi
        done
        if ! ${matched}; then
          # BDF from UUID not found — try GPU index fallback
          CARD_GPU_INDICES+=("${gpu_idx}")
        fi
      fi
      gpu_idx=$((gpu_idx + 1))
    done < <(xpu-smi --list-gpus 2>/dev/null | grep "^GPU " || true)
  fi

  # Fallback: if any GPU index is missing, use sequential indices
  for i in "${!CARD_BDFS[@]}"; do
    if [[ -z "${CARD_GPU_INDICES[${i}]:-}" ]]; then
      CARD_GPU_INDICES+=("${i}")
    fi
  done

  log INFO "Discovered ${#CARD_BDFS[@]} GPU card(s):"
  for i in "${!CARD_BDFS[@]}"; do
    log INFO "  Card ${i}: ${RENDER_NODES[${i}]} (${CARD_BDFS[${i}]})"
  done
}

# ------------------------------------------------------------------
# Probe VRAM for a single card (by BDF)
# Returns: total used free (in MB)
# ------------------------------------------------------------------
probe_card_vram() {
  local gpu_idx="$1"
  local prev_free="${2:-}"
  local out
  out=$(xpu-smi --query-gpu=memory.total,memory.used,memory.free --id="${gpu_idx}" \
        --format=csv,noheader,nounits 2>/dev/null) || true

  if [[ -n "${out}" ]]; then
    local total used free
    total=$(echo "${out}" | awk -F',' '{print $1}' | tr -d ' ')
    used=$(echo "${out}" | awk -F',' '{print $2}' | tr -d ' ')
    free=$(echo "${out}" | awk -F',' '{print $3}' | tr -d ' ')
    # Only log when values change from non-zero (avoid "was 0MB" noise on first probe)
    if [[ -n "${prev_free}" ]] && [[ "${prev_free}" -gt 0 ]] 2>/dev/null && [[ "${prev_free}" != "${free}" ]]; then
      log INFO "Card ${gpu_idx}: total=${total}MB used=${used}MB free=${free}MB (was ${prev_free}MB)"
    fi
    echo "${free}"
  else
    log WARN "xpu-smi failed for card ${gpu_idx} — assuming full VRAM"
    echo "32656"
  fi
}

# ------------------------------------------------------------------
# Probe all cards; return per-card free MB space
# Fills: CARD_FREE (array), updates probe failure tracking
# Tracks previous values for change detection across calls
declare -a PREV_CARD_FREE=()
probe_all_cards() {
  CARD_FREE=()
  CARD_USED=()
  local all_failed=true

  for i in "${!CARD_BDFS[@]}"; do
    local bdf="${CARD_BDFS[${i}]}"
    local prev_free="${PREV_CARD_FREE[${i}]:-}"
    PREV_CARD_FREE[i]="${CARD_FREE[${i}]:-0}"
    local free
    free=$(probe_card_vram "${CARD_GPU_INDICES[${i}]}" "${prev_free}")
    CARD_FREE+=("${free}")

    if [[ "${free}" = "32656" ]]; then
      all_failed=true
    else
      all_failed=false
    fi
    # Store 0 for CARD_USED (not currently tracked, keeping for future use)
    CARD_USED+=(0)
  done

  if ${all_failed}; then
    log WARN "xpu-smi failed on all cards (probe limit=${INGEST_VRAM_PROBE_FAIL_LIMIT})"
    PROBE_FAIL_COUNT=$((PROBE_FAIL_COUNT + 1))
    if [[ "${PROBE_FAIL_COUNT}" -ge "${INGEST_VRAM_PROBE_FAIL_LIMIT}" ]]; then
      log WARN "Probe failure limit reached — degrading to assume-full VRAM"
      for i in "${!CARD_BDFS[@]}"; do
        CARD_FREE[i]=32656
      done
  PROBE_FAIL_COUNT=0
  true > "${INGEST_RETRY_FILE}"
    fi
  else
    PROBE_FAIL_COUNT=0
  fi
}

# ------------------------------------------------------------------
# Get cost class from output height
# ------------------------------------------------------------------
get_cost_class() {
  local output_h="$1"
  if [[ "${output_h}" -le 1440 ]] 2>/dev/null; then
    echo "${COST_1440}"
  elif [[ "${output_h}" -le 2160 ]] 2>/dev/null; then
    echo "${COST_4K}"
  else
    echo "${COST_53K}"
  fi
}

# ------------------------------------------------------------------
# Get target height (min(probed, MAX_HEIGHT))
# ------------------------------------------------------------------
get_target_height() {
  local probed_height="$1"
  local override="$2"
  if [[ -n "${override}" ]] && [[ "${override}" -gt 0 ]] 2>/dev/null; then
    echo "${override}"
  elif [[ -n "${probed_height}" ]] && [[ "${probed_height}" -gt 0 ]] 2>/dev/null; then
    if [[ "${probed_height}" -gt "${MAX_HEIGHT}" ]]; then
      echo "${MAX_HEIGHT}"
    else
      echo "${probed_height}"
    fi
  else
    echo "${MAX_HEIGHT}"
  fi
}

# ------------------------------------------------------------------
# Detect GoPro filename prefix (GX*, GH*) — used to select the GoPro
# quality tier, which is independent of output height.
# ------------------------------------------------------------------
is_gopro_filename() {
  local filename="$1"
  case "${filename}" in
    GX*|GH*) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------
# Select ICQ quality tier by GoPro filename detection first, then by
# OUTPUT height (post MAX_HEIGHT downscale). Sources that downscale
# into the 4K tier (e.g. 5.3K GoPro -> 2160p) get the 4K quality
# target unless they match a GoPro filename prefix, in which case
# the GoPro tier takes precedence. Threshold 1600 sits between the
# 1440p and 2160p tiers.
# ------------------------------------------------------------------
get_icq_quality() {
  local output_h="$1"
  local filename="${2:-}"
  # Is GoPro filename — use the GoPro tier (not a height tier).
  # is_gopro_filename() is a boolean predicate; intentional direct use in
  # `if` (not an SC2310 oversight).
  # shellcheck disable=SC2310
  if [[ -n "${filename}" ]] && is_gopro_filename "${filename}"; then
    echo "${ICQ_QUALITY_GOPRO}"
  elif [[ -n "${output_h}" ]] && [[ "${output_h}" -gt 1600 ]] 2>/dev/null; then
    echo "${ICQ_QUALITY_2160}"
  else
    echo "${ICQ_QUALITY_1440}"
  fi
}

# ------------------------------------------------------------------
# Parse INGEST_SOURCES — format: name=remote:path[:h=NNN][:qp=NNN][,...]
# Outputs: name|remote|path|h_override|qp_override
# ------------------------------------------------------------------
parse_sources() {
  if [[ -z "${INGEST_SOURCES}" ]]; then
    log WARN "INGEST_SOURCES is not set — no sources configured"
    return
  fi

  IFS=',' read -ra SOURCES <<< "${INGEST_SOURCES}"
  for entry in "${SOURCES[@]}"; do
    local name remote path h_override qp_override
    name=$(echo "${entry}" | cut -d'=' -f1)
    remote=$(echo "${entry}" | sed 's/^[^=]*=//;s/:.*//')
    local remainder
    remainder="${entry#*=}"
    path="${remainder#*:}"
    path="${path#\*/}"
    h_override=""
    if [[ "${entry}" == *":h="* ]]; then
      h_override="${entry##*:h=}"
      h_override="${h_override%%:*}"
    fi
    qp_override=""
    if [[ "${entry}" == *":qp="* ]]; then
      qp_override="${entry##*:qp=}"
      qp_override="${qp_override%%:*}"
    fi

    echo "${name}|${remote}|${path}|${h_override}|${qp_override}"
  done
}

# ------------------------------------------------------------------
# Enumerate video files from rclone lsf (recursive, read-only)
# rclone --filter rules are evaluated in order, first match wins, so
# the _ingested/ exclusion must come before the extension includes,
# followed by a final catch-all exclude for everything else.
# ------------------------------------------------------------------
enumerate_files() {
  local remote="$1"
  local path="$2"
  local output stderr_file
  stderr_file=$(mktemp)
  output=$(rclone lsf --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
    "${remote}:${path}" \
    -R \
    --filter "- _ingested/**" \
    --filter "+ *.{mp4,MP4,mov,MOV,wmv,WMV,flv,FLV,avi,AVI}" \
    --filter "+ *[gG][oO][pP][rR][oO]*" \
    --filter "- *" \
    --files-only 2>"${stderr_file}" || true)
  if [[ "${output#EXIT_}" = "FAIL" ]]; then
    local err_head
    err_head=$(head -5 "${stderr_file}")
    log ERROR "rclone lsf failed for ${remote}:${path}: ${err_head}"
  fi
  rm -f "${stderr_file}"
  echo "${output}" | grep -v '^EXIT_' || true
}

# ------------------------------------------------------------------
# Install rclone configuration from secret mount
# ------------------------------------------------------------------
install_rclone_conf() {
  if [[ -f "${SECRET_MOUNT}/rclone.conf" ]]; then
    mkdir -p "${RCLONE_CONF_DIR}"
    cp "${SECRET_MOUNT}/rclone.conf" "${RCLONE_CONF}"
    log INFO "rclone.conf installed"
  fi
}

# ===========================================================================
# Cleanup / shutdown handling
# ===========================================================================
cleanup() {
  log INFO "Shutting down media-ingest..."
  # Kill contest watcher
  if [[ -n "${CONTEST_WATCHER_PID:-}" ]]; then
    kill "${CONTEST_WATCHER_PID}" 2>/dev/null || true
    wait "${CONTEST_WATCHER_PID}" 2>/dev/null || true
  fi
  # Kill any remaining ffmpeg processes
  if [[ -f "${RUNNING_FILE}" ]]; then
    while IFS='|' read -r pid _ _ _ _; do
      if kill -0 "${pid}" 2>/dev/null; then
        log WARN "Killing PID ${pid} (shutdown)"
        kill -TERM "${pid}" 2>/dev/null || true
      fi
    done < "${RUNNING_FILE}"
    rm -f "${RUNNING_FILE}"
  fi
  rm -f "${QUEUE_FILE}" "${RUNNING_FILE}"
  log INFO "Cleanup complete."
}

trap cleanup EXIT INT TERM

# ===========================================================================
# Queue helpers
# ===========================================================================

# Check if a filename already appears as the last field in the queue
  is_file_queued() {
  local fname="$1"
  [[ -f "${QUEUE_FILE}" ]] && [[ -s "${QUEUE_FILE}" ]] && grep -q "|${fname}|" "${QUEUE_FILE}"
}

# ------------------------------------------------------------------
# Retry-file helpers.
# Retry rows are stored as: filename|count|<queue_line> where
# <queue_line> itself is pipe-delimited (8 fields), so naive
# `awk -F'|' '{print $3}'` only grabs the queue_line's first subfield.
# These helpers join/split correctly and keep one row per filename.
# Sets globals RETRY_COUNT / RETRY_QUEUE_LINE on lookup.
# ------------------------------------------------------------------
retry_lookup() {
  local fname="$1"
  RETRY_COUNT=0
  RETRY_QUEUE_LINE=""
  if [[ -f "${INGEST_RETRY_FILE}" ]]; then
    local line
    # grep returns 1 (no match) for files with no retry history — that is
    # the common case, not an error. Under errexit+pipefail a bare non-zero
    # here would kill the whole script; `|| true` keeps it a no-op lookup.
    line=$(grep "^${fname}|" "${INGEST_RETRY_FILE}" 2>/dev/null | tail -1) || true
    if [[ -n "${line}" ]]; then
      RETRY_COUNT=$(echo "${line}" | awk -F'|' '{print $2}')
      RETRY_QUEUE_LINE=$(echo "${line}" | awk -F'|' '{for(i=3;i<=NF;i++){if(i>3)printf "|";printf "%s",$i}}')
    fi
  fi
  return 0
}

# Replace (dedup) the retry entry for a filename.
retry_write() {
  local fname="$1" count="$2" queue_line="$3"
  if [[ -f "${INGEST_RETRY_FILE}" ]]; then
    grep -v "^${fname}|" "${INGEST_RETRY_FILE}" > "${INGEST_RETRY_FILE}.tmp" 2>/dev/null || true
    mv "${INGEST_RETRY_FILE}.tmp" "${INGEST_RETRY_FILE}"
  fi
  echo "${fname}|${count}|${queue_line}" >> "${INGEST_RETRY_FILE}"
}

# Purge a filename's retry entry entirely (called on success).
retry_purge() {
  local fname="$1"
  [[ -f "${INGEST_RETRY_FILE}" ]] || return 0
  grep -v "^${fname}|" "${INGEST_RETRY_FILE}" > "${INGEST_RETRY_FILE}.tmp" 2>/dev/null || true
  mv "${INGEST_RETRY_FILE}.tmp" "${INGEST_RETRY_FILE}"
}

# ===========================================================================
# Dispatch: download + dispatch one file to an eligible card
# Arguments: source_name|remote|path|filename|h_override|qp_override|relpath
# Returns: 0 = dispatched, 1 = no card available (will retry)
# ===========================================================================
dispatch_one_file() {
  local line="$1"

  local source_name remote source_path filename h_override qp_override relpath attempts
  IFS='|' read -r source_name remote source_path filename h_override qp_override relpath attempts <<< "${line}"

  # Guard against corrupted queue/retry entries (empty remote/source_path
  # would otherwise reach `rclone copyto ":/"` and loop forever). Return 2
  # (distinct from 1 = no-card-available) so the caller drops it from the
  # queue instead of endlessly retrying.
  if [[ -z "${remote}" ]] || [[ -z "${source_path}" ]] || [[ -z "${filename}" ]]; then
    log ERROR "SKIP dispatch: corrupted queue entry (remote='${remote}' source_path='${source_path}' filename='${filename}')"
    return 2
  fi

  # Download file to work dir FIRST (needed for probing)
  mkdir -p "$(dirname "${WORK_DIR}")"
  local input_file="${WORK_DIR}/${filename}"
  mkdir -p "$(dirname "${input_file}")"
  log DEBUG "Downloading: ${remote}:${source_path}/${filename}"
   rclone copyto --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
     "${remote}:${source_path}/${filename}" "${input_file}" 2>&1 | tail -5 || {
    log ERROR "Failed to download ${filename}"
    return 1
  }
  if [[ -f "${input_file}" ]]; then
    local dl_size
    dl_size=$(wc -c < "${input_file}")
    log INFO "Download complete: ${filename} (${dl_size} bytes)"
  fi

  # Probe source height + framerate via ffprobe in one call (min(native, MAX_HEIGHT);
  # framerate feeds the GOP calculation below)
  local probed_height=0
  local probed_r_frame_rate=""
  if command -v ffprobe &>/dev/null; then
    local probe_out
    probe_out=$(ffprobe -v error -select_streams v:0 -show_entries stream=height,r_frame_rate -of default=noprint_wrappers=1:nokey=1 "${input_file}" 2>/dev/null || true)
    probed_height=$(printf '%s\n' "${probe_out}" | sed -n '1p')
    probed_r_frame_rate=$(printf '%s\n' "${probe_out}" | sed -n '2p')
    if [[ "${probed_height}" -le 0 ]] 2>/dev/null; then
      probed_height=0
    fi
  fi
  local output_h
  output_h=$(get_target_height "${probed_height}" "${h_override}")

  # Framerate-relative GOP (2 seconds of frames): keeps seek granularity
  # consistent across cameras with different native framerates (e.g. 120
  # frames @ 60fps vs 60 frames @ 30fps), instead of a single fixed value.
  # Falls back to omitting -g entirely if the framerate can't be parsed.
  local gop_size=""
  if [[ -n "${probed_r_frame_rate}" ]]; then
    local fr_num fr_den fps_int
    fr_num="${probed_r_frame_rate%%/*}"
    fr_den="${probed_r_frame_rate##*/}"
    if [[ "${fr_num}" -gt 0 ]] 2>/dev/null && [[ "${fr_den}" -gt 0 ]] 2>/dev/null; then
      fps_int=$(( fr_num / fr_den ))
      if [[ "${fps_int}" -gt 0 ]] 2>/dev/null; then
        gop_size=$(( fps_int * 2 ))
      fi
    fi
  fi

  # Cost class based on output height
  local pipeline_cost
  pipeline_cost=$(get_cost_class "${output_h}")

  # Check which card (if any) has enough free VRAM
  local best_card=-1
  local best_free=-1
  local best_active=999999
  local i
  for i in "${!CARD_BDFS[@]}"; do
    local bdf="${CARD_BDFS[${i}]}"
    if [[ "${CARD_USABLE[${i}]:-1}" = "0" ]]; then continue; fi
    local free="${CARD_FREE[${i}]:-0}"
    local active="${CARD_ACTIVE_COUNT[${i}]:-0}"
    local cooldown_until="${CARD_COOL_DOWN[${i}]:-0}"
    local now
    now=$(date +%s)

    # Skip if in cooldown
    if [[ "${cooldown_until}" -gt "${now}" ]] 2>/dev/null; then
      log DEBUG "Card ${i} (${bdf}) in cooldown (until ${cooldown_until}), skipping"
      continue
    fi

    # Skip if at capacity
    if [[ "${active}" -ge "${PIPELINES_PER_CARD}" ]] 2>/dev/null; then
      log DEBUG "Card ${i} (${bdf}) at capacity (${active} >= ${PIPELINES_PER_CARD}), skipping"
      continue
    fi

    # Check if free VRAM is sufficient for this file
    if awk "BEGIN {exit !(${free} >= ${pipeline_cost})}"; then
      # Pick card with fewest active jobs; tiebreak on highest free VRAM
      if [[ "${best_card}" -eq -1 ]]; then
        best_card=${i}
        best_free=${free}
        best_active=${active}
      else
        if [[ "${active}" -lt "${best_active}" ]] 2>/dev/null; then
          best_card=${i}
          best_free=${free}
          best_active=${active}
        elif [[ "${active}" -eq "${best_active}" ]] 2>/dev/null; then
          if awk "BEGIN {exit !(${free} > ${best_free})}"; then
            best_card=${i}
            best_free=${free}
          fi
        fi
      fi
    fi
  done

  if [[ "${best_card}" -eq -1 ]]; then
    log INFO "No card has enough VRAM for ${filename} (cost=${pipeline_cost}MB) — waiting (card0_free=${CARD_FREE[0]:-0}, card1_free=${CARD_FREE[1]:-0})"
    sleep "${INGEST_DISPATCH_INTERVAL}"
    return 1
  fi

  local bdf="${CARD_BDFS[${best_card}]}"
  local device="${RENDER_NODES[${best_card}]}"

   # Effective quality: per-source qp_override > GoPro filename match >
   # resolution tier (by OUTPUT height, so downscaled 5.3K sources get the
   # 4K tier unless they match a GoPro filename prefix)
   # (the per-source override keeps the ":qp=" key name for config compatibility;
   # it is an ICQ quality target, not a literal QP — see ICQ_QUALITY_1440/2160/GOPRO above)
   local effective_qp icq_tier
   if [[ -n "${qp_override}" ]] && [[ "${qp_override}" -gt 0 ]] 2>/dev/null; then
     effective_qp="${qp_override}"
     icq_tier="override"
   else
     effective_qp=$(get_icq_quality "${output_h}" "${filename}")
     # is_gopro_filename() is a boolean predicate; intentional direct use in
     # `if` (not an SC2310 oversight).
     # shellcheck disable=SC2310
     if is_gopro_filename "${filename}"; then
       icq_tier="gopro"
     elif [[ "${output_h}" -gt 1600 ]] 2>/dev/null; then
       icq_tier="2160"
     else
       icq_tier="1440"
     fi
   fi

  log INFO "Processing: ${source_name} / ${filename} → card ${best_card} (${bdf}, device=${device}) source=${probed_height}p output=${output_h}p icq=${effective_qp}(tier=${icq_tier}) gop=${gop_size:-default} cost=${pipeline_cost}MB free=${best_free}MB"

   # FFmpeg GPU encode — log to file (not pipe) so we track the real ffmpeg PID
   local output_file="${WORK_DIR}/${filename}.av1.mp4"
   local log_file="${LOG_DIR}/${filename}.log"
   # Ensure parent directories exist for subfolder support
   mkdir -p "$(dirname "${output_file}")" "$(dirname "${log_file}")"


  # Timeout guard: INGEST_FILE_TIMEOUT (default 6h) — prevents hung encodes
  local ENCODE_TIMEOUT="${FFMPEG_TIMEOUT:-${INGEST_FILE_TIMEOUT}}"

  # Build ffmpeg args: scale only when output differs from source (avoid pointless upscaling)
  # Arrays (not quoted strings) so multi-word flags expand as separate
  # argv entries — a quoted "-g ${gop_size}" string is passed to ffmpeg as
  # ONE argument ("Unrecognized option 'g 60'"), not two.
  local vf_args=()
  if [[ "${output_h}" != "${probed_height}" ]] && [[ "${probed_height}" -gt 0 ]] 2>/dev/null; then
    vf_args=(-vf "scale_vaapi=w=-2:h=${output_h}")
  fi

  # Framerate-relative GOP (see gop_size calc above). Omit -g entirely if
  # the source framerate couldn't be probed — falls back to encoder default.
  local gop_args=()
  if [[ -n "${gop_size}" ]]; then
    gop_args=(-g "${gop_size}")
  fi

  # ICQ uses -global_quality (not -qp). NOTE: -qp does NOT work as a fallback
  # for other modes — CQP on this driver ignores both -qp and -global_quality
  # entirely (see ICQ_QUALITY_1440/2160 comment above). RC_MODE=CQP/CBR/VBR
  # are exposed for experimentation but are not quality-calibrated; ICQ is
  # the only mode this script's quality targeting has been verified against.
  local quality_flag="-qp"
  local quality_val="${effective_qp}"
  if [[ "${RC_MODE}" = "ICQ" ]]; then
    quality_flag="-global_quality"
  fi

  timeout "${ENCODE_TIMEOUT}" ffmpeg -hide_banner \
    -vaapi_device "${device}" \
    -hwaccel vaapi -hwaccel_device "${device}" -hwaccel_output_format vaapi \
    -i "${input_file}" \
    "${vf_args[@]}" \
    -rc_mode "${RC_MODE}" \
    -c:v av1_vaapi \
    -b_depth "${B_DEPTH}" \
    "${gop_args[@]}" \
    "${quality_flag}" "${quality_val}" \
    -c:a copy \
    -y "${output_file}" 2>>"${log_file}" &

  local ffmpeg_pid=$!

  # Initialize attempts (default 0 from fresh entries), increment on dispatch
  attempts="${attempts:-0}"
  attempts=$((attempts + 1))

  # Record in RUNNING_FILE: pid|card_idx|source_name|filename|relpath|remote|source_path|pipeline_cost|output_file|attempts
  echo "${ffmpeg_pid}|${best_card}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}|${attempts}" >> "${RUNNING_FILE}"

  # Increment active count for this card
  CARD_ACTIVE_COUNT[${best_card}]=$(( ${CARD_ACTIVE_COUNT[${best_card}]:-0} + 1 ))

  log DEBUG "Launched PID ${ffmpeg_pid} on card ${best_card} (cost=${pipeline_cost}MB)"
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

  if [[ ! -f "${RUNNING_FILE}" ]] || [[ ! -s "${RUNNING_FILE}" ]]; then
    return 0
  fi

  true > "${tmp_running_file}"

  while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file attempts; do
    # Check if process is still alive
    if kill -0 "${pid}" 2>/dev/null; then
      # Process still running — keep it in RUNNING_FILE
      echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}|${attempts}" >> "${tmp_running_file}"
      continue
    fi

    # Process finished — check output file
    local success=false
    if [[ -s "${output_file}" ]]; then
      success=true
    fi

    # Decrement active count
    CARD_ACTIVE_COUNT[${card_idx}]=$(( ${CARD_ACTIVE_COUNT[${card_idx}]:-1} - 1 ))
    if [[ "${CARD_ACTIVE_COUNT[${card_idx}]}" -lt 0 ]] 2>/dev/null; then
      CARD_ACTIVE_COUNT[${card_idx}]=0
    fi

    if ${success}; then
      # --- Success path: log size ratio (informational only, no gating), upload + move ---
      if [[ -n "${RCLONE_CONFIG}" ]]; then
        local src_size out_size
        src_size=$(rclone lsl "${remote}:${source_path}/${filename}" 2>/dev/null | awk '{print $1}')
        out_size=$(stat -c '%s' "${output_file}" 2>/dev/null || echo 0)
        if [[ -n "${src_size}" ]] && [[ "${src_size}" -gt 0 ]] 2>/dev/null; then
          local size_ratio
          size_ratio=$(awk "BEGIN {printf \"%.2f\", (${out_size} / ${src_size}) * 100}")
          log INFO "Size ratio for ${filename}: output=${out_size}B source=${src_size}B (${size_ratio}% of source)"
        fi
      fi
      # filename is already relative to the source root (rclone lsf -R),
      # so it is used as-is for both the export path and the _ingested path.
      log INFO "Upload: ${output_file} → ${INGEST_DEST}/${filename}"
      rclone moveto --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
        "${output_file}" "${INGEST_DEST}/${filename}" 2>&1 | tail -5
      log INFO "Move to _ingested: ${remote}:${source_path}/${filename} → ${remote}:${source_path}/_ingested/${filename}"
      rclone moveto --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
        "${remote}:${source_path}/${filename}" "${remote}:${source_path}/_ingested/${filename}" 2>&1 | tail -5
      log INFO "Completed: ${filename} (card ${card_idx})"
      retry_purge "${filename}"
    else
      # --- Failure path: surface ffmpeg log, requeue (dedup), cooldown on device-init failure ---
      log ERROR "Encode failed or output empty for ${filename} (PID ${pid})"
      # Surface ffmpeg log to stdout before cleanup
      if [[ -f "${LOG_DIR}/${filename}.log" ]]; then
        log ERROR "ffmpeg log (${filename}):"
        tail -30 "${LOG_DIR}/${filename}.log" | while IFS= read -r line; do
          log ERROR "  ffmpeg: ${line}"
        done
        # Retain failed logs for post-mortem
        mkdir -p "${LOG_DIR}/failed"
        mv "${LOG_DIR}/${filename}.log" "${LOG_DIR}/failed/${filename}.log"
      fi
      # Requeue (dedup guard + retry counter)
      # is_file_queued() is a boolean predicate; intentional direct use in
      # `if !` (not an SC2310 oversight).
      # shellcheck disable=SC2310
      if ! is_file_queued "${filename}"; then
        retry_lookup "${filename}"
        local retry_count=$((RETRY_COUNT + 1))
        local queue_line="${RETRY_QUEUE_LINE}"
        if [[ "${retry_count}" -gt "${INGEST_MAX_ATTEMPTS}" ]]; then
          log WARN "Dropped ${filename} (attempts=${retry_count} > MAX_ATTEMPTS=${INGEST_MAX_ATTEMPTS}) — skipping requeue"
          retry_write "${filename}" "${retry_count}" "${queue_line}"
        elif [[ -n "${queue_line}" ]]; then
          queue_line=$(echo "${queue_line}" | awk -F'|' -v att="${retry_count}" '{OFS="|"; print $1,$2,$3,$4,$5,$6,$7,att}')
          grep -v "|${filename}|" "${QUEUE_FILE}" > "${QUEUE_FILE}.tmp" 2>/dev/null || true
          echo "${queue_line}" >> "${QUEUE_FILE}.tmp"
          mv "${QUEUE_FILE}.tmp" "${QUEUE_FILE}"
          retry_write "${filename}" "${retry_count}" "${queue_line}"
          log INFO "Re-queued: ${filename} (attempts=${retry_count})"
        else
          echo "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}" >> "${QUEUE_FILE}"
          retry_write "${filename}" "${retry_count}" "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}"
          log INFO "Re-queued: ${filename} (attempts=${retry_count})"
        fi
      else
        log WARN "Duplicate requeue skipped for: ${filename}"
      fi
      # Check for device-init failure → cooldown this card
      if [[ -f "${LOG_DIR}/failed/${filename}.log" ]]; then
        if grep -q "No VA display found\|Device creation failed" "${LOG_DIR}/failed/${filename}.log" 2>/dev/null; then
          local cooldown_until=$((now + INGEST_CARD_COOLDOWN))
          CARD_COOL_DOWN[${card_idx}]=${cooldown_until}
          log WARN "Device-init failure detected on card ${card_idx} — cooldown until ${cooldown_until}"
        fi
      fi
    fi

    rm -f "${output_file}"
    reaped=$((reaped + 1))
  done < "${RUNNING_FILE}"

  # Replace RUNNING_FILE with trimmed version
  mv "${tmp_running_file}" "${RUNNING_FILE}"
  return "${reaped}"
}

# ===========================================================================
# Contest watcher (background) — kills jobs on contended cards; streams
# throttled ffmpeg progress at DEBUG for observability of long encodes.
# ===========================================================================
contest_watcher() {
  log INFO "Contest watcher started (grace=${INGEST_CARD_CONTEST_GRACE}s, cooldown=${INGEST_CARD_COOLDOWN}s)"
  local cycle=0

  while true; do
    sleep "${INGEST_DISPATCH_INTERVAL}"
    cycle=$((cycle + 1))

    if [[ ! -f "${RUNNING_FILE}" ]] || [[ ! -s "${RUNNING_FILE}" ]]; then
      continue
    fi

    # Clear contest counters
    for i in "${!CARD_BDFS[@]}"; do
      CARD_CONTEST[${i}]=0
    done

    # Probe VRAM
    probe_all_cards

    # Device health check — kill jobs on cards that lost their devices
    for i in "${!RENDER_NODES[@]}"; do
      if [[ ! -e "${RENDER_NODES[${i}]}" ]]; then
        log ERROR "Render device ${RENDER_NODES[${i}]} (card ${i}) disappeared — killing active jobs"
        for i2 in "${!CARD_BDFS[@]}"; do
          CARD_ACTIVE_COUNT[${i2}]=0
        done
        continue 2
      fi
    done

    # Clear contest counters
    for i in "${!CARD_BDFS[@]}"; do
      CARD_CONTEST[${i}]=0
    done

    # Check each active job for contention
    local tmp_running="/tmp/ingest-running.tmp"
    true > "${tmp_running}"

    local reaped=0
    while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file attempts; do
      local bdf="${CARD_BDFS[${card_idx}]:-}"
      local free="${CARD_FREE[${card_idx}]:-0}"
      local now
      now=$(date +%s)

      if awk "BEGIN {exit !(${free} < ${pipeline_cost})}"; then
        # Card has insufficient VRAM for this job — it's contended
        local contested=${CARD_CONTEST[${card_idx}]:-0}
        contested=$((contested + 1))
        CARD_CONTEST[${card_idx}]=${contested}

        if [[ "${contested}" -ge $((INGEST_CARD_CONTEST_GRACE / INGEST_DISPATCH_INTERVAL)) ]]; then
          # Contest grace exceeded — kill the job
          log WARN "Contest kill: PID ${pid} (${source_name}/${filename}) on card ${card_idx} (free=${free}MB < cost=${pipeline_cost}MB)"
          # Surface ffmpeg log to stdout before cleanup (if log exists)
          if [[ -f "${LOG_DIR}/${filename}.log" ]]; then
            log ERROR "ffmpeg contest-kill log (${filename}):"
            tail -20 "${LOG_DIR}/${filename}.log" | while IFS= read -r line; do
              log ERROR "  ffmpeg: ${line}"
            done
          fi
          kill -TERM "${pid}" 2>/dev/null || true
          rm -f "${output_file}" "${LOG_DIR}/${filename}.log"

          # Decrement active count
          CARD_ACTIVE_COUNT[${card_idx}]=$(( ${CARD_ACTIVE_COUNT[${card_idx}]:-1} - 1 ))
          if [[ "${CARD_ACTIVE_COUNT[${card_idx}]}" -lt 0 ]] 2>/dev/null; then
            CARD_ACTIVE_COUNT[${card_idx}]=0
          fi

          # Requeue (dedup guard + retry counter)
          # is_file_queued() is a boolean predicate; intentional direct use in
          # `if !` (not an SC2310 oversight).
          # shellcheck disable=SC2310
          if ! is_file_queued "${filename}"; then
            retry_lookup "${filename}"
            local retry_count=$((RETRY_COUNT + 1))
            local queue_line="${RETRY_QUEUE_LINE}"
            if [[ "${retry_count}" -gt "${INGEST_MAX_ATTEMPTS}" ]]; then
              log WARN "Dropped ${filename} (attempts=${retry_count} > MAX_ATTEMPTS=${INGEST_MAX_ATTEMPTS}) — skipping requeue"
              retry_write "${filename}" "${retry_count}" "${queue_line}"
            elif [[ -n "${queue_line}" ]]; then
              queue_line=$(echo "${queue_line}" | awk -F'|' -v att="${retry_count}" '{OFS="|"; print $1,$2,$3,$4,$5,$6,$7,att}')
              grep -v "|${filename}|" "${QUEUE_FILE}" > "${QUEUE_FILE}.tmp" 2>/dev/null || true
              echo "${queue_line}" >> "${QUEUE_FILE}.tmp"
              mv "${QUEUE_FILE}.tmp" "${QUEUE_FILE}"
              retry_write "${filename}" "${retry_count}" "${queue_line}"
              log INFO "Re-queued: ${filename} (attempts=${retry_count}, card ${card_idx}, free=${free}MB)"
            else
              echo "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}" >> "${QUEUE_FILE}"
              retry_write "${filename}" "${retry_count}" "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}"
              log INFO "Re-queued: ${filename} (attempts=${retry_count}, card ${card_idx}, free=${free}MB)"
            fi
          else
            log WARN "Duplicate requeue skipped for: ${filename} (card ${card_idx} contended)"
          fi

          # Set cooldown on card
          CARD_COOL_DOWN[${card_idx}]=$((now + INGEST_CARD_COOLDOWN))
          CARD_CONTEST[${card_idx}]=0
          reaped=$((reaped + 1))
          continue
        fi
      else
        # Card has enough VRAM — reset contest counter
        CARD_CONTEST[${card_idx}]=0
      fi

      # Throttled progress logging: emit last ffmpeg progress line every ~2 cycles (~20s at default dispatch interval)
      if [[ "$((cycle % 2))" -eq 0 ]]; then
        if [[ -f "${LOG_DIR}/${filename}.log" ]] && [[ -s "${LOG_DIR}/${filename}.log" ]]; then
          local last_line
          last_line=$(tr '\r' '\n' < "${LOG_DIR}/${filename}.log" 2>/dev/null | tail -1 || true)
          if [[ -n "${last_line}" ]]; then
            log INFO "PID ${pid} (card ${card_idx}) ${last_line}"
          fi
        fi
      fi

      # Keep the job in RUNNING_FILE
      echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}" >> "${tmp_running}"
    done < "${RUNNING_FILE}"

    if [[ "${reaped}" -gt 0 ]]; then
      mv "${tmp_running}" "${RUNNING_FILE}"
    else
      mv "${tmp_running}" "${RUNNING_FILE}"
    fi
  done
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  # Discover GPU devices
  discover_devices
  if [[ ${#CARD_BDFS[@]} -eq 0 ]]; then
    log ERROR "No GPU devices found — cannot proceed"
    exit 1
  fi

  # Validate that render devices actually exist (not stale entries)
  local valid_count=0
  for i in "${!RENDER_NODES[@]}"; do
    if [[ -e "${RENDER_NODES[${i}]}" ]]; then
      valid_count=$((valid_count + 1))
    else
      log ERROR "Render device ${RENDER_NODES[${i}]} (card ${i}) does not exist — GPU passthrough missing?"
    fi
  done
  if [[ "${valid_count}" -eq 0 ]]; then
    log ERROR "No valid render devices found — cannot proceed (0/${#RENDER_NODES[@]} devices exist)"
    exit 1
  fi
  log INFO "Validated ${valid_count}/${#RENDER_NODES[@]} render device(s) available"

  # VA capability probe: per-node encode test (render node, fallback to card node)
  local usable_count=0
  local tmp_probe="/tmp/ffmpeg-probe.log"
  for i in "${!RENDER_NODES[@]}"; do
    local render_node="${RENDER_NODES[${i}]}"
    # Use CARD_INDEX to compute the card node path (bash param sub breaks: renderD128→cardD128)
    local card_node="/dev/dri/card${CARD_INDEX[${i}]:-0}"
    if [[ ! -e "${render_node}" ]] && [[ ! -e "${card_node}" ]]; then
      CARD_USABLE[i]=0
      log WARN "Card ${i} (${RENDER_NODES[${i}]} ${CARD_BDFS[${i}]}) — no device node exists, excluded"
      continue
    fi

    # Try render node first (preferred — lower contention)
    if [[ -e "${render_node}" ]]; then
      if timeout 10 ffmpeg -hide_banner -loglevel error \
        -vaapi_device "${render_node}" \
        -f lavfi -i testsrc=size=320x240:rate=1 -vf "format=nv12,hwupload" \
        -c:v av1_vaapi -rc_mode CQP -qp 28 -b_depth 1 -frames:v 1 -f null - \
        2>"${tmp_probe}" >/dev/null; then
        CARD_USABLE[i]=1
        log INFO "Card ${i} (${render_node}, bdf=${CARD_BDFS[${i}]}) VA-API OK (encode test passed)"
        usable_count=$((usable_count+1))
        continue
      else
        probe_err=$(grep -i "No VA display\|Device creation failed" "${tmp_probe}" 2>/dev/null | head -1 || true)
      fi
    fi

    # Fall back to card node
    if [[ -e "${card_node}" ]]; then
      if timeout 10 ffmpeg -hide_banner -loglevel error \
        -vaapi_device "${card_node}" \
        -f lavfi -i testsrc=size=320x240:rate=1 -vf "format=nv12,hwupload" \
        -c:v av1_vaapi -rc_mode CQP -qp 28 -b_depth 1 -frames:v 1 -f null - \
        2>"${tmp_probe}" >/dev/null; then
        CARD_USABLE[i]=2
        log INFO "Card ${i} (${card_node}, bdf=${CARD_BDFS[${i}]}) VA-API OK via card-node fallback"
        usable_count=$((usable_count+1))
        continue
      fi
    fi

    # Both nodes failed — exclude this card
    CARD_USABLE[i]=0
    local probe_err
    probe_err=$(grep -i "No VA display\|Device creation failed" "${tmp_probe}" 2>/dev/null | head -1 || true)
    if [[ -n "${probe_err}" ]]; then
      log WARN "Card ${i} (${RENDER_NODES[${i}]} ${CARD_BDFS[${i}]}) excluded — ${probe_err}"
    else
      log WARN "Card ${i} (${RENDER_NODES[${i}]} ${CARD_BDFS[${i}]}) excluded — VA-API probe failed (no device init)"
    fi
  done
  rm -f "${tmp_probe}"

  if [[ "${usable_count}" -eq 0 ]]; then
    log ERROR "No GPU node can initialize a VA-API display — cannot proceed"
    exit 1
  fi
  log INFO "VA-capable cards: ${usable_count}/${#RENDER_NODES[@]}"

  # Install rclone config
  install_rclone_conf
  export RCLONE_CONFIG="${RCLONE_CONF}"
  # Pin HOME/TMPDIR under /tmp so they don't collide with the read-only
  # root filesystem (OpenShift arbitrary UID defaults HOME=/)
  export HOME=/tmp
  export TMPDIR=/tmp

  # Initialize state files
  true > "${QUEUE_FILE}"
  true > "${RUNNING_FILE}"
  mkdir -p "${LOG_DIR}"

  log INFO "Starting media-ingest pipeline (GPU: ${#CARD_BDFS[@]} card(s))"
  log INFO "Sources: ${INGEST_SOURCES:-<not set>}, Dest: ${INGEST_DEST:-<not set>}"
  log INFO "RC_MODE=${RC_MODE}, ICQ_QUALITY_1440=${ICQ_QUALITY_1440}, ICQ_QUALITY_2160=${ICQ_QUALITY_2160} (tier selected by output height), B_DEPTH=${B_DEPTH} (inert on this driver), Pipelines per card: ${PIPELINES_PER_CARD}"
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
    true > "${QUEUE_FILE}"

    if [[ -n "${INGEST_SOURCES}" ]] && [[ -n "${INGEST_DEST}" ]]; then
      # parse_sources() always emits (possibly empty) output; its exit status
      # is not meant to gate the scan loop.
      # shellcheck disable=SC2310
      while IFS='|' read -r source_name remote source_path h_override qp_override; do
        [[ -z "${source_name}" ]] && continue
        [[ -z "${remote}" ]] && continue
        [[ -z "${source_path}" ]] && continue

        log INFO "Scanning: ${source_name} (${remote}:${source_path})"

        # enumerate_files() always emits (possibly empty) output; its exit
        # status is not meant to gate the scan loop.
        # shellcheck disable=SC2310
        while IFS= read -r filename; do
          [[ -z "${filename}" ]] && continue
          # Guard: skip directory entries (rclone lsf may include them)
          case "${filename}" in */ ) continue ;; * ) ;; esac
          local relpath="${source_path%/}/${filename}"

          # Skip if already queued in this scan cycle (dedup for requeued files)
          # is_file_queued() is a boolean predicate — invoking it directly in
          # `if` is intentional (not an SC2310 oversight); wrapping it would
          # require a temp variable for no functional benefit.
          # shellcheck disable=SC2310
          if is_file_queued "${filename}"; then
            log DEBUG "SKIP (already queued in scan): ${source_name} / ${filename}"
            continue
          fi

          # Check retry counter file
          retry_lookup "${filename}"
          if [[ "${RETRY_COUNT}" -gt 0 ]] 2>/dev/null; then
            local r_retry="${RETRY_COUNT}" r_queue_line="${RETRY_QUEUE_LINE}"
            # Skip malformed retry entries (empty path fields = corrupted data)
            local r_remote r_path
            r_remote=$(echo "${r_queue_line}" | awk -F'|' '{print $2}')
            r_path=$(echo "${r_queue_line}" | awk -F'|' '{print $3}')
            if [[ -z "${r_remote}" ]] || [[ -z "${r_path}" ]]; then
              log WARN "SKIP (corrupted retry entry for ${filename}) — removing from retry file"
              retry_purge "${filename}"
              continue
            fi
            if [[ "${r_retry}" -gt "${INGEST_MAX_ATTEMPTS}" ]] 2>/dev/null; then
              log INFO "SKIP (exceeded max attempts=${r_retry}): ${source_name} / ${filename}"
              continue
            fi
            # Re-add retried file with stored queue line (increment retry)
            r_retry=$((r_retry + 1))
            local new_queue_line
            new_queue_line=$(echo "${r_queue_line}" | awk -F'|' -v att="${r_retry}" '{OFS="|"; print $1,$2,$3,$4,$5,$6,$7,att}')
            grep -v "|${filename}|" "${QUEUE_FILE}" > "${QUEUE_FILE}.tmp" 2>/dev/null || true
            echo "${new_queue_line}" >> "${QUEUE_FILE}.tmp"
            mv "${QUEUE_FILE}.tmp" "${QUEUE_FILE}"
            retry_write "${filename}" "${r_retry}" "${new_queue_line}"
            log INFO "Re-adding retried: ${source_name} / ${filename} (attempts=${r_retry})"
          else
            # Queue line: name|remote|path|filename|h_override|qp_override|relpath|attempts
            echo "${source_name}|${remote}|${source_path}|${filename}|${h_override}|${qp_override}|${relpath}|0" >> "${QUEUE_FILE}"
          fi
        done < <(enumerate_files "${remote}" "${source_path}" || true)

      done < <(parse_sources || true)
    fi

    # --- Dispatch loop: concurrent dispatch + reaping ---
    while [[ -s "${QUEUE_FILE}" ]] 2>/dev/null || [[ -s "${RUNNING_FILE}" ]]; do
      # Reap completed jobs first (non-blocking: only processes that have exited)
      local reaped=0
      if [[ -s "${RUNNING_FILE}" ]]; then
        local tmp_running="/tmp/ingest-running.reap.tmp"
      true > "${tmp_running}"

    while IFS='|' read -r pid card_idx source_name filename relpath remote source_path pipeline_cost output_file attempts; do
          if kill -0 "${pid}" 2>/dev/null; then
            # Still running — keep in RUNNING_FILE
      echo "${pid}|${card_idx}|${source_name}|${filename}|${relpath}|${remote}|${source_path}|${pipeline_cost}|${output_file}|${attempts}" >> "${tmp_running}"
          else
            # Process finished — handle success/failure
            local success=false
            if [[ -s "${output_file}" ]]; then
              success=true
            fi

            # Decrement active count
            CARD_ACTIVE_COUNT[${card_idx}]=$(( ${CARD_ACTIVE_COUNT[${card_idx}]:-1} - 1 ))
            if [[ "${CARD_ACTIVE_COUNT[${card_idx}]}" -lt 0 ]] 2>/dev/null; then
              CARD_ACTIVE_COUNT[${card_idx}]=0
            fi

             if ${success}; then
               # --- Success path: log size ratio (informational only, no gating), upload + move ---
               if [[ -n "${RCLONE_CONFIG}" ]]; then
                 local src_size out_size
                 src_size=$(rclone lsl "${remote}:${source_path}/${filename}" 2>/dev/null | awk '{print $1}')
                 out_size=$(stat -c '%s' "${output_file}" 2>/dev/null || echo 0)
                 if [[ -n "${src_size}" ]] && [[ "${src_size}" -gt 0 ]] 2>/dev/null; then
                   local size_ratio
                   size_ratio=$(awk "BEGIN {printf \"%.2f\", (${out_size} / ${src_size}) * 100}")
                   log INFO "Size ratio for ${filename}: output=${out_size}B source=${src_size}B (${size_ratio}% of source)"
                 fi
               fi
               # filename is already relative to the source root (rclone lsf -R),
               # so it is used as-is for both the export path and the _ingested path.
               log INFO "Upload: ${output_file} → ${INGEST_DEST}/${filename}"
                rclone moveto --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
                  "${output_file}" "${INGEST_DEST}/${filename}" 2>&1 | tail -5
                log INFO "Move to _ingested: ${remote}:${source_path}/${filename} → ${remote}:${source_path}/_ingested/${filename}"
                rclone moveto --cache-dir /tmp/.cache/rclone --temp-dir /tmp \
                  "${remote}:${source_path}/${filename}" "${remote}:${source_path}/_ingested/${filename}" 2>&1 | tail -5
               log INFO "Completed: ${filename} (card ${card_idx})"
               retry_purge "${filename}"
             else
               # Surface ffmpeg log to stdout before cleanup
               log ERROR "Encode failed or output empty for ${filename} (PID ${pid})"
               if [[ -f "${LOG_DIR}/${filename}.log" ]]; then
                 log ERROR "ffmpeg log (${filename}):"
                 tail -30 "${LOG_DIR}/${filename}.log" | while IFS= read -r line; do
                   log ERROR "  ffmpeg: ${line}"
                 done
                 # Retain failed logs for post-mortem
                 mkdir -p "${LOG_DIR}/failed"
                 mv "${LOG_DIR}/${filename}.log" "${LOG_DIR}/failed/${filename}.log"
               fi
                # Requeue (dedup guard + retry counter)
                # is_file_queued() is a boolean predicate; intentional direct
                # use in `if !` (not an SC2310 oversight).
                # shellcheck disable=SC2310
                if ! is_file_queued "${filename}"; then
                  retry_lookup "${filename}"
                 local retry_count=$((RETRY_COUNT + 1))
                 local queue_line="${RETRY_QUEUE_LINE}"
                 if [[ "${retry_count}" -gt "${INGEST_MAX_ATTEMPTS}" ]]; then
                   log WARN "Dropped ${filename} (attempts=${retry_count} > MAX_ATTEMPTS=${INGEST_MAX_ATTEMPTS}) — skipping requeue"
                   retry_write "${filename}" "${retry_count}" "${queue_line}"
                 elif [[ -n "${queue_line}" ]]; then
                   queue_line=$(echo "${queue_line}" | awk -F'|' -v att="${retry_count}" '{OFS="|"; print $1,$2,$3,$4,$5,$6,$7,att}')
                   grep -v "|${filename}|" "${QUEUE_FILE}" > "${QUEUE_FILE}.tmp" 2>/dev/null || true
                   echo "${queue_line}" >> "${QUEUE_FILE}.tmp"
                   mv "${QUEUE_FILE}.tmp" "${QUEUE_FILE}"
                   retry_write "${filename}" "${retry_count}" "${queue_line}"
                   log INFO "Re-queued: ${filename} (attempts=${retry_count})"
                 else
                   echo "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}" >> "${QUEUE_FILE}"
                   retry_write "${filename}" "${retry_count}" "${source_name}|${remote}|${source_path}|${filename}|||${relpath}|${retry_count}"
                   log INFO "Re-queued: ${filename} (attempts=${retry_count})"
                 fi
               else
                 log WARN "Duplicate requeue skipped for: ${filename}"
               fi
               # Check for device-init failure → cooldown this card
               local cooldown_until
               cooldown_until=$(date +%s)
               if [[ -f "${LOG_DIR}/failed/${filename}.log" ]]; then
                 if grep -q "No VA display found\|Device creation failed" "${LOG_DIR}/failed/${filename}.log" 2>/dev/null; then
                   CARD_COOL_DOWN[${card_idx}]=$((cooldown_until + INGEST_CARD_COOLDOWN))
                   log WARN "Device-init failure on card ${card_idx} — cooldown until ${CARD_COOL_DOWN[${card_idx}]}"
                 fi
               fi
             fi

            rm -f "${output_file}"
            reaped=$((reaped + 1))
          fi
        done < "${RUNNING_FILE}"

        if [[ "${reaped}" -gt 0 ]]; then
          mv "${tmp_running}" "${RUNNING_FILE}"
        else
          rm -f "${tmp_running}"
        fi
      fi

      # Try to dispatch all available files (fill all slots up to card limits)
      if [[ -s "${QUEUE_FILE}" ]]; then
        probe_all_cards
        while [[ -s "${QUEUE_FILE}" ]]; do
          local d_line d_rc=0
          d_line=$(head -n 1 "${QUEUE_FILE}")
          if [[ -n "${d_line}" ]]; then
            # || d_rc=$? suspends errexit for the dispatch call while
            # preserving rc=0 (ok), rc=1 (no card), rc=2 (corrupted)
            # branches. A bare call under errexit would kill the script
            # on any non-zero return (fatal bug introduced in prior edit).
            # shellcheck disable=SC2310
            dispatch_one_file "${d_line}" || d_rc=$?
            if [[ "${d_rc}" -eq 0 ]] || [[ "${d_rc}" -eq 2 ]]; then
              # Dispatched, or dropped as corrupted — remove from queue either way
              sed -i "1d" "${QUEUE_FILE}"
            else
              # No card available — break out of dispatch loop
              log DEBUG "dispatch returned rc=${d_rc} (no card), breaking"
              break
            fi
          else
            break
          fi
        done
      fi

      # If no jobs running and queue is empty, break
      if [[ ! -s "${RUNNING_FILE}" ]] && [[ ! -s "${QUEUE_FILE}" ]]; then
        break
      fi

      sleep "${INGEST_DISPATCH_INTERVAL}"
    done

    # Brief sleep between scan cycles
    sleep "${INGEST_INTERVAL}"
  done
}

main "$@"
