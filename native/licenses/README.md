# Native source attribution

The project owner's software licence is recorded in the root `LICENSE` and
`LICENSING.md`. The scoped upstream notices below remain intact; the root grant
does not claim ownership of third-party work or override its original notices.

## Audio

`native/src/ax_audio.c`, `native/src/ax_pb.c` and `native/src/ax_engine.c` adapt
audio arithmetic, voice layout and command behavior from the Dolphin Emulator
Project, commit `e6f3ae17627e4344da95b13424af5baf4c892b08`:

- `Source/Core/Core/DSP/DSPAccelerator.cpp`
- `Source/Core/Core/HW/DSPHLE/UCodes/AXVoice.h`
- `Source/Core/Core/HW/DSPHLE/UCodes/AXStructs.h`
- `Source/Core/Core/HW/DSPHLE/UCodes/AX.h`, `AX.cpp` and `AXWii.cpp`

These source files retain the upstream GPL-2.0-or-later designation. The license
text is in `Dolphin-GPL-2.0-or-later.txt`. Local changes add explicit C interfaces,
checked guest-memory access, title identification, bounded command parsing,
transactional voice decoding and silent PCM capture. This notice does not apply
a new license to unrelated existing project files.

No game samples, generated proprietary code or DSP coefficient binary are
included in this source directory. Development tests use external lawful inputs.

## CPU reciprocal estimates

The `ppc_fres_estimates` and `ppc_frsqrte_estimates` tables and reciprocal-estimate
arithmetic in `native/src/cpu.c` correspond to Dolphin's
`Source/Core/Common/FloatUtils.cpp`, Copyright 2018 Dolphin Emulator Project,
GPL-2.0-or-later. The audit compared the complete 32-entry tables and associated
algorithms against commit `e6f3ae17627e4344da95b13424af5baf4c892b08`:

https://github.com/dolphin-emu/dolphin/blob/e6f3ae17627e4344da95b13424af5baf4c892b08/Source/Core/Common/FloatUtils.cpp

The local implementation uses explicit C integer/bit helpers and checked result
pointers. This comparison identifies a matching upstream implementation; it
does not establish the historical route by which every CPU helper was authored.
The same tables also occur in the pinned DolRecomp CPU implementation, which
retains Dolphin attribution. The existing `Dolphin-GPL-2.0-or-later.txt` supplies the licence text for
these attributed portions; this is not a blanket licence for `cpu.c` or the
whole repository.

## DolRecomp-compatible CPU interfaces and helper correspondences

The 16 October review compared `native/src/cpu.c` and
`native/include/protector/cpu.h` with `src/cpu/cpu.c` and `src/cpu/cpu.h` at:

https://github.com/ExpansionPak/DolRecomp/tree/6f2336397ad9fde3743a63cf083776d18d38345c/src/cpu

Upstream `cpu.c` carries **Copyright (C) 2026 ExpansionPak** and
**SPDX-License-Identifier: GPL-3.0-or-later**. Preserve that attribution and
grant for corresponding adapted portions, including the matching CPU
reset/callback-preservation and host-call sequences and compatible interfaces.
The project's root `LICENSE` supplies GPL version 3. Dolphin-origin reciprocal
portions retain the distinct attribution above.

This is conservative acknowledgement of observed implementation/interface
correspondences, not a claim that every local helper was copied or that every
matching declaration is independently copyrightable. The local implementation
adds checked memory access, source-bound platform hooks and explicit runtime
failure handling. Comparison and local commit history do not establish a full
historical chain of authorship. See `docs/PUBLIC_RELEASE_PROVENANCE.md` for the
review's exact scope and remaining distribution decisions.
