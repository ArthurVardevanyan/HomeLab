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

### ICQ Quality Value: Settable via `-global_quality` (CALIBRATED 2026-09, RETIERED 2026-09)

- **Correction:** An earlier revision of this file claimed "`-qp` option exists
  for ICQ mode." That is wrong. `av1_vaapi` exposes **no** `-qp` and **no**
  `-global_quality` in its private option list — both are generic
  `AVCodecContext` options. `-qp` is a no-op under ICQ; `-global_quality` is
  the one that binds.
- **Verified binding** with `-v verbose`, which prints:
  `RC mode: ICQ.` / `RC quality: 26.`
- **`q=-0.0` is a red herring.** VAAPI never reports a per-frame quantizer to
  ffmpeg's stats line. It does not indicate unset quality.
- **Superseded: single flat value replaced with resolution tiers.** The ICQ
  scale does not behave consistently across resolutions — break-even is
  ~6-7 points apart between 1440p and 4K (see below). A flat `QP_TARGET`/
  `ICQ_QUALITY` could not serve both cameras well, so the script now exposes
  `ICQ_QUALITY_1440` and `ICQ_QUALITY_2160`, selected by **output** height
  (post `MAX_HEIGHT` downscale) so a downscaled 5.3K source correctly lands
  in the 2160 tier.
- **1440p calibration** (300 frames, rear cam, 27.0 Mbps h264 source):

  | `-global_quality` | Bitrate   | % of source | SSIM   |
  | ----------------- | --------- | ----------- | ------ |
  | 26                | 26.5 Mbps | 98%         | 0.9872 |
  | **29**            | 19.3 Mbps | **71%**     | 0.9850 |
  | 30                | 16.8 Mbps | 62%         | 0.9839 |
  | 33                | 9.7 Mbps  | 36%         | 0.9786 |
  | 36                | 4.7 Mbps  | 18%         | 0.9709 |

- **4K60 calibration** (300 frames, front cam GoPro, 65.8 Mbps h264 source):

  | `-global_quality` | Bitrate                      | % of source | SSIM   |
  | ----------------- | ---------------------------- | ----------- | ------ |
  | 26                | 141 Mbps                     | 214%        | —      |
  | **27**            | ~125-130 Mbps (interpolated) | **~190%**   | —      |
  | 30                | 94 Mbps                      | 143%        | 0.9881 |
  | 32                | 77 Mbps                      | 117%        | 0.9871 |
  | 34                | 62 Mbps                      | 94%         | 0.9855 |
  | 36                | 44 Mbps                      | 67%         | 0.9830 |
  | 38                | 29 Mbps                      | 44%         | 0.9794 |
  | 40                | 20 Mbps                      | 30%         | 0.9746 |

- **Break-even vs. source is ~GQ 26 at 1440p but ~GQ 33 at 4K.** The
  previous flat defaults (24, then 26, then 38) either inflated 4K files
  (214-233% of source) or over-compressed 1440p relative to 4K quality.
- **Locked in (2026-09):** `ICQ_QUALITY_1440=29` (~71% of source, SSIM
  0.985), `ICQ_QUALITY_2160=27` (~190% of source — deliberately below
  break-even, chosen by the operator; expect roughly double the h264
  source size on 4K front-cam files).
- QVBR/AVBR are **not supported** by this driver — the old "QVBR fallback"
  plan below is void.
- _*GoPro files (GX* / GH_ prefix)** are now assigned `ICQ_QUALITY_GOPRO`
  by filename prefix, not by output height — this ensures GoPro's HEVC
  codec, dynamic-range profile, and codec behavior get a quality target
  calibrated for GoPro content, not generic 4K h264 content.
- GoPro 5.3K source: **ICQ_QUALITY_GOPRO=25 — user-selected, not
  SS/bitrate-calibrated.** Re-run a calibration sweep against actual
  GoPro footage (both 5.3K and 4K recording modes) before adopting this
  as a production default.

### B-Frame Depth

- **Option:** `-b_depth` is available (default 1)
- **RETRACTED — measured INERT (2026-09).** Verbose logging reports
  `Using intra, P- and B-frames (supported references: 3 / 1)` regardless
  of the value passed; 300-frame test encodes at `-b_depth` 1, 3, and 5
  produced byte-identical output (29237 kbps, SSIM 0.979390 in all three
  cases). This driver does not honor the option. Kept in the script as a
  passthrough (`B_DEPTH=3`) in case a future driver version honors it —
  do not rely on it for compression tuning.

### Speed/Quality Knob: `-compression_level` (MEASURED 2026-09)

- `-preset` and `-lookahead` do not exist for `av1_vaapi`. `-low_power 1`
  fails outright: `No usable encoding entrypoint found for profile
VAProfileAV1Profile0`. `-compression_level` (1=slowest/best to
  7=fastest/worst) is the only functional speed/quality knob.
- **Measured at ICQ 36, 4K, 300 frames:**

  | `compression_level`  | Speed | Bitrate   | SSIM     |
  | -------------------- | ----- | --------- | -------- |
  | 1 (slowest)          | 0.93x | 44.5 Mbps | 0.983273 |
  | 4 (default, no flag) | 2.01x | 43.9 Mbps | 0.982974 |
  | 7 (fastest)          | 2.39x | 47.0 Mbps | 0.982635 |

