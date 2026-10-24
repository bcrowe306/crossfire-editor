package crossfire_editor

import "core:encoding/ini"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "gui:skald"

/*
Editor modes: the tabs beside the menu bar (the mode bar) switch the whole workspace between the
editor's modes. **Scene** is the editor for scenes and their nodes (the viewport, the scene tree,
the inspector, the code tabs); **Level** is the world editor (level_mode.odin: an LDtk project's
levels on a big canvas). More can follow (3D, a pixel editor).

What a mode owns (`EDITOR_MODES`, its `EditorModeInfo`):
- its workspace, the area between the toolbar and the status bar (`view`, built by `sized`);
- its panel sizes and their layout state (`Mode_Layout`: the Scene mode's is `State.layout`, the
  Level mode's `State.level.layout`), which the dividers' messages change for the mode that shows;
- its bottom panel's tabs (`bottomTabs`) and the one it shows (`Mode_BottomTab`);
- the keys that only make sense in it (`ACTION_KEY_RULES`' `onlyIn`: the viewport's tools, node
  edits). The menu bar disables those items in other modes, so their shortcuts don't fire either.

Shared by every mode: the menu bar, the toolbar's file, undo and play buttons and Export (its
tools are the Scene mode's), the project browser, the Console and Output tabs (the same lists,
their scroll kept), Settings and Project Settings, the docs window, and **one undo history**:
each step remembers the mode it was made in (`UndoCommand.modeBefore` / `modeAfter`), and undo /
redo switch back to it, as they switch to a step's scene.

Switching: the mode bar's tabs (`mode-tab-<Name>`), View > Scene Mode / Level Mode, and a keymap
action per mode (`Mode_Scene` Ctrl+Alt+1, `Mode_Level` Ctrl+Alt+2: Ctrl+1 is the viewport's 100%
zoom). What belongs to a mode switches to it (`update`): opening a scene, selecting a node, a code
tab, a bottom tab only another mode has. The mode is remembered per project, in
`.editor/modes.ini` (`Mode_Save`, `Mode_Load`), with the Level mode's world.

**A new mode** needs an `EditorMode` value, its entry in `EDITOR_MODES` (a view, its bottom tabs),
an `Action` to switch to it (a `[keymap]` line in settings.default.ini, an `ACTION_LABELS` entry)
and its state beside `State.level`.
*/

// The editor's modes, in the mode bar's order
EditorMode :: enum {
	// Scenes and their nodes: the viewport, the scene tree and inspector, the code tabs
	Scene,
	// The world: an LDtk project's levels laid out on a canvas (level_mode.odin)
	Level,
}

// A mode's registration: what the mode bar shows and what the mode builds
EditorModeInfo :: struct {
	// Its tab's name and icon
	name, icon: string,
	// What it's for (the tab's tooltip, without the shortcut)
	about: string,
	// The keymap action that switches to it
	action: Action,
	// The workspace (between the toolbar and the status bar), at the size it's given
	view: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View,
	// Its bottom panel's tabs, in order
	bottomTabs: []BottomTab,
	// Its manual page (docs/manual, with an anchor)
	manual: string,
}

// Every mode's registration
EDITOR_MODES := [EditorMode]EditorModeInfo{
	.Scene = {
		name = "Scene", icon = ICON_CUBE, action = .Mode_Scene,
		about = "Scene mode: scenes and their nodes, the viewport, the inspector and code",
		view = sceneModeView,
		bottomTabs = []BottomTab{.Console, .Output, .Animation, .Mixer, .Git, .Tiles, .Timeline, .Live, .States, .Particles, .Dialogue, .Plugins},
		manual = "getting_started#editor-modes",
	},
	.Level = {
		name = "Level", icon = ICON_MAP, action = .Mode_Level,
		about = "Level mode: the world, your LDtk project's levels laid out",
		view = levelModeView,
		bottomTabs = []BottomTab{.LDtk, .Console, .Output},
		manual = "level_mode",
	},
}

// The mode bar's tab or the View menu: show that mode
Mode_Changed :: distinct EditorMode

// A tab clicked in the bottom panel's strip, by its index there (the mode's `bottomTabs`)
Bottom_Tab_Picked :: distinct int

// Where a project's mode is kept, relative to the project
MODES_FILE :: ".editor/modes.ini"

/*
The panel sizes of a mode (the dividers' messages change the shown mode's). The Level mode's start
at their defaults the first time they're asked for.
*/
Mode_LayoutOf :: proc(state: ^State, mode: EditorMode) -> ^Layout {
	switch mode {
	case .Scene: return &state.layout
	case .Level:
		l := &state.level.layout
		if l.leftWidth == 0 {
			workspace := l.workspace
			l^ = LEVEL_LAYOUT_DEFAULT
			l.workspace = workspace == {} ? state.layout.workspace : workspace
		}
		return l
	}
	return &state.layout
}

// The panel sizes of the mode that shows
Mode_Layout :: proc(state: ^State) -> ^Layout {
	return Mode_LayoutOf(state, state.mode)
}

// The bottom tab the shown mode shows
Mode_BottomTab :: proc(state: ^State) -> BottomTab {
	switch state.mode {
	case .Scene: return state.bottomTab
	case .Level: return state.level.bottomTab
	}
	return state.bottomTab
}

// Whether a mode's bottom panel has a tab
Mode_HasBottomTab :: proc(mode: EditorMode, tab: BottomTab) -> bool {
	for t in EDITOR_MODES[mode].bottomTabs do if t == tab do return true
	return false
}

