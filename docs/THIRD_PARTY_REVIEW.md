# Third-party provenance and redistribution review

## Current review disposition — 16 October

Read [PUBLIC_RELEASE_PROVENANCE.md](PUBLIC_RELEASE_PROVENANCE.md) for the completed
bounded technical review, exact remaining release decisions and its limits.
It identifies 13 explicit traced/contour SVG cases within the 77-file authored
bundle, maps every input to its selected entries, and records the remaining
artwork-rights and artwork-licensing decisions. Owner inclusion approval remains
distinct from these decisions. No authored bytes or clearance flags changed.

The source follow-up records DolRecomp-compatible CPU reset/host-call/interface
correspondences and conservatively retains ExpansionPak's upstream attribution.
Known Dolphin notices remain intact. Source-only distribution is distinguished
from a future bundled converter: external model/wheel/tool redistribution review
is conditional on actually shipping those artifacts, not a generic release gate
for today's unbundled source kit. HDcube weights must remain unbundled.

The older audit below retains its original evidence and unresolved-at-the-time
wording; the decision record supersedes its broad “review all dependencies” task
list. No legal clearance or complete independent authorship certification is
claimed. Publication remains unauthorized.

## Historical inventory and review collection — 15–16 October

Audit date: 15 October 2026; owner decision updated 16 October. Status: **private
engineering evidence, not release clearance**. The owner approved
GPL-3.0-or-later for original redistributable project software; `LICENSE` and
`LICENSING.md` now record that grant and preserve upstream notices. This does
not authorize publication or grant rights in the original game or derivative
assets. Source provenance and third-party terms still need their own review.

## Native runtime and generated code

`native/licenses/README.md` identifies Dolphin-derived audio implementation and
the matching CPU reciprocal tables/arithmetic. It links the audited upstream
revision and retains the GPL-2.0-or-later text. The CPU notice was missing from
the earlier audio-only notice and has now been added without changing behavior.

The bootstrap pins DolRecomp commit
`6f2336397ad9fde3743a63cf083776d18d38345c`. Its locally verified source contains
the GPL version 3 text; its CPU/emitter/decoder files declare GPL-3.0-or-later.
Its CPU source also attributes reciprocal estimates to Dolphin. A compiler's
licence is not automatically the licence of all its output: emitted helpers,
copied implementation and linked runtime code must be reviewed separately.
The complete derivation of every local CPU helper is not established by this
bounded audit. Do not apply a blanket MIT licence or mark the source cleared.

Translated game code, extracted content, generated restoration payloads and
game-specific authored reconstructions remain separate rights-review items.
They are not included merely because a source-file scanner passes. Root project
licence selection is now resolved as GPL-3.0-or-later for the original project
software only; this does not replace the separate rights-review items.

## Pinned build tools and external resources

The exact URLs, revisions, sizes and SHA-256 identities are recorded in
`reference/personal_tool_sources.json`. These are local bootstrap downloads,
not binaries bundled in the allowlisted source snapshot.

| Input | Recorded upstream terms | Remaining handoff review |
| --- | --- | --- |
| nodtool 2.0.0-alpha.12 | MIT OR Apache-2.0 | Retain exact-release notices and review bundled components before redistribution |
| DolRecomp pinned source | GPL-3.0-or-later, with retained Dolphin notices | Review emitted/copied helper provenance and obligations for the actual delivery |
| astcenc 5.5.0 | Apache-2.0 | Retain release licence and any applicable notices if bundled |
| Dolphin DSP coefficients | Pinned free-DSP replacement provenance | Review the exact resource/generator notice and selected packaging; not game-disc content |

The ASTC release licence is available at
https://github.com/ARM-software/astc-encoder/blob/5.5.0/LICENSE.txt.
The tool manifest provides the other exact source links. Cairo 1.18.4 is a
separately installed native requirement for atlas rasterization; Python package
metadata alone does not audit that system library. Apple SDK/platform framework
terms, codec executables used by cinematic preparation, and native libraries
inside wheels also need delivery-specific review. Do not infer bundled binaries'
terms from their Python wrapper alone.

