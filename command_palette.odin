package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"
import ce "code_editor/editor"

/*
The command palette, also Search Everywhere (TODO.md's "UI and UX" round 1, 2026-10-25): one
popup (`view_command_palette.odin`) that finds anything in the editor by typing a few of its
letters (`Command_Palette`: Ctrl+Shift+P or Ctrl+P; Edit > Command Palette, Help > Search
Everywhere).

What it lists (`Palette_Entries`), each a `PaletteKind`:
- **Actions**: every keymap action of the mode with its shortcut (`ACTION_LABELS`), and the menus'
  items that aren't keymap actions (New Script, New Scene, Grid Settings, Keyboard Shortcuts)
- **Code**: in a code tab, the code editor's own palette (its commands with their keys, windows,
  utilities, color themes: `CodeEditor_PaletteEntries`). The code editor's palette isn't shown
  any more: its keys and its menu open this one (code_editor_host.odin), so there's one palette
- **Settings**: every row of the Settings dialog (`PALETTE_SETTINGS`, the theme and viewport
  colors, the Project tab's pages): Settings opens on its tab with the row lit and scrolled to
- **Nodes** of the open scene (selected, their parents expanded), **assets**, scenes and scripts
  (selected in the browser; a scene opens, a script opens in its code tab), **docs**: the manual's
  and the API's pages (the docs window opens at the page)

The query: a **prefix** keeps one category (`PALETTE_PREFIXES`: `>` actions and code commands,
`,` settings, `@` nodes, `#` assets, `?` docs; the popup's category buttons type them), the rest
is matched fuzzily against each entry's label (the code editor's `ce.fuzzy_score`: a
case-insensitive subsequence; word starts and runs of letters score higher, shorter labels win
ties), best first, then by category (`PaletteKind` order) and label. An empty query lists
everything in category order. At most `PALETTE_SHOWN` rows show (the count says how many match).

Keys: typing filters, Up / Down (Page Up / Page Down by a page) move the highlight, Enter runs it,
Escape closes; a click runs a row. Nothing moves (no animation): the popup is there at once.
*/

// What a palette entry is
PaletteKind :: enum {
	Action,
	// A code editor command (in a code tab)
	Code,
	Setting,
	Node,
	Asset,
	Doc,
}

// The prefix that keeps a category (`>` keeps actions and the code editor's commands)
PALETTE_PREFIXES := [PaletteKind]u8{.Action = '>', .Code = '>', .Setting = ',', .Node = '@', .Asset = '#', .Doc = '?'}
// What the rows and the category buttons call each kind
PALETTE_KIND_NAMES := [PaletteKind]string{.Action = "Action", .Code = "Code", .Setting = "Setting", .Node = "Node", .Asset = "Asset", .Doc = "Docs"}
// The most rows shown (the rest are counted: type more to find them)
PALETTE_SHOWN :: 60

// One thing the palette can run
PaletteEntry :: struct {
	kind: PaletteKind,
	// What the query matches, and what's shown after it (a shortcut, a path, the page's address)
	label, detail: string,
	// .Action: the message sent
	msg: Msg,
	// .Code: the code editor's entry, run in the code tab
	code: ce.Palette_Entry,
	// .Setting: the Settings tab, and the Project tab's page
	settingTab: SettingsTab,
	projectTab: ProjectSettingsTab,
	// .Node: the node's index in the open scene; .Asset: the asset's index (or a scene's, a
	// script's: `browser`), .Doc: the page's address
	index: int,
	browser: BrowserItemKind,
	address: string,
}

// A matching entry, and its score for the query
PaletteMatch :: struct {
	entry: int,
	score: int,
}

// The popup's state
PaletteState :: struct {
	open: bool,
	// The query as typed, the prefix included (owned)
	query: string,
	// The highlighted row (in the matches' order)
	highlight: int,
}

// One row of the Settings dialog: its tab and its label (`settingRow`'s)
PaletteSetting :: struct {
	tab: SettingsTab,
	label: string,
}

