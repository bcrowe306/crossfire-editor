---
title: The code editor
description: Write your game's Odin scripts in tabs beside your scenes, with completion, error checking, go to definition, find and replace, and a command palette, or use an external editor such as Zed or VS Code instead.
order: 37
---

# The code editor

Your game's scripts are Odin files in the project's `scripts/` folder. The editor has its own
**code editor** for them: each script opens in a **code tab** next to the scene tabs, in the
middle of the window. It colors Odin code, and with the Odin language server it completes what
you type, underlines mistakes and jumps to where things are defined.

If you'd rather use another program (Zed, VS Code...), you can: see
[Using an external editor instead](#using-an-external-editor-instead).

This page has three parts:

- **[Working in code tabs](#working-in-code-tabs):** [opening a script](#opening-a-script), [the tabs](#code-tabs),
  [saving](#saving), [closing a tab](#closing-a-tab), [files changed on disk](#files-changed-on-disk)
- **[Writing Odin](#writing-odin):** [completion and errors](#completion-and-errors-the-odin-language-server),
  [going to definitions](#going-to-definitions), [going to an error](#going-to-an-error-from-the-output-tab-or-the-console),
  [find and replace](#find-and-replace), [the command palette](#the-command-palette),
  [editing shortcuts](#editing-shortcuts), [which shortcuts work while you type](#which-shortcuts-work-while-you-type-code),
  [keymaps and themes](#keymaps-and-themes), [auto-closing brackets](#auto-closing-brackets-and-quotes)
- **[Your project in the code](#your-project-in-the-code):** [names in strings](#names-in-strings-scenes-nodes-animations),
  [hovers and previews](#hovers-and-previews), [code and scenes, linked](#code-and-scenes-linked),
  [dragging things into the code](#dragging-things-into-the-code), [code actions](#code-actions-ctrl),
  [the running game in the code](#the-running-game-in-the-code)

Then [using an external editor instead](#using-an-external-editor-instead) and
[questions](#questions).

## Working in code tabs

Each script opens in a tab of its own, beside the scene tabs, and saves with the project.

### Opening a script

Any of these opens a script in a code tab (or shows its tab, if it's already open):

| Where | How |
|---|---|
| Inspector | Select a node with a script, then **Open in Editor** in its Script section |
| Scripts menu | **Scripts > Open Script** opens the selected node's script |
| Scene tree | Right-click a node with a script: **Open Script (Name)** |
| Browser | Double-click a script in the Scripts folder, right-click it and choose **Open in Editor**, or click **Open** in its preview |
| New script | **Scripts > New Script...** (or **New** in the inspector) makes the file and opens it |

Shader files (`.frag`) open in code tabs too (a shader's **Edit** button), and compile when you
save them.

### Code tabs

Code tabs come after the scene tabs. Each shows the file's name, with a **●** after it while it
has changes you haven't saved. Click a tab to show its file; click a scene tab to go back to the
scene. Anything that opens another scene (the browser, Play Scene...) shows the scene too.

Under the code, a status line shows:

- the file's name, with "(unsaved)" while it has changes (or the code editor's own messages)
- **Ln** and **Col**: where the caret is
- **Language server**: whether completion and error checking are working (`off (no ols)` when
  there's no language server; see below)

When the window is narrow, the tab strip scrolls sideways: use the mouse wheel over it.

### Saving

- **File > Save** (Ctrl+S) saves the project **and** every code tab with changes.
- The **save button** in the code view's header (the disk icon) saves only the script that shows.
- **Play** (F5), **Build Scripts** (Ctrl+B) and **Export** save the scripts first, so the game
  always runs what you see.

After a script is saved, the editor builds the scripts in the background, so the inspector learns
about new fields you added. Build errors go to the **Output** tab.

Scripts you haven't saved count as unsaved changes: the window's title gets its `*`, and quitting
asks first.

### Closing a tab

Click the tab's **×**, middle-click the tab, or use **Scripts > Close Code Tab** (Ctrl+W, also
while you type in the code).

A tab with unsaved changes asks **"Save changes to mover.odin?"** first:

| Button | What it does |
|---|---|
| **Save** | Saves the file, then closes the tab |
| **Don't Save** | Closes the tab; the changes are lost |
| **Cancel** | Keeps the tab open |

When a tab closes, the tab beside it shows, or the scene when it was the last.

### Files changed on disk

If another program changes a script that's open (another editor, Git switching branches, a pull),
the code tab notices within about a second, and as soon as you show its tab again:

- **No unsaved changes in the tab:** it reloads the file by itself and keeps the caret on its
  line. The Console says "mover.odin changed on disk: reloaded".
- **Unsaved changes in the tab:** a yellow bar over the code says "mover.odin changed on disk, and
  you have unsaved changes." Choose **Reload (lose mine)** to take the file from disk, or **Keep
  mine** to keep your text (your next save writes it over the file).

## Writing Odin

The code editor colors Odin code, follows the shortcuts of VS Code and Zed, and with the Odin
language server completes, checks and navigates it.

### Completion and errors: the Odin language server

Completion and error checking come from **OLS**, the Odin language server: a separate program
that understands Odin code. The editor works without it (you can type, save and build), but
there's no completion or underlining then.

The editor looks for OLS in this order and uses the first it finds:

1. **Settings > Editor > Language server**, if you typed a path (or a program name) there
2. `ols` in your PATH
3. an `ols` beside the editor (the macOS app has one)
4. one built in the editor's source checkout (`task ols`, for people building the editor
   themselves)
5. the one Zed's Odin extension downloads (Linux)

Settings > Editor shows which one it found ("Uses ..."), and Settings > Toolchain has a row for
it. When none is found, the Console says so once, and the status line says `off (no ols)`. You
can get OLS from its project page (github.com/DanielGavin/ols), or install Zed and its Odin
extension.

What it gives you:

- **Completion:** suggestions appear as you type (after a `.` for example: `e.` lists the
  engine's procedures). Ctrl+Space asks for them anywhere. Up and Down choose, Enter or a click
  takes one. A struct's fields are listed as the code declares them, with the comment above each
  one beside it:

  ```
  speed: f32          Pixels a second
  node: ^e.Node       The node it's attached to
  ```

  Other suggestions carry a short tag for what they are: `fn` (a procedure), `type`, `var`,
  `const`, `enum`, `pkg` (a package), `kw` (a keyword).
- **Parameter hints:** inside a call's brackets, the procedure's parameters show, the current one
  highlighted (Ctrl+Shift+Space asks for them).
- **Hover:** rest the mouse on a name to see its type and documentation.
- **Errors and warnings:** underlined in the code (red errors, yellow warnings) with a mark in the
  margin. Rest the mouse on one to read it. **F8** and **Shift+F8** jump to the next and previous
  problem. Mistakes in how code is written show as you type; type errors show when you save
  (OLS checks the code then).
- **Problems panel:** Ctrl+Shift+M lists every problem in every open file; click one to go there.
- **Quick fixes:** Ctrl+. at an underlined spot lists fixes the server offers; Enter applies one.
  The same menu has the editor's own fixes and its [code actions](#code-actions-ctrl).

The editor writes `scripts/ols.json` for the language server, so it knows where the engine and
your project's scripts are. It keeps it up to date by itself. If you write your own `ols.json`
(without the editor's `_generated_by` line), the editor leaves it alone.

### Going to definitions

| Keys | What it does |
|---|---|
| **F12**, or Ctrl+click a name | Go to Definition: jumps to where it's defined. In another file, that file opens in its own tab |
| **Alt+F12** | Peek Definition: shows the definition in a small window over the code (Enter opens it, Escape closes) |
| **Shift+F12** | Find All References: a panel listing every use; click one, or step through them with **F4** and **Shift+F4** |
| **Alt+Shift+F12** | Find Usages in Project: the scenes' and components' nodes using a script, a field or an event (see [Code and scenes, linked](#code-and-scenes-linked)) |
| **F2** | Rename Symbol: in the code, and for scripts, fields and events in the project too |
| **Alt+Left** / **Alt+Right** | Back and forward through the places you jumped to |

These need the language server too (except Find Usages, and F2 on a script, a field or an
event: those the editor does itself). A definition outside your project (in the engine or Odin's
own library) opens **read only**: the status line says "(read only: outside the project)", and
typing changes nothing, since those files are shared by every project.

### Going to an error from the Output tab or the Console

A line that names a place in a file is a link: the compiler's errors in the **Output** tab
(`/home/me/MyGame/scripts/hero.odin(12:5) Error: Undeclared name: speed`), and in the
**Console** anything with a file and line, such as a crash (`panic`) or a failed `assert` in
your game. Point at the line: it turns the accent color, is underlined, and the pointer becomes
a hand. **Click it** to open the file in a code tab with the caret at that line and column. Or
right-click the line and choose **Go to Error**.

- Paths are read the way the tool wrote them: Odin's `file(line:column)`, and `file:line:column`
  or `file:line` (shader compilers and most other tools). Windows paths such as
  `C:\Games\MyGame\scripts\hero.odin(12:5)` work too.
- A path that isn't absolute is looked for where the build ran, then in the project and its
  `scripts/` folder.
- A file outside the project (an engine source in a crash's location, for example) opens read
  only, as Go to Definition's do.
- With an external editor (below), the line opens there instead, at the line (and column, with
  `{column}` in its arguments).

### Find and replace

- **Ctrl+F** opens the find bar. It searches as you type and highlights every match, with an
  "N of M" count. **Enter** and **Shift+Enter** (or **F3** / **Shift+F3**, **Ctrl+G** /
  **Ctrl+Shift+G**) go to the next and previous match. **Escape** closes it.
- The bar's **Aa**, **W** and **.\*** buttons (or **Alt+C**, **Alt+W**, **Alt+R**) turn on
  matching case, whole words and regular expressions.
- **Ctrl+H** adds a replace field. **Tab** moves between the fields, **Enter** replaces the
  current match, **Ctrl+Alt+Enter** replaces them all. Each replace can be undone in one step.
- **Ctrl+D** selects the word at the caret; pressed again, it adds the next place that word
  appears, with a caret of its own, so you can change them all at once. **Ctrl+Shift+L** selects
  every place at once.

### The command palette

**Ctrl+P** (also Ctrl+Shift+P) opens the **command palette**: a
searchable list of everything the code editor can do, with each command's shortcut. Type part of
a name to filter it, Up and Down to choose, Enter to run, Escape to close. Commands you used
lately are at the top.

The palette also opens the code editor's windows:

| Window | What it's for |
|---|---|
| **Find / Replace** | The find bar |
| **Keymap Editor** | The code editor's shortcuts (see below) |
| **Theme Editor** | Its colors |
| **Utilities** | The language server's state, and Restart / Stop / Start buttons for it |

Escape goes back to the code.

### Editing shortcuts

The code editor follows the shortcuts of VS Code and Zed. On macOS, use Cmd where this table says
Ctrl.

| Keys | What it does |
|---|---|
| Ctrl+Z / Ctrl+Shift+Z or Ctrl+Y | Undo / redo (in the code: separate from the scene's undo) |
| Ctrl+C, Ctrl+X, Ctrl+V | Copy, cut, paste |
| Ctrl+A | Select all |
| Ctrl+L | Select the line |
| Ctrl+/ | Comment or uncomment the lines |
| Alt+Up / Alt+Down | Move the line up or down |
| Shift+Alt+Up / Shift+Alt+Down | Copy the line up or down |
| Ctrl+Shift+K | Delete the line |
| Ctrl+Enter / Ctrl+Shift+Enter | New line below / above |
| Tab / Shift+Tab | Indent / outdent |
| Ctrl+Alt+Up / Ctrl+Alt+Down | Add a caret above / below |
| Alt+click | Add a caret where you click |
| Ctrl+= / Ctrl+- / Ctrl+0 | Bigger text, smaller text, normal size |

Right-click the code for a menu (cut, copy, paste, select all, quick fix, find, next problem).
You can drag a selection to move it (hold Alt or Ctrl to copy it instead).

### Which shortcuts work while you type code

While the keyboard is in the code (after you click in it), the code editor gets your keys. Only
these editor shortcuts still work then:

| Shortcut | Action |
|---|---|
| Ctrl+S | Save (the project and every script) |
| F5, Ctrl+F5, F6, Shift+F5, Ctrl+Shift+F5 | Play, Play Scene, Pause, Stop, Restart |
| Ctrl+B | Build Scripts |
| F1 | Help in the [docs window](docs_window.md): the API entry of the engine procedure or type at the caret (or the type of the field or variable there), otherwise this manual's code editor page |
| Ctrl+W | Close the code tab |
| Ctrl+Shift+E | Export |
| Ctrl+J | Show or hide the bottom panel |
| Ctrl+, | Settings |
| Ctrl+Q | Quit |

(These are the defaults; if you change them in Settings > Keyboard, your keys work instead.)

The others mean something else in the code: Ctrl+D selects the next match instead of duplicating
a node, Ctrl+O opens another script in a tab (a file
dialog) instead of another project, and Ctrl+Shift+S saves the script under a new name. Click
outside the code (the scene tree, the viewport) and the editor's shortcuts are back.

### Keymaps and themes

The code editor has **its own** shortcuts and colors, separate from the rest of the editor's
(Settings > Keyboard doesn't change them).

**Shortcuts:** command palette > **Keymap Editor** lists every command and its keys. Type to
filter (by name, or by keys like "ctrl+shift"). **Enter** records new keys for the chosen command
(replacing its old ones), **Shift+Enter** adds another, **Del** removes them, **Ctrl+R** puts the
default back, **Escape** closes.

**Your Zed or VS Code shortcuts:** the palette's **Preferences: Import Keybindings from Zed**
reads Zed's `~/.config/zed/keymap.json`; **Preferences: Import Keybindings from VSCode** reads VS
Code's `keybindings.json`. They're added to the code editor's keymap. Commands it has no
equivalent for, and key sequences (like Ctrl+K Ctrl+C), are skipped; the status line says how
many.

**Colors:** the palette's **Color Theme: ...** commands pick a theme: **Ayu Dark** (the default),
**Ayu Light** or **Dark+**. With the editor's Light appearance, the code starts on Ayu Light until
you choose a theme. **Theme Editor** (in the palette) changes any single color: pick it, then
drag the R, G, B, A sliders or press Enter to type a hex value; Del puts a color back.

These are saved in a `code_editor` folder beside the editor's settings file (`keymap.json` and
`theme.json`; see [Settings and the toolchain](settings_and_toolchain.md)). The palette's
**Preferences: Reset Key Bindings to Defaults** and **Reset Theme** start over.

### Auto-closing brackets and quotes

When you type an opening bracket or quote, the code editor adds its closer after the caret:
`(` `[` `{` `"` `'` and `` ` ``. Also:

- Typing the closer when it's already next just steps over it.
- **Backspace** between an empty pair removes both.
- **Enter** between `{}`, `()` or `[]` puts the closer on its own line and indents the line
  you're on.
- With text selected, typing an opening bracket or quote wraps the selection in the pair.
- `<` closes only straight after a name (`Map<`), since elsewhere in code it means "less than".

Turn it off with **Settings > Editor > Auto-close**.

## Your project in the code

The language server knows Odin; the editor knows your project: its scenes and nodes, assets,
animations, input actions, the running game. It adds what only it knows to the code tab, with or
without the language server, so you don't have to remember how to refer to things in code:

| You want to | The code tab |
|---|---|
| Name a scene, a node, an animation, an action... | Completes the names that fit inside an engine call's string, its constants (`SCENE_FOREST`) outside it, and underlines a name the project doesn't have ([Names in strings](#names-in-strings-scenes-nodes-animations)) |
| See what a name stands for | Rest the mouse on it: an image's picture, a sound with a play button, an animation's frames, an engine procedure's documentation ([Hovers and previews](#hovers-and-previews)) |
| Know who uses a script, rename it everywhere | Marks in the margin, Find Usages in the project, renames carried into your scenes ([Code and scenes, linked](#code-and-scenes-linked)) |
| Use a node, a property, an animation... in code | Drag it onto the code ([Dragging things into the code](#dragging-things-into-the-code)) |
| Handle an event, export a field, register a struct | Ctrl+. ([Code actions](#code-actions-ctrl)) |
| See what the game is doing | Its live values beside the fields, numbers you drag, log points ([The running game in the code](#the-running-game-in-the-code)) |

Also:

- **Your project's constants complete.** The constants of `scripts/assets.odin` (see
  [Scripts](scripts.md#assets-in-code-scriptsassetsodin): every asset, scene, animation, state,
  parameter, group, bus, dialogue node and node path) are in the completion list, each saying what
  it names: type `SCENE_` for the scenes, `ANIM_HERO_` for the hero's animations. They don't show
  after a `.` (that's a member) or in comments.
- **Problems the build wouldn't tell you.** A field tagged `export:""` with a type the inspector
  can't edit (`[3]f32`, a map...), an option that isn't one (`export:"defualt=3"`), or a `min=`,
  `max=` or number `default=` that isn't a number is underlined as a warning as soon as you type
  it. The game itself only warns about those when it runs.
- **The inspector follows what you type.** The editor reads the scripts' source as you type (the
  **script index**; it never waits for a build): a field you add to a script's struct shows in the
  inspector a moment later, before you save or build, with "From the source: not built yet" over
  the fields (after a build: "From the last build"). After a build, the build's description is
  used again for every file that hasn't changed since. A new script's fields show the moment New
  Script makes it.

### Names in strings: scenes, nodes, animations...

Many engine procedures take a name as a string: a scene for `e.Game_ChangeScene`, a node path for
`e.Node_FindPath`, an animation for `e.AnimationPlayer_Play`, an input action for
`e.Input_IsActionPressed`. The engine says which kind of name each parameter takes (its types
`SceneName`, `NodePath`, `AnimationName`, `ActionName`...; they're all plain strings, so any string
still goes in), and the code tab uses it:

- **Inside the string, the names that fit complete.** Type the opening quote and the list opens:
  `e.Game_ChangeScene(self.game, "` lists your scenes, `e.Audio_SetBusVolume("` your buses. Pick
  one with Enter or Tab. Names with spaces work too.
- **Outside the string, the constants come first.** `e.Game_ChangeScene(self.game, ` then a letter
  or Ctrl+Space lists the `SCENE_` constants of `scripts/assets.odin` before anything else, so the
  compiler checks the name.
- **A name the project doesn't have is underlined** as a warning: "No scene "Forrest": did you
  mean "Forest"?". With the caret on it, **Ctrl+.** offers the fixes: the closest name, or its
  constant (`Use SCENE_FOREST`). The Problems panel (Ctrl+Shift+M) lists them with the others.

What fits where:

| The call takes | It completes | Checked against |
|---|---|---|
| A node path (`Node_FindPath`, `Node_FindChild`, `Camera2D_SetFollowTargetPath`) | The nodes around the node running the script: its children, `..` for its parent, then that one's children after `../`, the scene's top level after `/`. From a node field (`e.Node_FindPath(self.camera, "...")`), the nodes around that node | Every node the script is attached to |
| A node of the scene (`Scene_FindNode`) | The scene's top-level nodes, and every node name (a bare name finds a node anywhere) | The scenes of every node the script is attached to |
| An animation (`AnimationPlayer_Play`, `IsPlaying`...) | Through a node field (`&self.sprite.animation`): that sprite's animations. Otherwise every animation of the project, those of the sprites under the script's node first | That sprite's, or the project's |
| A state or a parameter (`StateMachine_Is`, `Travel`, `SetFloat`...) | The state machine's, through a node field (`self.brain`); else the project's | The same |
| A clip (`Animator_Play`) | The Animator's, through a node field; else the project's | The same |
| A dialogue node (`DialogueBox_Start`, `Dialogue_Start`) | The DialogueBox's dialogue's nodes, through a node field; else every dialogue's | The same |
| An input action, group, bus, scene, Steam achievement | The project's (Project Settings > Input, the nodes' groups, the Mixer, the scenes, Project Settings > Steam), and those your code adds (`Node_AddToGroup`, `Audio_AddBus`, `Input_AddAction`, `Game_CreateScene`) | The same |
| A sound file (`Game_PlaySound` with a path) | The project's sounds and music | The files on disk |

**A script on several nodes** is checked from each of them. When a path is right from some and
wrong from others, the warning says which: `No node "../Camera" from LairScene/Hero (it's there
from ForestScene/Hero)`. A script on a component's node is checked from every instance of the
component, so `..` from its root goes to wherever the component was placed.

**What isn't checked**, so there are no false alarms: names your code builds while it runs (a
variable, `fmt.tprintf`, a string with an escape), paths into nodes that make their children
while the game runs (an LDtkLevel's entities, a TileMap's layers), and paths from a node the
editor can't tell (a local variable: `e.Node_FindPath(sprite, "...")`). A path from a node no scene
has the script on yet isn't checked either.

### Hovers and previews

Rest the mouse on something in the code and the hover shows it, not only its name. It works on
the constants of `scripts/assets.odin` (`TEXTURE_SHIP`, `SOUND_JUMP`, `ANIM_HERO_RUN`...), on a
string that names an asset or a scene (`"assets/ship.png"`, `"ForestScene"`), and on the default
of an asset field (`` sprite: e.TextureAsset `export:"default=assets/ship.png"` ``):

| Rest on | The hover shows |
|---|---|
| An image (or an Aseprite file) | Its picture and size (and its frames and tags) |
| A sound or music | Its length and a play button: click it to hear the sound, again to stop it |
| An animation | Its frames side by side (the first eight), its speed and frame count |
| An animation asset | Its animations, and the first one's frames |
| A dialogue, or a dialogue node | The node's first lines and options |
| A component | Its picture, as the project browser shows it |
| A scene | What's in it: its nodes by kind, its camera, its scripts |
| A font | A line of text written with it |

The hover stays open while the mouse is on it, so you can reach the play button; move away or
press Escape to close it.

**Engine documentation.** Rest on an engine procedure, type or constant (`e.Camera2D_Follow`,
`e.Camera2D`) and the hover shows its documentation as the
[API reference](https://crossfireengine.io/api/) has it: its declaration, what it does, its
inputs, what it returns and an example. The editor reads it from the engine it builds with, so
it's always that engine's. **F1** on one opens its entry of the API reference in the editor's
[docs window](docs_window.md); anywhere else, F1 opens this page there.

**Open Docs.** Right-click a name in the code and choose **Open Docs** to read about it in the
docs window. An engine name goes to its page: a node type (`e.Sprite`, `e.Camera2D`) to its guide
in the [node guides](nodes.md), anything else (`e.Camera2D_Follow`, `e.TextureAsset`) to its API
entry. A field, a variable or a parameter goes through its type: on `self.door`, with the field
declared `door: ^e.Sprite`, it opens the Sprite's guide; on a local made from it, the same.

**Colors.** A color in the code gets a swatch, a small square of the color after its line:
`sdl.Color{255, 128, 0, 255}` (or `sdl.Color{r = 255, ...}`), a declared color given a value
(`tint: sdl.Color = {255, 255, 255, 255}`), the default of an exported color field
(`` tint: sdl.Color `export:"default=#ff8000"` ``) and `e.ParseColor("#ff8000")`. **Click the
swatch** to open the **Color** dialog: pick a color, type its hex, set its alpha, and **OK**
writes it into the code in the same form (numbers stay numbers, hex stays hex). It's one step you
can undo with Ctrl+Z in the code. A color written with a variable or an expression gets no
swatch: the editor only changes what it can read back.

### Code and scenes, linked

Your scripts and your scenes name the same things: a node runs `Hero`, stores a value for its
`speed`, listens to its `hit` event, a Timeline animates `script.speed`. The code tab shows those
links and keeps them working when you rename.

**Marks in the margin.**

- The line with `Script_Register(Hero, ...)` (or `NodeType_Register`, `Data_Register`) has a mark
  and a note after it: `3 nodes`, `2 nodes, a global`, `no node uses it`. It counts every node
  running the script in your scenes and components (as its script, one of its more scripts, or
  its node type), the instances of a component whose root runs it, the globals, and for a data
  type its data resources.
- An exported field gets a mark when nodes **set its value** (instead of using the default):
  `speed: 3 nodes override it`, `a global sets it`, `1 Timeline track`. An event gets one when
  something listens to it: `hit: 2 listeners`.
- Rest the mouse on a mark for the list, with each node's value (`ForestScene: Hero (speed =
  250)`). **Click it**: with one, its scene or component opens (in its tab) with the node
  selected; with several, a menu lists them (Up and Down, Enter, or a click) and the one you pick
  opens. A global opens Project Settings > Globals; a data resource is selected in the browser.

**Find Usages** (**Alt+Shift+F12**, or right-click > **Find Usages in Project**). With the caret on
a script's name, an exported field or an event, anywhere the code names it (its declaration,
`self.speed`, `hero.speed`, `Hero{speed = 3}`), the references panel lists its uses in the
project instead of in the code: the nodes running the script; for a field, every node running it
with its value (those that set it first, then the Timeline tracks animating it, then those using
the default); for an event, the listeners. Click one, or step through them with **F4**, to open
it. **Shift+F12** (Find All References) still lists the uses in the code.

**Rename** (**F2**, or right-click > **Rename Symbol**). A box opens under the name: type the new
one and press **Enter** (Escape cancels). On a script's name, an exported field or an event, the
box says what else changes ("Also: 3 nodes in 2 scenes, 4 stored values, 1 Timeline track") and
renaming carries into the project:

| You rename | In the code | In your scenes, components and project |
|---|---|---|
| A script (its struct) | Every place that names the type: the struct, `Script_Register`, `^Hero` parameters, `e.Node_GetScript(node, Hero)`, `e.Global(Hero)`... (not procedures named after it, such as `Hero_Hurt`) | The nodes running it (first and more scripts), the globals, listeners to its global's events, LDtk entity rules; LDtk entities that ran it because they're named like it get a rule so they keep running it |
| A node type | The same | The nodes of that type |
| A data type | The same, and `kind=` in field tags | The data resources of that type |
| An exported field | The field, and its uses: `self.speed`, `hero.speed` and the like where the code shows the type of what's before the dot, `Hero{speed = 3}` | The values stored on nodes, globals and data resources, and Timeline tracks animating `script.speed` |
| An event | The field, its uses, and `"script.hit"` strings passed to the engine | The listeners (on the nodes running the script, and to a global's events) |

- **Undo:** the project's side is **one undo step** (Ctrl+Z in the scene). The code tab's change is
  one undo step in that tab; other script files that changed open in their own tabs, unsaved, each
  with its own undo step. Save to keep them (Ctrl+S, or Save Project saves every tab).
- **A use the editor can't be sure of is left alone:** `thing.speed` where the code doesn't show
  what `thing` is (a value from somewhere it can't follow). The status line says how many and
  where (`left 1 .speed of unknown type (enemy.odin:24)`); the build tells you if one needed
  renaming. Another struct's field of the same name is never renamed.
- **A name that's taken** is refused in the box: another declaration of the scripts, a field the
  struct already has, a script or type the project already has.
- **What can't be renamed from here:** an LDtk entity's fields set script fields by their names;
  when a renamed field may be one of those, the Console says so, so you can rename it in LDtk.
- Anything else (a local variable, a procedure) is renamed by the language server, in the code
  only.

**Values whose field went.** Rename a field by hand (or remove it) and the values nodes stored for
it aren't deleted: the inspector lists them under the fields as kept, ignored by the game, with a
**×** to remove each (an undoable edit). When a field's type changes so that a stored value
doesn't fit any more (`speed` was a number, it's now a `bool`), the inspector says the game uses
the default instead, with a **Reset**.

### Dragging things into the code

Drag something from the editor onto a code tab and it becomes code: you don't have to remember
what a node's path is, which constant names an animation, or which engine procedure plays it.
**Where you let go decides the shape:**

- **In the script's struct** (or anywhere outside a procedure): a **field**, before the struct's
  closing brace. A node becomes a pointer to it (`camera: ^e.Camera2D` with its path as the
  default: the game sets it before `ready`), an asset a field of its handle type, a name (an
  action, an animation, a bus...) an exported field of its name type, so each node can change
  it in the inspector.
- **In a procedure:** a **statement**, on the line after the one you dropped on (or on that line
  when it's empty), indented like the code there. A condition comes as an `if` block with the
  cursor inside it; a value as `x := ...`.
- **Between a call's brackets** (on an argument): the thing's **constant** from
  `scripts/assets.odin` (`ACTION_JUMP`, `PATH_HERO_SPRITE`; text in quotes when it has none, like
  an Animator's clips), or, where the call doesn't take that kind of name, an expression for it
  (`self.hero`, `self.hero.position`). **Inside a string**, the name itself.

**A plain drop does the most common thing. Hold Shift when you let go** for a small menu of the
other useful choices (at most four), with a preview of the code each one writes: Up and Down
move through it, Enter (or a click) writes the one you picked, Escape writes nothing.

**What each kind of thing becomes** (the first is the plain drop; the others are in the menu):

| Drag | From | In a struct | In a procedure | On an argument |
|---|---|---|---|---|
| A node | The scene tree | `hero: ^e.CharacterMover` (its path) | What its kind does first: `e.AudioPlayer_Play(self.jump)`, `e.ParticleEmitter_Start(self.dust)`, `e.Camera2D_Shake(self.camera, 4, 0.3)`; any node: its world position, hide it, remove it | Its path constant where the call takes a path, else the node (`self.hero`); its path as text |
| A property (Position, Rotation, Visible, a label's Text...) | Its label in the inspector | A field for its node | Set it (`self.hero.position.x = 0`), read it; Position also: its world position, move it in the world | Its value (`self.hero.visible`) |
| A script field | Its label in the inspector's Script section | A field for its node | Set it, read it (`self.speed`, or `e.Node_GetScript(self.enemy, Enemy).speed` on another node) | Its value |
| An event | Its name in the inspector's Events section | A field for its node | Listen to it: `e.Event_Subscribe(&self.node.onExit, proc(...) {...}, self)`, reading its data; a script's event: also fire it | Its subject (`&self.door.onOpened`) |
| An animation | The grip beside the Animation panel's list | `runAnimation: e.AnimationName` | Play it, play it from the start, if it's playing | `ANIM_HERO_RUN`, `"run"` |
| A state | The grip by the selected state in the States tab | `attackState: e.StateName` | Travel to it, if it's the current state | `STATE_HERO_BRAIN_ATTACK` |
| A state machine parameter | The grip beside it in the States tab | A field of its name | Set it (a Float or Bool), fire it (a Trigger), read it | `PARAM_HERO_BRAIN_SPEED` |
| An input action | Project Settings > Input's list (the dialog steps aside while you drag) | `jumpAction: e.ActionName` | If it was just pressed, if it's held, if it was just released, its strength | `ACTION_JUMP`, or a condition |
| A group | The chips under the inspector's Groups field | `enemiesGroup: e.GroupName` | For each node in it, add this node to it, if this node is in it | `GROUP_ENEMIES` |
| A bus | The grip on its strip in the Mixer | `musicBus: e.BusName` | Set its volume, mute it | `BUS_MUSIC` |
| A clip | The grip beside the Timeline's clip list | `introClip: e.ClipName` | Play it, play it from the start | `"intro"` |
| A scene | The browser | `forestScene: e.SceneName` (`kind=scene`: a scene list in the inspector) | Change to it, push it over this one | `SCENE_FOREST` |
| A sound | The browser | `jump: e.SoundAsset` (with a line using it) | Play it, play it on a bus | `SOUND_JUMP` |
| Music | The browser | `theme: e.MusicAsset` | Crossfade a MusicPlayer to it, play it on one | `MUSIC_THEME` |
| A component | The browser | `coin: e.ComponentAsset` | Add one here, add one under this node | `COMPONENT_COIN` |
| An image, a font, a data resource, an animation asset | The browser | A field of its handle type | Load it (`e.Asset_Texture`, `e.Asset_Font`, `e.Data`), use the animations on a sprite | Its constant |
| A dialogue | The browser | A field with its path | Show it in a new dialogue box | `DIALOGUE_STORY` |

The grips (a small dotted handle) show only while a code tab is open; the labels, event names,
action rows and browser rows are dragged as they are. A press that doesn't move still does what a
click does (it selects the row, opens the scene).

**The code uses what your script already has.** Code that needs a node uses your script's field
for it when there's one (a field whose default path leads to that node; for something without a
node of its own, like music played on a MusicPlayer, the script's field of that type, else the
scene's first node of it), and `self.node` for the node the script is on. When the
script has none, **the drop adds the field too** (`sprite: ^e.AnimatedSprite` with the node's
path), in the same step. Everything a drop writes is **one step you can undo** with Ctrl+Z, and
the cursor ends where you'd type next: after the statement, inside the `if` block, before a value
you'll want to change. "The script" is the procedure's parameter of your struct's type (`self` in
the template's procedures).

### Code actions (Ctrl+.)

Press **Ctrl+.** (or right-click > **Quick Fix**) and, besides the fixes for a problem at the
caret, the menu lists what the editor can do there for your project. Each is offered only where
it applies, shows the code it writes beside the menu while it's selected, and is **one step you
can undo** with Ctrl+Z. Up and Down choose, Enter applies, Escape closes.

| Where the caret is | Actions |
|---|---|
| A node field (`door: ^e.Sprite`, or `self.door` in the script's code) | **Handle door's onExit** (one per event the node has): writes a handler procedure before the script's registration and subscribes it in `ready` (adding `ready` when there's none): `if self.door != nil do e.Event_Subscribe(&self.door.onExit, Hero_onDoorExit, self)` |
| The script struct's line (or its `using script` line, or its `Script_Register`) | **Handle its Sprite's onExit**...: the same for the node the script runs on, when every node running it is of one kind |
| A field that isn't exported yet (of a type the inspector edits) | **Export speed**: adds `` `export:"default=250"` ``, the default from where your code first sets it (`self.speed = 250`), else 0, `false`, the first node that fits for a node field. For numbers also **Export speed with a range...** |
| An exported field | **Remove export from speed** (values nodes stored for it stay, listed in the inspector to remove); **Set speed's range...** for numbers; **Show speed in the inspector** |
| A `^e.StateMachine` field in the script's code, or a blank line there | **Insert a switch over brain's states**: `switch e.StateMachine_Current(self.brain)` with a `case` per state's constant (`STATE_HERO_BRAIN_IDLE`), inside `if self.brain != nil` |
| A struct with `using script: e.Script` (or an engine node type first) that nothing registers | **Register Loose as a script** (or **as a node type**): the `@(init)` registration New Script writes, with `ready` and `update`, and the `vendor:sdl3` import if the file lacks it |
| A `Script_Register` (or `NodeType_Register`) | **Add the update hook**, **draw**, **destroy**... the hooks it doesn't have, with their parameters; the physics ones (`collisionEnter`...) when the script runs on a body or an area, `sceneChanged` and `loaded` for a global |

**The Range dialog** (from **...with a range...** and **Set ...'s range...**) asks for **Min**,
**Max** and **Default** (empty: no limit) and says what it writes (`export:"default=3 min=0
max=9"`); **OK** writes it into the code, **Cancel** writes nothing. It refuses a range whose min
is over its max, a default outside it, or a fraction for an `int`.

**A handler subscribed in code** runs for every node using the script, in every scene. To
connect one particular node's event to another node's script instead, use **Listen...** in the
inspector's Events section (see [Listening to an event](scripts.md#listening-to-an-event)).

**Between the inspector and the code:**

- **Show speed in the inspector** (on an exported field) selects a node running the script (the
  selected one if it does, else one in the open scene, else the first: its scene opens) and
  scrolls the inspector to the field.
- In the inspector, **Ctrl+click** a script field's label, or right-click it and choose **Go to
  Declaration**, to open the script at the field.

### The running game in the code

While your game runs from **Play** (F5), its scripts' code tabs show what the game is doing.

**Live values.** Each script's struct line says which running node its values come from
(`live: Hero`), and every field line shows that node's value in the game (`= 312`), updated four
times a second: exported fields and your script's own state alike (`hp`, `timer`, `state`). When
the node has its own value in the inspector, the hint says so too (`= 312  (Hero's own: 300)`).
The values come from:

1. the node you picked in the hint's menu: when several running nodes use the script, the hint
   reads `live: Hero (1 of 3) ▾`; click it to choose another;
2. else the node chosen in the [Live tab](live.md), when it runs the script;
3. else the node selected in the scene, when it runs the script;
4. else the first running node that runs it.

Choosing another node in the Live tab or the scene goes back to that rule. Only the fields on
the lines you can see are asked for, so a long script costs the game nothing more. The values go
when the game stops.

**Scrubbing numbers.** Hold **Alt** and drag a number in an exported field's default
(`` speed: f32 `export:"default=250 min=0 max=400"` ``) left or right: the running game's value
changes as you drag (one step every few pixels; **Shift** for finer steps), starting from the
game's value, kept within the field's `min` and `max`. The code itself doesn't change while you
drag. When you let go, a menu asks where the value goes:

| Choice | What it changes |
|---|---|
| **Write ... as the default in the code** | The `default=` in the code tab (Ctrl+Z undoes it; save to keep it: hot reload restarts the game with it). Every node without its own value uses it |
| **Write ... to Hero's own value (the inspector)** | That node's value in the scene, as if typed in the inspector (Ctrl+Z in the scene undoes it). Offered first when the node already has its own value, since a new default wouldn't change that node |
| **Keep ... in the running game only** | Nothing: the game keeps it until it stops (Escape does the same) |

A number in a procedure's code (`x := 250`) can't be scrubbed: changing it means building the
game again, and hot reload restarts the game, so it couldn't follow your drag. A plain Alt+click
still adds a cursor.

**Log points.** To see a value at a line without adding a log line to your script, set a **log
point**: click in the gutter's marker column (just left of the code) beside a line inside a
procedure, or right-click the line and choose **Add Log Point...**. Type what to log, an
expression or several with commas (`self.hp, damage`), and press **OK**. The line gets a diamond
in the gutter and its expression after it.

Each time the game reaches that line (before running it), the Console shows a **logpoint** line:
`hero.odin:42: self.hp = 3, damage = 1`. Click its location to go to the line. Your script isn't
changed: while log points are on, the editor builds the game from a copy of the scripts with the
log lines added on the same lines, so line numbers and errors still match your file. If the game
is running, adding, changing or turning off a log point builds it again and restarts it where it
was ([hot reload](scripts_node_types_hot_reload.md)); otherwise it applies from the next Play.
Exported games never have them.

Click a log point's diamond to **edit** it, **turn it off** (it stays, dimmed, logging nothing)
or **remove** it. Log points are kept per project, for you (`.editor/logpoints.ini`, which git
ignores), and follow their line when you add lines above it. A log point can't go on a `case` or
`else` line, a line that continues the statement above, or a line inside a literal: put it on
the statement's first line, or the line below.

## Using an external editor instead

To open scripts in another program, open **Edit > Settings > Editor** and, under **Scripts**:

| Setting | What it does |
|---|---|
| **Code editor** | Untick **Use the built-in code editor**: scripts then open in the program below |
| **External program** | The program: a name found in your PATH (`zed`, `code`) or its full path (**Browse...** picks it). The line under it says what it found, or "Not found" |
| **Arguments** | What the program is given. `{file}` is the script, `{line}` its line, `{column}` the column (an error's, else 1), `{folder}` the project's `scripts/` folder. Without `{file}`, the file is added at the end |

The default is Zed with `{folder} {file}:{line}`. For VS Code, set the program to `code` and the
arguments to `{folder} --goto {file}:{line}`.

Tips:

- **Keep `{folder}` in the arguments.** It opens the scripts folder as the program's workspace,
  so its Odin language server finds the `ols.json` the editor writes there: that's what makes
  completion know the engine (`e.`) and your other scripts.
- **Zed:** install its **Odin** extension (Extensions, search "Odin"): it brings highlighting and
  OLS. The built-in code editor can use that OLS too.
- The program runs in the scripts folder. If it exits with an error straight away, the Console
  says so: check the program and its arguments.
- The program doesn't tell the editor about changes: save in it, then Play or Build Scripts
  (Ctrl+B) as usual.

## Questions

**There's no completion, and the status line says "off (no ols)".** No language server was found.
Install OLS (or Zed with its Odin extension), or type its path in Settings > Editor > Language
server, then open the script again.

**Completion doesn't know the engine (nothing after `e.`).** The language server reads
`scripts/ols.json`. The editor writes it when you open a script; check that the file exists, and
that it wasn't replaced by one of your own. With an external editor, keep `{folder}` in the
arguments.

**An error shows in the code, but the game builds.** Or the other way round: the underlines come
from the language server, which can be a moment behind, or a different version from the compiler.
The **Output** tab after Build Scripts (Ctrl+B) has the compiler's own word.

**A constant doesn't complete, or completes but the build says it doesn't exist.** The editor
writes `scripts/assets.odin` when you save the project (and before every build): a scene, node
or animation you just added gets its constant then. Save (Ctrl+S) first.

**A name is underlined but the game has it.** The game made it while running: a node added by
code, a group added in another way than `Node_AddToGroup`, an animation made in code. Pass it
through a variable, or name it with what your code uses; the warning doesn't stop the build.

**A name in a string doesn't complete.** The call must be an engine procedure through its
import (`e.Game_ChangeScene(...)`), and the list opens on the opening quote or a letter (Ctrl+Space
otherwise). Node paths need the script attached to a node first; animations, states and clips
need a node field (`self.sprite`) to know which node's, otherwise every one of the project shows.

**The inspector says "From the source: not built yet."** The fields come from the script's
source, which changed since the last build (or there's been none). They're right for editing; the
game runs the new code once it's built (Ctrl+B, or Play).

**There are no live values beside my script.** The game must be running from Play (not an
exported game), and a node in the playing scene must run the script: the struct line says which.
Fields on lines out of view are asked for when you scroll to them.

**My log point logs nothing.** Is it on (a bright diamond)? Is hot reload on (Settings > Editor)?
Without it, log points apply from the next Play. If the expression doesn't compile, the Output
tab shows the error on your line: edit the log point. A log point whose line was changed or
deleted is skipped (the Output tab says so) until you set it again.

**I pressed Ctrl+D in the code and it didn't duplicate my node.** While you type code, Ctrl+D
selects the next match. Click the scene tree or the viewport first.

**I want my own shortcuts in the code editor.** Use the palette's Keymap Editor, or import your
Zed or VS Code keymap. Settings > Keyboard only changes the editor's other shortcuts.
