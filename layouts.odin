package crossfire_editor

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
Layouts (TODO.md's "UI and UX" round "Workflow", 2026-10-25). The user's decision: maximize and
presets, no docking.

- **Maximize a panel** (`Layout.maximized`, per mode): a double-click on a panel's header title or
  tab strip (`Maximize_Track`, read in `view` from last frame's rects), View > Maximize Panel or
  `Action.Maximize_Panel` (Ctrl+Shift+M: the panel under the pointer, else the center) shows that
  panel alone over the mode's workspace; the same again, or Escape (`.Deselect` / `.Level_Cancel`),
  restores. The Scene mode's panels: the browser (Left), the center (the viewport, a code or slicer
  tab), the bottom panel, the scene tree, the inspector; the Level mode's: the Levels sidebar
  (Left), the canvas (Center), the bottom panel, the Layers sidebar (Right).
- **Presets** (`LayoutPreset`: the sidebars' widths, the bottom panel's and scene tree's heights,
  the preview's, which panels are open, the bottom tab): built-in ones (`BuiltinLayout`: Default,
  Code, Level, Wide Viewport; `LayoutPreset_Builtin` per mode) and the project's own, saved with
  View > Layout > Save Current Layout As... (a name; the same name replaces it). Reset Layout
  applies Default. A preset applies to the mode that shows.
- **Saved per project** in `.editor/layout.ini`: each mode's layout (`[Scene]`, `[Level]`) and the
  saved presets (`[preset <name>]`), written when they change (`Layouts_Follow`, after every
  message but the dividers' drags) and read when the project opens (`Layouts_Load`).
*/

LAYOUT_FILE :: ".editor/layout.ini"

// A panel shown alone over its mode's workspace (`Layout.maximized`)
MaxPanel :: enum {
	None,
	// The Scene mode's project browser; the Level mode's Levels sidebar
	Left,
	// The viewport (or the code or slicer tab that shows); the Level mode's canvas
	Center,
	Bottom,
	// The Level mode's Layers sidebar (the Scene mode's right sidebar is two panels)
	Right,
	Scene_Tree,
	Inspector,
}

// The built-in layouts of View > Layout
BuiltinLayout :: enum {
	Default,
	// Room for code: a narrow right sidebar, a short bottom panel on the Console
	Code,
	// Painting levels: a tall bottom panel on the Tiles tab (the Level mode's: its World tab)
	Level,
	// Narrow sidebars and no bottom panel
	Wide_Viewport,
}

BUILTIN_LAYOUT_NAMES := [BuiltinLayout]string{
	.Default       = "Default",
	.Code          = "Code",
	.Level         = "Level",
	.Wide_Viewport = "Wide Viewport",
}

// A layout to apply: the panel sizes, which are open, the bottom tab
LayoutPreset :: struct {
	// Its name (owned in `LayoutState.presets`; a built-in's is a constant)
	name: string,
	leftWidth, rightWidth, bottomHeight, sceneTreeHeight, previewHeight: f32,
	bottomOpen, previewOpen: bool,
	bottomTab: BottomTab,
}

// The project's layouts (State.layouts)
LayoutState :: struct {
	// The presets saved in the project (owned)
	presets: [dynamic]LayoutPreset,
	// The Save Current Layout As... dialog and its name (owned)
	saveOpen: bool,
	saveName: string,
	// The file's text as last read or written (owned), so it's written only when it changes
	written: string,
}

// Toggles a panel maximized in the shown mode (the same one again, or None, restores)
Panel_Maximized :: distinct MaxPanel
// Applies a built-in preset (`user` < 0) or the project's preset `user`
Layout_Preset_Applied :: struct {
	builtin: BuiltinLayout,
	user: int,
}
Layout_Save_Opened :: struct {}
Layout_Save_Name_Changed :: distinct string
Layout_Save_Confirmed :: struct {}
Layout_Save_Cancelled :: struct {}

// The panel the shortcut maximizes: the one under the pointer last frame (set by `Maximize_Track`)
@(private="file")
maximizePointerPanel: MaxPanel

/*
A built-in preset for a mode.

Inputs:
- mode: The mode it applies to (the Level mode's sizes and tabs differ)
- which: The preset

Returns:
- The preset
*/
LayoutPreset_Builtin :: proc(mode: EditorMode, which: BuiltinLayout) -> LayoutPreset {
	p := LayoutPreset{
		name = BUILTIN_LAYOUT_NAMES[which],
		leftWidth = DEFAULT_LEFT_WIDTH, rightWidth = DEFAULT_RIGHT_WIDTH,
		bottomHeight = 200, sceneTreeHeight = 280, previewHeight = 220,
		bottomOpen = true, previewOpen = true,
		bottomTab = mode == .Level ? .World : .Console,
	}
	if mode == .Level do p.bottomHeight = LEVEL_LAYOUT_DEFAULT.bottomHeight
	switch which {
	case .Default:
	case .Code:
		p.rightWidth = MIN_SIDEBAR_WIDTH
		p.bottomHeight = MIN_BOTTOM_HEIGHT * 1.5
		p.previewOpen = false
		p.bottomTab = .Console
	case .Level:
		p.bottomHeight = mode == .Level ? LEVEL_LAYOUT_DEFAULT.bottomHeight : 340
		p.bottomTab = mode == .Level ? .World : .Tiles
	case .Wide_Viewport:
		p.leftWidth, p.rightWidth = MIN_SIDEBAR_WIDTH, MIN_SIDEBAR_WIDTH
		p.bottomOpen, p.previewOpen = false, false
	}
	return p
}

/*
The shown layout of a mode as a preset (its sizes, open panels and bottom tab).

Returns:
- The preset, unnamed
*/
Layout_Capture :: proc(state: ^State, mode: EditorMode) -> LayoutPreset {
	l := Mode_LayoutOf(state, mode)
	return {
		leftWidth = l.leftWidth, rightWidth = l.rightWidth, bottomHeight = l.bottomHeight,
		sceneTreeHeight = l.sceneTreeHeight, previewHeight = l.previewHeight,
		bottomOpen = l.bottomOpen, previewOpen = l.previewOpen,
		bottomTab = mode == .Level ? state.level.bottomTab : state.bottomTab,
	}
}

/*
Applies a preset to a mode: its sizes (at least the panels' minimums), open panels and bottom tab
(when the mode has it). A maximized panel is restored.
*/
Layout_Apply :: proc(state: ^State, mode: EditorMode, p: LayoutPreset) {
	l := Mode_LayoutOf(state, mode)
	l.leftWidth = max(p.leftWidth, MIN_SIDEBAR_WIDTH)
	l.rightWidth = max(p.rightWidth, MIN_SIDEBAR_WIDTH)
	l.bottomHeight = max(p.bottomHeight, MIN_BOTTOM_HEIGHT)
	if p.sceneTreeHeight > 0 do l.sceneTreeHeight = max(p.sceneTreeHeight, MIN_SCENE_TREE_HEIGHT)
	if p.previewHeight > 0 do l.previewHeight = max(p.previewHeight, MIN_PREVIEW_HEIGHT)
	l.bottomOpen = p.bottomOpen
	l.previewOpen = p.previewOpen
	l.maximized = .None
	if Mode_HasBottomTab(mode, p.bottomTab) {
		switch mode {
		case .Scene: state.bottomTab = p.bottomTab
		case .Level: state.level.bottomTab = p.bottomTab
		}
	}
}

/*
The layout file's text: each mode's layout, then the saved presets.

Returns:
- The text (temp allocated)
*/
Layouts_Text :: proc(state: ^State) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "; The editor's panel layout for this project (Crossfire Editor)\n")
	write :: proc(b: ^strings.Builder, section: string, p: LayoutPreset) {
		fmt.sbprintf(b, "[%s]\nleft = %.0f\nright = %.0f\nbottom = %.0f\ntree = %.0f\npreview = %.0f\nbottom_open = %v\npreview_open = %v\nbottom_tab = %v\n",
			section, p.leftWidth, p.rightWidth, p.bottomHeight, p.sceneTreeHeight, p.previewHeight, p.bottomOpen, p.previewOpen, p.bottomTab)
	}
	for mode in EditorMode do write(&b, fmt.tprintf("%v", mode), Layout_Capture(state, mode))
	for p in state.layouts.presets do write(&b, fmt.tprintf("preset %s", p.name), p)
	return strings.to_string(b)
}

