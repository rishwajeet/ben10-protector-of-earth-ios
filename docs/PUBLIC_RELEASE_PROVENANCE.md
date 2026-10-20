# Public-release provenance decision record

Reviewed 16 October 2026. **Technical provenance triage complete for the selected
source/artwork candidates; public distribution is not cleared.** This is an
evidence-based engineering review, not a legal opinion or an exhaustive guarantee
of authorship. No permission request, publication or model redistribution occurred.

## Exact scope

Baseline: `source-export-v29`, 304 exported files / 9,344,517 bytes, from the
explicit source allowlist; `authored-inputs-release-candidate-v1`, 77 files /
8,079,894 bytes, covering 78 selected texture entries. The build guide appears
twice in the export, so there are 303 distinct source paths. The follow-up source
export adds this report and the scoped attribution/review updates; its identity
is recorded in the private implementation handoff.

The review inspected the allowlist and source attribution/reference markers,
focused runtime/helper and parser implementations, local CPU introduction
history, the pinned DolRecomp CPU source, all authored-file hashes and XML/JSON
structure, all SVG titles/descriptions, recipe dependency mappings, collected
dependency inventories and selected substantive licence texts, and upstream
licences/resources. It did not establish independent authorship for every line
of project code, perform a whole-Internet similarity search, obtain contributor
assignments, or substantively adjudicate all 175 collected dependency notices.
Those are not claimed as completed checks.

Private evidence in the unchanged release workspace:

- `authored-provenance-review-v1.json`: all 77 exact paths, hashes, origin classes,
  embedded SVG origin metadata and selected-entry mappings. No unmapped file.
- `AUTHORED-INPUTS.json` in the staged bundle: original approval/clearance flags,
  unchanged. All 77 hashes were independently rechecked for this review.
- Prior `dependency-inventory-*-v2.json` and `dependency-notices-*-v1/`: exact
  installed-host records, not a new all-platform binary clearance.
- `source-export-v29/EXPORT-RECEIPT.json`: exact source inventory reviewed.

## 1. Source findings

| Surface | Observed origin / evidence | Review disposition |
| --- | --- | --- |
| Original runtime, Apple shell, tools and synthetic tests | Project code and local history; original-software grant in `LICENSING.md`. Source filtering excludes complete translated chunks, binaries and game media. | Owner GPL-3.0-or-later grant is present. No new incompatible licence was identified in the focused review. This is not independent proof of every contributor's ownership. |
| Dolphin AX audio | `native/src/ax_audio.c`, `ax_pb.c`, `ax_engine.c` explicitly retain Dolphin copyright and GPL-2.0-or-later headers; matching text and pinned source links are retained. | Known attribution and licence are recorded. Keep these notices; do not relabel them as solely project-owned. |
| CPU reciprocal estimates | `native/src/cpu.c` explicitly maps its estimate tables/arithmetic to Dolphin `Common/FloatUtils.cpp`; scoped notice already present. | Known Dolphin-origin notice remains. The existence of common hardware constants alone is not an ownership finding. |
| DolRecomp-compatible CPU interface/reset/host-call code | Local `cpu.c` and `cpu.h` compared to pinned DolRecomp `src/cpu/cpu.{c,h}`. Matching reset/callback sequences and ABI declarations exist, beyond the already identified reciprocal tables. Upstream CPU implementation carries Copyright (C) 2026 ExpansionPak and GPL-3.0-or-later. | Added a conservative scoped upstream acknowledgement in `native/licenses/README.md`. No claim of independent ownership over corresponding upstream portions. Compatible licensing path identified; similarity does not establish the complete historical copying route. |
| Title-specific hooks and format parsers | `tools/build_native_entry.py` patches locally generated external chunks. `protector_native/bigb.py` expressly derives grammar from the title's loader. `tools/audit_bigb.py` cites barncastle's R4S observations; `protector_native/cinematics.py` cross-checks Bink header fields against FFmpeg. | These are not a shipped complete game translation. Keep factual-format/interoperability observations distinct from permission to copy an implementation. Their reverse-engineering/distribution treatment belongs in the legal review below. |
| Scene antialiasing | `native/metal/scene_antialias.h` cites Timothy Lottes' 2011 NVIDIA FXAA paper and states an independently expressed Metal method. The implementation omits the paper's low-pass/subpixel blend and uses its own bounded search. | Reference is recorded, not evidence of an imported NVIDIA SDK file. The independent-expression comment is an author claim, not external certification. Preserve it; do not invent an NVIDIA redistribution grant. |
| Native touch/control artwork | `native/ios/control_art.h` and `native/apple/action_glyphs.h` contain procedural paths. The control-art header describes original drawings and a plain diamond rather than the show's mark. | Separate from the traced source-HUD SVG bundle. No embedded raster or external font asset is supplied by these headers. Treat original-authorship claims as project provenance, not a trademark clearance. |

