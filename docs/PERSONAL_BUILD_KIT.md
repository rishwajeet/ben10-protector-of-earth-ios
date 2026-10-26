# Protector Native personal-build kit: detailed reference

This is the detailed reference behind the repository README, which has the
step-by-step build. The kit contains source, hash contracts and reconstruction
tools, not a game dump, generated game code, restored media, model weights,
Apple SDKs, credentials or an installable game. The original project software
is **GPL-3.0-or-later**; see `LICENSE` and `LICENSING.md` at the source root.
Upstream notices remain intact. The owner approved publishing this source kit as
a developer preview on 20 October 2026. Never share the IPA, extracted files or
content package you produce: they contain material converted from your game.

The supported original is Wii USA RBNEG9 revision 0. The builder rejects other
revisions rather than changing behaviour or borrowing another game's assets.
Only use original inputs you are entitled to use. This is an engineering
boundary, not a determination of dumping, copyright or trademark permissions.

## Host and tools

Use an Apple Silicon Mac with full Xcode, the iPhone SDK, CMake, Ninja and uv.
Installation and acceptance of Apple terms are user actions. Commands below use
placeholder paths outside this source directory. Choose new private output
directories and retain your original input and saves.

```sh
uv run python tools/personal_build.py doctor
uv run python tools/personal_build.py doctor --cinematics
uv run python tools/bootstrap_personal_tools.py --work-dir /private/protector-tools
```

Bootstrap downloads the pinned official nodtool and ASTC encoder, builds the
pinned DolRecomp source without LLVM, runs its upstream tests and obtains the
admitted Dolphin free-replacement DSP coefficients. Hashes and source URLs are
in `reference/personal_tool_sources.json`. It does not install system packages,
download models, fetch game data or request an Apple account. A completed
bootstrap can be rerun to verify and reuse its outputs. Downloads and partial
source extraction remain available for a checked retry after interruption.

The optional cinematic doctor additionally checks external `ffmpeg` and
`ffprobe`, Bink/HEVC decoders, the VideoToolbox HEVC encoder, required scan and
colour filters, VideoToolbox acceleration and the HEVC metadata bitstream
filter. It only inspects advertised capabilities: no game media is opened,
models loaded, hardware encoder exercised or output generated. FFmpeg/ffprobe
must already be on PATH; the bootstrap does not install them. The cinematic
runner repeats this check before importing inference code. A passed check does
not qualify available memory, output quality, model rights or full-library
replay. Keep heavy runs stopped while competing work needs the machine.

## Prepare and build a personal app

```sh
uv run python tools/personal_build.py prepare --input /private/game.rvz --work-dir /private/protector-build --nodtool /private/protector-tools/bin/nodtool --dolrecomp /private/protector-tools/build/dolrecomp
uv run python tools/personal_build.py build --work-dir /private/protector-build --coefficients /private/protector-tools/downloads/dsp_coef.bin --sdk iphoneos --authored-inputs /private/authored-inputs
uv run python tools/personal_build.py ipa --app /private/protector-build/build-iphoneos/protector_ios_interactive.app --output /private/Protector-unsigned.ipa
```

The build remains strict-floating-point, ARM64 and enhanced-only. Large personal
content is imported separately, not embedded in the IPA. The app icon is
rendered from the artwork bundle's Omnitrix vectors by `tools/make_app_icon.py`;
without `--authored-inputs` the app has no icon. The resulting IPA
contains locally translated game code and must not be distributed as the public
kit. It is unsigned for installation and requires the user's own signing path.
No signing, installation or refresh result is implied by successful compilation.

The raw translation's 122 pinned generated files are checked before title hooks
are prepared. A different locally built recompiler binary is not silently
trusted: the current initial host/toolchain qualification still requires the
admitted binary hash. Report a mismatch rather than editing admission hashes.

## Reconstruct enhanced resources

### Obtain and verify the exact model weights

