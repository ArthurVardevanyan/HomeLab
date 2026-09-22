# media-ingest: GPU-accelerated video ingestion server

Per-source video ingest from NAS SMB to a new folder with GPU-accelerated AV1 encoding.

## Table of Contents

- [media-ingest: GPU-accelerated video ingestion server](#media-ingest-gpu-accelerated-video-ingestion-server)
  - [Table of Contents](#table-of-contents)
  - [Strategy](#strategy)
  - [Encoder Facts (Measured)](#encoder-facts-measured)
  - [Configuration](#configuration)
  - [Quality \& Bitrate](#quality--bitrate)
  - [Visual Quality QA](#visual-quality-qa)
    - [Original QA (ICQ 32 / 35 / 24)](#original-qa-icq-32--35--24)
    - [ICQ 34 Verification (New 1440p sample)](#icq-34-verification-new-1440p-sample)
    - [ICQ Headroom Verdict](#icq-headroom-verdict)
  - [GPU Usage](#gpu-usage)
    - [Concurrency Constraint (Measured)](#concurrency-constraint-measured)
    - [Safety Net: Per-File Watchdog](#safety-net-per-file-watchdog)
  - [Scheduler](#scheduler)
  - [Operational Mode](#operational-mode)
  - [Troubleshooting](#troubleshooting)
  - [Phase 2: 10-bit CPU](#phase-2-10-bit-cpu)

## Strategy

Per-source output = **min(native, 4K)**:

| Source                  | Output                     | ICQ tier | Observed Bitrate                                               |
| ----------------------- | -------------------------- | -------- | -------------------------------------------------------------- |
| Rear 2560×1440 30fps    | 1440p (native, no upscale) | 1440     | ~8 Mbps (~31% of source, ICQ 34 projected)                     |
| Front 3840×2160 60fps   | 4K (native)                | 2160     | ~53 Mbps (~80% of source, ICQ 35 projected)                    |
| GoPro GX*/GH* (any res) | min(native, 4K)            | gopro    | 50.1% of source (measured at ICQ 24 — calibrated, no headroom) |

ICQ quality is **resolution-tiered** (`ICQ_QUALITY_1440`,
`ICQ_QUALITY_2160`) plus **GoPro-specific** (`ICQ_QUALITY_GOPRO`) — the
ICQ scale does not behave the same across source resolutions or codecs
(see [Quality & Bitrate](#quality--bitrate)).

Tier selection order:

1. **GoPro filename** — files matching `GX*` or `GH*` prefix (GoPro's
   own naming convention for 5.3K/4K linear and chaptered modes) get the
   `gopro` tier regardless of output height.
2. **Resolution tier** — sources that don't match GoPro filenames are
   assigned by output height (post `MAX_HEIGHT` downscale): 2160p+ → 2160
   tier, 1440p and below → 1440 tier.

Output size is not gated or capped: the ingest script logs an output/source
size ratio per file for visibility, but always uploads the result regardless
of size. Use the per-source `:qp=` override in `INGEST_SOURCES` only if a
specific camera needs a value outside its tier (the key is named `:qp=` for
config compatibility, but the value is an ICQ quality target, not a literal
QP — see [Encoder Facts](#encoder-facts-measured)).

**The ICQ quality scale is not intuitive, and it does not behave the same
across resolutions — calibrate per resolution before changing it.** On
this encoder, break-even against the h264 source is around quality 26 at
1440p but around quality 33 at 4K — a ~7-point offset. The current 4K
tier value (27) is **below** the 4K break-even point and is expected to
produce roughly 2x the h264 source size; this is a deliberate choice, not
a bug — see [Quality & Bitrate](#quality--bitrate) for the measured
curves.

## Encoder Facts (Measured)

| Claim                                                         | Reality                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Source                                             |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `-crf` is a valid ffmpeg option for `av1_vaapi`               | **`-crf` does not exist.** `-crf`/CRF is a software-encoder concept (`libx264`/`libsvtav1`). VAAPI's closest analogue is ICQ (adaptive quality), not a literal QP. Driver supports `-rc_mode {ICQ, CQP, CBR, VBR}` only.                                                                                                                                                                                                                                                                                                | `ffmpeg -h encoder=av1_vaapi`                      |
| `QVBR`/`AVBR` are usable rate-control modes                   | **Rejected at encoder-open time.** `Driver does not support QVBR RC mode (supported modes: CQP, CBR, VBR, ICQ)` — same rejection for AVBR. Not a config error; the driver hard-fails.                                                                                                                                                                                                                                                                                                                                   | Live test (`-rc_mode QVBR`/`AVBR`), 2026-09        |
| `CQP` gives predictable constant-QP output                    | **Broken on this driver.** CQP ignores both `-qp` and `-global_quality`, logging `No quality level set; using default (25)`, and emits 319–403 Mbps regardless of the value passed (measured on a 65.8 Mbps source). Do not use CQP for quality targeting.                                                                                                                                                                                                                                                              | Live test, 2026-09                                 |
| `preset` and `lookahead` are valid encoder options            | **Neither `-preset` nor `-lookahead` exists.** These are libx264/libsvtav1 concepts.                                                                                                                                                                                                                                                                                                                                                                                                                                    | `ffmpeg -h encoder=av1_vaapi`                      |
| 10-bit AV1 encoding is supported on this hardware             | **Not on VA-API.** vainfo shows only `VAProfileAV1Profile0` for encoding (8-bit only).                                                                                                                                                                                                                                                                                                                                                                                                                                  | `vainfo`                                           |
| `libsvtav1` is available for 10-bit CPU encoding              | **Present.** The `gpu-toolbox` image includes `libsvtav1` via the jellyfin-ffmpeg7 bundle. No rebuild needed. CPU throughput is poor at 4K (~0.1× realtime measured, and 4K encodes OOM'd at the pod's 4Gi limit) — not currently a practical alternative without raising limits.                                                                                                                                                                                                                                       | Container filesystem, live test 2026-09            |
| ICQ quality value is settable via `-global_quality`           | **Confirmed.** ICQ uses `-global_quality` (not `-qp`; `-qp` is a no-op in ICQ mode). Quality range ~15 (high quality) to 45 (low quality); three tiers: resolution-tiered (`ICQ_QUALITY_1440`=34, `ICQ_QUALITY_2160`=35) plus GoPro-specific (`ICQ_QUALITY_GOPRO`=24, selected by `GX*`/`GH*` filename prefix). Verified binding via `-v verbose` (`RC mode: ICQ.` / `RC quality: N.`).                                                                                                                                 | `ffmpeg -h encoder=av1_vaapi`                      |
| ffmpeg's `q=-0.0` in the stats line means quality is unset    | **False.** VAAPI never reports a per-frame quantizer to ffmpeg's stats line, so `q=-0.0` is expected and says nothing about whether `-global_quality` took effect. Confirm with `-v verbose` instead.                                                                                                                                                                                                                                                                                                                   | `ffmpeg -v verbose`                                |
| Encoding hangs while an LLM is resident on the GPU            | **Not reproducible.** A 4K60 encode completed normally with a 28.4 GB model resident on card 0. The earlier claim in `NOTES.md` and in [GPU Usage](#gpu-usage) did not hold up on retest — see below.                                                                                                                                                                                                                                                                                                                   | Live test, 2026-09                                 |
| `B_DEPTH`/`-b_depth` controls compression efficiency          | **Measured inert.** Verbose logging reports `Using intra, P- and B-frames (supported references: 3 / 1)` regardless of the value; 300-frame test encodes at `-b_depth` 1, 3, and 5 produced byte-identical output. Kept as a passthrough only, not a tuning knob.                                                                                                                                                                                                                                                       | Live test (`-v verbose`, matched encodes), 2026-09 |
| `VBR` with a matched bitrate ceiling beats ICQ                | **Marginally, yes.** At equal SSIM (0.9794), `VBR -b:v 20M -maxrate 20M` produced 27.1 Mbps vs. ICQ's 29.2 Mbps — ~7% smaller, plus a hard ceiling ICQ cannot provide. Not adopted as the default (single-clip result, adds per-resolution bitrate config); documented as an option.                                                                                                                                                                                                                                    | Live test, 2026-09                                 |
| `-preset`/`-compression_level` is a useful speed/quality knob | **Not worth using off-default.** `-compression_level` (1=slowest/best to 7=fastest/worst) is the only functional speed knob (`-preset`/`-lookahead` don't exist). Measured at ICQ 36, 4K: `cl=1` → 0.93x realtime, SSIM 0.983273; default (`cl=4`) → 2.01x realtime, SSIM 0.982974; `cl=7` → 2.39x realtime but SSIM 0.982635 **and larger output** (47.0 vs 43.9 Mbps). Slowing down costs 2.2x encode time for +0.0003 SSIM — noise. Default is already the sweet spot; `cl=7` is strictly worse (faster AND bigger). | Live test, 2026-09                                 |
| `low_power` mode works on this encoder                        | **Fails.** `-low_power 1` errors with `No usable encoding entrypoint found for profile VAProfileAV1Profile0` — the driver has no low-power AV1 entrypoint on this hardware.                                                                                                                                                                                                                                                                                                                                             | Live test, 2026-09                                 |
| GOP size (`-g`) default is 12 (ffmpeg generic default)        | **Not what's actually applied.** `ffmpeg -h full` reports the generic `AVCodecContext` default of 12, but the driver's real applied default is ~120 (2s @ 60fps) — a no-flag encode and `-g 120` produced byte-identical output (43.850 Mbps, SSIM 0.982974). `-g 300` saves only ~1.6% (43.2 Mbps) at equal SSIM — not a meaningful size win. The script sets `-g` to `fps x 2` for consistent 2s seek granularity across cameras with different framerates, not for size.                                             | Live test, 2026-09                                 |

## Configuration

The ConfigMap is populated from `components/ingest/ingest.env`.

| Variable              | Purpose                                                                                       | Default                        |
| --------------------- | --------------------------------------------------------------------------------------------- | ------------------------------ |
| `INGEST_SOURCES`      | Comma-separated sources: `name=remote:ingest/import/...[:h=NNN][:qp=NNN][,...]`               | _placeholder_                  |
| `INGEST_DEST`         | rclone dest path (e.g., `nas:ingest/export`)                                                  | _placeholder_                  |
| `RC_MODE`             | Rate control: `ICQ` (default), `CQP`, `CBR`, `VBR`. **QVBR/AVBR not supported by iHD 25.4.6** | `ICQ`                          |
| `ICQ_QUALITY_1440`    | ICQ quality target for sources with output height ≤1600p                                      | `34`                           |
| `ICQ_QUALITY_2160`    | ICQ quality target for sources with output height >1600p                                      | `35`                           |
| `ICQ_QUALITY_GOPRO`   | ICQ quality target for GoPro files (selected by `GX*`/`GH*` filename prefix, not resolution)  | `24`                           |
| `ICQ_QUALITY`         | **Deprecated.** Flat quality target; if set, seeds all three tiers above unless also set.     | _unset_                        |
| `QP_TARGET`           | **Deprecated.** Legacy alias for `ICQ_QUALITY` (flat); honored only if `ICQ_QUALITY` unset.   | _unset_                        |
| `B_DEPTH`             | B-frame reference depth (1-INT_MAX). **Measured inert on this driver** — kept as passthrough. | `3`                            |
| `PIPELINES_PER_CARD`  | Concurrent pipelines per GPU card (LLM off)                                                   | `4`                            |
| `ENCODE_DEVICE`       | GPU render node for encoding                                                                  | `/dev/dri/renderD128` (card 0) |
| `INGEST_FILE_TIMEOUT` | Per-file watchdog timeout (seconds). Prevents hung encodes from clogging slots forever.       | `21600` (6h)                   |
| `INGEST_MAX_ATTEMPTS` | Max dispatch attempts per file. Exceeded = permanently dropped, not requeued.                 | `3`                            |

GOP size (`-g`) is not configurable via env — it's computed automatically
as `fps x 2` from each source's probed framerate, for consistent ~2s seek
granularity across cameras with different native framerates (see
[Quality & Bitrate](#quality--bitrate)).

Example `INGEST_SOURCES` (fill in your actual paths):

```txt
rear=nas:ingest/import/rear:h=1440,front=nas:ingest/import/front:h=2160,gopro=nas:ingest/import/gopro
```

## Quality & Bitrate

ICQ quality is **resolution-tiered** (`ICQ_QUALITY_1440`,
`ICQ_QUALITY_2160`) rather than a single flat value. **Important:** ICQ
uses `-global_quality` (not `-qp`; `-qp` is a no-op in ICQ mode). Lower
values = higher quality = higher bitrate.

### Why tiered: the ICQ scale shifts with resolution

The same quality value produces very different size ratios at 1440p vs.
4K — break-even (output size = source size) is ~6-7 points apart:

| Resolution                             | Break-even vs. h264 source |
| -------------------------------------- | -------------------------- |
| 1440p (2560×1440@30, 27.0 Mbps source) | ~ICQ 26                    |
| 4K60 (3840×2160@60, 65.8 Mbps source)  | ~ICQ 33                    |

A flat value tuned for one resolution is wrong for the other — it either
over-compresses 1440p or inflates 4K. This is why the config exposes two
separate variables instead of one.

### Measured calibration curves

Sweeps run 2026-09 on `av1_vaapi` / iHD 25.4.6. SSIM is measured against a
near-lossless 960p proxy of each source (relative ranking is reliable;
absolute values are approximate — `libvmaf` is not compiled into this
jellyfin-ffmpeg build).

**1440p** — 300 frames of rear-cam footage, **27.0 Mbps h264** source:

| `-global_quality`           | Bitrate   | % of source | SSIM                  |
| --------------------------- | --------- | ----------- | --------------------- |
| 26                          | 26.5 Mbps | 98%         | 0.9872                |
| 29                          | 19.3 Mbps | 71%         | 0.9850                |
| 30                          | 16.8 Mbps | 62%         | 0.9839                |
| 33                          | 9.7 Mbps  | 36%         | 0.9786                |
| **34** (`ICQ_QUALITY_1440`) | ~8.0 Mbps | ~31%        | ~0.977 (interpolated) |
| 36                          | 4.7 Mbps  | 18%         | 0.9709                |

**4K60** — 300 frames of front-cam GoPro footage, **65.8 Mbps h264** source:

| `-global_quality`           | Bitrate                      | % of source | SSIM                  |
| --------------------------- | ---------------------------- | ----------- | --------------------- |
| 26                          | 141 Mbps                     | 214%        | —                     |
| 27 (pre-QA)                 | ~125-130 Mbps (interpolated) | ~190%       | —                     |
| 30                          | 94 Mbps                      | 143%        | 0.9881                |
| 32                          | 77 Mbps                      | 117%        | 0.9871                |
| 34                          | 62 Mbps                      | 94%         | 0.9855                |
| **35** (`ICQ_QUALITY_2160`) | ~53 Mbps                     | ~80%        | ~0.984 (interpolated) |
| 36                          | 44 Mbps                      | 67%         | 0.9830                |
| 38                          | 29 Mbps                      | 44%         | 0.9794                |
| 40                          | 20 Mbps                      | 30%         | 0.9746                |

The current 4K tier value (35) sits just **above** the ~33 break-even point
— QA measured ~80% of the h264 source size (SSIM 0.9560). The pre-QA value
of 27 was **below** break-even and produced ~2× the h264 source size; this
was a quality-first choice (no perceptual quality gain above 35).

These curves are calibrated on one clip per resolution. GoPro files are
**not** assigned by resolution — they are selected by filename prefix
(`GX*` / `GH*`, matching GoPro's own 5.3K/4K naming convention) and
receive `ICQ_QUALITY_GOPRO` regardless of output height. The current value
of 24 is **calibrated** (2026-09 QA, SSIM 0.9680 at 50.1% of source) —
already in the imperceptible band, no headroom, keep at 24.

ICQ has no output bitrate ceiling, so actual output size still varies with
scene complexity and is **not capped or gated** — the ingest script logs
an informational `output/source size ratio` per file and always uploads
the result. Review flagged files manually rather than relying on automatic
re-encoding or rejection.

### Speed vs. quality: `-compression_level`

`-compression_level` (1=slowest/best quality, 7=fastest/worst) is the only
functional speed/quality knob on this encoder — `-preset` and `-lookahead`
don't exist for `av1_vaapi`, and `-low_power` fails outright (see
[Encoder Facts](#encoder-facts-measured)). Measured at ICQ 36, 4K:

| `compression_level` | Speed (realtime) | Bitrate   | SSIM     |
| ------------------- | ---------------- | --------- | -------- |
| 1 (slowest)         | 0.93x            | 44.5 Mbps | 0.983273 |
| **4 (default)**     | **2.01x**        | 43.9 Mbps | 0.982974 |
| 7 (fastest)         | 2.39x            | 47.0 Mbps | 0.982635 |

**Not worth changing from default.** Slowing to `cl=1` costs 2.2x the
encode time for a +0.0003 SSIM gain — noise. Speeding up to `cl=7` is both
faster **and** produces a larger file (47.0 vs. 43.9 Mbps) — strictly
worse. The script does not set this flag; the driver default (4) is used.

### GOP size

The script sets `-g` to `fps x 2` per source (e.g. 120 @ 60fps, 60 @
30fps), computed from the probed framerate. This is **not** a meaningful
size optimization — a no-flag encode already defaults to a GOP of ~120
(confirmed byte-identical to explicit `-g 120`), and even `-g 300` only
saves ~1.6% over that. The purpose is **consistent seek granularity**
(~2s) across cameras with different native framerates, not compression.
If the framerate can't be probed, `-g` is omitted and the driver default
applies.

## Visual Quality QA

Full-file QA comparing `ingest/test/` sources against the AV1 exports in
`ingest/export/` (2026-09). 1440p and 4K frames decoded locally (h264/AV1
on `ffmpeg-free` build); GoPro frames decoded via the `media-ingest` pod
(Jellyfin ffmpeg 7.1.4, Intel Xe QSV for HEVC). PNGs are lossless 8-bit.

### Original QA (ICQ 32 / 35 / 24)

**1440p** — 2560×1440 @ 30fps, 614 MB h264 → 264 MB AV1 (42.9%), ICQ 32:

| Frame    | Time   | SSIM All   | PSNR Avg     | XPSNR R   |
| -------- | ------ | ---------- | ------------ | --------- |
| F00      | 0.0s   | 0.9344     | 37.66 dB     | 43.14     |
| F01      | 44.9s  | 0.9412     | 37.37 dB     | 42.87     |
| F02      | 89.8s  | 0.9364     | 37.08 dB     | 42.47     |
| F03      | 134.6s | 0.9413     | 36.94 dB     | 42.70     |
| F04      | 179.5s | 0.9391     | 36.57 dB     | 42.46     |
| **Mean** |        | **0.9385** | **37.12 dB** | **42.73** |

**4K** — 3840×2160 @ 60fps, 1480 MB h264 → 1117 MB AV1 (75.4%), ICQ 35:

| Frame    | Time   | SSIM All   | PSNR Avg     | XPSNR R   |
| -------- | ------ | ---------- | ------------ | --------- |
| F00      | 0.0s   | 0.9627     | 35.63 dB     | 44.28     |
| F01      | 44.9s  | 0.9683     | 32.07 dB     | 42.51     |
| F02      | 89.8s  | 0.9559     | 35.35 dB     | 43.95     |
| F03      | 134.6s | 0.9502     | 34.49 dB     | 42.72     |
| F04      | 179.5s | 0.9429     | 36.28 dB     | 43.45     |
| **Mean** |        | **0.9560** | **34.76 dB** | **43.38** |

**GoPro 5.3K** — 5312×2988 → 3840×2160, 4012 MB → 2012 MB (50.1%), ICQ 24:

| Frame    | Time   | SSIM All   | PSNR Avg     | XPSNR R   |
| -------- | ------ | ---------- | ------------ | --------- |
| F00      | 0.0s   | 0.9838     | 44.85 dB     | 50.30     |
| F01      | 80.2s  | 0.9598     | 42.44 dB     | 46.03     |
| F02      | 160.4s | 0.9710     | 44.14 dB     | 46.80     |
| F03      | 240.6s | 0.9605     | 43.22 dB     | 46.22     |
| F04      | 320.8s | 0.9650     | 42.88 dB     | 45.95     |
| **Mean** |        | **0.9680** | **43.51 dB** | **47.06** |

### ICQ 34 Verification (New 1440p sample)

Re-encoded a different 1440p sample (586 MB source → 304 MB export, 51.9%)
at ICQ 34 — the current setting.

| Frame    | Time   | SSIM All   | PSNR Avg     | XPSNR R   |
| -------- | ------ | ---------- | ------------ | --------- |
| F00      | 0.0s   | 0.9477     | 34.94 dB     | 41.93     |
| F01      | 44.9s  | 0.9108     | 32.21 dB     | 39.60     |
| F02      | 89.8s  | 0.9129     | 32.91 dB     | 39.80     |
| F03      | 134.6s | 0.9127     | 33.91 dB     | 40.27     |
| F04      | 179.5s | 0.9322     | 33.79 dB     | 40.26     |
| **Mean** |        | **0.9233** | **33.55 dB** | **40.37** |

The SSIM drop from ICQ 32 (0.9385) to ICQ 34 (0.9233) is consistent with the
projected ~0.92–0.93 range. 0.9233 is below the "imperceptible" band (0.95+)
but still "very good" — acceptable for dashcam content with moderate scene
complexity.

### ICQ Headroom Verdict

On this encoder **higher ICQ = more compression** (smaller file, lower SSIM).

| Resolution | ICQ | SSIM Mean | Size vs. source | Headroom | Status                                                             |
| ---------- | --- | --------- | --------------- | -------- | ------------------------------------------------------------------ |
| 1440p h264 | 32  | 0.9385    | 42.9%           | Yes      | **Raised to 34** — SSIM 0.9233 (projected; verified on new sample) |
| 4K h264    | 35  | 0.9560    | 75.4%           | No       | Keep — imperceptible (≥0.95)                                       |
| GoPro 5.3K | 24  | 0.9680    | 50.1%           | No       | Keep — imperceptible (≥0.95)                                       |

4K and GoPro are already in the imperceptible band — there is no headroom to
raise their ICQ. Only 1440p has room for additional compression; 34 is the
current setting and has been verified.

## GPU Usage

Two Intel Arc Pro B70 GPUs (Battlemage), `gpu.intel.com/xe: "2"` (one virtual device per card).

Pipeline cost (single-card decode+encode):

| Source → Output | Cost     | LLM resident fits      |
| --------------- | -------- | ---------------------- |
| 1440p→1440p     | ~600 MB  | card 0: 4×, card 1: 2× |
| 4K→4K           | ~1400 MB | card 0: 1×, card 1: ✗  |
| 5.3K→4K         | ~2000 MB | card 0: 1×, card 1: ✗  |

With LLMs scaled down (~30+ GiB/card): both cards can run 4+ pipelines each.

### Concurrency Constraint (Measured)

**Superseded — not reproducible on retest.** This section previously claimed VA-API encode context creation hangs indefinitely while an LLM is resident. A 2026-09 retest ran a 4K60 encode to completion at ~110 fps with a 28.4 GB model resident on card 0 — no hang. The original claim is retracted; see [Encoder Facts](#encoder-facts-measured).

**Current operating model:** LLM-off scale-down is no longer required for correctness. It may still help throughput (freeing VRAM for more concurrent pipelines — see the table above), but is not a prerequisite for safe encoding. The per-file watchdog (below) remains as a safety net regardless.

### Safety Net: Per-File Watchdog

A per-file kill timeout (`INGEST_FILE_TIMEOUT`, default 6h) prevents a hung encode from wedging the pipeline forever:

- On timeout: kills ffmpeg, drops partial output, re-queues the file
- Source originals are only moved to `_ingested/` after verified upload, so a timeout **never loses footage**
- When LLMs are accidentally left active: files will hang → timeout → retry in the next window (minor delay, no data loss)

### Retry Counter (Attempt Limiting)

To prevent files from being requeued indefinitely when they fail on every dispatch (e.g., malformed files, GPU-specific issues), a retry counter tracks per-file attempt counts:

- On each dispatch, the attempt counter increments
- If `attempts > INGEST_MAX_ATTEMPTS` (default 3): file is **permanently dropped** — not requeued
- Failed files that exceed the limit are logged: `Dropped $filename (attempts=N > MAX_ATTEMPTS=3) — skipping requeue`
- The retry counter persists across scan cycles in `/tmp/ingest-retry-counter`
- Files already retried and within the limit get their counter incremented on re-queue and are re-added to the queue

## Scheduler

Whole-pipeline per card (decode + encode on one card). Files assigned to the card with:

1. Fewest running pipelines (load balance)
2. VRAM budget sufficient for pipeline cost
3. Balanced across both cards when LLMs are off

When LLMs are off: up to 4 pipelines per card, limited by hardware encoder throughput.

## Operational Mode

1. Fill `INGEST_SOURCES` and `INGEST_DEST` in the ConfigMap
2. Create Vault key: `vault kv put homelab/media-ingest unas` (copy `[unas]` SMB section from existing `homelab/nextcloud/unas`)
3. Wait for `gpu-toolbox` image rebuild (Tekton PAsC triggers on containerfile change — `rclone` is already included)
4. `argocd app sync media-ingest`
5. Verify pod on `gpu-1`, `xe` = 2 allocated
6. Run per-resolution ICQ calibration: 1 real sample per camera, sweep `-global_quality` (see [Quality & Bitrate](#quality--bitrate))
7. Set `ICQ_QUALITY_1440` / `ICQ_QUALITY_2160` / `ICQ_QUALITY_GOPRO` based on calibration results
8. Monitor `xpu-smi` for activity on both cards

## Troubleshooting

- **SCC admission failure**: ensure the `media-ingest` SCC exists and is bound to the `ingest` service account
- **GPU device not found**: confirm `/dev/dri/renderD128` and `/dev/dri/renderD129` exist on the node
- **Vault secret not found**: ExternalSecret will error until the vault key exists at `homelab/media-ingest`
- **No files ingested**: check that `INGEST_SOURCES` and `INGEST_DEST` are filled and valid
- **Encode hangs**: the per-file watchdog kills the process after `INGEST_FILE_TIMEOUT` seconds (default 6h) and re-queues the file. The earlier "LLM residency causes a hang" theory did not reproduce on retest (see [Encoder Facts](#encoder-facts-measured)) — treat a hang as a generic stall, not evidence of LLM contention

## Phase 2: 10-bit CPU

True 10-bit AV1 output is not possible with VA-API on iHD 25.4.6 (8-bit only). CPU-based 10-bit encoding via `libsvtav1` is **already present** in the `gpu-toolbox` image (via jellyfin-ffmpeg7), but measured throughput is poor at 4K (~0.1x realtime) and 4K encodes OOM'd at the pod's memory limit — not currently practical without raising resource limits. No rebuild required if revisited — just a new `:engine=cpu` mode in the ingest script.
