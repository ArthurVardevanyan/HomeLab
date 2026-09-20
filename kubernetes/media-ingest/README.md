# media-ingest: GPU-accelerated video ingestion server

Per-source video ingest from NAS SMB to a new folder with GPU-accelerated AV1 encoding.

## Table of Contents

- [media-ingest: GPU-accelerated video ingestion server](#media-ingest-gpu-accelerated-video-ingestion-server)
  - [Table of Contents](#table-of-contents)
  - [Strategy](#strategy)
  - [Encoder Facts (Measured)](#encoder-facts-measured)
  - [Configuration](#configuration)
  - [Quality \& Bitrate](#quality--bitrate)
  - [GPU Usage](#gpu-usage)
    - [Concurrency Constraint (Measured)](#concurrency-constraint-measured)
    - [Safety Net: Per-File Watchdog](#safety-net-per-file-watchdog)
  - [Scheduler](#scheduler)
  - [Operational Mode](#operational-mode)
  - [Troubleshooting](#troubleshooting)
  - [Phase 2: 10-bit CPU](#phase-2-10-bit-cpu)

## Strategy

Per-source output = **min(native, 4K)**:

| Source                | Output                 | Expected Bitrate (ICQ 24 / QVBR 24) |
| --------------------- | ---------------------- | ----------------------------------- |
| Rear 2560×1440 60fps  | 1440p (native)         | ~15 Mbit/s                          |
| Front 3840×2160 60fps | 4K (native)            | ~30 Mbit/s                          |
| GoPro 5312×2988 60fps | 4K (5.3K→4K downscale) | ~28 Mbit/s                          |

Per-source `:qp=` override in `INGEST_SOURCES` to set a per-source quality target (same scale as QVBR/ICQ).

## Encoder Facts (Measured)

| Claim                                              | Reality                                                                                                       | Source                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `-crf` is a valid ffmpeg option for `av1_vaapi`    | **`-crf` does not exist.** Only `-rc_mode {ICQ, QVBR, AVBR, CBR, VBR, CQP}` are available.                    | `ffmpeg -h encoder=av1_vaapi` |
| `preset` and `lookahead` are valid encoder options | **Neither `-preset` nor `-lookahead` exists.** These are libx264/libsvtav1 concepts.                          | `ffmpeg -h encoder=av1_vaapi` |
| 10-bit AV1 encoding is supported on this hardware  | **Not on VA-API.** vainfo shows only `VAProfileAV1Profile0` for encoding (8-bit only).                        | `vainfo`                      |
| `libsvtav1` is available for 10-bit CPU encoding   | **Present.** The `gpu-toolbox` image includes `libsvtav1` via the jellyfin-ffmpeg7 bundle. No rebuild needed. | Container filesystem          |
| ICQ quality value is settable via `-qp`            | **Probe pending.** Calibration with null-sink encodes required to map ICQ target value to measured bitrate.   | Pending                       |
| B-frame depth controls compression efficiency      | **Settable via `-b_depth`.** Higher = better compression. Default 1, recommended 3-4 after calibration.       | `ffmpeg -h encoder=av1_vaapi` |

## Configuration

The ConfigMap uses placeholder values — fill these in before first deploy.

| Variable              | Purpose                                                                                 | Default                        |
| --------------------- | --------------------------------------------------------------------------------------- | ------------------------------ |
| `INGEST_SOURCES`      | Comma-separated sources: `name=remote:ingest/import/...[:h=NNN][:qp=NNN][,...]`         | _placeholder_                  |
| `INGEST_DEST`         | rclone dest path (e.g., `nas:ingest/export`)                                            | _placeholder_                  |
| `RC_MODE`             | Rate control: `ICQ`, `QVBR` (default), `AVBR`, `CBR`, `VBR`, `CQP`                      | `QVBR`                         |
| `QP_TARGET`           | Global quality target (used by ICQ; placeholder for QVBR)                               | `24`                           |
| `QVBR_QUALITY`        | QVBR quality target (CRF-like scale: 22-30 = archive range)                             | `24`                           |
| `B_DEPTH`             | B-frame reference depth (1-INT_MAX). Higher = better compression.                       | `3`                            |
| `PIPELINES_PER_CARD`  | Concurrent pipelines per GPU card (LLM off)                                             | `4`                            |
| `ENCODE_DEVICE`       | GPU render node for encoding                                                            | `/dev/dri/renderD128` (card 0) |
| `INGEST_FILE_TIMEOUT` | Per-file watchdog timeout (seconds). Prevents hung encodes from clogging slots forever. | `21600` (6h)                   |

Example `INGEST_SOURCES` (fill in your actual paths):

```txt
rear=nas:ingest/import/rear:h=1440,front=nas:ingest/import/front:h=2160,gopro=nas:ingest/import/gopro:h=2160:qp=22
```

## Quality & Bitrate

| QP / QVBR Quality | 1440p60   | 4K60      | Storage (10h/wk) |
| ----------------- | --------- | --------- | ---------------- |
| 22 (archive)      | ~22 M     | ~44 M     | ~7.5 TB/yr       |
| **24 (default)**  | **~15 M** | **~30 M** | **~5 TB/yr**     |
| 26 (standard)     | ~10 M     | ~20 M     | ~3.4 TB/yr       |

**Important:** ICQ quality target is NOT yet calibrated. The table above uses QVBR quality values, which are well-defined and portable. ICQ may use a different scale — calibration will determine this.

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

**VA-API encode context creation hangs indefinitely while an LLM model is actively resident/inferring.** This was verified experimentally — both cards will deadlock on context creation when llama-swap models are loaded. The "LLM resident + concurrent ingest" operating mode is **not viable** on this hardware.

**Operating model:** Scale LLMs down (`kubectl scale deploy/llama-swap -n llm --replicas=0`), run ingestion batches, scale LLMs back up afterward. The ingest pod runs 24/7 (no auto-detect needed — you manage LLM scaling yourself).

### Safety Net: Per-File Watchdog

A per-file kill timeout (`INGEST_FILE_TIMEOUT`, default 6h) prevents a hung encode from wedging the pipeline forever:

- On timeout: kills ffmpeg, drops partial output, re-queues the file
- Source originals are only moved to `_ingested/` after verified upload, so a timeout **never loses footage**
- When LLMs are accidentally left active: files will hang → timeout → retry in the next window (minor delay, no data loss)

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
6. Scale LLMs down for calibration batch: `kubectl scale deploy/llama-swap -n llm --replicas=0`
7. Run calibration: ICQ/QVBR value-mapping probes + 1 real sample per camera
8. Set `RC_MODE` + quality target + `B_DEPTH` based on calibration results
9. Scale LLMs back up: `kubectl scale deploy/llama-swap -n llm --replicas=2`
10. Monitor `xpu-smi` for activity on both cards

## Troubleshooting

- **SCC admission failure**: ensure the `media-ingest` SCC exists and is bound to the `ingest` service account
- **GPU device not found**: confirm `/dev/dri/renderD128` and `/dev/dri/renderD129` exist on the node
- **Vault secret not found**: ExternalSecret will error until the vault key exists at `homelab/media-ingest`
- **No files ingested**: check that `INGEST_SOURCES` and `INGEST_DEST` are filled and valid
- **Encode hangs**: this is expected if LLMs are active. The watchdog will kill the process after `INGEST_FILE_TIMEOUT` seconds (default 6h) and re-queue the file

## Phase 2: 10-bit CPU

True 10-bit AV1 output is not possible with VA-API on iHD 26.2.2 (8-bit only). Phase 2 can add CPU-based 10-bit encoding using `libsvtav1`, which is **already present** in the `gpu-toolbox` image (via jellyfin-ffmpeg7). No rebuild required — just a new `:engine=cpu` mode in the ingest script.