### Historical 15 October binary inspection: preparation tools versus the iPhone app

The binary hash and installed-tool observations in this subsection identify
the inspected artifacts at that time. They are not a fresh inspection of the
later content-compatible IPA or a live inventory of the host. The current IPA
identity is recorded in the private handoff; provenance conclusions remain
bounded to the exact evidence below.

The inspected `cmake/InteractiveIOS.cmake` links the local static runtime plus
Apple frameworks/system libraries. The existing personal iPhone executable
(`build-iphoneos/protector_ios_interactive.app/protector_ios_interactive`, SHA-256
`baa93c34870f008fb793278ef2b15ec8a6bebdf3ecfe1e8391a581d922abc9f7`)
has only Apple system/framework dynamic load commands in `otool -L`. Its bundle
contains the executable, Info.plist, input receipt, controller reference and DSP
coefficients; no Python environment, model weights or third-party dynamic
framework is bundled. Combined with the build configuration, this supports
treating the Python restoration stack as Mac preparation dependencies, not
Python libraries shipped in this app. Dynamic-load inspection alone cannot
prove the provenance of statically linked code; the native-source review above
still applies. This was read-only inspection of an existing binary, not a build
or physical-device test.

The currently installed preparation FFmpeg reports version 8.1.2, configured
with `--enable-gpl --enable-version3`, and `ffmpeg -L` reports GPL-3.0-or-later.
Do not describe that binary as an LGPL-only FFmpeg build. It is an external
preparation executable, not an iPhone runtime library or source-snapshot asset.
This observation does not establish the exact FFmpeg binary used by every older
encode. Review the selected build and notices if later bundling a converter
binary or FFmpeg itself.

## Authored-input boundary and owner decision — 16 October

The owner has now approved making the seven authored-input bundles public.
This resolves the decision to keep them private, but is not third-party rights
clearance or an instruction to publish the working repository. The approved
local staging contains **77 exact inputs / 8,079,894 bytes**: 36 standalone SVGs
and 41 recipe JSON files covering all **78 selected entries**. No input bytes or
recipe identities were changed to remove the historical `private` schema names.

`tools/export_personal_authored_inputs.py` walks the seven pinned contracts and
their layered/sign SVG dependencies, invokes the existing worker validators,
checks file hashes and bounded private-path/credential patterns, and writes a
new external review candidate. It excludes historical `owner.json` files,
developer `reference-parents.json`, unreferenced files and pixel payloads.
`AUTHORED-INPUTS.json` distinguishes `owner_inclusion_authorized: true` from
`distribution_clearance: false` and `published: false`. Verification rejects
missing/extra/changed files, links, contract drift and false clearance labels.
This is a dependency-closure and safe-packaging check, not legal review, a full
secret audit, a new art-quality pass or fresh pixel reconstruction.

The dispatcher inventory still uses the historical
`requires_private_authored_inputs` flag for these seven families. Interpret it
as a requirement for the separate authored bundle, not an owner veto on
distribution. The source export alone still does not contain that bundle.

| Family | Selected entries | Source contract |
| --- | ---: | --- |
| Vectors | 31 | `reference/personal_vector_recipes.json` |
| Structural plates | 20 | `reference/personal_structural_plates.json` |
| Atlases | 6 | `reference/personal_atlas_recipes.json` |
| Facades | 7 | `reference/personal_facade_recipes.json` |
| Finite materials | 8 | `reference/personal_finite_recipes.json` |
| Layered atlases | 3 | `reference/personal_layered_atlas_recipes.json` |
| Painted signs | 3 | `reference/personal_sign_recipes.json` |

These counts were read from the actual `requires_private_authored_inputs` routes
in `tools/personal_texture_pipeline.py`, not inferred from file extensions.
The contracts identify required inputs; their private recipe/drawing bundles
are not added to the source export by completing a hash or pixel check.