/*
Shows a bottom tab: in the shown mode when it has it, else in the first mode that does, which then
shows (the status bar's branch opens the Git tab in the Scene mode). Opens a collapsed panel.
*/
Mode_ShowBottomTab :: proc(state: ^State, tab: BottomTab) {
	if !Mode_HasBottomTab(state.mode, tab) {
		for mode in EditorMode do if Mode_HasBottomTab(mode, tab) {
			Mode_Set(state, mode)
			break
		}
	}
	switch state.mode {
	case .Scene: state.bottomTab = tab
	case .Level: state.level.bottomTab = tab
	}
	Mode_Layout(state).bottomOpen = true
}

/*
A log tab the editor brings forward (Play's Console, a build's Output): every mode that has it shows
it, without switching modes.
*/
Mode_ShowLogTab :: proc(state: ^State, tab: BottomTab) {
	state.bottomTab = tab
	if Mode_HasBottomTab(.Level, tab) do state.level.bottomTab = tab
}

/*
Switches to a mode and remembers it for the project (`Mode_Save`). Gestures of the mode left
behind end (a drag, a node being renamed in the scene tree).

Inputs:
- state: The editor state
- mode: The mode to show
- save: Write `.editor/modes.ini` (undo and project loads switch without writing)
*/
Mode_Set :: proc(state: ^State, mode: EditorMode, save := true) {
	if state.mode == mode do return
	state.viewport.drag = {}
	state.treeDrag = {}
	state.assetDrag = {}
	CodeDrag_Clear(state)
	if state.rename.active && state.rename.target == .Node {
		delete(state.rename.text)
		state.rename = {}
	}
	state.mode = mode
	if save do Mode_Save(state)
}

/*
Writes the project's mode and the Level mode's world to `.editor/modes.ini` (only when the project
is a folder on disk and the text changed).

Returns:
- "" or what went wrong
*/
Mode_Save :: proc(state: ^State) -> string {
	root := state.project.rootPath
	if root == "" || !os.exists(root) do return ""
	path, _ := filepath.join({root, MODES_FILE}, context.temp_allocator)
	text := fmt.tprintf("; The editor's mode for this project (Crossfire Editor)\nmode = %v\nlevel_file = %s\n", state.mode, state.level.file)
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == text do return ""
	if state.mode == .Scene && state.level.file == "" && !os.exists(path) do return ""
	_ = os.make_directory_all(filepath.dir(path))
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	return ""
}

/*
Reads the project's mode and the Level mode's world from `.editor/modes.ini` (missing or
unreadable: the Scene mode). Called when a project opens.
*/
Mode_Load :: proc(state: ^State) {
	state.mode = .Scene
	delete(state.level.file)
	state.level.file = ""
	delete(state.level.level)
	state.level.level = ""
	path, _ := filepath.join({state.project.rootPath, MODES_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	it := ini.iterator_from_string(string(data))
	for key, value in ini.iterate(&it) {
		switch key {
		case "mode":
			if mode, ok := reflect.enum_from_name(EditorMode, strings.trim_space(value)); ok do state.mode = mode
		case "level_file":
			state.level.file = strings.clone(strings.trim_space(value))
		}
	}
}

/*
The mode bar: a tab per mode (its icon and name; under about 560 px of window only icons), beside
the menu bar. Keys `mode-tab-<Name>`.
*/
modeBarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	compact := s.layout.workspace.x > 0 && s.layout.workspace.x < MODE_BAR_COMPACT_WIDTH
	tabs := make([dynamic]skald.View, context.temp_allocator)
	for info, mode in EDITOR_MODES {
		active := mode == s.mode
		label := compact ? info.icon : fmt.tprintf("%s  %s", info.icon, info.name)
		key := fmt.tprintf("mode-tab-%s", info.name)
		button := skald.button(ctx, label, Msg(Mode_Changed(mode)),
			id = skald.hash_id(key),
			bg = active ? th.color.primary : th.color.surface,
			fg = active ? th.color.on_primary : th.color.fg_muted,
			padding = {th.spacing.sm + 2, 2}, font_size = th.font.size_sm, radius = th.radius.sm,
			width = compact ? math.round(th.font.size_md * 2.2) : 0)
		append(&tabs, skald.tooltip(ctx, button, actionTip(s, info.about, info.action), id = skald.hash_id(fmt.tprintf("%s-tip", key))))
	}
	return skald.row(..tabs[:], spacing = 2, cross_align = .Center)
}

// Under this window width the mode bar shows only its tabs' icons
MODE_BAR_COMPACT_WIDTH :: 560

/*
The workspace of the mode that shows, at the size layout gives it (reported to `update` first:
every mode's layout turns divider positions into panel sizes with it).
*/
modeWorkspaceView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	if size != s.layout.workspace do skald.send(ctx, Workspace_Measured(size))
	return EDITOR_MODES[s.mode].view(ctx, s, size)
}

/*
The modes' messages: switching, a bottom tab picked.

Returns:
- Whether `m` was one
*/
Modes_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Mode_Changed:
		Mode_Set(state, EditorMode(v))
		return {}, true
	case Bottom_Tab_Picked:
		tabs := EDITOR_MODES[state.mode].bottomTabs
		if int(v) < 0 || int(v) >= len(tabs) do return {}, true
		Mode_ShowBottomTab(state, tabs[v])
		if tabs[v] == .Git do return Git_Refresh(state), true
		return {}, true
	case Action:
		for info, mode in EDITOR_MODES do if info.action == v {
			Mode_Set(state, mode)
			return {}, true
		}
	}
	return {}, false
}