/*
The Settings dialog's rows, by tab: `palette_settings_cover_the_dialog` checks each `settingRow`
label in view_settings.odin is here. The theme and viewport colors (`THEME_COLOR_LABELS`,
`VIEWPORT_COLOR_LABELS`) and the Project tab's pages are added from their tables.
*/
PALETTE_SETTINGS := []PaletteSetting{
	{.Appearance, "Preset"}, {.Appearance, "Theme"}, {.Appearance, "Text size"}, {.Appearance, "Spacing"},
	{.Appearance, "Row height"}, {.Appearance, "Corners"}, {.Appearance, "Selection opacity"},
	{.Editor, "Merge edits within"}, {.Editor, "Longest merged edit"}, {.Editor, "Undo steps kept"},
	{.Editor, "Console lines kept"}, {.Editor, "Code editor"}, {.Editor, "Auto-close"}, {.Editor, "Language server"},
	{.Editor, "LDtk program"}, {.Editor, "Aseprite program"}, {.Editor, "External program"}, {.Editor, "Arguments"},
	{.Editor, "Optimized Play"}, {.Editor, "Hot reload"}, {.Editor, "Wheel pans"}, {.Editor, "Rotation snap"},
	{.Editor, "Scale snap"}, {.Editor, "Audio device"},
	{.Keyboard, "Keyboard shortcuts"},
	{.Toolchain, "Odin program"},
}

/*
Everything the palette lists now (see the file's doc block): the mode's actions, the code tab's
commands (`codePath`: the code tab showing, "" none), the settings, the open scene's nodes, the
project's assets, scenes and scripts, the docs' pages.

Returns:
- The entries, by category (temp allocated)
*/
Palette_Entries :: proc(s: ^State, codePath: string) -> []PaletteEntry {
	out := make([dynamic]PaletteEntry, context.temp_allocator)
	keymap := &s.settings.keymap
	browserFocused := s.browserFocused && s.mode == .Scene
	for action in Action {
		label := ACTION_LABELS[action]
		if label == "" || action == .Command_Palette || !Action_InMode(action, s.mode, browserFocused) do continue
		chord := Keymap_Shortcut(keymap, action)
		append(&out, PaletteEntry{kind = .Action, label = label, detail = chord == {} ? "" : Chord_Format(chord), msg = Msg(action)})
	}
	// The menus' items that aren't keymap actions
	if s.mode == .Scene {
		append(&out,
			PaletteEntry{kind = .Action, label = "New script", detail = "Scripts menu", msg = Msg(New_Script_Opened{})},
			PaletteEntry{kind = .Action, label = "Grid settings", detail = "View menu", msg = Msg(Open_Grid_Settings{})})
	}
	append(&out,
		PaletteEntry{kind = .Action, label = "New scene", detail = "Scene menu", msg = Msg(Scene_Action{.New, -1})},
		PaletteEntry{kind = .Action, label = "Keyboard shortcuts", detail = "Help menu", msg = Msg(Open_Keyboard_Settings{})})

	// The code editor's commands, in a code tab
	if codePath != "" {
		for entry in CodeEditor_PaletteEntries(codePath) {
			detail := entry.detail == "" ? "Code editor" : fmt.tprintf("Code editor  %s", entry.detail)
			append(&out, PaletteEntry{kind = .Code, label = entry.label, detail = detail, code = entry})
		}
	}

	// Settings
	for setting in PALETTE_SETTINGS {
		append(&out, PaletteEntry{kind = .Setting, label = setting.label, detail = fmt.tprintf("Settings > %v", setting.tab), settingTab = setting.tab})
	}
	for label in THEME_COLOR_LABELS do append(&out, PaletteEntry{kind = .Setting, label = label, detail = "Settings > Appearance", settingTab = .Appearance})
	for label in VIEWPORT_COLOR_LABELS do append(&out, PaletteEntry{kind = .Setting, label = label, detail = "Settings > Appearance", settingTab = .Appearance})
	if s.project.rootPath != "" {
		for tab in ProjectSettingsTab {
			append(&out, PaletteEntry{kind = .Setting, label = fmt.tprintf("Project %v settings", tab), detail = "Settings > Project",
				settingTab = .Project, projectTab = tab})
		}
	}

	// The open scene's nodes
	if s.currentScene >= 0 && s.currentScene < len(s.project.scenes) {
		scene := &s.project.scenes[s.currentScene]
		for node, i in scene.nodes {
			append(&out, PaletteEntry{kind = .Node, label = node.name, detail = fmt.tprintf("%v  %s", node.kind, Palette_NodePath(scene, i)), index = i})
		}
	}

	// Scenes, assets and scripts
	for &scene, i in s.project.scenes {
		if Scene_IsComponent(&scene) do continue
		append(&out, PaletteEntry{kind = .Asset, label = scene.name, detail = "Scene", index = i, browser = .Scene})
	}
	for asset, i in s.project.assets {
		append(&out, PaletteEntry{kind = .Asset, label = filepath.base(asset.path), detail = fmt.tprintf("%v  %s", asset.kind, asset.path), index = i, browser = .Asset})
	}
	for script, i in s.scriptFiles {
		append(&out, PaletteEntry{kind = .Asset, label = filepath.base(script), detail = fmt.tprintf("Script  %s", script), index = i, browser = .Script})
	}

	// The docs' pages
	for page in Docs_Library().pages {
		if page.title == "" do continue
		append(&out, PaletteEntry{kind = .Doc, label = page.title, detail = page.api ? "API reference" : "Manual", address = page.address})
	}
	return out[:]
}