This is a concrete public-release dependency, not a reason to discard or redo
the completed private outputs. Before claiming a disc-only public kit, resolve
the provenance and release treatment of these exact inputs. Any inputs kept
private must remain an explicit unmet dependency unless an independently
qualified source-derived reconstruction replaces them. Do not silently omit
these 78 entries, substitute different artwork, or treat a root-code licence
as permission for the separate input bundles. No publication has occurred and
no replacement decision has been made. The owner's inclusion approval above does
not grant rights to underlying game artwork or select a licence for it.

## Model weights are not source-code licences

Exact selected filenames and hashes remain in
`reference/personal_texture_recipes.json` and
`reference/personal_cinematic_recipes.json`. All five weights remain external;
none is cleared for inclusion in the source snapshot by this audit.

| Weight | Evidence inspected | Current treatment |
| --- | --- | --- |
| PBRify Upscaler V4 | Its named model release explicitly lists CC0 | Preserve release evidence and exact weight identity; no bundled weight |
| ArtCNN R16F96 | Project licence is MIT, Copyright 2024 Joao Chrisostomo | Project licence alone is not a reviewed selected-weight provenance chain |
| HDcube3 500k | Current project licence prohibits model redistribution without permission and claims no copyright in outputs | Do not bundle weights without permission; that output claim does not clear the game's underlying rights |
| Real-ESRGAN anime-6b | Project licence is BSD-3-Clause, Copyright 2021 Xintao Wang | Review selected v0.2.2.4 asset terms separately |
| Real-ESRGAN animevideov3 | Same project licence | Review selected v0.2.5.0 asset terms separately |

Primary evidence:

- https://github.com/Kim2091/Kim2091-Models/releases/tag/4x-PBRify_UpscalerV4
- https://github.com/Artoriuz/ArtCNN/blob/main/LICENSE
- https://github.com/Venomalia/HDcube/blob/main/LICENSE
- https://github.com/Venomalia/HDcube/releases/tag/3.0
- https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE

Current-branch licence pages are dated observations, not immutable evidence of
every historical release asset's terms. No permission request was sent and no
model-download policy was changed.

### Exact model acquisition identities — 16 October

`reference/personal_model_sources.json` now records direct official URLs, exact
filenames, lengths and hashes for the five selected weights. GitHub release
asset metadata was inspected, then each official file was streamed through
SHA-256 without saving another copy or deserializing a model. All five match
the existing texture/cinematic recipe hashes: **243,569,014 bytes** total.
The ArtCNN URL is pinned to commit
`e138cc15c0d9fb6ec04b86fc453f7faa30e2b5d3`; the four other files use named
upstream release assets. A release URL can still change, so byte identity is
mandatory. This verifies acquisition provenance, not underlying training-data
rights or model redistribution permission.

`tools/check_personal_models.py` is an offline, read-only preflight. It verifies
the acquisition table against both recipe contracts and checks each canonical
filename, size and hash before any inference. It neither downloads nor accepts
licences, and reports these boundaries explicitly. All five current local
weights passed. Seven synthetic tests cover missing/wrong/linked/nonregular
files, read-only operation and the exact catalog coverage.

## Installed Python dependencies

`tools/audit_personal_dependencies.py` inventories exact lock pins using installed
distribution metadata, without importing Torch, ONNX Runtime or other inference
libraries. It fingerprints recorded licence/notice files and labels missing
packages, mismatched versions and unreviewed notice text explicitly. It does not
install packages or treat metadata as legal clearance.

For example, in an already cached locked environment:

```sh
uv run --offline --no-project --python 3.14.7 --with-requirements requirements-personal.lock python tools/audit_personal_dependencies.py --lock requirements-personal.lock --output /private/dependency-inventory-base.json
```