/*
Reads a layout file's text: the modes' layouts are applied, the presets kept (replacing the
state's). Unknown keys and sections are skipped.
*/
Layouts_Parse :: proc(state: ^State, text: string) {
	LayoutPresets_Clear(&state.layouts)
	read: map[string]LayoutPreset
	defer delete(read)
	order := make([dynamic]string, context.temp_allocator)
	it := ini.iterator_from_string(text)
	for key, value in ini.iterate(&it) {
		section := it.section
		if section == "" do continue
		if section not_in read {
			// Missing keys keep the Default's (an older or hand-written file)
			p := LayoutPreset_Builtin(section == "Level" ? .Level : .Scene, .Default)
			p.name = ""
			read[strings.clone(section, context.temp_allocator)] = p
			append(&order, strings.clone(section, context.temp_allocator))
		}
		p := &read[section]
		v := strings.trim_space(value)
		number, _ := strconv.parse_f32(v)
		switch key {
		case "left":         p.leftWidth = number
		case "right":        p.rightWidth = number
		case "bottom":       p.bottomHeight = number
		case "tree":         p.sceneTreeHeight = number
		case "preview":      p.previewHeight = number
		case "bottom_open":  p.bottomOpen = v == "true"
		case "preview_open": p.previewOpen = v == "true"
		case "bottom_tab":
			if tab, ok := reflect.enum_from_name(BottomTab, v); ok do p.bottomTab = tab
		}
	}
	for section in order {
		p := read[section]
		if mode, ok := reflect.enum_from_name(EditorMode, section); ok {
			Layout_Apply(state, mode, p)
		} else if strings.has_prefix(section, "preset ") {
			name := strings.trim_space(section[len("preset "):])
			if name == "" do continue
			p.name = strings.clone(name)
			append(&state.layouts.presets, p)
		}
	}
}