- **Conclusion: not worth changing.** `cl=1` costs 2.2x the encode time
  for a +0.0003 SSIM gain (noise). `cl=7` is both faster **and** produces
  a larger file — strictly worse. The script does not set this flag.

### GOP Size (MEASURED 2026-09)

- `ffmpeg -h full` reports the generic `AVCodecContext` default GOP as 12,
  but this is **not what the driver actually applies**. A no-flag encode
  and an explicit `-g 120` produced byte-identical output (43.850 Mbps,
  SSIM 0.982974) — the real effective default is ~120 (2s @ 60fps).
- `-g 300` (5s @ 60fps) measured only ~1.6% smaller (43.2 Mbps) at
  equivalent SSIM (0.983051) — not a meaningful size optimization.
- **Decision:** set `-g` to `fps x 2` per source (probed via ffprobe) for
  **consistent ~2s seek granularity** across cameras with different native
  framerates (60fps front/GoPro vs. 30fps rear), not for size. Falls back
  to omitting `-g` (driver default) if the framerate can't be parsed.

## Concurrency Constraint (Verified)

### VA-API Context Creation Hangs with Active LLMs — RETRACTED 2026-09

- **Previous claim:** "Encode context creation hangs indefinitely when an LLM
  model is actively inferring. Card locks up on context creation ioctl."
- **Retest result: NOT REPRODUCIBLE.** A 4K60 `av1_vaapi` encode on
  `/dev/dri/renderD128` completed normally at ~110 fps with `llama-swap`
  running and **28.4 GB resident on card 0** (confirmed via `xpu-smi stats`).
  Context creation succeeded immediately; no hang, no lockup.
- **Conclusion:** The original diagnosis was likely a different fault
  (possibly the device in `survivability mode`, see Hardware). Do not scale
  LLMs down on this basis.
- **Impact:** "LLM resident + concurrent ingest" is a **valid** operating
  mode. The per-file watchdog remains as a general safety net.

## Hardware

- **GPUs:** Two Intel Arc Pro B70 (Battlemage), iHD 25.4.6, libva 1.23.0
- **Driver channel:** kobuk-team/intel-graphics PPA (Intel's official compute runtime channel)
- **Device nodes:** `/dev/dri/renderD128` (card 0), `/dev/dri/renderD129` (card 1)
- **`libsvtav1`:** Present in `gpu-toolbox` image (via jellyfin-ffmpeg7). CPU throughput poor at 4K (~0.1x realtime); 4K encodes OOM'd at the pod's memory limit — not currently practical.
- **iHD version:** 25.4.6, confirmed via `-v verbose` (`Intel iHD driver for Intel(R) Gen Graphics - 25.4.6 (d892c52)`). This file and the README previously said 26.2.2, then 26.3.2 — both were wrong; 25.4.6 is the verified value.
- **⚠ Device 2 in survivability mode (observed 2026-09):** `xpu-smi discovery`
  reports a third device with `Device State: survivability mode` and
  `Recovery Action: Firmware update and GPU reset`. Encoding works on
  renderD128/129, so this is not currently blocking ingest, but it is an
  unresolved hardware fault worth chasing separately — and it is a plausible
  explanation for the retracted "LLM causes VA-API hang" report above.

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

- [x] ICQ value mapping — done 2026-09, 300-frame real-footage sweeps at
      both 1440p and 4K resolutions with SSIM. See "ICQ Quality Value" above.
- [x] ~~QVBR quality target verification~~ — void, QVBR unsupported by driver
- [x] Real sample encodes — rear 1440p (`..._000528R.MP4`) and 4K60 front
      cam (`..._000003F.MP4`)
- [x] Measure actual bitrates — see calibration tables above
- [x] Lock in `RC_MODE=ICQ`, `ICQ_QUALITY_1440=29`, `ICQ_QUALITY_2160=27`,
      `ICQ_QUALITY_GOPRO=25` (user-selected, not calibrated), `B_DEPTH=3`
      (inert, kept as passthrough)
- [x] B-depth sensitivity test (1, 3, 5) — measured **inert**, byte-identical
      output at all three values. See "B-Frame Depth" above.
- [x] `-compression_level` speed/quality sweep (1/4/7) — measured; default
      (4) is optimal, not worth changing. See "Speed/Quality Knob" above.
- [x] GOP size investigation — measured; framerate-relative `-g` (fps x 2)
      adopted for seek consistency, not size. See "GOP Size" above.
- [ ] Calibration sweep for the **GoPro** source (5.3K, 4K, and any other
      recording modes) — GoPro files now get `ICQ_QUALITY_GOPRO` by filename
      prefix (`GX*`/`GH*`), not the 2160 height tier; the current value of
      25 is user-selected, not SSIM/bitrate-calibrated.
- [ ] Set `PIPELINES_PER_CARD` based on measured throughput
- [ ] Confirm `xpu-smi` shows activity on both cards during batch
- [ ] Investigate device 2 `survivability mode` fault (see Hardware)

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