/*
A node's ancestors' names, the scene's top first ("Level > Player"; "" for a top-level node).
*/
Palette_NodePath :: proc(scene: ^SceneDef, index: int) -> string {
	chain := Breadcrumbs_Chain(scene, index)
	if len(chain) < 2 do return ""
	names := make([dynamic]string, context.temp_allocator)
	for n in chain[:len(chain) - 1] do append(&names, scene.nodes[n].name)
	return strings.join(names[:], " > ", context.temp_allocator)
}

/*
Splits a query into the categories its prefix keeps and the text to match.

Returns:
- The categories (every one without a prefix), and the rest of the query, trimmed
*/
Palette_ParseQuery :: proc(query: string) -> (kinds: bit_set[PaletteKind], text: string) {
	q := strings.trim_left_space(query)
	if len(q) > 0 {
		for prefix, kind in PALETTE_PREFIXES do if q[0] == prefix do kinds += {kind}
	}
	if kinds == {} do return ~bit_set[PaletteKind]{}, strings.trim_space(q)
	return kinds, strings.trim_space(q[1:])
}

/*
The entries a query matches, best first (see the file's doc block for the order).

Returns:
- The matches (temp allocated)
*/
Palette_Matches :: proc(entries: []PaletteEntry, query: string) -> []PaletteMatch {
	kinds, text := Palette_ParseQuery(query)
	out := make([dynamic]PaletteMatch, context.temp_allocator)
	for entry, i in entries {
		if entry.kind not_in kinds do continue
		m, ok := ce.fuzzy_score(entry.label, text)
		if !ok do continue
		append(&out, PaletteMatch{entry = i, score = text == "" ? 0 : m.score})
	}
	Sort :: struct { entries: []PaletteEntry }
	sortCtx := Sort{entries}
	context.user_ptr = &sortCtx
	slice.stable_sort_by(out[:], proc(a, b: PaletteMatch) -> bool {
		if a.score != b.score do return a.score > b.score
		entries := (^Sort)(context.user_ptr).entries
		ea, eb := entries[a.entry], entries[b.entry]
		if ea.kind != eb.kind do return ea.kind < eb.kind
		// An empty query keeps each category's own order (the menus', the tree's, the manual's)
		if a.score == 0 do return a.entry < b.entry
		return ea.label < eb.label
	})
	return out[:]
}

// The code tab the palette's code commands are for ("" when none shows)
Palette_CodePath :: proc(s: ^State) -> string {
	return s.mode == .Scene ? CodeTabs_Active(s) : ""
}

// Opens the palette, empty
Palette_Open :: proc(s: ^State) {
	delete(s.palette.query)
	s.palette = {open = true, query = strings.clone("")}
}

// Closes the palette
Palette_Close :: proc(s: ^State) {
	delete(s.palette.query)
	s.palette = {}
}

// The palette's messages
// The query typed
Palette_Query_Changed :: distinct string
// Up / Down (±1), Page Up / Page Down (± a page)
Palette_Highlight_Moved :: distinct int
// Enter: runs the highlighted row
Palette_Confirmed :: struct {}
// A row clicked (in the matches' order)
Palette_Chosen :: distinct int
// A category button: its prefix replaces the query's (-1: All, no prefix)
Palette_Category_Picked :: distinct int
Palette_Closed :: struct {}