Run the corresponding lock for each of the base, vectors, atlases, structural
and delivery environments. Use a fresh external output path; existing reports
are preserved. Re-run after lock or installed-wheel changes.
Python 3.14.7 is the interpreter used for this audit, not a claim of support for
every Python version. Explicit selection matters outside the checkout: a
different default interpreter can select an uncached wheel and fail offline.

The initial 15 October macOS audit matched every pin in all five environments: 21 base,
4 vector, 11 atlas, 3 structural and 4 delivery distributions, representing
**31 distinct packages**. The inventories fingerprinted **173 recorded notice
files** across those distinct packages. The evidence lives in the private
release work directory as `dependency-inventory-{base,vectors,atlases,structural,delivery}-v1.json`.
These counts describe this installed host, not every wheel/platform in the locks.

Notable follow-ups:

- FlatBuffers 25.12.19 and Spandrel 0.4.2 declare licence metadata but expose no
  notice file through the installed distribution listing. The later collection
  pass below obtains exact-version upstream texts for these two cases; it does
  not change the installed-wheel inventory or imply all upstream notices have
  been enumerated.
- CairoSVG declares LGPL-3.0-or-later. Do not describe all Python dependencies
  as MIT/BSD or decide binary-distribution obligations from a package list.
- NumPy and Torch declare multiple licences; their bundled/native notices need
  substantive review. The presence of a hashed notice is not that review.
- Missing `License-Expression` or legacy `License` fields are not an assertion
  of no licence: some packages instead provide classifiers and notice files.

### Collected notice-text evidence

The audit tool now supports optional `--notice-dir` collection. All selected
installed versions must match; every source notice is rehashed against the
inventory before a new external directory is created. Existing directories are
never replaced. The collector writes byte-verified copies and a
`NOTICE-RECEIPT.json`; copying a notice does not mark its terms reviewed.

```sh
uv run --offline --no-project --python 3.14.7 --with-requirements requirements-personal.lock python tools/audit_personal_dependencies.py --lock requirements-personal.lock --output /private/dependency-inventory-base.json --notice-dir /private/dependency-notices-base --fetch-missing-notices
```

Here `uv --offline` prevents package resolution downloads, while the explicit
`--fetch-missing-notices` flag authorises the tool to retrieve only the following
two small licence texts. Omit that flag for fully offline collection. The exact
version, size and SHA-256 must match; changed upstream text fails closed:

| Package | Version-tagged text | SHA-256 |
| --- | --- | --- |
| FlatBuffers 25.12.19 | https://raw.githubusercontent.com/google/flatbuffers/v25.12.19/LICENSE | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| Spandrel 0.4.2 | https://raw.githubusercontent.com/chaiNNer-org/spandrel/v0.4.2/LICENSE | `7458e7c247ac7470a4a892b7db02cd04f50cc105142561e28db1f5a7001d4fce` |

The FlatBuffers text is Apache-2.0. The Spandrel text is MIT and retains
Copyright 2024 The ChaiNNer Organization. The version-tagged URLs plus byte
hashes identify the observed texts, rather than trusting a mutable branch.

All five environments now have private `dependency-notices-*-v1` collections
and `dependency-inventory-*-v2.json` reports. Independent readback verified all
**275 copied files**, representing **175 distinct package/notice records**
(173 installed files plus the two upstream supplements) across **31 packages**.
There are no packages without a collected notice in this selected inventory.
Common packages are deliberately repeated in per-environment collections;
distinct texts total 769,142 bytes. No wheel, binary, model or game content was
copied into those collections. The notice texts are not currently exported in
the source snapshot; the reproducible collector and this evidence are included.

These results close the missing-text collection task, not the release-rights
gate. Full notice/exception review, bundled native-component obligations and
delivery-specific redistribution decisions remain separate.

The owner-approved root software licence is now present; no public repository
or signing identity was changed. Final clearance requires source/helper ownership review, exact
dependency/model/resource notices for the chosen delivery, original-game rights
boundaries, and explicit publication authority.