/*
Reads the project's `.editor/layout.ini` (missing: the layouts stay as they are). Called when a
project opens, after `Mode_Load`.
*/
Layouts_Load :: proc(state: ^State) {
	LayoutPresets_Clear(&state.layouts)
	delete(state.layouts.written)
	state.layouts.written = ""
	if state.project.rootPath == "" do return
	path, _ := filepath.join({state.project.rootPath, LAYOUT_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	Layouts_Parse(state, string(data))
	// What's on disk now: written again only when something changes
	state.layouts.written = strings.clone(Layouts_Text(state))
}

/*
Writes `.editor/layout.ini` when the layouts changed since it was read or written (only for a
project folder on disk; nothing while the layout is the untouched default and there's no file).

Returns:
- "" or what went wrong
*/
Layouts_Save :: proc(state: ^State) -> string {
	root := state.project.rootPath
	if root == "" || !os.exists(root) do return ""
	text := Layouts_Text(state)
	if text == state.layouts.written do return ""
	path, _ := filepath.join({root, LAYOUT_FILE}, context.temp_allocator)
	if state.layouts.written == "" && !os.exists(path) {
		// Nothing to remember until the layout differs from the defaults the editor starts with
		defaults := State{layout = Layout_Defaults(), level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .World}}
		defaults.level.layout.workspace = {1, 1}
		if text == Layouts_Text(&defaults) do return ""
	}
	_ = os.make_directory_all(filepath.dir(path))
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	delete(state.layouts.written)
	state.layouts.written = strings.clone(text)
	return ""
}

// The Scene mode's panel sizes when the editor starts (init's)
Layout_Defaults :: proc() -> Layout {
	return {
		leftWidth = DEFAULT_LEFT_WIDTH,
		rightWidth = DEFAULT_RIGHT_WIDTH,
		bottomHeight = 200,
		sceneTreeHeight = 280,
		bottomOpen = true,
		previewOpen = true,
		previewHeight = 220,
	}
}

// Frees the saved presets
LayoutPresets_Clear :: proc(l: ^LayoutState) {
	for p in l.presets do delete(p.name)
	clear(&l.presets)
}

// Frees the project's layouts
LayoutState_Destroy :: proc(l: ^LayoutState) {
	LayoutPresets_Clear(l)
	delete(l.presets)
	delete(l.saveName)
	delete(l.written)
	l^ = {}
}

/*
Saves the layouts after a message that may have changed them; not during a divider's drag (its
messages come every frame: the file is written by the next other message).
*/
Layouts_Follow :: proc(state: ^State, m: Msg) {
	#partial switch _ in m {
	case Left_Resized, Center_Resized, Viewport_Resized, Scene_Tree_Resized, Workspace_Measured, Browser_Tree_Resized, Browser_Body_Measured, Frame_Requested:
		return
	}
	if problem := Layouts_Save(state); problem != "" do logLine(state, .Warning, strings.clone(problem))
}