/*
The palette's messages (from `update`).

Returns:
- The command, and whether the message was one of these
*/
Palette_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Palette_Query_Changed:
		delete(s.palette.query)
		s.palette.query = strings.clone(string(v))
		s.palette.highlight = 0
	case Palette_Category_Picked:
		_, text := Palette_ParseQuery(s.palette.query)
		query := text
		if int(v) >= 0 && int(v) < len(PaletteKind) do query = fmt.tprintf("%c%s", PALETTE_PREFIXES[PaletteKind(v)], text)
		// The text is part of the old query: copied before it goes
		query = strings.clone(query)
		delete(s.palette.query)
		s.palette.query = query
		s.palette.highlight = 0
	case Palette_Highlight_Moved:
		count := min(len(Palette_Matches(Palette_Entries(s, Palette_CodePath(s)), s.palette.query)), PALETTE_SHOWN)
		if count > 0 do s.palette.highlight = clamp(s.palette.highlight + int(v), 0, count - 1)
	case Palette_Confirmed:
		return Palette_RunRow(s, s.palette.highlight), true
	case Palette_Chosen:
		return Palette_RunRow(s, int(v)), true
	case Palette_Closed:
		Palette_Close(s)
	case:
		return {}, false
	}
	return {}, true
}

/*
Runs a row of the palette's matches (closing it).

Returns:
- The command (an action's message, sent next)
*/
Palette_RunRow :: proc(s: ^State, row: int) -> skald.Command(Msg) {
	codePath := Palette_CodePath(s)
	entries := Palette_Entries(s, codePath)
	matches := Palette_Matches(entries, s.palette.query)
	Palette_Close(s)
	if row < 0 || row >= len(matches) || row >= PALETTE_SHOWN do return {}
	return Palette_Run(s, entries[matches[row].entry], codePath)
}

/*
Runs a palette entry: sends an action, runs a code command in its tab, opens Settings at a
setting, selects a node or an asset, opens a page of the docs.

Returns:
- The command (an action's message)
*/
Palette_Run :: proc(s: ^State, entry: PaletteEntry, codePath := "") -> skald.Command(Msg) {
	switch entry.kind {
	case .Action:
		return skald.cmd_now(entry.msg)
	case .Code:
		CodeEditor_RunPaletteEntry(codePath, entry.code)
	case .Setting:
		// The dialog opens on the tab it has (the Project tab on its page)
		s.settingsDialog.tab = entry.settingTab
		if entry.settingTab == .Project do s.projectSettings.tab = entry.projectTab
		SettingsDialog_Open(s)
		// A row is lit and scrolled to (the Keyboard and Project tabs are the row): its label, from
		// PALETTE_SETTINGS or the color tables, lives as long as the editor
		if entry.settingTab != .Project && entry.settingTab != .Keyboard {
			s.settingsDialog.highlight = entry.label
			settingsRevealWanted = true
		}
	case .Node:
		Mode_Set(s, .Scene)
		s.codeTab, s.slicer.shown = 0, 0
		scene := &s.project.scenes[s.currentScene]
		if entry.index < 0 || entry.index >= len(scene.nodes) do break
		// Its parents open in the tree, so its row shows
		for p := scene.nodes[entry.index].parent; p >= 0 && p < len(scene.nodes); p = scene.nodes[p].parent do scene.nodes[p].expanded = true
		clear(&s.selection)
		s.selectedNode = entry.index
	case .Asset:
		Mode_Set(s, .Scene)
		switch entry.browser {
		case .Scene:
			s.codeTab, s.slicer.shown = 0, 0
			s.browserOpen[.Scenes] = true
			s.browserSelection = {kind = .Scene, folder = .Scenes, index = entry.index}
			openScene(s, entry.index)
		case .Asset:
			if entry.index >= len(s.project.assets) do break
			s.browserOpen[AssetFolder(s.project.assets[entry.index].kind)] = true
			selectAsset(s, entry.index)
		case .Script:
			if entry.index >= len(s.scriptFiles) do break
			s.browserOpen[.Scripts] = true
			s.browserSelection = {kind = .Script, folder = .Scripts, index = entry.index}
			path := joinPath(s.project.rootPath, s.scriptFiles[entry.index], allocator = context.temp_allocator)
			if absolute, err := os.get_absolute_path(path, context.temp_allocator); err == nil do path = absolute
			return Script_Open(s, path, 1)
		case .Folder, .None:
		}
	case .Doc:
		Docs_Navigate(&s.docs, entry.address)
	}
	return {}
}
