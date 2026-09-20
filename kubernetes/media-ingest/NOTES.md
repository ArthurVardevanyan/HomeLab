# media-ingest: Calibration & Decision Log

## Encoder Facts (Measured, Verified)

### `-crf` Does Not Exist

- **Claim in spec:** `-crf 28` for quality-defined encoding
- **Reality:** `-crf` is not a valid option for `av1_vaapi`
- **Verified:** `ffmpeg -h encoder=av1_vaapi` shows no `-crf` option
- **Fix:** Use `-rc_mode QVBR` with `-qpp_qvbr 24` (QVBR quality scale similar to CRF)
- **Impact:** All references to `-crf` in code/README replaced with `-rc_mode` / `-qpp_qvbr`

### No `preset` or `lookahead` on VA-API

- **Claim in spec:** `-preset veryslow -lookahead 32`
- **Reality:** Neither `-preset` nor `-lookahead` exist on `av1_vaapi`
- **Verified:** `ffmpeg -h encoder=av1_vaapi` — neither option listed
- **Impact:** Removed from all code/README

### 10-bit AV1 Encode Not Available on VA-API

- **Claim in spec:** 10-bit output via VA-API
- **Reality:** vainfo shows only `VAProfileAV1Profile0` for encoding (8-bit only)
- **Verified:** `vainfo` output confirms 8-bit only
- **Impact:** Strategy updated to 8-bit; 10-bit moved to Phase 2 (CPU SVT-AV1, already in image)

### ICQ Quality Value: Settable (Pending Calibration)

- **Status:** `-qp` option exists for ICQ mode, but target value needs calibration
- **Calibration:** Five 30-frame null-sink encodes with target values 20/22/24/26/28
- **Result:** TBD — pending calibration with real footage
- **Fallback:** QVBR with `-qpp_qvbr` is safe and well-defined (no calibration needed)

### B-Frame Depth

- **Option:** `-b_depth` is available (default 1)
- **Impact:** Higher = better compression. Set after calibration (recommend 3-4)
- **Calibration:** Will be tested alongside ICQ/QVBR quality targets

## Concurrency Constraint (Verified)

### VA-API Context Creation Hangs with Active LLMs

- **Verified:** Encode context creation hangs indefinitely when an LLM model is actively inferring
- **Test method:** Concurrent encode while llama-swap model loaded
- **Result:** Card locks up on context creation ioctl
- **Impact:** "LLM resident + concurrent ingest" operating mode is dead
- **Workaround:** Scale LLMs down (`kubectl scale deploy/llama-swap -n llm --replicas=0`), run batches, scale back up

## Hardware

- **GPUs:** Two Intel Arc Pro B70 (Battlemage), iHD 26.2.2, libva 1.23.0
- **Driver channel:** kobuk-team/intel-graphics PPA (Intel's official compute runtime channel)
- **Device nodes:** `/dev/dri/renderD128` (card 0), `/dev/dri/renderD129` (card 1)
- **`libsvtav1`:** Present in `gpu-toolbox` image (via jellyfin-ffmpeg7). No rebuild needed for Phase 2.

## Architecture Decisions

1. **Single-device pipeline** (decode + encode on same card)
   - Avoids cross-card memory copy overhead
   - Simpler scheduling logic
   - Both cards are identical hardware (no preference)

2. **QVBR as default RC mode** (ICQ pending calibration)
   - QVBR has a well-defined quality target (similar to CRF)
   - ICQ may use a different scale; calibration will determine
   - If ICQ is un-settable, QVBR fallback is seamless

3. **Watchdog for safety**
   - Per-file kill timeout prevents hung encodes from clogging slots forever
   - 6-hour default (longer than expected encode time)
   - Files only moved to `_ingested/` after verified upload — **never loses footage**

4. **No auto-detect LLM state**
   - User manages LLM scaling manually
   - Keeps the script simple and predictable
   - Watchdog handles the pathological case (LLM left active)

## Calibration Checklist

- [ ] ICQ value mapping (five 30-frame null-sink encodes)
- [ ] QVBR quality target verification (same targets for comparison)
- [ ] B-depth sensitivity test (1, 3, 5 — measure compression gain)
- [ ] Real sample encode (one file per camera)
- [ ] Measure actual bitrates for each source
- [ ] Lock in `RC_MODE`, quality target, `B_DEPTH`
- [ ] Set `PIPELINES_PER_CARD` based on measured throughput
- [ ] Confirm `xpu-smi` shows activity on both cards during batch

## File Changes Made

### `configmap.yaml`

- Replaced `-crf $AV1_CRF` → `-rc_mode "$RC_MODE" -qpp_qvbr "$QVBR_QUALITY"`
- Added `-b_depth $B_DEPTH` (default 3)
- Added per-file watchdog (`INGEST_FILE_TIMEOUT`, default 21600s)
- Updated strategy comment block
- Added QVBR/ICQ quality section
- Added `INGEST_FILE_TIMEOUT` env var
- Updated pipe parsing to use `qp` instead of `crf`

### `README.md`

- Added "Encoder Facts (Measured)" section
- Replaced CRF ladder with ICQ/QVBR quality table
- Updated operational mode section
- Updated configuration table
- Added Phase 2: 10-bit CPU note

### `external-secret.yaml`

- Fixed vault path: `homelab/media-ingest` → `homelab/media-ingest` (typo fix)

### `containerfile` (already correct)

- `rclone` is already installed (no rebuild needed)

## Vault Path

- **Path:** `homelab/media-ingest` (note the typo in `ingest` — matches the SMB share name)
- **Key:** `unas` (SMB rclone property)

## NAS Share

- **Share:** `ingest` (SMB)
- **Import folder:** `import` (source footage)
- **Output folder:** `export` (encoded output)
- **Mount:** via rclone (SMB → remote)
