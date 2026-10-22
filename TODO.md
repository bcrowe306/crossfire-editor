# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Common engine features (2026-10-21)

The features most 2D engines have that this one doesn't, as the user listed them. Items 1-10
(shaders deferred) were built one per dev release (2026-10-21/22), each with a user guide in
`docs/manual/`. The rest are being built now (decisions of 2026-10-22, below each item), one per
dev release, each tested, documented and removed from here when done.

4. **Shaders and post-processing**: custom fragment shaders on sprites and screen effects.
   Decided: a built-in effect library (hit flash, outline, dissolve, palette swap, CRT, bloom,
   color grading) shipped precompiled per platform, **plus** user-written shaders compiled with
   SDL_shadercross (a new dependency). SDL 3.4 runs them only on its "gpu" backend
   (`SDL_CreateGPURenderState`); other backends and the web fall back (no effect, or a CPU
   approximation where cheap).
11. **Hot reload of scripts**, more than one script per node, custom node types from game code.
12. **Asset import settings**: per-texture filtering and atlas packing, audio conversion,
    bitmap / MSDF fonts. Decided: audio conversion runs ffmpeg when it's installed; MSDF fonts
    with msdfgen built from source (a submodule, like Box2D and SDL); BMFont bitmap fonts too.
13. **Trails and lines**: trail renderers, line nodes (ropes, lasers), and GPU particles
    (decided: yes, on SDL_GPU, GPU backend only, the CPU emitter as the fallback).
15. **Skeletal animation**. Decided: the engine's own bones, skinned sprites and IK, edited in
    the editor and keyed with the Timeline, **plus** DragonBones JSON import (not Spine: its
    runtime license).
17. **A dialogue system**. Decided: an own dialogue asset with a graph editor (like the States
    tab) and a typewriter text box node, **plus** importing `.yarn` (Yarn Spinner) files into it.
18. **Touch input and virtual joysticks; Steam achievements and cloud saves.** Decided: touch
    and on-screen joysticks now; the Steam API (achievements, stats, cloud saves) with a stub
    backend until the Steamworks SDK is available. Mobile export targets: later (below).
19. **Editor plugins**: tool scripts, custom inspectors, import plugins. Decided: Odin packages
    in the project, built by the editor into a shared library against a plugin API, reloaded
    when they change.
20. **Local multiplayer**: players joining with a device, each player's own input actions and
    view (split screen exists). Online: not planned.

## Documentation

- **The user manual** (`docs/manual/`, started 2026-10-21): pages for the older features
  (scenes and nodes, scripts, physics, particles, sound, LDtk, Aseprite, components, export...).
  Decided (2026-10-22): written as one item now. **The docs will later become a static site
  built with Astro**: every page Markdown with YAML frontmatter (title, description, order),
  plain relative links, no GitHub-only syntax.

## Later (decided not to build yet)

- **Mobile export targets** (Android, iOS): Odin can target both (`-subtarget:android`,
  `-subtarget:iphone`); needs the Android SDK/NDK here and CI's Mac for iOS (decided
  2026-10-22: later).
- **Steam's real backend**: the Steamworks SDK (a partner download) behind the engine's Steam API
  (built with a stub in item 18).

## Builds and releases

- **macOS bundle signing and notarization**, deferred until the version 1 release (decided
  2026-10-20; the Apple developer account exists). Then CI's
  `combine-macos` signs with the Developer ID (a temporary keychain, hardened runtime,
  `entitlements.plist`) and notarizes and staples the disk image with `xcrun notarytool`,
  falling back to ad hoc without the secrets. The secrets come from a gitignored `.env`
  (`tools/macos/signing.env.example`, `tools/macos/set_signing_secrets.sh`).
