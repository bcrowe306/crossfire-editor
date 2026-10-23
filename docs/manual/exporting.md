---
title: Exporting your game
description: Turn your project into a game other people can run, on Linux, Windows, macOS or in a web browser, from Project Settings > Export, File > Export, or the command line.
order: 35
---

# Exporting your game

**Play** runs your game from the editor. **Exporting** makes the game on its own: a program (or a
web page) you can give to players, upload to itch.io, or put on a USB stick. They don't need the
editor, or anything else, to run it.

- [Exporting, step by step](#exporting-step-by-step)
- [The targets](#the-targets)
- [Each target's settings](#each-targets-settings)
- [What each target makes](#what-each-target-makes)
- [Which computer can export what](#which-computer-can-export-what)
- [Web exports](#web-exports)
- [Where exports go](#where-exports-go)
- [Exporting from the command line](#exporting-from-the-command-line)
- [Project archives are something else](#project-archives-are-something-else)
- [Questions](#questions)

## Exporting, step by step

1. **File > Project Settings...**, then the **Export** tab.
2. On the left, **tick** the targets you want (Linux x86_64, Web...). Click a target's name to
   see its settings on the right.
3. Change any settings (the defaults are fine to start with).
4. Press **Export** beside the target's name to export that one, or **Apply**, then **File >
   Export...** (Ctrl+Shift+E) to export every ticked target.

What happens:

- The project is saved first (scripts too), so the export is what you see.
- Each target is built in turn. The **Output** tab shows every step and what the tools print; the
  Console says "Exported ... to ..." for each one that worked, or why it failed. A failed target
  doesn't stop the others.
- You can keep working, and even Play, while it exports. **Cancel Export** (beside Export, while
  one runs) stops it.

File > Export with no target ticked opens the Export tab to choose some.

## The targets

The Export tab lists every target, grouped:

| Group | Targets | Can export now? |
|---|---|---|
| Desktop | Linux x86_64, Linux ARM64, Windows x86_64, Windows ARM64, macOS x86_64, macOS ARM64 | Yes (see [which computer](#which-computer-can-export-what)) |
| Web | Web (WebAssembly) | Yes, from any computer |
| Store | Steam | Not yet |
| Console | PlayStation 5, Xbox Series X\|S, Nintendo Switch | Not yet (they need the console makers' licensed tools) |

A target this computer can't export shows "(not implemented)" after its name, and its settings
say why. **x86_64** is most PCs and older Macs; **ARM64** is Apple Silicon Macs (M1 and later),
and some Windows and Linux laptops.

Under the target's name, a line says whether it's ready ("Ready to export from this machine.") or
what it needs.

## Each target's settings

| Setting | Targets | What it does |
|---|---|---|
| **Output folder** | All | Where the export goes: a folder inside the project (like `export/linux`) or anywhere else (a full path). Empty: `export/<target>` in the project, like `export/linux_x64` |
| **Executable** | Desktop | The game program's name. Empty: the project's name |
| **Page title** | Web | The browser tab's title. Empty: the project's name |
| **Optimize** | Desktop, Web | Builds a faster game; the build takes longer. On by default: leave it on for games you give out |
| **Bundle libraries** | Desktop | Puts the SDL3 libraries beside the game, so players don't need them installed. Only needed when the engine's SDL isn't built into games (Settings > Toolchain, "Static SDL") |
| **Single file** | Linux, Windows | Puts the project's scenes and assets inside the game program: the game is one file. Off: they go in a `data/` folder beside it. On by default |
| **Hide console** | Windows | No black console window beside the game |
| **Bundle ID** | macOS | The app's identifier, like `com.example.mygame`. Empty: `io.crossfire.<name>` |
| **Archive** | All | Also packs the export into one file beside its folder, ready to upload: `.tar.gz` (Linux, macOS) or `.zip` (Windows, Web) |

The settings are saved with the project, in `export.ini` beside `project.xml` (only once you
change something). Changing them is a step you can undo.

## What each target makes

| Target | What's in the output folder |
|---|---|
| **Linux** | The game program (named after **Executable**). With Single file off, a `data/` folder beside it; without the static SDL, a `lib/` folder with SDL's libraries |
| **Windows** | `<name>.exe`. With Single file off, `data/` beside it; without the static SDL, SDL's DLLs beside it |
| **macOS** | `<name>.app`, an app players double-click. The project's files are inside it (`Contents/Resources/data`), whatever Single file says |
| **Web** | `index.html`, `index.js`, `index.wasm` and `index.data`: the page, its code, the game and its files |

Players run the game from the folder (or the single file). Development-only settings are off in
exports: collision shapes (Project Settings > General > Show shapes) never show.

A Linux game runs on Linux systems as new as the one it was built on, or newer. Games made with
the prebuilt players from a release (below) run on Linux from about 2020 on.

## Which computer can export what

Desktop games are **compiled**: turned into a program by the Odin compiler. A compiler makes
programs for the computer it runs on, so:

- **A project with scripts** (`.odin` files in `scripts/`) exports for desktop only on that
  system: a Windows game on Windows, a macOS game on a Mac, a Linux game on Linux. It needs the
  Odin compiler and a linker (see [Settings and the toolchain](settings_and_toolchain.md)).
- **A project without scripts** needs no compiling: the editor copies a ready-made game program,
  the **prebuilt player**, and puts the project in it. Released editors carry prebuilt players for
  Linux x86_64, Windows x86_64 and macOS ARM64, so they export those three from any of them, with
  nothing to install.
- **Web** exports work from every computer. They always compile, so they need Odin, scripts or
  not, and Emscripten (below).

macOS games are signed (an ad hoc signature, which Apple Silicon Macs require) when exported on a
Mac. To give a macOS game to other people without warnings, it needs Apple's signing and
notarization, which the editor doesn't do yet.

## Web exports

A web export runs in a browser: put it on a website, or upload it to itch.io as an HTML game.

**Emscripten** turns the game into something browsers run. The first web export installs it
(about 1 GB, once; it needs **Python** on your computer): the Console says "The web export needs
Emscripten: installing it first (the export runs after)", and the export runs when it's done.
You can also install it ahead of time with **Edit > Settings > Toolchain > Install Emscripten**.

**Testing it:** a web game can't be opened by double-clicking `index.html` (browsers don't let a
page load its files from your disk). Serve the folder instead. With Python, in a terminal:

```sh
cd MyGame/export/web
python3 -m http.server
```

then open `http://localhost:8000` in a browser. The game fills the window, keeping its shape.

**For itch.io:** tick **Archive**; upload the `.zip` beside the output folder as an HTML game.

Things to know:

- **Sound starts after the player's first click or key press.** Browsers don't let pages play
  sound before that. Start your game on a title screen that waits for a key.
- **Images must be PNG or BMP** on the web. Other formats (JPEG, WebP...) show in desktop games
  but not in browsers.
- The renderer is always WebGL, whatever Project Settings > General > Renderer says.

## Where exports go

By default, into the project's `export/` folder: `export/linux_x64`, `export/windows_x64`,
`export/web`... An archive goes beside its folder (`export/web.zip`).

The `export/` folder isn't part of the project: Save Project As, project archives and Git leave
it out. You can delete it any time; exporting makes it again.

The **Output folder** can't be the project folder itself, or inside its `scenes/`, `assets/` or
`scripts/` folders: the export says so.

## Exporting from the command line

The editor can export without opening its window, for scripts and automatic builds:

```sh
crossfire-editor path/to/MyGame --export Linux_x64
```

The target is one of `Linux_x64`, `Linux_ARM64`, `Windows_x64`, `Windows_ARM64`, `macOS_x64`,
`macOS_ARM64` or `Web`. It uses the project's export settings (`export.ini`), prints each step
and what the tools print, and exits with 0 when the export worked, 1 when it didn't (with the
reason). A web export installs Emscripten first when it's missing.

Add `--settings path/to/editor.ini` to use particular editor settings (the Odin compiler's path,
for example).

## Project archives are something else

An export is the **game**, for players. A **project archive** (File > Export Project
Archive..., an `.odinsdl` file) is the **project**, for someone who'll open it in the editor. See
[Projects](projects.md#project-archives-the-project-in-one-file).

## Questions

**It says "No Odin compiler to build the game with".** The project has scripts (or it's a web
export), so the game has to be compiled. Install Odin with **Edit > Settings > Toolchain > Install
Odin**, or set the path to yours there.

**A project with scripts won't export for Windows from my Linux computer.** Games with scripts are
compiled on the system they're for. Export that target on a Windows computer (copy the project
there, or use a project archive).

**The exported game says it can't find SDL3, or a library.** Tick **Bundle libraries**, or build
the engine's static SDL so the game carries SDL inside it (Settings > Toolchain shows "Static
SDL").

**The web page is black, or says it can't load.** Serve the folder over HTTP (see [Testing
it](#web-exports)); opening `index.html` from your disk doesn't work.

**The web game has no sound.** Click in the page, or press a key: browsers start sound only then.

**An image is missing in the web version.** It's not a PNG or BMP. Convert it to PNG and choose
it again.

**Windows warns about the game when players open it.** Windows (SmartScreen) and macOS
(Gatekeeper) warn about programs that aren't signed with a paid certificate. Players can still
run it (Windows: More info > Run anyway; macOS: after the first try, System Settings > Privacy &
Security > Open Anyway).
