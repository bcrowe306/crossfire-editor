# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Common engine features (2026-10-21)

The features most 2D engines have that this one doesn't, as the user listed them. The first ten
(shaders deferred) are being built one per dev release, in this order; each gets a user guide in
`docs/manual/`. Remove an item here once it's built.

4. **Shaders and post-processing** (deferred by the user): custom fragment shaders on sprites
   (hit flash, outline, dissolve, palette swap) and screen effects (CRT, bloom, grading). Check
   what SDL's GPU renderer allows first, across platforms and the web; the software renderer
   can't run them.
10. **Parallax and camera tools**: parallax backgrounds outside LDtk, camera limit zones and
    rooms, smooth zoom, multiple viewports (split screen, minimaps, picture in picture).
11. **Hot reload of scripts**, more than one script per node, custom node types from game code.
12. **Asset import settings**: per-texture filtering and atlas packing, audio conversion,
    bitmap / MSDF fonts.
13. **Trails and lines**: trail renderers, line nodes (ropes, lasers); GPU particles maybe.
14. **Collision from sprites** (polygons from an image's alpha) and shared physics materials.
15. **Skeletal animation**: Spine / DragonBones import, or simple bones and IK.
16. **Audio effects** on buses (reverb, low-pass, echo), music crossfades, adaptive layers.
17. **A dialogue system**: branching dialogue data and a typewriter text box (Yarn / Ink style).
18. **More platforms**: Android, iOS, touch input and virtual joysticks; Steam achievements and
    cloud saves.
19. **Editor plugins**: tool scripts running in the editor, custom inspectors, import plugins.
20. **Multiplayer**: local multiplayer helpers; online later, maybe.

## Documentation

- **The user manual** (`docs/manual/`, started 2026-10-21 with the features above): published
  with the API docs on GitHub Pages and opened from the editor (Help > Manual: the page for
  what's selected). Older features still need their pages (scenes, nodes, scripts, physics,
  particles, sound, LDtk, Aseprite, components, export...).

## Editor viewport

- **Skald GPU rendering for the viewport** (the user's question, 2026-10-21): the engine draws
  with SDL's renderer into a hidden window's texture, read back and uploaded to Skald (~0.6 ms an
  upload fullscreen). A viewport that renders continuously (animations, particles, scripts
  always live) needs measuring first: the readback stalls the GPU each frame, and the editor
  otherwise draws only when something changes. Options: keep the round trip with a "live" toggle
  and a frame cap, paused when unfocused; or let Skald draw the engine's frames itself (a
  textured-quad API, or Vulkan interop with SDL's GPU renderer). Ask before changing Skald.

## Builds and releases

- **macOS bundle signing and notarization**, deferred until the version 1 release (decided
  2026-10-20; the Apple developer account exists). Then CI's
  `combine-macos` signs with the Developer ID (a temporary keychain, hardened runtime,
  `entitlements.plist`) and notarizes and staples the disk image with `xcrun notarytool`,
  falling back to ad hoc without the secrets. The secrets come from a gitignored `.env`
  (`tools/macos/signing.env.example`, `tools/macos/set_signing_secrets.sh`).
