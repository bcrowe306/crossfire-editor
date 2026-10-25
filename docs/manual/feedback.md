---
title: Notifications, problems and history
description: "How the editor tells you what happened: toasts with progress for builds, exports, saves and installs; the Problems tab listing what's wrong with the project; the History tab of undo steps; what empty panels offer."
order: 45
---

# Notifications, problems and history

The editor tells you what it's doing and what went wrong without making you read the Console:
short notifications in the corner, a list of the project's problems, and the list of your undo
steps.

- [Notifications](#notifications)
- [The Problems tab](#the-problems-tab)
- [The History tab](#the-history-tab)
- [Empty panels](#empty-panels)
- [Questions](#questions)

## Notifications

A notification (a "toast") shows in the window's bottom-right corner when something finishes:

| When | It says | Its button |
|---|---|---|
| You save the project (**Ctrl+S**) | Saved, and the project's name | |
| An export finishes | Exported, and the target | **Open Folder**: the exported game in your file manager |
| Play's build, or **Scripts > Build Scripts**, fails (the quiet builds after opening a project or saving a script only show in the Output and Problems tabs) | Building the game (or the scripts) failed | **Show Problems**: the build's errors in the [Problems tab](#the-problems-tab) |
| An export, a save, an import, a Git command or a plugin fails | What failed, and why | **Show Output** or **Show Console**: the full story |
| Odin or Emscripten is installed (Settings > Toolchain) | Installed, and the version | |
| A project archive is written | Its file name | **Open Folder** |

- Notifications stack, the newest at the bottom, four at most.
- They show for a few seconds (warnings a little longer), then go. **Errors stay until you
  dismiss them**, so you don't miss one.
- **Click** a notification (or its **×**) to dismiss it. Its button does what it says and
  dismisses it too.
- Simple notices ("Saved") don't get in your way: while only they show, clicks go through them to
  what's under them, and they have no ×. While a dialog is open, every notification lets clicks
  through, so the dialog's buttons stay reachable.
- They appear and go at once: the editor doesn't animate.
- Everything a notification says is in the Console too, with the details.

**Long jobs** show a notification with a progress bar while they run, above the others: building
the game for Play or building the scripts, exporting (the bar follows the export's steps, "2 of
3" when you export to several platforms), installing Odin or Emscripten, building a plugin and
writing a project archive. The time it has taken shows on the right. A build's bar compares the
time with how long the last one took, so the first build of a session shows only the time.

## The Problems tab

The bottom panel's **Problems** tab (in the Scene and Level modes; **Edit > Problems**) lists
what's wrong with the project:

| Problem | For example |
|---|---|
| **Missing asset** | A Sprite's image, an animation's sheet, a sound, a component, a shader, a dialogue or an LDtk file that isn't in the project folder any more |
| **Broken node path** | A camera following a node that was deleted, an Animator track, a listener, an IK chain or a script's node field naming a node that isn't there |
| **Unresolved reference** | A node using a script or a node type that your scripts don't have (after the last scripts build) |
| **Script error** | An error the last build found, with its file and line, and the problems the editor finds in exported fields while you type |

Each row says what's wrong and where: the scene and the node (`PlayScene > World > Ship`), or the
file and line. **Click a row** to go to the cause: the scene opens with the node selected (its
parents expanded in the scene tree), or the script opens in a code tab at the line.

The list is checked again when you show the tab, when you save, when a build finishes and when
you press **Refresh**. Missing assets and script errors are errors (red); the others are
warnings (amber).

## The History tab

The bottom panel's **History** tab (**Edit > Undo History**) lists your undo steps: **Opened**
(the project as you opened it), then every edit, oldest first. The step you're at is selected;
steps you undid are greyed, below it, until a new edit replaces them.

**Click a step** to go back (or forward) to it: the editor undoes or redoes every step in between,
one at a time, as **Ctrl+Z** and **Ctrl+Shift+Z** would, showing the mode and scene of the last
one. The list is the same as the undo history of [Scenes and nodes](scenes_and_nodes.md): one
history for every mode, edits in the Level mode included.

## Empty panels

A panel with nothing to show says why, with a button for the obvious next step:

| Panel | Its button |
|---|---|
| The inspector with nothing selected, a scene with no nodes | **Add Node...** |
| The browser when the search matches nothing | **Clear Search** |
| The Console | **Play** |
| The Output tab | **Build Scripts** |
| The Animation, Tiles, Timeline, States and Particles tabs without their node selected | **Add AnimatedSprite**, **Add TileMap**, **Add Animator**, **Add StateMachine**, **Add ParticleEmitter** (inside the selected node) |
| The Live tab while the game isn't running | **Play** |
| The Problems tab before it's checked | **Check Now** |
| The Level mode's Levels sidebar without an LDtk project | **Import...** |

## Questions

**A notification covers what I want to click.** Click it to dismiss it; info notifications go by
themselves after a few seconds.

**The Problems tab says a script doesn't exist, but it does.** The list uses the last scripts
build: build them (**Scripts > Build Scripts**) and press **Refresh**.

**Can I undo to a step and then make a new edit?** Yes: the steps after it (greyed) are dropped,
as after any undo.