Review each upstream project's terms, then manually obtain these five files
from the official links into one external directory. Keep the filenames exactly
as listed. They total **243,569,014 bytes** (about 244 MB). Do not substitute an
ONNX/FP16 conversion, a discriminator checkpoint, a similarly named model or
the alternative PBRify `.pth`: the accepted recipes pin the following bytes.

| Required file | Official source | Exact bytes |
| --- | --- | ---: |
| `4x-PBRify_UpscalerV4.safetensors` | [PBRify V4 asset](https://github.com/Kim2091/Kim2091-Models/releases/download/4x-PBRify_UpscalerV4/4x-PBRify_UpscalerV4.safetensors) | 139,793,020 |
| `ArtCNN_R16F96.onnx` | [ArtCNN pinned source](https://raw.githubusercontent.com/Artoriuz/ArtCNN/e138cc15c0d9fb6ec04b86fc453f7faa30e2b5d3/ONNX/ArtCNN_R16F96.onnx) | 16,313,082 |
| `4xHDcube3_500k.pth` | [HDcube 3.0 asset](https://github.com/Venomalia/HDcube/releases/download/3.0/4xHDcube3_500k.pth) | 67,020,101 |
| `RealESRGAN_x4plus_anime_6B.pth` | [Real-ESRGAN v0.2.2.4 asset](https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth) | 17,938,799 |
| `realesr-animevideov3.pth` | [Real-ESRGAN v0.2.5.0 asset](https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth) | 2,504,012 |

```sh
uv run python tools/check_personal_models.py --model-dir /private/models
```

This read-only offline preflight prints a status for every model and exits 2 if
anything is missing, linked or mismatched; exit 0 means all five match. It does
not deserialize weights, import inference packages, modify files, download
anything or accept licences. Full SHA-256 identities and terms-review links are
in `reference/personal_model_sources.json`, cross-checked against the texture
and cinematic recipe contracts. A successful check proves file identity, not
legal clearance. Models remain external and unbundled; do not mirror HDcube
weights without the upstream permission required by its custom terms.

### Reconstruct geometry and cinematics

```sh
uv run --with-requirements requirements-personal.lock python tools/personal_geometry.py --game /private/protector-build/extracted --work-dir /private/model-build
uv run --with-requirements requirements-personal.lock python tools/personal_cinematics.py --game /private/protector-build/extracted --work-dir /private/movie-build --model-dir /private/models
```

Geometry recipes cover all 194 profiles and rescan all 336 original packages.
NetworkX 3.6.1 and NumPy 2.4.2 preserve the qualified outline correspondence.
Cinematic recipes cover all 76 movies; add `--run` to execute restoration after
providing the exact local model weights and checking their individual licences.
`--movie watch.bik` selects one movie. Neither a manifest check nor a one-movie
sample is a full-library reconstruction pass.

Private reconstruction has now passed all 2,221 selected texture entries on the
development Mac. The main index's 225 authored-treatment placeholders resolve
through the companion contracts. This does not establish a disc-only public
converter or private-input distribution clearance. Complete private pack
assembly and one bounded Mac title-screen consumer check have also passed.
`tools/personal_textures.py` can replay selected implemented operations, but a
subset does not produce a complete runtime pack. Source-constant and bicubic
operations require exact reference pixels. Neural operations record distinct
exact and bounded-rounding results separately. Main-neural outputs can also
match an individually qualified hash without private reference images, as
described below. Those private references are not included in this kit.

The vector, structural-plate, atlas, facade, finite-material, layered-atlas and sign
companion tools require a separate authored-input bundle for 78 selected entries.
The owner approved public inclusion on 16 October; an exact 77-file local review
candidate now exists. It is separate from the source export and remains subject
to artwork rights/licence review. Owner approval and successful reconstruction
do not, by themselves, establish a cleared disc-only public converter.
Atlas replay additionally requires cairo 1.18.4
installed locally; `requirements-personal-atlases.lock` pins the Python libraries,
not the native cairo library. Those replay jobs except fresh painted signs do
not load neural models. Sign compositor checks using retained painted parents
are explicitly separate from fresh reconstruction of the neural backgrounds.

Keep the source and authored-input folders as siblings: the workers intentionally
require authored inputs outside the source tree. Verify the supplied bundle from
the source directory before running it:

```sh
uv run python tools/export_personal_authored_inputs.py verify ../authored-inputs
uv run --with-requirements requirements-personal-atlases.lock python tools/personal_texture_pipeline.py run --stage atlases --game /private/protector-build/extracted --work-dir /private/texture-build --authored-inputs ../authored-inputs/atlases
```

The sibling bundle has `vectors`, `structural`, `atlases`, `facades`, `finite`,
`layered-atlases` and `signs` directories. Pass the matching directory for each
stage. `AUTHORED-INPUTS.json` records contracts, file hashes and approval scope;
it contains no original pixels or model weights. Historical contract/worker
fields named `private` remain unchanged for receipt/cache compatibility; they
do not supersede the owner's approval. Missing bundle inputs remain fatal, not
permission to omit textures or substitute different art.

### Unified texture routing

For a bounded macOS resume, the main batch runner can limit fresh workers and
watch resource pressure while preserving completed candidates:

```sh
uv run --with-requirements requirements-personal.lock python tools/replay_personal_texture_batches.py \
  --game /private/protector-build/extracted --work-dir /private/texture-build/neural \
  --model-dir /private/models --kind local-neutral --kind local-rgb-neutral \
  --batch-size 1 --max-new-workers 32 --max-worker-rss-mib 4096 \
  --max-swap-growth-mib 256 --min-memory-free-percent 50
```

These are optional **sampled stop thresholds**, not hard memory quotas or a
guarantee that no swap occurs. The guard measures the spawned worker's RSS and
macOS-wide swap growth/free-memory report roughly every two seconds; it does not
attribute system-wide pressure to a particular app or measure all GPU allocations.
Unavailable pressure readings fail closed. A breach interrupts only that owned
worker, with a bounded grace period before termination. The existing 10 GiB disk
reserve still applies. Choose thresholds appropriate to other active work.

`--max-new-workers` stops before another uncached worker after the selected count;
cached entries are revalidated without inference. The checkpoint keeps the full
requested total and explicitly records a worker-limit stop, not completion.
Rerunning reuses verified candidates. Hash admission remains strict: an unknown
numerical output still requires separate developer qualification, not a looser
memory mode or an automatic fallback to old artwork.

A failed worker or guarded preflight writes a timestamped `batch-failure-*.json`
with the requested source IDs, error and available pressure measurements. The
checkpoint records `stopped-on-worker-error` and points to that receipt; earlier
verified entries remain reusable. Inspect the failure before resuming. A host
free-memory stop can occur even when sampled process RSS is below its limit,
because RSS does not account for all GPU/unified-memory pressure. Preserve
completed guard receipts before a resume: cached revalidation replaces their
working copies with fresh cache-verification receipts.

First-pass Torch execution has an explicit `--device mps|cpu`, separate from
`--provider`, which selects the ONNX finisher backend. The historical default
is still `mps`. `--mps-memory-fraction` explicitly controls Torch's allocator
limit, with `0 < fraction <= 0.5` and default 0.5. An explicit runtime setting
overrides the corresponding environment high-watermark setting, so changing
only the environment is not a reliable cap. The actual fraction and requested
low-watermark environment setting are recorded in execution receipts. These
allocator controls do not replace host-memory and swap checks.

The local-model engine releases the prior ONNX session before RGB inference,
then releases the RGB model and cached MPS allocations before luma finishing.
It collects unreachable model objects and, for a CPU first pass on macOS,
requests release of unused malloc pages; live image tensors are unaffected.
Its CPU finisher uses one intra/inter-op thread and disables ONNX's CPU memory
arena to bound retained allocator growth. CoreML keeps its default session
settings. These scheduling/lifetime changes do not reduce resolution, change
model weights or relax pixel admission. Execution receipts record the actual
finisher settings; resource guards remain necessary.

`--dat-window-batch-size 1..128` is an **experimental, opt-in** execution path;
zero (the default) retains the original implementation. It batches independent
DAT spatial-attention windows, not input-image tiles, and retains full-image
feature maps, learned biases and shifted-window masks. It fails closed unless
the installed DAT implementation matches the qualified source hash. CPU mode
also requests release of unused heap pages on macOS between completed blocks;
this does not free live tensor memory. Window batching alone did not complete
the initial 512-square CPU pilot; do not blindly increase the cap or repeat it
unchanged.

`--cpu-conv-output-rows 1..256` is a separate **opt-in CPU DAT/ESRGAN** workspace bound;
zero (the default) leaves convolution execution unchanged. It requires
`--device cpu` and the pinned architecture implementation. ESRGAN additionally
pins its shared block helper. Each output row retains its
complete convolution input neighbourhood, including the exact outer padding.
This does not divide the image passed through the attention network or alter
weights, precision, resolution or the selected reference pixels. Geometry tests
cover padding, stride, dilation, groups and partial final row blocks. Backend
rounding can differ; normal full-output pixel admission remains mandatory.

Combined 32-window attention batches and 64-output-row convolutions passed
selected 256-square and 512-square production sources on the tested Mac, with
at most one-value RGB rounding and exact alpha. Both runs recorded zero sampled
swap growth. This qualifies those complete outputs, not every texture, hardware
backend or a fixed memory guarantee. The larger run's sampled RSS stayed below
its 8 GiB stop setting, while the whole-command maximum exceeded 8 GiB between
samples: these guards are **not hard quotas**. The default MPS path is unchanged.

The same 64-row convolution path also passed a selected 256-square ESRGAN
source with full 4096-square output and CoreML finishing, at at most one-value
RGB rounding and exact alpha. Its sampled peak was 2,707.47 MiB RSS with at
least 53% reported free memory and no swap growth. This is one qualified full
output, not a guarantee for all connected artwork canvases or every platform.

To schedule around a known unresolved source, the batch runner accepts repeated
`--defer-entry SOURCE_ID` with `--batch-size 1`. IDs must belong to the full
selected set. An already saved candidate is still revalidated normally; only
an uncached entry is deferred. The checkpoint keeps the full selected total and
lists skipped IDs in `deferred_sources`. A run that reaches the end with such
entries uses `stopped-with-deferred-entries`, never complete. A worker-cap stop
or error also retains that list. Deferral is not an accepted substitute, does
not produce pixels for that source, and is not automatically persisted into
the next command: omit the option later to attempt the pending source again.

```sh
uv run python tools/personal_texture_pipeline.py plan --output /private/texture-plan.json
uv run --with-requirements requirements-personal-atlases.lock python tools/personal_texture_pipeline.py run --stage atlases --game /private/protector-build/extracted --work-dir /private/texture-build --authored-inputs /private/authored-atlases
```

`plan` checks complete, non-overlapping routing and contract/source-lock identity
without loading models, decoding pixels or opening private drawings. It lists
the requirement locks, neural flag, private-input needs and parent dependencies
for every stage. It does not claim private inputs exist or validate their rights.
Run with the listed requirement lock(s); the dispatcher does not install packages.

`run` executes only one explicitly selected stage. Neural stages additionally
require `--allow-neural` and `--model-dir`; they are never inferred from a missing
cache or launched by `plan`. Main neural work uses one-entry isolated workers;
RGB grid work uses one whole canvas per process. These bounds release model
memory between jobs, but do not promise low peak memory within a neural job.
Do not run them during competing memory-heavy work merely because other stages
can run. Painted signs accept fresh model parents here, never silently retained
reference parents. `--provider cpu` selects the ONNX provider, not an all-CPU
promise: the existing PBRify stage still uses MPS.

Main source/neural and grid stages additionally accept `--device cpu` and
`--cpu-conv-output-rows 64`. The grid's RGB restoration still makes one
whole-canvas model call and preserves the exact crop; only individual CPU
convolution workspaces are row-bounded. The grid model is released before
finishing and fresh execution metadata is retained separately from cached
verification. These options are rejected for unsupported companion stages,
including signs, instead of being silently ignored. Default first-pass device
is still MPS. Large complete feature maps can still exceed available memory.

The dispatcher also accepts `--max-worker-rss-mib`, `--max-swap-growth-mib`
and `--min-memory-free-percent`. CPU RGB grid stages additionally support the
experimental `--cpu-tail-input-rows 32` option, which preserves the complete
full-canvas ESRGAN residual trunk and evaluates only the final 4x upsampling
tail in feature-row strips. Each strip includes the exact two-feature-row halo;
true outer padding, full width, FP32 weights and selected crop remain unchanged.
There is no seam blending or input-image tiling. This requires the source-pinned
nearest-neighbor ESRGAN tail topology and is rejected for other stages/devices.
Synthetic full-model and exact-halo tests pass. The 1280×1024 connected-canvas
production replay also passes all 20 selected tiles against full-resolution
references (maximum one RGB unit, exact alpha), with one complete residual-trunk
call and 34 tail strips. Other output hashes still need their own admission;
this is not a generic tolerance waiver. Zero retains the original tail. The option is separate from the
convolution workspace bound and does not make the sampled guards hard quotas.

For grid/sign and other companion stages, the dispatcher guards the direct worker,
records sampled telemetry in its dispatch receipt,
and preserves a timestamped failure receipt on interruption or error. Main
source/neural stages forward the thresholds to their batch runner, which owns
the actual inference children; guarding only the dispatcher would miss their
RSS. Preflight pressure failures happen before creating a new workspace.
These remain optional sampled stops, not hard memory quotas or completion proof.

The workspace records its exact contracts and retains completed candidates for
worker revalidation on retry. Thumbnail replay consumes reconstructed full-art
parents from its `neural/candidates` directory, or explicitly supplied external
`--parent-candidates` directories. It never starts missing parent inference.
`--numerical-reference` is a private developer comparison option, not a public
replacement for portable rounding admission. A dispatch receipt records only
the selected worker's successful exit; use that worker's receipts for source and
pixel results. No dispatcher stage cooks or declares a complete runtime pack.

### Known numerical output hashes

`reference/personal_texture_variants.json` contains 1,105 individually checked
main-neural output hashes. Each record is bound to the complete selected entry
(source, recipe/model identities, dimensions and reference hash), with a pinned
private qualification receipt. These saved outputs were independently compared
with the selected pixels: every changed component differs by exactly one UNORM
value, and every alpha component is identical. No pixels or local paths are in
the registry. This is a finite list of qualified byte results, not a blanket
one-value tolerance at runtime or a guarantee for every Mac/backend.

Replay, cache reuse and delivery preparation accept an exact selected hash or
one of these listed hashes. Unknown outputs still fail without an explicit
private developer comparison. Receipts distinguish a fresh private comparison
from a known-hash lookup (`comparison_this_run: false`). The selected reference
hash is not replaced. Source-only, vector, sign, grid and thumbnail outputs are
not silently admitted through this main-neural registry. The 34 larger saved
outputs excluded by the initial one-megapixel budget are now separately checked
and listed, including 31 4096-square and three 2048-square outputs. Other output
variants still need qualification; registry membership does not guarantee fresh
replay on another system. The complete selected main-neural set has now replayed
on the development Mac, with 301 exact and 1,105 independently qualified rounded
outputs. Connected grids and painted signs have their own qualification below;
they are not admitted through the main-neural registry.

Registered thumbnails have a separate hash-only registry,
`reference/personal_thumbnail_variants.json`. Its 30 known rounded outputs are
bound to the selected thumbnail source, registered crop and parent recipe/pixels.
The remaining four selected thumbnails reproduce exactly. Thumbnail rebuilds
and delivery staging accept these listed hashes without private reference images;
changed crops, unknown output/parent hashes and withdrawn parent qualifications
fail closed. This does not extend numerical admission to grids, signs or other
authored treatments. Parent candidates must still be reconstructed first.

Connected RGB grids now have their own finite registry,
`reference/personal_grid_variants.json`: 47 independently qualified rounded
outputs plus one exact selected output cover all 48 RGB tiles. Each qualification
reassembled the original whole canvas and pins the selected entry, canvas/model
recipe, crop and execution receipt. Fresh replay has passed all 21 canvases on
the development Mac. Unknown hashes still fail without explicit private
qualification; no generic pixel tolerance is enabled for public kit users.
The three painted signs also passed fresh reconstruction exactly, including
their neural parents. Their private authored drawings still require separate
distribution clearance. Complete runtime-pack assembly subsequently passed all
2,221 entries and 410 companion pairs; this is not public distribution clearance.

```sh
uv run --with-requirements requirements-personal-structural.lock python tools/personal_texture_variants.py --verify-cache --game /private/protector-build/extracted --cached-work /private/texture-build/neural --output-dir /private/known-output-check
```

This command revalidates original inputs and registered saved candidates through
the worker's actual cache-admission path. It refuses private reference arguments
and never invokes inference, including when a candidate is missing. Developer
qualification is a separate mode requiring private reference pixels and the
saved candidate's execution receipt; it does not infer qualification from old
summary counters. Strip-wise comparisons bound temporary comparison memory.

### Texture delivery and final composition

```sh
uv run python tools/personal_texture_delivery.py plan
uv run --with-requirements requirements-personal-delivery.lock python tools/personal_texture_delivery.py prepare --batch raw-000 --game /private/protector-build/extracted --work-dir /private/texture-delivery --candidates /private/texture-build/vectors/candidates
```

The selected set has 37 delivery batches, each containing at most 64 entries:
2,190 opaque ASTC entries, three straight-alpha entries (including two with
lossless mip tails), and 28 raw RGBA entries. The full raw staging footprint is
10,507,255,808 logical bytes before compression, in addition to candidates and
cooked outputs. A batch requires its raw-byte budget plus 5 GiB free headroom.
Only the requested batch is staged. Supply additional candidate directories
using repeated `--candidates`; conflicting copies and missing entries fail.

Preparation rechecks the original file table, freshly decodes each selected
typed original plane, and checks candidate dimensions, alpha and pixel identity.
It creates cooker-compatible raw manifests without applying runtime companion
guards prematurely. Rerunning revalidates source/candidate bytes and retains
matching content-addressed payloads. It rejects corrupt existing payloads and
does not replace them. Private numerical comparisons are opt-in and limited to
the existing neural/grid-RGB/thumbnail lanes. Listed main-neural hashes also
work without private references; unknown outputs and other-family portability
remain unresolved. No models, compression or downloads run during preparation.

After preparation, use the existing cooker matching each batch's lane. These
are explicit compression commands, **not low-memory planning commands**:

```sh
uv run --with-requirements requirements-personal-delivery.lock python tools/cook_texture_pack.py /private/texture-delivery/opaque-000/pack.json /private/cooked-textures/opaque-000 --encoder /private/protector-tools/bin/astcenc --block 4 --quality thorough --threads 1
uv run --with-requirements requirements-personal-delivery.lock python tools/cook_alpha_texture_pack.py /private/texture-delivery/straight-000/pack.json /private/cooked-textures/straight-000 --encoder /private/protector-tools/bin/astcenc --threads 1
```

Repeat opaque cooking for the exact batch IDs from `plan`; do not cook `raw-000`.
Completed batches remain independent. Existing cookers require new output
directories; an interrupted partial cook is not a completed resumable manifest.
The delivery lock pins OpenEXR 3.5.2, NumPy 2.4.2, Pillow 12.1.1 and SciPy 1.17.0.
Its binding/synthetic codec tests and full production recooking under this lock
pass on the development Mac. Final admission requires the hash-pinned ASTC encoder and rejects
changes to selected formats, including the straight-alpha tail distinction.

```sh
uv run --with-requirements requirements-personal-delivery.lock python tools/personal_texture_delivery.py assemble --game /private/protector-build/extracted --work-dir /private/texture-delivery --cooked-dir /private/cooked-textures --output /private/RestoredArt
```

Assembly refuses to start with any missing batch. It checks staged pixels and
admission receipts, source/encoder links, all 2,221 selected identities and exact
formats, then uses the existing dual-decode codec validator/composer and restores
all 410 reciprocal companion pairs. It requires final payload bytes plus 5 GiB
headroom and writes only to a new output. An assembly receipt proves a complete
selected candidate pack was assembled, not new runtime/art acceptance or public
distribution rights. The full production assembly has passed. A subsequent
muted Mac normal-startup check loaded this exact manifest and all 194 replayed
geometry profiles, displaying the restored title at frame 1369 with 12 texture
sources used in that frame and no runtime error. This is not a campaign,
physical-phone, all-asset appearance or sustained-performance claim.

Geometry replay writes compact JSON and enforces the runtime's 24 MiB manifest
limit before writing. The previous pretty-printed output exceeded that limit
despite identical geometry; do not use it as the delivery manifest. The corrected
194-profile replay is 17,032,063 bytes and retains the exact selected ordered
entry hash. No geometry or runtime memory guard was relaxed.

Do not replace missing enhanced treatments with baseline art or upload existing
derivative payloads to bypass unfinished recipe portability. Source and model
identity, image quality, and whole-game acceptance are separate checks.

## Storage, import and acceptance

Source/dependency provenance and outstanding rights gates are recorded in
`docs/THIRD_PARTY_REVIEW.md`. The private source snapshot includes scoped Dolphin
audio and CPU-estimate attribution plus an offline dependency-metadata inventory
tool. Matching package versions and fingerprinting notices do not establish
redistribution clearance; model weights remain external and unbundled.

The latest private replayed personal archive is 9,787,143,382 bytes (about
9.79 GB / 9.12 GiB). Its full stream/file hashes and native manifest admission
were verified; it has not had a new full simulator or phone import. The earlier
9,854,921,671-byte archive retains its own full simulator-picker import evidence,
which does not establish a full import of the newer archive. A fresh phone import also
needs another payload-sized allocation plus headroom and any prior retained
content. Conversion needs original inputs, working output, models and compiler
intermediates; account for macOS swap as well as file sizes. Tools retain complete
work on failure and do not sweep other projects, caches, inputs or old content.

Once every enhanced class is available, package and verify the personal content
with `tools/package_personal_content.py`, then transfer it to the app's system
document picker. Keep saves and signing identity stable across later updates.
Deleting the app is not a normal update or refresh procedure.

The packager and native importer accept two exact original-file tables: all 442
pinned extraction files, or the 436-file `sys/` + `files/` runtime projection used
by older packages. A partial metadata subset, unknown file or changed source hash
is rejected. The full-extraction archive requires the updated content-compatible
app; earlier app builds accepted only the runtime projection. Use the current
IPA identified in the private delivery handoff, not an older retained installer.

### Back up and restore saved progress

Before removing the app, return to its pre-Play screen (close and relaunch the
app if a game session is running). Open **Save backups → Back up saved progress**.
Choose a location outside Protector Native, such as iCloud Drive or a folder on
your Mac. Keep the resulting `.pnsave` file. A file left inside the app is also
removed when the app is deleted; a successful export does not prove cloud sync
has completed. Check the file is available at its destination before removal.

To restore, open **Save backups → Restore saved progress**, choose the `.pnsave`
file, then confirm **Restore progress**. The app verifies the format, supported
title/edition and per-file hashes before asking to replace progress. Existing
nonempty progress is copied to **Files → Protector Native → Save Recovery**
before replacement; choose that recovery file through the same flow to undo a
restore. A failed pre-replacement check leaves current progress unchanged.

Backups contain enhanced-edition saved progress only, not imported game content,
the original/legacy save namespace, settings, signing credentials or an app
installer. Restore is available only before Play. It can be used on a fresh
installation before reimporting content. Import your personal content package
separately; a save backup cannot recreate it. Backup/restore does not qualify
signer refresh, reinstall retention or physical-device reliability.

The development build has been installed, updated in place and played with
audio on one iPhone 18 Pro. Signing refresh through free-account tools and
other iPhone models have not yet been tested.