Local CPU files first appear in commit
`471adfd728b1c32da7f1af982337f93e1c9fcc94`; later reciprocal-estimate work appears
in `b7e2c4e`. Commit authorship shows the local introduction, not proof of legal
ownership. Token comparison exposed ABI/reset/host-call correspondences; a
negative long-line comparison was not used as proof that code was original.

The GPL-2.0-**or-later** designation matters: this is not a GPL-2.0-only dependency
being silently combined with GPLv3. Preserve upstream notices and applicable
terms. Compiler output does not become freely redistributable just because its
generator is GPL; input-derived game translation remains outside the public kit.
See the [GNU licence FAQ](https://www.gnu.org/licenses/gpl-faq.en.html).

## 2. Artwork findings: “authored” does not mean independently owned

All 36 SVGs are vector-only in the inspected XML: no `<image>`, `<script>`,
`<foreignObject>`, `<text>` or external href was found. That is a packaging fact,
not rights clearance. Vector paths can reproduce the original work.

| Technical class | Files | Evidence and release treatment |
| --- | ---: | --- |
| Explicit source-font-atlas traces | 3 SVG | Embedded metadata says source-alpha glyph-atlas contour reconstruction. These are precomputed source-shaped assets, not just general rasterization code. Hold pending rights treatment or qualified local reconstruction. |
| Explicit source-coverage traces | 6 SVG | Embedded metadata says threshold-128 green-coverage contour fit, with source keys and vtracer parameters. Same hold. |
| Source-contour redraws with new shading | 4 SVG | Descriptions explicitly retain a contour derived from the pinned source plane while adding shading. New shading does not establish rights in the underlying contour. Same hold. |
| Source-coordinate HUD redraws | 8 SVG | Titles/descriptions identify health/energy fills, frames and Omnitrix faces/housings. They range from simple fills to recognisable source-specific designs; not all have the same legal risk. No blanket clearance inferred. |
| Source-bound atlas drawings | 12 SVG | Six direct atlas inputs plus six layered-atlas dependencies. Contract identity is clear, but no embedded independent-origin metadata establishes rights. Includes simple shapes and more detailed source layouts. |
| Hand-drawn lettering in source layouts | 3 SVG | Explicit path-based lettering; no font file or live text dependency. This does not by itself clear the composite game sign or layout. |
| Source-bound procedural recipes | 41 JSON | 20 structural, 7 facade, 8 finite-material, 3 layered-atlas and 3 sign recipes. These encode geometry, sample regions and composition instructions; some may be functional/generic, but that must not be inferred for all from their JSON format. |

The exact three font-atlas filenames begin `5aee2d281325`, `60f11d6034ee`,
and `fda010459519`; their embedded source keys are respectively
`256x512-011e4572640c9b41459963c6c9884dc724e0bf94a9836ad76651755ab1edc05d`,
`256x512-7f1c5d69d0069b594140d68077b3327041f518ef8af8975c07de443b1e421faa`,
and `256x128-56f6ec5f00c6592c7c4cb608d6e396952ae3cc7ed13ae934fff347e6c3b8ac16`.
The six coverage-trace filename prefixes are `2f704fa5da21`, `3b51d0ac3e41`,
`6356bd0eefc2`, `8d29bbe593ba`, `995c57f8d174` and `a5e192918a9b`.
Full paths/hashes and all 78 dependencies are in the private machine-readable
inventory. The 13 explicit trace/contour cases are the strongest direct evidence,
not a declaration that all other inputs are legally safe or legally infringing.

No underlying-rightsholder permission or transferable artwork licence was found
in the selected bundle/contracts. Owner inclusion approval is present, but the
root software grant expressly excludes this artwork. Two distinct questions
remain: permission or other lawful basis for the underlying expression, and the
licence for any new contributions that the project can actually license.

The [US Copyright Office's derivative-work guidance](https://copyright.gov/circs/circ14.pdf)
explains why rights in new additions do not automatically extend to preexisting
material. This is context, not a ruling on this project or every jurisdiction.
Public availability, noncommercial intent, a disc requirement and vectorization
are not treated here as automatic clearance.

## 3. Dependencies: blockers must match what is distributed

The selected public delivery is source/tools plus separately reviewed inputs,
not a bundled Python environment, weight mirror, app binary or content pack.
The 31 pinned Python distributions, their native wheel components, FFmpeg,
Cairo, nodtool, astcenc and model weights are external preparation dependencies.
Do not confuse their presence on this development Mac with inclusion in GitHub.

- Existing inventories cover 175 distinct collected package/notice records.
  This review read selected multi-licence/unclear-metadata texts, including
  NumPy's native-library notice, Torch's notice collection entry points,
  CairoSVG's LGPLv3 text, resvg-py's MIT grant and OpenEXR's BSD-3-Clause text.
  It did **not** certify all native components of every possible wheel.
- Under the current unbundled source-kit scope, an exhaustive binary-notice
  clearance is not a prerequisite created merely by importing those packages.
  If a standalone converter, wheel cache or environment is later redistributed,
  its actual binaries, notices, source/relinking obligations and exceptions need
  a separate packaging review. That would be a changed release scope.
- The pinned Dolphin `dsp_coef.bin` resource has documented free-replacement
  provenance: the upstream readme identifies coefficient generation and the
  adjacent generator constructs FIR coefficients with explicit GBA adjustments.
  It is downloaded from upstream, not shipped in the source export. This closes
  the question of whether the selected download is simply a requested console
  ROM dump; it is not a blanket clearance for distributing a generated IPA.
- Model identities are hash-pinned and local. PBRify V4's exact release labels
  the model CC0. ArtCNN's pinned commit has an MIT licence. Both selected
  Real-ESRGAN tags retain BSD-3-Clause. These identify upstream declarations,
  not a training-data-rights warranty.
- HDcube is the concrete no-redistribution exception: its current model licence
  forbids redistribution without permission. The historical 3.0 tag resolves to
  `d1f318cc91713b0a9bca0cefcafe997b66a7d542`; no `LICENSE` was found at that tag,
  so the current licence must not be represented as a historical tagged grant.
  Keep manual official acquisition and no bundled/mirrored weights. No author
  permission is needed merely to avoid redistributing it; permission is needed
  before changing that policy. Model-output statements do not clear game rights.

Primary upstream evidence checked:

- [Dolphin free-DSP readme](https://raw.githubusercontent.com/dolphin-emu/dolphin/e6f3ae17627e4344da95b13424af5baf4c892b08/docs/DSP/free_dsp_rom/dsp_rom_readme.txt)
- [Dolphin coefficient generator](https://raw.githubusercontent.com/dolphin-emu/dolphin/e6f3ae17627e4344da95b13424af5baf4c892b08/docs/DSP/free_dsp_rom/generate_coefs.py)
- [PBRify V4 release](https://github.com/Kim2091/Kim2091-Models/releases/tag/4x-PBRify_UpscalerV4)
- [ArtCNN pinned licence](https://raw.githubusercontent.com/Artoriuz/ArtCNN/e138cc15c0d9fb6ec04b86fc453f7faa30e2b5d3/LICENSE)
- [Real-ESRGAN v0.2.2.4 licence](https://raw.githubusercontent.com/xinntao/Real-ESRGAN/v0.2.2.4/LICENSE)
- [Real-ESRGAN v0.2.5.0 licence](https://raw.githubusercontent.com/xinntao/Real-ESRGAN/v0.2.5.0/LICENSE)
- [HDcube current model licence](https://raw.githubusercontent.com/Venomalia/HDcube/main/LICENSE)
- [HDcube 3.0 README](https://raw.githubusercontent.com/Venomalia/HDcube/d1f318cc91713b0a9bca0cefcafe997b66a7d542/README.md)
- [NVIDIA FXAA paper](https://developer.download.nvidia.com/assets/gamedev/files/sdk/11/FXAA_WhitePaper.pdf)
- [Barncastle R4S research](https://gist.github.com/barncastle/c418ab984e7588f43a453eeb10a038f0)

## 4. Exact remaining public-release decisions

| ID | Blocking question | Closure evidence / action |
| --- | --- | --- |
| ART-1 | May the source-derived authored bundle be distributed? | A documented rights basis for the actual files, reviewed by qualified counsel where needed; or an explicitly selected alternative that reconstructs the affected inputs locally from the user's dump and passes exact-output qualification. Neither occurred. Do not silently drop the 78 entries. |
| ART-2 | What licence covers the project's new artwork/recipe contributions? | Select an appropriate grant after ART-1 and ownership scope are established. Existing code GPL approval does not answer this. A new licence alone cannot cure underlying rights. |
| LEGAL-1 | Is the selected reverse-engineered converter/source distribution and public presentation acceptable for the intended jurisdictions? | Qualified review of actual code/artwork boundaries, game/EULA/anti-circumvention issues where applicable, and branding/affiliation claims. No finding of infringement or legality is made here; do not substitute a generic disclaimer for this decision. |
| ACCEPT-1 | Does the personal build work acceptably on the user's phone? | The newly authorized phone setup/test phase must record signing, install, exact content import, bounded user gameplay/visual acceptance, save/lifecycle/update/refresh and, after permission, listening. Installation alone is not acceptance. See the live phone handoff, not this static audit, for progress. |
| PUB-1 | Is the exact final release approved and clean? | Explicit publication authority plus final reviewed allowlist/source/artwork hashes, notices and release copy. Publish a new clean export, not the dirty checkout/history; never attach the game IPA/PNC. |

Known GPL notice gaps and model acquisition identity questions are now narrowed
to the evidence above; do not retain a vague demand to “audit all dependencies”
as though every external package were being shipped. Conversely, this technical
review cannot create absent artwork rights or independently certify all source
ownership. If contributor/third-party copying evidence emerges, reopen only
that exact file and grant, not the completed runtime/campaign QA.

No runtime code, game assets, model weights or authored-input bytes were changed
by this review. The original large workspace stays in place by user decision.
