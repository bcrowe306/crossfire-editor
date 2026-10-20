# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Builds and releases

- **macOS bundle signing and notarization** with gon (`brew install mitchellh/gon/gon`, a
  checked-in `.json` config), once an Apple developer account is available: `task
  macos:notarize`, `tools/macos/gon.json.example`, `entitlements.plist`.
- A disk image background (the volume and app have the Crossfire icon).
- **Linux and Windows bundles** the same way: Taskfile.linux.yml (an AppImage?) and
  Taskfile.windows.yml (an installer?), with CI calling them as it does for macOS.
- **Prebuilt players for every platform** in every release archive (each archive has only its
  own platform's today; enough while exports only build for the host).
- **The zig experiment**: one linker everywhere, and Linux builds against an old glibc (a build
  made on this Arch machine needs GLIBC 2.43).
