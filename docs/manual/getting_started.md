---
title: Getting started
description: Install and run the Crossfire Editor, learn the parts of its window, and make a first tiny game with a picture and some text.
order: 1
---

# Getting started

The **Crossfire Editor** is where you make 2D games with the **Crossfire Engine**. You put your
game together from scenes (a level, a menu) built out of nodes (a picture, some text, a camera,
a wall), add your own code where you need it, and press **Play** to try it. This page gets you
from installing the editor to running your first game.

- [Installing it](#installing-it)
- [The demo project](#the-demo-project)
- [The window](#the-window)
- [Your first game](#your-first-game)
- [What you'll need for scripts](#what-youll-need-for-scripts)
- [Where to go next](#where-to-go-next)
- [Questions](#questions)

## Installing it

Download the editor from the project's
[releases page](https://github.com/bcrowe306/crossfire-editor/releases). Pick the file for your
computer:

| Computer | File | How to install |
|---|---|---|
| **Linux** | the `.AppImage` | Make it executable (`chmod +x Crossfire_Editor-*.AppImage`, or tick "allow executing" in your file manager's properties) and run it. Nothing else to install |
| **Linux** | the `.tar.gz` archive | Unpack it anywhere and run `./crossfire-editor`. `./install-desktop-entry.sh` (in the archive) adds it to your application menu, with its icon |
| **Windows** | the `-setup.exe` installer | Run it. It adds **Crossfire Editor** to the Start menu (and a desktop icon if you tick it) |
| **Windows** | the `.zip` archive | Unpack it anywhere and run `crossfire-editor.exe` |
| **macOS** | the `.dmg` disk image | Open it and drag **Crossfire Editor** onto **Applications**. It needs macOS 15 or newer |

The editor draws with Vulkan, so your computer needs a graphics driver that has it (any recent
one does; on a Mac the app brings its own).

On macOS, the app isn't notarized by Apple yet, so the first time you open it macOS may refuse.
Open **System Settings > Privacy & Security** and choose **Open Anyway** for Crossfire Editor.

## The demo project

The first time you start the editor it opens the **demo project**: a small space game (a menu, a
play scene, an options screen) and a platformer level made in LDtk. Press **F5** to play it. Look
around: click things in the scene tree, see their settings in the inspector, change some and play
again. You can't break anything you can't undo (Ctrl+Z).

Where the demo lives:

- from an archive (Linux `.tar.gz`, Windows `.zip`): `examples/demo_project`, beside the editor;
- from the AppImage, the Windows installer or the macOS app: a copy in your **Documents** folder,
  `Documents/Crossfire Editor`, made the first time you start it.

To open another project, start the editor with its folder (`crossfire-editor path/to/MyGame`) or
use **File > Open Project** (Ctrl+O). See [Projects](projects.md).

## The window

```
+------------------------------------------------------------------+
| menu bar: File  Edit  Scripts  View  Scene  Help                 |
| toolbar: new, open, save | undo, redo | tools | play controls    |
+-----------+--------------------------------------+---------------+
| browser   | scene tabs              view buttons | scene tree    |
|           |                                      |               |
|           |   viewport                           +---------------+
|           |                                      | inspector     |
|           +--------------------------------------+               |
| preview   | bottom panel: Console, Output, ...   |               |
+-----------+--------------------------------------+---------------+
| status bar                                                       |
+------------------------------------------------------------------+
```

| Part | What it's for |
|---|---|
| **Menu bar** | Every command. Each menu shows the shortcut beside the command |
| **Toolbar** | New, Open, Save; Undo and Redo; the tools (Select, Move, Rotate, Scale, Pan); in the middle **Play**, **Play this scene**, **Pause**, **Stop** and the game's collision shapes (on while you develop: [Seeing the shapes](physics.md#seeing-the-shapes)); **Export** on the right |
| **Browser** (left) | Your project's files, sorted into folders: Scenes, Scripts, Images, Audio, Music, Fonts, Data, Components, Levels and more. The search box at the top filters them. **+** imports a file (Ctrl+I), the trash button removes one |
| **Preview** (under the browser) | What the selected file is: an image's picture and size, a sound you can play, a scene's facts and its settings |
| **Viewport** (middle) | The open scene, drawn the way the game draws it. Click a node to select it, drag it to move it. Each open scene has a tab above it |
| **Scene tree** (right, top) | Every node of the open scene, children indented under their parents |
| **Inspector** (right, bottom) | The selected node's settings: its name, position, rotation, scale, and what its kind has (an image, a text, a sound...) |
| **Bottom panel** | Tabs: **Console** (messages from the editor and your game), **Output** (building), **Animation**, **Mixer**, **Git**, **Tiles**, **Timeline**, **Live**, **States**, **Dialogue**, **Plugins**. Ctrl+J shows or hides it |
| **Status bar** (bottom) | The project's name, **Modified** or **Saved**, the open scene, its node count, what's selected, the tool, whether the game is playing, and the game's screen size |

Drag the lines between the panels to resize them. Hover over almost anything (a button, a setting's
name in the inspector) to see what it does.

**Help > User Manual** (F1) opens this manual, and **Help > Keyboard Shortcuts** lists every
shortcut (you can change them there too).

### The Console and Output tabs

The **Console** shows what the editor and your game say; the **Output** tab, what building and
exporting say. Each line has a level (Debug, Info, Warning in yellow, Error in red) and a
category (what it's about: **engine**, **SDL**, **editor**, **game**, or your scripts' own, see
[Logging](scripts.md#logging)). The row over the lines filters them:

| Control | What it does |
|---|---|
| **Search** | Only lines containing the text, in any case. Escape empties it |
| **Errors**, **Warnings**, **Info**, **Debug** | Each shows or hides its lines; the number is how many there are |
| **All categories** | A menu of every category seen so far, checked when shown: pick as many as you like (it stays open), **Show All** shows them again |
| **↓** (Follow) | Keeps the newest line in view (on at first). Scrolling up stops it, so you can read; scrolling back to the end starts it again |

When some lines are hidden the row says how many show ("12 of 340 lines"). Right-click a line
to copy it, copy every line shown, hide its category or show only it, or turn every filter off
(**Show Everything**). The trash button in the panel's corner clears the tab.

The Console keeps the newest 5000 lines and drops the oldest: **Settings > Editor > Console
lines kept** changes how many.

## Your first game

A picture and a line of text on the screen. It takes five minutes and no code.

### 1. Make a project

1. **File > New Project** (Ctrl+N).
2. **Name**: `MyFirstGame`. **Location**: a folder for your games (**Browse...** picks one).
3. **Create**.

The editor opens it. It has one scene, **Main**, with one node, **World**. The red outline in the
viewport is the **game area**: what the player's screen shows (1280 x 720 pixels to start with).

### 2. Bring in a picture

1. Click **+** at the top of the browser (or Ctrl+I) and pick an image: a PNG of a character, a
   spaceship, anything. It's copied into your project's `assets/` folder and appears in the
   browser's **Images** folder. You can pick several files at once (Ctrl+click or Shift+click
   them in the dialog), and the dialog opens in the folder you imported from last time.
2. Click it in the browser: the preview under the browser shows it.

### 3. Put it in the scene

1. Click **World** in the scene tree, so the new node goes inside it.
2. Drag the image from the browser into the viewport, and let go inside the red game area.

A **Sprite** node named after the file appears where you dropped it, inside World. Drag it
around with the mouse. With the **Move** tool (W) you get arrows: drag one to move only sideways
or only up and down. Try **Rotate** (E) and **Scale** (R) too.

The inspector shows the Sprite's **Position**, **Rotation** and **Scale**: you can type numbers
there instead.

### 4. Add some text

1. Select **World** again.
2. **Edit > Add Node...** (Ctrl+Shift+A, or the **+** above the scene tree).
3. Type `label` in the search box and press Enter.

A **Label** appears at World's corner (position 0, 0: the top-left of the game area). In the
inspector:

- **Text**: `Hello, game!`
- **Position X** `640`, **Position Y** `100`: the middle, near the top.
- **Font size**: `48`.
- **Color**: pick one you like.

### 5. Play it

Press **F5** (or the toolbar's play button). The editor saves the project and opens your game in
its own window: your picture and your text. Close the window, or press **Shift+F5** (Stop), to
come back.

That's a game. Not a very exciting one yet: nothing moves, and nothing listens to the keyboard.
That's what scripts are for.

### 6. Save

**File > Save** (Ctrl+S). Play saves too. A `*` in the window's title, and **Modified** in the
status bar, mean there are changes you haven't saved.

## What you'll need for scripts

Games without code (scenes, menus that switch scenes, physics, animations) play straight away:
the editor comes with a ready-made game player.

Once your project has scripts (your own Odin code), the editor compiles your game, which needs:

- **Odin** (the programming language): **Edit > Settings...** (Ctrl+,) **> Toolchain > Install
  Odin** downloads the right version (a few minutes, once).
- **A linker**, which can't come with the editor: `clang` on Linux (from your package manager),
  Xcode's command line tools on macOS (`xcode-select --install`), Visual Studio Build Tools on
  Windows ("Desktop development with C++").

**Settings > Toolchain** lists what was found and what's missing.

## Where to go next

| To... | Read |
|---|---|
| Organize scenes, add and arrange nodes, use the viewport | [Scenes and nodes](scenes_and_nodes.md) |
| Show pictures, animate them, use Aseprite files, write text | [Sprites and images](sprites_and_images.md) |
| Make things move, react to keys, keep score | [Scripts](scripts.md) |
| Make things fall, collide and bounce | [Physics](physics.md) |
| Reuse a group of nodes (an enemy, a coin) in many places | [Components](components.md) |
| Draw levels from tiles | [Tilemaps](tilemaps.md) |
| Menus, buttons, health bars | [The UI system](ui.md) |
| Animate anything over time (doors, cutscenes) | [Keyframe animation](animation.md) |
| Save, copy and share your project | [Projects](projects.md) |

## Questions

**The editor opens a different project.** It opens the demo when started without a project. Use
**File > Open Recent** to get back to yours, or start it with your project's folder.

**Play does nothing, or the Console says Odin wasn't found.** Your project has scripts and needs
Odin and a linker ([What you'll need for scripts](#what-youll-need-for-scripts)). The **Output**
tab shows what the build said.

**My picture isn't where I put it in the game.** Without a camera the game shows the game area
(the red outline) exactly. Anything outside it is off screen.

**I changed something by mistake.** **Edit > Undo** (Ctrl+Z) takes back any edit, one at a time;
the Edit menu says what it will undo.
