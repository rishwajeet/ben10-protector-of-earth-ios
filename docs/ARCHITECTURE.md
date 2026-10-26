# Architecture

This port runs *Ben 10: Protector of Earth* (Wii, USA `RBNEG9` revision 0) as a
native iPhone app. The game's own code decides everything that happens in play;
the project supplies the machine it expects and upgrades how the result is
presented. Nothing interprets PowerPC instructions at runtime.

## The two outputs

The player's Mac turns their disc into two things that meet only on the phone.

| Output | Contains | Made by |
| --- | --- | --- |
| The app (`.ipa`) | The recompiled game code, the runtime, the renderer and the iOS shell | `tools/personal_build.py` |
| The content package (`.pnc`, about 10 GB) | The game's data files, restored textures, refined models and restored cutscenes | `tools/package_personal_content.py` |

Keeping them apart means a code update or a weekly re-sign replaces only the
app. The imported content and saves stay in the app's container.

## Recompiled code

`personal_build.py prepare` extracts the disc with
[nod](https://github.com/encounter/nod), checks every file against the hashes
in `reference/personal_build_inputs.json`, and runs
[DolRecomp](https://github.com/ExpansionPak/DolRecomp) on the main executable.
The result is about 4.7 million lines of C in 120 files, plus a header
describing the guest memory map. It stays in the player's work folder and never
enters this repository.

Translated functions operate on a `CPUState` (`native/include/protector/cpu.h`):
PowerPC registers, condition and floating-point state, and guest memory. Guest
memory accesses are inlined in the generated code. `native/src/cpu.c` supplies
the instruction semantics that the generated code calls out to, such as
floating-point estimates, which follow Dolphin's.

`tools/build_native_entry.py` inserts a host call at 84 translated addresses.
These hooks mark the points where native code takes part: controller updates,
the logical update and frame-delta writes that drive pacing, the end of the
render loop, and visibility tests. The executable's hash and the generated
header's hash are checked first, so a different executable is refused before
any hook is placed.

`native/src/boot.c` and `native/src/dol_loader.c` set up memory the way the
Wii's system software leaves it for a game, load the executable's sections and
start the translated entry point.

## Runtime

| Area | Files | Role |
| --- | --- | --- |
| Disc and files | `native/src/platform.c` | Mounts the extracted disc and serves the game's file reads from the content package |
| Timing | `native/src/guest_pacer.c`, `motion_clock.c` | Ties the game's timebase to wall-clock time, re-anchoring after a stall instead of racing to catch up |
| Audio | `native/src/ax*.c`, `native/apple/audio_output.mm` | Runs the game's AX mixing (adapted from Dolphin, GPL-2.0-or-later) and feeds Core Audio. Uses Dolphin's free replacement DSP coefficient table |
| Input | `native/src/live_input.c`, `touch_layout.c`, `native/ios/` | Presents touch controls and game controllers to the game as its original controller, with motion gestures mapped to buttons |
| Saves | `native/src/save_store.c`, `native/apple/save_backup.mm` | Stores the game's save data atomically, with backup and restore from the start screen |
| Session | `native/apple/game_session.mm` | Runs the translated game on its own thread and coordinates it with rendering |

## Graphics

`native/src/live_gx.c` captures the GX command stream each frame and
`native/metal/live_gx_renderer.mm` turns it into Metal. That covers vertex
formats and transforms, TEV colour-combiner stages, blending and depth, and EFB
copies, the framebuffer captures the game uses for shadows, blur and screen
effects. Common TEV configurations get specialised shaders.

Upgrades on top of the original output:

- **Resolution.** Each axis renders at a whole multiple of the Wii's 640×448,
  chosen to sit just under the phone's display, so copies, viewports and
  shadow windows scale by whole numbers. On an iPhone 18 Pro that is 2560×1344.
- **Widescreen.** The Wii's framebuffer is anamorphic. The 3D projection is
  widened to the screen's aspect, and 2D draws are classified so the HUD, menus
  and full-screen effects keep their intended shape and placement.
- **Antialiasing.** `native/metal/scene_antialias.h` applies an edge-only pass
  based on the method in NVIDIA's FXAA paper, without its subpixel blur, so
  painted textures and ink lines stay sharp.
- **60 fps.** The game updates at 30 Hz. Between two real frames, the renderer
  matches each draw to its counterpart in the next frame (same geometry,
  material and textures) and draws its vertices partway between the two.
  Unmatched draws are shown as they are. No image is blended and no future pose
  is predicted. In heavy scenes the presentation steps down to a steady 30.

Replacement content is looked up by the identity of the original data, not by
position. `native/metal/texture_pack.mm` swaps a texture only when its decoded
source pixels match a restored entry's source hash, and
`geometry_pack.mm` swaps a model only when its index data, vertex format and
anchor hashes match exactly. Anything unmatched renders as original.
`cinematic_pack.mm` plays restored cutscenes through AVFoundation in place of the
game's Bink movies, on the game's own timing.

## Restoration pipeline

All of it runs on the player's Mac from their own disc. The repository holds
recipes, hashes and code; the release's artwork bundle adds 77 redrawn and
traced textures and their recipes.

- **Textures.** 2,221 textures, routed by recipe: 1,406 upscaled by the pinned
  models (Real-ESRGAN, PBRify, ArtCNN, HDcube), 590 rebuilt by deterministic
  source operations, and the rest from grids, thumbnails, pairs and the
  artwork bundle's vectors, plates, signs and atlases. They are compressed to ASTC and
  assembled into one pack.
- **Cutscenes.** All 76 movies are restored from 640×480 to 2880×2160 at their
  original timing with two Real-ESRGAN models, then encoded with VideoToolbox.
- **Models.** `tools/personal_geometry.py` rebuilds 194 model profiles from the
  disc. `protector_native/geometry_refinement.py` adds points to their
  silhouettes, each a fixed weighted mix of original vertices, so the game's own
  skinning and animation still deform them. Creases and open edges stay as they
  were.

Every stage checks its inputs and outputs. Deterministic stages must reproduce
the recorded hash exactly. Model inference rounds differently on every Mac, so
those outputs are checked against the player's own source textures instead:
`reference/personal_texture_fingerprints.json` records, per region, how far the
output sits from the original pixels and how much detail it added, and an
output must land within rounding distance of the reviewed one.
`docs/PERSONAL_BUILD_KIT.md` describes each tool and its checks.

## App shell

`native/ios/interactive_main.mm` is a UIKit and MetalKit app. It hosts the
renderer, the touch controls and controller support (GameController), and the
start screen, which handles content import, save backups and the About sheet.
`native/ios/content_import.mm` verifies the content package before activating
it, and an interrupted import leaves the previous content in place.

## Verification and limits

- Every main level has been spot-checked. The fort, the canyon and the final
  boss have been played on an iPhone 18 Pro. That is sampled coverage, not a
  full campaign pass.
- The full conversion has run on one Mac (M4 Pro, macOS 27, Xcode 27). The
  texture fingerprints were calibrated by rebuilding textures with different
  inference settings on that Mac, not yet on a second one.
- iPhone only. Older iPhones are untested.
- Physical performance was measured on one phone: the heavy fort fight held
  60 fps for 86 seconds at a nominal thermal state; the heaviest GPU scenes step
  down to 30.

## Credits

The recompiler is DolRecomp by ExpansionPak (GPL-3.0-or-later). AX audio
mixing and floating-point estimate tables are adapted from Dolphin
(GPL-2.0-or-later). Disc extraction uses nod, texture compression uses
astcenc, and the restoration models are listed with their sources and licences
in the README. See `LICENSING.md` and `native/licenses/` for notices.