/*
Toggles a maximized panel in the shown mode: `panel` maximized, or restored when it already is
(or None). The Level mode has no scene tree or inspector.
*/
Layout_ToggleMaximized :: proc(state: ^State, panel: MaxPanel) {
	l := Mode_Layout(state)
	if panel == .None || l.maximized == panel {
		l.maximized = .None
		return
	}
	if state.mode == .Level && (panel == .Scene_Tree || panel == .Inspector) do return
	if state.mode == .Scene && panel == .Right do return
	l.maximized = panel
	if panel == .Bottom do l.bottomOpen = true
}

/*
The layouts' messages: maximizing, presets, the Save Current Layout As... dialog.

Returns:
- Whether `m` was one
*/
Layouts_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Panel_Maximized:
		Layout_ToggleMaximized(state, MaxPanel(v))
	case Layout_Preset_Applied:
		if v.user >= 0 {
			if v.user < len(state.layouts.presets) do Layout_Apply(state, state.mode, state.layouts.presets[v.user])
		} else {
			Layout_Apply(state, state.mode, LayoutPreset_Builtin(state.mode, v.builtin))
		}
	case Layout_Save_Opened:
		state.layouts.saveOpen = true
		delete(state.layouts.saveName)
		state.layouts.saveName = strings.clone("My Layout")
	case Layout_Save_Name_Changed:
		delete(state.layouts.saveName)
		state.layouts.saveName = strings.clone(string(v))
	case Layout_Save_Cancelled:
		state.layouts.saveOpen = false
	case Layout_Save_Confirmed:
		name := strings.trim_space(state.layouts.saveName)
		if LayoutName_Problem(name) != "" do return true
		Layout_SavePreset(state, name)
		state.layouts.saveOpen = false
	case:
		return false
	}
	return true
}

/*
Saves the shown mode's layout as the project's preset `name` (replacing one of that name).
*/
Layout_SavePreset :: proc(state: ^State, name: string) {
	p := Layout_Capture(state, state.mode)
	for &existing in state.layouts.presets do if existing.name == name {
		p.name = existing.name
		existing = p
		return
	}
	p.name = strings.clone(name)
	append(&state.layouts.presets, p)
}

// Why a preset name can't be used ("" when it can): empty, a section's brackets
LayoutName_Problem :: proc(name: string) -> string {
	if strings.trim_space(name) == "" do return "Name the layout."
	if strings.contains_any(name, "[]\n;=") do return "A layout's name can't have [ ] ; = in it."
	return ""
}

// View > Layout: the built-in presets, the project's, Save Current Layout As..., Reset Layout
Layout_MenuItems :: proc(s: ^State) -> []skald.Menu_Item(Msg) {
	items := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	for name, which in BUILTIN_LAYOUT_NAMES {
		append(&items, skald.Menu_Item(Msg){label = name, msg = Msg(Layout_Preset_Applied{builtin = which, user = -1})})
	}
	if len(s.layouts.presets) > 0 do append(&items, skald.Menu_Item(Msg){separator = true})
	for p, i in s.layouts.presets {
		append(&items, skald.Menu_Item(Msg){label = p.name, msg = Msg(Layout_Preset_Applied{user = i})})
	}
	append(&items,
		skald.Menu_Item(Msg){separator = true},
		skald.Menu_Item(Msg){label = "Save Current Layout As...", msg = Msg(Layout_Save_Opened{})},
		skald.Menu_Item(Msg){label = "Reset Layout", msg = Msg(Layout_Preset_Applied{builtin = .Default, user = -1})},
	)
	return items[:]
}

// The Save Current Layout As... dialog: a name, Save (Enter) and Cancel
layoutSaveDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if !s.layouts.saveOpen do return closedDialog(ctx, "layout-save-dialog")
	tk := uiTokens(ctx)
	th := ctx.theme
	name := s.layouts.saveName
	problem := LayoutName_Problem(name)
	replaces := false
	for p in s.layouts.presets do if p.name == strings.trim_space(name) do replaces = true
	info := problem != "" ? problem : replaces ? fmt.tprintf("Replaces the saved layout %s.", strings.trim_space(name)) : "Saves the panel sizes and the shown tabs in this project, under View > Layout."
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Layout_Save_Cancelled{} },
		on_confirm = dialogConfirm(problem == "", proc() -> Msg { return Layout_Save_Confirmed{} }),
		content = skald.col(
			uiText(th, .Title, "Save Current Layout"),
			skald.row(
				skald.col(uiText(th, .Label, "Name"), width = tk.fieldXS),
				skald.flex(1, skald.text_input(ctx, name,
					proc(v: string) -> Msg { return Layout_Save_Name_Changed(v) },
					id = skald.hash_id("layout-save-name"), placeholder = "My Layout")),
				spacing = tk.buttonGap,
				cross_align = .Center,
			),
			uiText(th, .Muted, info, max_width = tk.textDialog, color = problem != "" && name != "" ? th.color.warning : {}),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Layout_Save_Cancelled{}), id = skald.hash_id("layout-save-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Save", Msg(Layout_Save_Confirmed{}), id = skald.hash_id("layout-save-ok"),
					font_size = th.font.size_sm, disabled = problem != ""),
				spacing = tk.buttonGap,
			),
			spacing = tk.rowGap,
			padding = tk.panelPadding * 2,
			cross_align = .Stretch,
			width = tk.dialogS,
		),
		id = skald.hash_id("layout-save-dialog"),
	)
}

