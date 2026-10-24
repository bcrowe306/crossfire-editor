---
title: Settings and the toolchain
description: Change how the editor looks (a live theme editor) and behaves, rebind its shortcuts, check and install the tools that build your games, and find your way around Project Settings.
order: 38
---

# Settings and the toolchain

There are two kinds of settings:

- **The editor's settings** (**Edit > Settings...**, Ctrl+,): how the editor looks and behaves
  for you, on this computer, whatever project is open. Its theme, text size, shortcuts, code
  editor, the tools it builds games with.
- **Project Settings** (**File > Project Settings...**): the game's own settings, saved with the
  project, so everyone working on it gets the same: its name, screen size, start scene, input
  actions, export targets.

- [The Settings dialog](#the-settings-dialog)
- [Appearance](#appearance)
- [Editor](#editor)
- [Keyboard: changing shortcuts](#keyboard-changing-shortcuts)
- [Toolchain: what building games needs](#toolchain-what-building-games-needs)
- [Project](#project)
- [Where the settings are saved](#where-the-settings-are-saved)
- [Project Settings](#project-settings)
- [Questions](#questions)

## The Settings dialog

**Edit > Settings...** (Ctrl+,) opens it, with five tabs: **Appearance**, **Editor**,
**Keyboard**, **Toolchain** and **Project**. Hover over a setting's name to see what it does.

The buttons at the bottom:

| Button | What it does |
|---|---|
| **Reset to Defaults** | Puts the open tab's settings back to how they came (not on the Project tab) |
| **Cancel** | Closes, dropping your changes |
| **Apply** | Uses the changes and saves them, keeping the dialog open |
| **Save** | Uses the changes, saves them and closes |

## Appearance

This tab is the editor's **theme editor**: everything on it shows **at once**, while you change
it, so you see the result before keeping it. **Apply** or **Save** keeps the look (in your
`editor.ini`); **Cancel** puts the old one back.

| Setting | Default | What it does |
|---|---|---|
| **Preset** | Dark | A ready-made look: Dark, Light, Midnight (deep blue), Graphite (gray with an orange accent), High Contrast, Paper (warm light). Choosing one replaces the colors; change any of them after (the dropdown then says Custom) |
| **Theme** | Dark | The base: Dark or Light. The colors you haven't set are its |
| **Text size** | 13 px | The size of the editor's text; headings and small text grow with it |
| **Spacing** | 75% | The room around and between controls (more for a roomy look, less to fit more) |
| **Row height** | 26 px | Rows in the project browser and the scene tree (this one shows when you press Apply or Save) |
| **Corners** | 100% | How round corners are: 0 square, 100 standard, more for rounder |

**Colors:** every color of the theme has a row. Click its swatch to pick a new one (a color wheel,
values, or a hex code like `#E8833A`); the ↶ beside a color you've set puts the base theme's back.

| Color | Where it shows |
|---|---|
| **Window background** | Behind every panel |
| **Panels** | Panels, sidebars and buttons |
| **Popups** | Menus, dropdowns, tooltips and dialogs |
| **Borders** | The lines between panels and around fields |
| **Main text**, **Muted text** | Most text; captions, hints and placeholders |
| **Accent**, **Text on accent** | Selected and focused things, primary buttons; the text on them |
| **Selection** | Behind selected text and rows (**Selection opacity** sets how see-through) |
| **Success**, **Warning**, **Danger** | Things that worked, warnings, errors |

The colors you set are saved in `editor.ini`'s `[theme]` section, one line each (`bg = #1B1B1B`,
`selection = #E8833A50`), with `corner_radius`. The code editor has its own colors: see
[The code editor](code_editor.md#keymaps-and-themes).

## Editor

**Undo:**

| Setting | Default | What it does |
|---|---|---|
| **Merge edits within** | 500 ms | Changes to the same thing closer together than this undo as one step (typing a name, dragging a number, nudging with the arrow keys) |
| **Longest merged edit** | 3000 ms | A long run of merged changes is still cut into steps this long (0: never cut) |
| **Undo steps kept** | 200 | How far back Undo goes; the oldest steps are dropped |

**Console:** **Console lines kept** (5000) is how many lines the Console and the Output tab each
keep; past it the oldest go. See [the Console](getting_started.md#the-console-and-output-tabs).

**Viewport:** the grid belongs to the project (Project Settings > Grid). **Wheel pans** (off by
default) makes the mouse wheel move the view and Ctrl + wheel zoom: nicer on a touchpad.
**Rotation snap** (15°) and **Scale snap** (0.1) are the steps Rotate and Scale drags snap to,
with snapping on or Shift held.

**Scripts:**

| Setting | Default | What it does |
|---|---|---|
| **Code editor** | On | Use the built-in code editor (tabs next to the scenes). Off: scripts open in the external program |
| **Auto-close** | On | Close brackets and quotes as you type, in the code editor |
| **Language server** | Found automatically | The Odin language server (OLS) for completion and error checking: a path, or a name in your PATH. The line under it says which one is used |
| **LDtk program** | `ldtk` | The level editor that **Open in LDtk** starts |
| **Aseprite program** | `aseprite` | The pixel art editor that **Open in Aseprite** starts |
| **External program** | `zed` | The code editor scripts open in when the built-in one is off (**Browse...** picks it) |
| **Arguments** | `{folder} {file}:{line}` | What the external program is given |
| **Optimized Play** | Off | Builds the game for Play with optimizations: a faster game, but about 50 s per build instead of 4. Exports have their own Optimize setting |
| **Hot reload** | On | Saving a script while the game plays rebuilds it and restarts the game where it was |
| **Audio device** | System default | Where Play's game and the editor's sound previews play |

More about these: [The code editor](code_editor.md) (the code editor, the language server, the
external program), [Hot reload](scripts_node_types_hot_reload.md#hot-reload-changing-scripts-while-the-game-plays).

## Keyboard: changing shortcuts

The Keyboard tab lists every action with up to **two** shortcuts each. **Help > Keyboard
Shortcuts** opens it too.

- **Find one:** type in **Search actions and shortcuts**, by the action's name ("zoom") or by
  its keys ("ctrl+shift").
- **Change one:** click the shortcut (or the **-** of an empty slot). It says "Press keys...":
  press the new keys, with Ctrl, Shift, Alt or Super held as you want them. **Escape** cancels.
- **Remove one:** click it, then **Clear** (beside the help text) while it waits for keys.
- **Put a row back:** the ↶ button at the row's end.

If a shortcut is also used by another action, a yellow line under it says so ("Ctrl+D is also
Duplicate node"). That's allowed, but only one of them works: the one higher in the list.

**On a Mac, Cmd takes Ctrl's place.** Every shortcut written with Ctrl here and in the rest of
this manual is Cmd on macOS (Save is Cmd+S, Undo Cmd+Z), and the editor shows it that way: in
menus, tooltips and this tab, where Alt is called Option. Cmd+click selects several nodes, as
Ctrl+click does elsewhere. The settings file stores shortcuts the same way on every computer
("Ctrl+S" means Cmd+S on a Mac), so one `editor.ini` works on all of them; a shortcut that should
use the Mac's Control key is written with Super.

Menus and tooltips always show your shortcuts. A few things to know:

- Single keys (Q, W, G, Delete...) don't work while you type in a text field, so you can type
  those letters.
- While you type in the built-in code editor, only a few shortcuts reach the editor (save, play,
  build, export...): see [The code editor](code_editor.md#which-shortcuts-work-while-you-type-code).
  The code editor's own shortcuts are changed in its Keymap Editor, not here.

## Toolchain: what building games needs

**Play** and **Export** turn your project into a game program. The Toolchain tab lists every tool
that takes part, with a green ✓ when it's found (and where) or a red ✗ when it's missing (and how
to get it):

| Row | What it's for |
|---|---|
| **Odin compiler** | Builds games that have scripts. The engine uses Odin `dev-2026-10` |
| **Engine sources** | The engine your games are built from. Released editors carry it (an `engine/` folder beside the editor) |
| **Linker (clang)** or **Linker (Visual Studio)** | Odin needs it to make programs: clang on Linux, Xcode's command line tools on macOS (`xcode-select --install`), Visual Studio Build Tools with "Desktop development with C++" on Windows |
| **Prebuilt player** | A ready-made game program: projects **without** scripts play and export with it, with nothing compiled |
| **Static SDL** | SDL built into games, so they're one file and need no libraries beside them |
| **Emscripten** | Builds web exports |
| **Git** | Optional: [version control](version_control.md) in the Git tab |
| **Shader compiler** | For your own shaders (the built-in effects need nothing) |
| **Font tool** | For fonts set to stay sharp at any size |
| **Plugin API** | For the project's [editor plugins](plugins.md) |
| **ffmpeg** | Optional: converting sounds to Ogg Vorbis |
| **Odin language server** | Optional: completion and error checking in the code editor |

The rows read the dialog's settings as you type, so a new Odin path shows its result before you
press Apply.

**A project without scripts** plays and exports with the prebuilt player: a released editor needs
nothing installed. **A project with scripts** needs the Odin compiler and the linker.

Below the list:

- **Odin program:** the `odin` to use, a path or a name in your PATH. Empty: `odin` in your PATH,
  else the one the editor installed.
- **Install Odin dev-2026-10:** downloads the Odin version the engine uses (about 70 MB, from
  GitHub) into the editor's data folder (the path is shown under the button). It takes a few
  minutes. You still need the linker.
- **Install Emscripten:** downloads Emscripten and the sound library's sources for web exports
  (about 1 GB; it needs Python) into the same folder. The first web export does it too. See
  [Exporting](exporting.md#web-exports).

The editor's data folder is `~/.local/share/crossfire-editor` on Linux,
`%APPDATA%\crossfire-editor` on Windows and `~/Library/Application Support/crossfire-editor` on
macOS.

## Project

The **Project** tab shows the open project's [Project Settings](#project-settings) tabs, inside
the Settings dialog, so you can change both in one place. Apply and Save apply the project's
changes too (as one step you can undo); Cancel drops them.

## Where the settings are saved

The editor's settings are saved in **`editor.ini`**:

- beside the editor's program, when you run it from a folder you unpacked (a release archive);
- in the editor's data folder (above) when it's installed: the macOS app, the Linux AppImage,
  the Windows installer, or any folder you can't write to.

Beside `editor.ini` are `recent_projects.txt` (File > Open Recent) and a `code_editor` folder
(the code editor's own shortcuts and colors).

`editor.ini` is plain text, one `name = value` per line, but change settings in the dialog rather
than by hand. Settings missing from it use their defaults; a line the editor doesn't understand
is reported in the Console and skipped. To start over, delete it (with the editor closed).

To use another settings file, start the editor with `--settings path/to/file.ini`.

## Project Settings

**File > Project Settings...** (or the Settings dialog's Project tab) holds the game's settings.
They're saved with the project (in `project.xml`, and `export.ini` for exports). Press **Apply**
to use the changes; they're one step you can undo. **Cancel** drops them. Hover over a setting's
name to see what it does.

### General

| Setting | What it does |
|---|---|
| **Name** | The game's name: the window's title, and the exported program's name unless you choose another |
| **Resolution** | The game's size in pixels (1280 x 720 for a new project): what the camera shows |
| **Scaling** | How the game fills a window of another size: **Letterbox** (keeps its shape, black bars), **Stretch** (fills it, stretched), **IntegerScale** (whole multiples only, for crisp pixel art), **Overscan** (keeps its shape, cuts the edges off), **None** (no scaling) |
| **Renderer** | What draws the game: **Auto** (the best one on each system) or one you choose (OpenGL, Vulkan, Direct3D, Metal...). Ones this computer doesn't have are marked. Web exports always use WebGL |
| **Image filtering** | Smooth (painted art) or Pixels (pixel art: hard square pixels), for every image that doesn't choose its own. See [Image filtering](asset_import.md#image-filtering-smooth-or-pixels) |
| **Window** | **Fullscreen**, **VSync** (frames in step with the screen), **High DPI** (sharper on high-density screens): how the game's window starts |
| **Sound output** | The sample rate and channels the game asks its sound device for. Stereo at 48000 Hz works everywhere |
| **Background** | The color behind everything |
| **Start scene** | The scene the game starts in (Play and exports). Play Scene (Ctrl+F5) starts in the open scene instead |
| **Icon** | The game window's icon: one of the project's images, or None for the Crossfire logo |
| **Scene change**, **Change time**, **Change color**, **Loading scene** | How the game goes from one scene to another. See [Scene changes](scene_changes.md) |
| **Language** | The language the game starts in, from its translation tables. Empty: the player's system language |
| **Pixels per meter**, **Gravity**, **Show shapes**, **Smooth motion** | Physics: the world's scale and gravity, collision shapes drawn while you Play (never in exports; F9 shows and hides them in the game), and smooth drawing of moving bodies |

### The other tabs

| Tab | What it holds | More |
|---|---|---|
| **Input** | The game's **input actions** (named inputs like `jump` or `ui_accept`) and the keys, mouse buttons and gamepad buttons and sticks that trigger them; **Add the default ui_ actions**; local players | [Local multiplayer](local_multiplayer.md#project-settings), [Touch controls](touch_and_steam.md#input-actions-first) |
| **Globals** | Scripts that run for the whole game, whatever the scene (a score keeper, the music), in the order they start, and their fields | |
| **Export** | The export targets and their settings | [Exporting](exporting.md) |
| **Grid** | The viewport grid: cell width and height, major lines, how strong the lines are (View > Grid Settings... opens it) | |
| **Steam** | The Steam app ID, cloud saves, achievements | [Steam](touch_and_steam.md#steam) |

## Questions

**My changes didn't show.** Press Apply or Save: the dialog works on a copy until then.

**A shortcut stopped working.** Another action may have the same keys (look for the yellow
line in the Keyboard tab), or you're typing in a text field or the code editor. The ↶ button puts
a shortcut back.

**Play says there's no Odin compiler.** The project has scripts. Use **Install Odin** in the
Toolchain tab, or set **Odin program** to yours. The Linker row must be green too.

**Settings > Toolchain says the linker is missing.** Install it as the row says (clang, Xcode's
command line tools, or Visual Studio Build Tools). The editor can't install it for you.

**How do I put every setting back?** Reset to Defaults on each tab, or close the editor and
delete `editor.ini`.

**Are Project Settings per computer?** No: they're part of the project, so they travel with it
(and with Git). The editor's settings are yours, on this computer.
