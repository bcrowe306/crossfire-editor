---
title: The code editor
description: Write your game's Odin scripts in tabs beside your scenes, with completion, error checking, go to definition, find and replace, and a command palette, or use an external editor such as Zed or VS Code instead.
order: 33
---

# The code editor

Your game's scripts are Odin files in the project's `scripts/` folder. The editor has its own
**code editor** for them: each script opens in a **code tab** next to the scene tabs, in the
middle of the window. It colors Odin code, and with the Odin language server it completes what
you type, underlines mistakes and jumps to where things are defined.

If you'd rather use another program (Zed, VS Code...), you can: see
[Using an external editor instead](#using-an-external-editor-instead).

- [Opening a script](#opening-a-script)
- [Code tabs](#code-tabs)
- [Saving](#saving)
- [Closing a tab](#closing-a-tab)
- [Files changed on disk](#files-changed-on-disk)
- [Completion and errors: the Odin language server](#completion-and-errors-the-odin-language-server)
- [Going to definitions](#going-to-definitions)
- [Going to an error from the Output tab or the Console](#going-to-an-error-from-the-output-tab-or-the-console)
- [Find and replace](#find-and-replace)
- [The command palette](#the-command-palette)
- [Editing shortcuts](#editing-shortcuts)
- [Which shortcuts work while you type code](#which-shortcuts-work-while-you-type-code)
- [Keymaps and themes](#keymaps-and-themes)
- [Auto-closing brackets and quotes](#auto-closing-brackets-and-quotes)
- [Dropping nodes and assets onto the code](#dropping-nodes-and-assets-onto-the-code)
- [Using an external editor instead](#using-an-external-editor-instead)
- [Questions](#questions)

## Opening a script

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

## Code tabs

Code tabs come after the scene tabs. Each shows the file's name, with a **●** after it while it
has changes you haven't saved. Click a tab to show its file; click a scene tab to go back to the
scene. Anything that opens another scene (the browser, Play Scene...) shows the scene too.

Under the code, a status line shows:

- the file's name, with "(unsaved)" while it has changes (or the code editor's own messages)
- **Ln** and **Col**: where the caret is
- **Language server**: whether completion and error checking are working (`off (no ols)` when
  there's no language server; see below)

When the window is narrow, the tab strip scrolls sideways: use the mouse wheel over it.

## Saving

- **File > Save** (Ctrl+S) saves the project **and** every code tab with changes.
- The **save button** in the code view's header (the disk icon) saves only the script that shows.
- **Play** (F5), **Build Scripts** (Ctrl+B) and **Export** save the scripts first, so the game
  always runs what you see.

After a script is saved, the editor builds the scripts in the background, so the inspector learns
about new fields you added. Build errors go to the **Output** tab.

Scripts you haven't saved count as unsaved changes: the window's title gets its `*`, and quitting
asks first.

## Closing a tab

Click the tab's **×**, middle-click the tab, or use **Scripts > Close Code Tab** (Ctrl+W, also
while you type in the code).

A tab with unsaved changes asks **"Save changes to mover.odin?"** first:

| Button | What it does |
|---|---|
| **Save** | Saves the file, then closes the tab |
| **Don't Save** | Closes the tab; the changes are lost |
| **Cancel** | Keeps the tab open |

When a tab closes, the tab beside it shows, or the scene when it was the last.

## Files changed on disk

If another program changes a script that's open (another editor, Git switching branches, a pull),
the code tab notices within about a second, and as soon as you show its tab again:

- **No unsaved changes in the tab:** it reloads the file by itself and keeps the caret on its
  line. The Console says "mover.odin changed on disk: reloaded".
- **Unsaved changes in the tab:** a yellow bar over the code says "mover.odin changed on disk, and
  you have unsaved changes." Choose **Reload (lose mine)** to take the file from disk, or **Keep
  mine** to keep your text (your next save writes it over the file).

## Completion and errors: the Odin language server

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

The editor writes `scripts/ols.json` for the language server, so it knows where the engine and
your project's scripts are. It keeps it up to date by itself. If you write your own `ols.json`
(without the editor's `_generated_by` line), the editor leaves it alone.

## Going to definitions

| Keys | What it does |
|---|---|
| **F12**, or Ctrl+click a name | Go to Definition: jumps to where it's defined. In another file, that file opens in its own tab |
| **Alt+F12** | Peek Definition: shows the definition in a small window over the code (Enter opens it, Escape closes) |
| **Shift+F12** | Find All References: a panel listing every use; click one, or step through them with **F4** and **Shift+F4** |
| **Alt+Left** / **Alt+Right** | Back and forward through the places you jumped to |

These need the language server too. A definition outside your project (in the engine or Odin's
own library) opens **read only**: the status line says "(read only: outside the project)", and
typing changes nothing, since those files are shared by every project.

## Going to an error from the Output tab or the Console

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

## Find and replace

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

## The command palette

**Ctrl+P** (also Ctrl+Shift+P, or F1 while you type code) opens the **command palette**: a
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

## Editing shortcuts

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

## Which shortcuts work while you type code

While the keyboard is in the code (after you click in it), the code editor gets your keys. Only
these editor shortcuts still work then:

| Shortcut | Action |
|---|---|
| Ctrl+S | Save (the project and every script) |
| F5, Ctrl+F5, F6, Shift+F5 | Play, Play Scene, Pause, Stop |
| Ctrl+B | Build Scripts |
| Ctrl+W | Close the code tab |
| Ctrl+Shift+E | Export |
| Ctrl+J | Show or hide the bottom panel |
| Ctrl+, | Settings |
| Ctrl+Q | Quit |

(These are the defaults; if you change them in Settings > Keyboard, your keys work instead.)

The others mean something else in the code: Ctrl+D selects the next match instead of duplicating
a node, F1 opens the palette instead of this manual, Ctrl+O opens another script in a tab (a file
dialog) instead of another project, and Ctrl+Shift+S saves the script under a new name. Click
outside the code (the scene tree, the viewport) and the editor's shortcuts are back.

## Keymaps and themes

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

## Auto-closing brackets and quotes

When you type an opening bracket or quote, the code editor adds its closer after the caret:
`(` `[` `{` `"` `'` and `` ` ``. Also:

- Typing the closer when it's already next just steps over it.
- **Backspace** between an empty pair removes both.
- **Enter** between `{}`, `()` or `[]` puts the closer on its own line and indents the line
  you're on.
- With text selected, typing an opening bracket or quote wraps the selection in the pair.
- `<` closes only straight after a name (`Map<`), since elsewhere in code it means "less than".

Turn it off with **Settings > Editor > Auto-close**.

## Dropping nodes and assets onto the code

You can drag things into the code to add **exported fields** (the values the inspector shows) to
the script's struct:

- **A node from the scene tree:** drag it onto the code. The script gets a field pointing at that
  node, named after it, like `camera: ^e.Camera2D` with the node's path as its default. When the
  game starts, the field already points at the node. In the inspector, the field becomes a list
  of the scene's nodes of that kind.
- **An asset from the browser** (an image, sound, music, font, component, data resource or
  animation): drag it onto the code. The script gets a field of its handle type (`TextureAsset`,
  `SoundAsset`, `ComponentAsset`...) set to that asset, with a comment showing a line of code that
  uses it. The inspector can then choose another asset for each node.

The field goes before the closing brace of the file's script struct, in one step you can undo
with Ctrl+Z. Save the script so the inspector shows the new field.

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

**I pressed Ctrl+D in the code and it didn't duplicate my node.** While you type code, Ctrl+D
selects the next match. Click the scene tree or the viewport first.

**I want my own shortcuts in the code editor.** Use the palette's Keymap Editor, or import your
Zed or VS Code keymap. Settings > Keyboard only changes the editor's other shortcuts.