// The rect a widget was drawn at last frame (false when it wasn't drawn: another mode's)
@(private="file")
drawnRect :: proc(ctx: ^skald.Ctx(Msg), key: string) -> (skald.Rect, bool) {
	st, ok := ctx.widgets.states[skald.hash_id(key)]
	if !ok || st.last_rect.w <= 0 || st.last_drawn_frame + 1 < ctx.widgets.frame do return {}, false
	return st.last_rect, true
}

/*
The panels' headers that maximize on a double-click (their title zones and tab strips), and the
panels' bodies the shortcut looks under the pointer for, per mode.
*/
@(private="file")
MAXIMIZE_HEADERS := [EditorMode][]struct { key: string, panel: MaxPanel }{
	.Scene = {
		{"panel-title-browser", .Left}, {"center-tabs", .Center}, {"bottom-tabs-scroll", .Bottom},
		{"panel-title-scene-tree", .Scene_Tree}, {"panel-title-inspector", .Inspector},
	},
	.Level = {
		{"panel-title-levels", .Left}, {"level-canvas-header", .Center}, {"level-bottom-tabs-scroll", .Bottom},
		{"panel-title-layers", .Right},
	},
}

@(private="file")
MAXIMIZE_BODIES := [EditorMode][]struct { key: string, panel: MaxPanel }{
	.Scene = {
		{"browser-scroll", .Left}, {"viewport-canvas", .Center}, {"code-editor", .Center}, {"slicer-canvas", .Center},
		{"scene-tree-scroll", .Scene_Tree}, {"inspector-scroll", .Inspector}, {"panel-bottom", .Bottom},
	},
	.Level = {
		{"level-list-scroll", .Left}, {LEVEL_CANVAS_KEY, .Center}, {"level-layers-scroll", .Right}, {"panel-bottom", .Bottom},
	},
}

/*
Called by `view` each frame: a double-click on a panel's header title or tab strip toggles it
maximized; notes the panel under the pointer for the shortcut.
*/
Maximize_Track :: proc(ctx: ^skald.Ctx(Msg), s: ^State, keysTaken: bool) {
	p := ctx.input.mouse_pos
	maximizePointerPanel = .None
	for b in MAXIMIZE_BODIES[s.mode] {
		if r, ok := drawnRect(ctx, b.key); ok && pointIn(r, p) {
			maximizePointerPanel = b.panel
			break
		}
	}
	if keysTaken || Overlay_PopupOpen(ctx) do return
	if !ctx.input.mouse_pressed[.Left] || ctx.input.mouse_click_count[.Left] != 2 do return
	for h in MAXIMIZE_HEADERS[s.mode] {
		if r, ok := drawnRect(ctx, h.key); ok && pointIn(r, p) {
			skald.send(ctx, Msg(Panel_Maximized(h.panel)))
			return
		}
	}
}

/*
What `Action.Maximize_Panel` maximizes: with one maximized, restores it; else the panel under
the pointer, else the center.
*/
Maximize_ActionPanel :: proc(state: ^State) -> MaxPanel {
	if Mode_Layout(state).maximized != .None do return .None
	return maximizePointerPanel == .None ? .Center : maximizePointerPanel
}

/*
A panel header's title, as a zone the double-click finds (`panel-title-<key>`).
*/
panelTitleZone :: proc(ctx: ^skald.Ctx(Msg), key: string, title: skald.View) -> skald.View {
	if key == "" do return title
	return skald.zone(ctx, title, skald.hash_id(fmt.tprintf("panel-title-%s", key)))
}
