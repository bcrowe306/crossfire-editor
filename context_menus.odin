package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

/*
Context menus: one right-click menu for every place in the editor, as in any graphics program.

What was clicked is a `ContextTarget`; `Context_Menu_Opened` (sent by the place's own mouse
handling: the viewport on a right click that didn't drag, the trees, tabs, logs and panels on a
right press) shows `ContextMenu_Items` for it at the pointer, built each frame with Skald's
`popup_menu` (labels, the keymap's shortcuts, checkmarks, separators, disabled rows, submenus).
Choosing an item sends its message (an `Action` where one exists, so the menu, the shortcut and the
menu bar do the same thing), then `Context_Menu_Closed`.

	target            what it offers
	Ctx_Node          the node (selected first): edit, script, component, visibility, transform,
	                  order, selection, view; from the viewport or the scene tree
	Ctx_Viewport      empty space: add or paste a node there, select, view and grid toggles
	Ctx_Tree          below the scene tree's rows: add, paste, select, expand / collapse
	Ctx_Browser       the browser's row (selected first): per scene, asset kind, script, folder
	Ctx_Scene_Tab     a scene tab: play, set as start, show in the browser, close (others, right)
	Ctx_Code_Tab      a code tab: save, close (others, saved), copy path, show in the browser
	Ctx_Log           a Console or Output line: copy it, copy all shown, hide or show only its
	                  category, show everything, clear
	Ctx_Log_Categories  the Console's (Output's) category button: every category seen, checked
	                  when shown (picking one keeps the menu open: `ContextMenu.keepOpen`)

Widget key: `context-menu` (the driver's `click_context_item <label>[/<submenu label>]`).
*/

// What a context menu is for
ContextTarget :: union {
	Ctx_Node,
	Ctx_Viewport,
	Ctx_Tree,
	Ctx_Browser,
	Ctx_Scene_Tab,
	Ctx_Code_Tab,
	Ctx_Log,
	Ctx_Log_Categories,
	Ctx_Graph,
	Ctx_Align,
	Ctx_Guide,
}

// A guide of the open scene (its index)
Ctx_Guide :: distinct int

// The viewport header's Align button: the Align and Distribute items
Ctx_Align :: struct {}

// A node of the open scene, right-clicked in the viewport (at `world`) or the scene tree
Ctx_Node :: struct {
	node: int,
	world: [2]f32,
	viewport: bool,
}

// Empty space in the viewport, at `world`
Ctx_Viewport :: struct {
	world: [2]f32,
}

// Empty space below the scene tree's rows
Ctx_Tree :: struct {}

// The browser's selected row (the right-click selects it first)
Ctx_Browser :: struct {}

// A scene or component tab (the scene's index)
Ctx_Scene_Tab :: distinct int

// A code tab (0-based)
Ctx_Code_Tab :: distinct int

// A line of the Console (or the Output tab), by its serial number (`LogList.serial` + its index,
// so lines dropped meanwhile don't shift it); -1: below the lines
Ctx_Log :: struct {
	output: bool,
	line: int,
}

// The Console's (or the Output tab's) category filter button: its menu of categories
Ctx_Log_Categories :: struct {
	output: bool,
}

// A box or empty space in one of the bottom panel's graphs (context_menus_panels.odin)
Ctx_Graph :: struct {
	graph: GraphKind,
	// The box (a state, a dialogue node, a track...); -1: empty space
	item: int,
	// A second index where the graph has one (a key of a track, a transition)
	sub: int,
	// Where in the graph it was clicked (its own coordinates; the Timeline's: x is the time)
	local: [2]f32,
}

// The graphs and lists of the bottom panel that have context menus
GraphKind :: enum {
	States,
	Dialogue,
	Timeline_Track,
	Timeline_Key,
	Mixer_Bus,
	Git_Change,
	Live_Node,
	Animation,
	Dialogue_Step,
	Plugin,
}

// The open context menu (`State.contextMenu`)
ContextMenu :: struct {
	open: bool,
	// Where it opened (window px)
	at: [2]f32,
	target: ContextTarget,
	// The item just chosen keeps it open: the next `Context_Menu_Closed` is ignored (several
	// categories picked in a row)
	keepOpen: bool,
}

// What a node menu does to the selection's roots (`Node_Command`)
NodeCommand :: enum {
	Toggle_Visible,
	Move_Up,
	Move_Down,
	Reset_Position,
	Reset_Rotation,
	Reset_Scale,
	Reset_Transform,
	Bring_Forward,
	Send_Backward,
	Select_Children,
	Select_Parent,
	Copy_Path,
	Expand_All,
	Collapse_All,
}

// What a tab menu does (`Tab_Command`)
TabCommand :: enum {
	Close,
	Close_Others,
	Close_Right,
	Close_All,
	Close_Saved,
	Show_In_Browser,
	Save,
}

// What a file menu item does with its file (`File_Command`)
FileCommand :: enum {
	Show_In_Folder,
	Copy_Path,
	Copy_Relative_Path,
}

// What a log menu does (`Log_Command`)
LogCommand :: enum {
	Copy_Line,
	// The lines the tab shows (its filters applied)
	Copy_All,
	// Filter out the line's category
	Hide_Category,
	// Show the line's category alone
	Only_Category,
}

// The menu for a target, opened at a point (window px)
Context_Menu_Opened :: struct {
	at: [2]f32,
	target: ContextTarget,
}
// The menu closed (an item was chosen, or it was dismissed)
Context_Menu_Closed :: struct {}
// A node command on the selection's roots
Node_Command :: struct {
	op: NodeCommand,
}
// Add Node, the new node placed at a world point (the viewport's menu)
Add_Node_Here :: distinct [2]f32
// Paste, the pasted nodes moved so the first lands at a world point
Paste_Here :: distinct [2]f32
// A tab command: `index` a scene's (scene tabs) or a code tab's (0-based)
Tab_Command :: struct {
	op: TabCommand,
	index: int,
	code: bool,
}
// A file command: `path` is the project's (relative) or absolute
File_Command :: struct {
	op: FileCommand,
	path: string,
}
// Open a file in the external code editor (Settings > Editor), whatever the built-in one's setting
Script_Open_External :: struct {
	file: string,
}
// Add an asset to the open scene at the view's center, as dropping it there would
Asset_Add_To_Scene :: distinct int
// A log command: the Console's lines, or the Output tab's
Log_Command :: struct {
	op: LogCommand,
	output: bool,
	line: int,
}

/*
The context menu's messages; true when `m` was one. Node commands and the "here" adds are undo
steps (`History_Classify`); the rest are view changes, the clipboard or files.
*/
ContextMenu_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Context_Menu_Opened:
		state.contextMenu = {open = true, at = v.at, target = v.target}
		// What was clicked becomes the selection, unless it's part of it already (the menu then acts
		// on all of it)
		#partial switch t in v.target {
		case Ctx_Node:
			scene := &state.project.scenes[state.currentScene]
			if t.node < 0 || t.node >= len(scene.nodes) {
				state.contextMenu.open = false
				break
			}
			if Selection_Contains(state, t.node) {
				state.selectedNode = t.node
				state.selectionSet = true
			} else {
				clear(&state.selection)
				state.selectedNode = t.node
			}
		case Ctx_Code_Tab:
			if int(t) < 0 || int(t) >= len(state.codeTabs) do state.contextMenu.open = false
		case Ctx_Scene_Tab:
			if int(t) < 0 || int(t) >= len(state.project.scenes) do state.contextMenu.open = false
		}
		return {}, true
	case Context_Menu_Closed:
		// An item that keeps the menu open (the category filter's) came just before
		if state.contextMenu.keepOpen {
			state.contextMenu.keepOpen = false
			return {}, true
		}
		state.contextMenu.open = false
		return {}, true
	case Node_Command:
		nodeCommand(state, v.op)
		return {}, true
	case Add_Node_Here:
		delete(state.addNode.search)
		state.addNode = {open = true, at = cast([2]f32)v}
		return {}, true
	case Paste_Here:
		pasteHere(state, cast([2]f32)v)
		return {}, true
	case Tab_Command:
		return tabCommand(state, v), true
	case File_Command:
		fileCommand(state, v)
		return {}, true
	case Script_Open_External:
		return Script_OpenInEditor(state, v.file, 1), true
	case Asset_Add_To_Scene:
		if int(v) < 0 || int(v) >= len(state.project.assets) do return {}, true
		state.assetDrag.asset = int(v)
		return skald.cmd_now(Msg(Asset_Dropped{world = state.viewport.center})), true
	case Log_Command:
		list := logListOf(state, v.output)
		log := LogList_Lines(list)
		// The line by its serial number: older lines may have been dropped since the menu opened
		line := v.line - list.serial
		text := ""
		switch v.op {
		case .Copy_Line:
			if line >= 0 && line < len(log) do text = log[line].text
		case .Copy_All:
			// What the tab shows: the lines that pass its filters
			lines := make([dynamic]string, context.temp_allocator)
			for i in LogList_Shown(list) do append(&lines, log[i].text)
			text = strings.join(lines[:], "\n", context.temp_allocator)
		case .Hide_Category, .Only_Category:
			if line >= 0 && line < len(log) {
				category := log[line].category
				if v.op == .Only_Category {
					for &c, i in list.categories do c.hidden = i != category
				} else if category >= 0 && category < len(list.categories) {
					list.categories[category].hidden = true
				}
			}
		}
		if text != "" do _ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
		return {}, true
	}
	if command, handled := ContextMenu_PanelUpdate(state, m); handled do return command, true
	return {}, false
}

/*
The open menu's view (a `popup_menu` over everything), or nothing. Built first in the frame, so
it takes the clicks meant for it before the widgets under it see them.
*/
contextMenuView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if !s.contextMenu.open do return skald.spacer(0)
	items := ContextMenu_Items(s)
	if len(items) == 0 {
		skald.send(ctx, Msg(Context_Menu_Closed{}))
		return skald.spacer(0)
	}
	return skald.popup_menu(ctx, items, s.contextMenu.at, Msg(Context_Menu_Closed{}), id = skald.hash_id("context-menu"))
}

/*
Opens the context menu for `target` when the right button goes down over `rect` (window px; a
widget's last rect), unless a popup or dialog covers it. Returns whether it did.
*/
rightPressOpens :: proc(ctx: ^skald.Ctx(Msg), rect: skald.Rect, target: ContextTarget) -> bool {
	if !ctx.input.mouse_pressed[.Right] || rect.w <= 0 do return false
	p := ctx.input.mouse_pos
	if p.x < rect.x || p.y < rect.y || p.x >= rect.x + rect.w || p.y >= rect.y + rect.h do return false
	if skald.mouse_over_overlay(ctx) do return false
	if mr := ctx.widgets.modal_rect_prev; mr.w > 0 do return false
	skald.send(ctx, Msg(Context_Menu_Opened{at = p, target = target}))
	ctx.input.mouse_pressed[.Right] = false
	return true
}

/*
The items of the open menu (temp allocated), for its target.
*/
ContextMenu_Items :: proc(s: ^State) -> []skald.Menu_Item(Msg) {
	items := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	switch t in s.contextMenu.target {
	case Ctx_Node:      nodeItems(s, &items, t)
	case Ctx_Viewport:  viewportItems(s, &items, t.world)
	case Ctx_Tree:      treeItems(s, &items)
	case Ctx_Browser:   browserItems(s, &items)
	case Ctx_Scene_Tab: sceneTabItems(s, &items, int(t))
	case Ctx_Code_Tab:  codeTabItems(s, &items, int(t))
	case Ctx_Log:       logItems(s, &items, t)
	case Ctx_Log_Categories: logCategoryItems(s, &items, t)
	case Ctx_Graph:     ContextMenu_PanelItems(s, &items, t)
	case Ctx_Align:     append(&items, ..ViewportTools_AlignItems(s))
	case Ctx_Guide:
		append(&items,
			msgItem("Remove Guide", Msg(Guide_Removed(int(t)))),
			msgItem("Remove All Guides", Msg(Guides_Cleared{})),
			MENU_SEPARATOR,
			actionItem(s, "Hide Guides", .Toggle_Guides))
	}
	// No separator first, last or twice in a row
	out := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	for item in items {
		if item.separator && (len(out) == 0 || out[len(out) - 1].separator) do continue
		append(&out, item)
	}
	for len(out) > 0 && out[len(out) - 1].separator do pop(&out)
	return out[:]
}

// ITEMS

MenuItems :: [dynamic]skald.Menu_Item(Msg)

// An item running an action: its shortcut is the keymap's (this platform's keys)
actionItem :: proc(s: ^State, label: string, action: Action, disabled := false, checked := false) -> skald.Menu_Item(Msg) {
	return {label = label, shortcut = Chord_OnPlatform(Keymap_Shortcut(&s.settings.keymap, action)), msg = Msg(action), disabled = disabled, checked = checked}
}

// An item sending a message
msgItem :: proc(label: string, msg: Msg, disabled := false, checked := false) -> skald.Menu_Item(Msg) {
	return {label = label, msg = msg, disabled = disabled, checked = checked}
}

MENU_SEPARATOR :: skald.Menu_Item(Msg){separator = true}

// A submenu of `items` (copied to the temp allocator)
submenuItem :: proc(label: string, items: []skald.Menu_Item(Msg)) -> skald.Menu_Item(Msg) {
	return {label = label, submenu = slice.clone(items, context.temp_allocator)}
}

// The file items every file's menu has: show it in the file manager, copy its path
fileItems :: proc(items: ^MenuItems, path: string) {
	append(items,
		msgItem("Show in File Manager", Msg(File_Command{.Show_In_Folder, strings.clone(path, context.temp_allocator)})),
		msgItem("Copy Path", Msg(File_Command{.Copy_Path, strings.clone(path, context.temp_allocator)})),
		msgItem("Copy Relative Path", Msg(File_Command{.Copy_Relative_Path, strings.clone(path, context.temp_allocator)})))
}

@(private="file")
nodeItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Node) {
	scene := &s.project.scenes[s.currentScene]
	if t.node < 0 || t.node >= len(scene.nodes) do return
	node := &scene.nodes[t.node]
	several := len(s.selection) > 1
	roots := Selection_Roots(s)
	isRoot := Scene_IsComponent(scene) && node.parent < 0

	append(items, actionItem(s, "Add Child Node...", .Add_Node))
	if t.viewport do append(items, msgItem("Add Node Here...", Msg(Add_Node_Here(t.world))))
	append(items, MENU_SEPARATOR)
	append(items,
		actionItem(s, "Cut", .Cut_Node, disabled = isRoot),
		actionItem(s, "Copy", .Copy_Node),
		actionItem(s, "Paste", .Paste_Node, disabled = len(s.clipboard) == 0),
		actionItem(s, "Duplicate", .Duplicate_Node, disabled = isRoot),
		actionItem(s, "Delete", .Delete_Node, disabled = isRoot),
		actionItem(s, "Rename", .Rename_Node, disabled = several),
		MENU_SEPARATOR)

	// Its code and what it's an instance of
	if !several {
		append(items, actionItem(s, node.script != "" ? fmt.tprintf("Open Script (%s)", node.script) : "Add Script...", .Add_Script))
		if node.kind == .Component {
			if i := Project_FindComponent(&s.project, node.component); i >= 0 {
				append(items,
					msgItem(fmt.tprintf("Edit Component (%s)", s.project.scenes[i].name), Msg(Component_Opened(i))),
					msgItem("Make Unique", Msg(Component_Made_Unique{})))
			}
		} else {
			append(items, actionItem(s, "Save as Component...", .Save_As_Component, disabled = isRoot))
		}
		append(items, MENU_SEPARATOR)
	}

	// Visibility, transform, order
	allVisible := true
	for r in roots do if !scene.nodes[r].visible do allVisible = false
	append(items, msgItem(allVisible ? "Hide" : "Show", Msg(Node_Command{.Toggle_Visible})))
	append(items, submenuItem("Transform", {
		msgItem("Reset Position", Msg(Node_Command{.Reset_Position})),
		msgItem("Reset Rotation", Msg(Node_Command{.Reset_Rotation})),
		msgItem("Reset Scale", Msg(Node_Command{.Reset_Scale})),
		MENU_SEPARATOR,
		msgItem("Reset All", Msg(Node_Command{.Reset_Transform})),
	}))
	if align := ViewportTools_AlignItems(s); len(align) > 0 do append(items, submenuItem("Align and Distribute", align))
	first, last := nodeSiblingEnds(scene, t.node)
	append(items, submenuItem("Order", {
		msgItem("Move Up", Msg(Node_Command{.Move_Up}), disabled = several || first),
		msgItem("Move Down", Msg(Node_Command{.Move_Down}), disabled = several || last),
		MENU_SEPARATOR,
		msgItem(fmt.tprintf("Bring Forward (z %d)", node.zIndex + 1), Msg(Node_Command{.Bring_Forward})),
		msgItem(fmt.tprintf("Send Backward (z %d)", node.zIndex - 1), Msg(Node_Command{.Send_Backward})),
	}))
	hasChildren := t.node + 1 < len(scene.nodes) && scene.nodes[t.node + 1].parent == t.node
	append(items, submenuItem("Select", {
		msgItem("Children", Msg(Node_Command{.Select_Children}), disabled = !hasChildren),
		msgItem("Parent", Msg(Node_Command{.Select_Parent}), disabled = node.parent < 0),
		actionItem(s, "All", .Select_All),
		actionItem(s, "None", .Deselect),
	}))
	append(items, MENU_SEPARATOR)
	append(items, actionItem(s, "Frame Selected", .Frame_Selected))
	if !several do append(items, msgItem("Copy Node Path", Msg(Node_Command{.Copy_Path})))
	if !t.viewport do append(items, MENU_SEPARATOR, msgItem("Expand All", Msg(Node_Command{.Expand_All})), msgItem("Collapse All", Msg(Node_Command{.Collapse_All})))
}

// Whether a node is the first and the last of its parent's children
@(private="file")
nodeSiblingEnds :: proc(scene: ^SceneDef, node: int) -> (first, last: bool) {
	before, after := nodeSiblings(scene, node)
	return before < 0, after < 0
}

// The node's previous and next sibling (-1: none)
@(private="file")
nodeSiblings :: proc(scene: ^SceneDef, node: int) -> (before, after: int) {
	before, after = -1, -1
	parent := scene.nodes[node].parent
	for n, i in scene.nodes {
		if n.parent != parent || i == node do continue
		if i < node do before = i
		if i > node && after < 0 do after = i
	}
	return
}

@(private="file")
viewportItems :: proc(s: ^State, items: ^MenuItems, world: [2]f32) {
	v := &s.viewport
	hasNodes := len(s.project.scenes[s.currentScene].nodes) > 0
	append(items,
		msgItem("Add Node Here...", Msg(Add_Node_Here(world))),
		msgItem("Paste Here", Msg(Paste_Here(world)), disabled = len(s.clipboard) == 0),
		MENU_SEPARATOR,
		actionItem(s, "Select All", .Select_All, disabled = !hasNodes),
		actionItem(s, "Deselect", .Deselect, disabled = s.selectedNode < 0),
		MENU_SEPARATOR,
		actionItem(s, "Frame Selected", .Frame_Selected, disabled = s.selectedNode < 0),
		actionItem(s, "Fit the View", .View_Fit),
		actionItem(s, "Zoom to 100%", .Zoom_100),
		actionItem(s, "Zoom In", .Zoom_In),
		actionItem(s, "Zoom Out", .Zoom_Out),
		MENU_SEPARATOR)
	append(items, submenuItem("Tool", {
		actionItem(s, "Select", .Tool_Select, checked = s.tool == .Select),
		actionItem(s, "Move", .Tool_Move, checked = s.tool == .Move),
		actionItem(s, "Rotate", .Tool_Rotate, checked = s.tool == .Rotate),
		actionItem(s, "Scale", .Tool_Scale, checked = s.tool == .Scale),
		actionItem(s, "Pan", .Tool_Pan, checked = s.tool == .Pan),
	}))
	append(items, submenuItem("Show", {
		actionItem(s, "Grid", .Toggle_Grid, checked = v.gridVisible),
		actionItem(s, "Snap to Grid", .Toggle_Snap, checked = v.snap),
		actionItem(s, "Collision Shapes", .Toggle_Collision_Shapes, checked = v.showShapes),
		actionItem(s, "Lighting", .Toggle_Lighting, checked = !v.unlit),
		actionItem(s, "Animations", .Toggle_Animation, checked = v.animate),
		actionItem(s, "Guides", .Toggle_Guides, checked = !v.guidesHidden),
	}))
	append(items, msgItem("Grid Settings...", Msg(Open_Grid_Settings{})))
	if len(s.project.scenes[s.currentScene].guides) > 0 do append(items, msgItem("Remove All Guides", Msg(Guides_Cleared{})))
	ViewportTools_ViewportItems(s, items)
}

@(private="file")
treeItems :: proc(s: ^State, items: ^MenuItems) {
	hasNodes := len(s.project.scenes[s.currentScene].nodes) > 0
	append(items,
		actionItem(s, "Add Node...", .Add_Node),
		actionItem(s, "Paste", .Paste_Node, disabled = len(s.clipboard) == 0),
		MENU_SEPARATOR,
		actionItem(s, "Select All", .Select_All, disabled = !hasNodes),
		MENU_SEPARATOR,
		msgItem("Expand All", Msg(Node_Command{.Expand_All}), disabled = !hasNodes),
		msgItem("Collapse All", Msg(Node_Command{.Collapse_All}), disabled = !hasNodes))
}

@(private="file")
browserItems :: proc(s: ^State, items: ^MenuItems) {
	selection := s.browserSelection
	switch selection.kind {
	case .Scene:
		if selection.index < 0 || selection.index >= len(s.project.scenes) do return
		i := selection.index
		scene := &s.project.scenes[i]
		append(items,
			msgItem("Open", Msg(Scene_Action{.Open, i})),
			msgItem("Play Scene", Msg(Scene_Action{.Play, i})),
			msgItem("Set as Start Scene", Msg(Scene_Action{.Set_Start, i}), disabled = scene.name == s.project.startScene),
			MENU_SEPARATOR,
			actionItem(s, "Rename", .Rename_Node),
			actionItem(s, "Duplicate", .Duplicate_Node),
			actionItem(s, "Copy", .Copy_Node),
			actionItem(s, "Cut", .Cut_Node),
			actionItem(s, "Paste", .Paste_Node, disabled = !s.hasSceneClipboard),
			actionItem(s, "Delete", .Delete_Node),
			MENU_SEPARATOR,
			msgItem("New Scene", Msg(Scene_Action{.New, i})),
			MENU_SEPARATOR)
		fileItems(items, SceneFilePath(scene, context.temp_allocator))
	case .Asset:
		if selection.index < 0 || selection.index >= len(s.project.assets) do return
		assetItems(s, items, selection.index)
	case .Script:
		if selection.index < 0 || selection.index >= len(s.scriptFiles) do return
		path, _ := filepath.join({s.project.rootPath, s.scriptFiles[selection.index]}, context.temp_allocator)
		absolute, err := os.get_absolute_path(path, context.temp_allocator)
		if err != nil do absolute = path
		append(items,
			msgItem("Open", Msg(Script_Open_File{file = absolute, line = 1})),
			msgItem("Open in External Editor", Msg(Script_Open_External{file = absolute})),
			actionItem(s, "Build Scripts", .Build_Scripts),
			MENU_SEPARATOR)
		fileItems(items, s.scriptFiles[selection.index])
	case .Folder, .None:
		folderItems(s, items, selection.kind == .Folder ? selection.folder : nil)
	}
}

@(private="file")
assetItems :: proc(s: ^State, items: ^MenuItems, index: int) {
	asset := s.project.assets[index]
	#partial switch asset.kind {
	case .Component:
		if i := Project_FindComponent(&s.project, asset.path); i >= 0 do append(items, msgItem("Edit", Msg(Component_Opened(i))))
		append(items,
			msgItem("Add to Scene", Msg(Component_Instance_Added(index))),
			msgItem("Rename", Msg(Component_Rename_Started(index))),
			MENU_SEPARATOR,
			msgItem("New Component", Msg(Component_New{})))
	case .Image:
		append(items, msgItem("Add to Scene as a Sprite", Msg(Asset_Add_To_Scene(index))))
		if e.Aseprite_IsFile(asset.path) {
			append(items,
				msgItem("Open in Aseprite", Msg(Aseprite_Asset_Open_Requested(index))),
				msgItem("Show Its Animations", Msg(Anim_Asset_Shown(asset.path))))
		}
	case .Audio:
		append(items,
			actionItem(s, "Play", .Play_Audio_Preview),
			actionItem(s, "Stop", .Stop_Audio_Preview),
			msgItem("Use as Music (streamed)", Msg(Asset_Kind_Changed{index, .Music})),
			msgItem("Convert to Ogg Vorbis", Msg(Audio_Convert_Requested(index)), disabled = Toolchain_FFmpeg() == "" || strings.has_suffix(strings.to_lower(asset.path, context.temp_allocator), ".ogg")))
	case .Music:
		append(items,
			actionItem(s, "Play", .Play_Audio_Preview),
			actionItem(s, "Stop", .Stop_Audio_Preview),
			msgItem("Use as a Sound", Msg(Asset_Kind_Changed{index, .Audio})),
			msgItem("Convert to Ogg Vorbis", Msg(Audio_Convert_Requested(index)), disabled = Toolchain_FFmpeg() == "" || strings.has_suffix(strings.to_lower(asset.path, context.temp_allocator), ".ogg")))
	case .LDtk:
		append(items,
			msgItem("Add to Scene", Msg(Asset_Add_To_Scene(index))),
			msgItem("Open in LDtk", Msg(LDtk_Asset_Open_Requested(index))))
	case .Animation:
		append(items,
			msgItem("Edit Animations", Msg(Anim_Asset_Shown(asset.path))),
			msgItem("Add to Scene", Msg(Asset_Add_To_Scene(index))),
			MENU_SEPARATOR,
			msgItem("New Animations", Msg(Anim_Set_New{})))
	case .Theme:
		append(items, msgItem("New Theme", Msg(Theme_Created{})))
	case .PhysicsMaterial:
		append(items, msgItem("New Material", Msg(Material_Created{})))
	case .Shader:
		append(items,
			msgItem("Open", Msg(Script_Open_File{file = projectFilePath(s, asset.path), line = 1})),
			msgItem("New Shader", Msg(Shader_New_Requested{})))
	case .Atlas:
		append(items, msgItem("New Atlas", Msg(Atlas_Created{})))
	case .Dialogue:
		append(items,
			msgItem("Edit", Msg(Bottom_Tab_Changed(int(BottomTab.Dialogue)))),
			msgItem("New Dialogue", Msg(Dialogue_Created{})))
	case .Data:
		append(items, msgItem("New Data Resource...", Msg(New_Data_Opened{})))
	case .Font:
		if !strings.has_suffix(strings.to_lower(asset.path, context.temp_allocator), ".fnt") {
			append(items, msgItem("Sharp at Any Size (MSDF)", Msg(Asset_MSDF_Changed{index, !asset.msdf}), checked = asset.msdf))
		}
	}
	append(items, MENU_SEPARATOR)
	fileItems(items, asset.path)
	append(items, MENU_SEPARATOR, actionItem(s, "Remove from Project...", .Remove_Asset))
}

// A folder's menu (`folder` nil: empty space)
@(private="file")
folderItems :: proc(s: ^State, items: ^MenuItems, folder: Maybe(BrowserFolder)) {
	f, isFolder := folder.?
	if isFolder {
		#partial switch f {
		case .Data:       append(items, msgItem("New Data Resource...", Msg(New_Data_Opened{})))
		case .Components: append(items, msgItem("New Component", Msg(Component_New{})))
		case .Animations: append(items, msgItem("New Animations", Msg(Anim_Set_New{})))
		case .Themes:     append(items, msgItem("New Theme", Msg(Theme_Created{})))
		case .Materials:  append(items, msgItem("New Material", Msg(Material_Created{})))
		case .Atlases:    append(items, msgItem("New Atlas", Msg(Atlas_Created{})))
		case .Dialogues:  append(items, msgItem("New Dialogue", Msg(Dialogue_Created{})))
		case .Shaders:    append(items, msgItem("New Shader", Msg(Shader_New_Requested{})))
		case .Scripts:    append(items, actionItem(s, "Build Scripts", .Build_Scripts))
		case .Scenes:
			append(items, msgItem("New Scene", Msg(Scene_Action{.New, -1})))
			append(items, actionItem(s, "Paste Scene", .Paste_Node, disabled = !s.hasSceneClipboard))
		}
		append(items, MENU_SEPARATOR)
	}
	append(items, actionItem(s, "Import Asset...", .Import_Asset))
	append(items, submenuItem("New", {
		msgItem("Scene", Msg(Scene_Action{.New, -1})),
		msgItem("Component", Msg(Component_New{})),
		msgItem("Data Resource...", Msg(New_Data_Opened{})),
		msgItem("Animations", Msg(Anim_Set_New{})),
		msgItem("UI Theme", Msg(Theme_Created{})),
		msgItem("Physics Material", Msg(Material_Created{})),
		msgItem("Shader", Msg(Shader_New_Requested{})),
		msgItem("Atlas", Msg(Atlas_Created{})),
		msgItem("Dialogue", Msg(Dialogue_Created{})),
	}))
	// A copied scene pastes from any folder's menu (the Scenes folder has its own item)
	if s.hasSceneClipboard && !(isFolder && f == .Scenes) do append(items, actionItem(s, "Paste Scene", .Paste_Node))
	append(items, MENU_SEPARATOR)
	folderPath := isFolder ? BrowserFolder_Path(f) : ""
	append(items, msgItem("Show in File Manager", Msg(File_Command{.Show_In_Folder, folderPath})))
}

@(private="file")
sceneTabItems :: proc(s: ^State, items: ^MenuItems, index: int) {
	scene := &s.project.scenes[index]
	component := Scene_IsComponent(scene)
	open := ViewportTabScenes(s)
	isLast := len(open) > 0 && open[len(open) - 1] == index
	if !component {
		append(items,
			msgItem("Play Scene", Msg(Scene_Action{.Play, index})),
			msgItem("Set as Start Scene", Msg(Scene_Action{.Set_Start, index}), disabled = scene.name == s.project.startScene),
			MENU_SEPARATOR)
	}
	append(items,
		actionItem(s, "Save", .Save_Project),
		msgItem("Show in Browser", Msg(Tab_Command{.Show_In_Browser, index, false})),
		MENU_SEPARATOR,
		msgItem("Close", Msg(Tab_Command{.Close, index, false}), disabled = len(open) <= 1),
		msgItem("Close Others", Msg(Tab_Command{.Close_Others, index, false}), disabled = len(open) <= 1),
		msgItem("Close Tabs to the Right", Msg(Tab_Command{.Close_Right, index, false}), disabled = isLast),
		MENU_SEPARATOR)
	fileItems(items, component ? scene.component : SceneFilePath(scene, context.temp_allocator))
}

@(private="file")
codeTabItems :: proc(s: ^State, items: ^MenuItems, index: int) {
	path := s.codeTabs[index]
	append(items,
		msgItem("Save", Msg(Tab_Command{.Save, index, true})),
		msgItem("Show in Browser", Msg(Tab_Command{.Show_In_Browser, index, true})),
		msgItem("Open in External Editor", Msg(Script_Open_External{file = strings.clone(path, context.temp_allocator)})),
		MENU_SEPARATOR,
		actionItem(s, "Close", .Close_Code_Tab),
		msgItem("Close Others", Msg(Tab_Command{.Close_Others, index, true}), disabled = len(s.codeTabs) <= 1),
		msgItem("Close Tabs to the Right", Msg(Tab_Command{.Close_Right, index, true}), disabled = index == len(s.codeTabs) - 1),
		msgItem("Close Saved", Msg(Tab_Command{.Close_Saved, index, true})),
		msgItem("Close All", Msg(Tab_Command{.Close_All, index, true})),
		MENU_SEPARATOR)
	fileItems(items, path)
}

@(private="file")
logItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Log) {
	list := logListOf(s, t.output)
	log := LogList_Lines(list)
	// t.line is the line's serial number (`LogList.serial` + its index)
	index := t.line - list.serial
	onLine := t.line >= 0 && index >= 0 && index < len(log)
	category := onLine ? LogList_CategoryName(list, log[index]) : ""
	append(items,
		msgItem("Copy Line", Msg(Log_Command{.Copy_Line, t.output, t.line}), disabled = !onLine),
		msgItem(LogList_Filtered(list) ? "Copy All Shown" : "Copy All", Msg(Log_Command{.Copy_All, t.output, -1}), disabled = len(log) == 0),
		MENU_SEPARATOR,
		msgItem(onLine ? fmt.tprintf("Hide '%s'", category) : "Hide Category", Msg(Log_Command{.Hide_Category, t.output, t.line}), disabled = !onLine),
		msgItem(onLine ? fmt.tprintf("Show Only '%s'", category) : "Show Only Category", Msg(Log_Command{.Only_Category, t.output, t.line}), disabled = !onLine),
		msgItem("Show Everything", Msg(Log_Filters_Cleared{t.output}), disabled = !LogList_Filtered(list)),
		MENU_SEPARATOR,
		actionItem(s, "Clear", .Clear_Console, disabled = len(log) == 0))
}

// The Console's (or Output tab's) category filter, from its header's button: every category seen,
// checked when shown; picking one flips it and the menu stays open
@(private="file")
logCategoryItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Log_Categories) {
	list := logListOf(s, t.output)
	allShown := true
	for c in list.categories do if c.hidden do allShown = false
	append(items, msgItem("Show All", Msg(Log_Categories_Shown{t.output}), disabled = allShown), MENU_SEPARATOR)
	if len(list.categories) == 0 do append(items, msgItem("(no lines yet)", Msg(Log_Categories_Shown{t.output}), disabled = true))
	for c, i in list.categories {
		item := msgItem(fmt.tprintf("%s (%d)", c.name, c.count), Msg(Log_Category_Toggled{t.output, i}))
		item.checked = !c.hidden
		append(items, item)
	}
}

// COMMANDS

// A project file's absolute path (absolute paths stay)
projectFilePath :: proc(s: ^State, path: string) -> string {
	if filepath.is_abs(path) do return path
	joined, _ := filepath.join({s.project.rootPath, path}, context.temp_allocator)
	absolute, err := os.get_absolute_path(joined, context.temp_allocator)
	return err == nil ? absolute : joined
}

@(private="file")
fileCommand :: proc(state: ^State, v: File_Command) {
	absolute := projectFilePath(state, v.path)
	switch v.op {
	case .Show_In_Folder:
		folder := os.is_dir(absolute) ? absolute : filepath.dir(absolute)
		url := fmt.tprintf("file://%s", folder)
		if !sdl.OpenURL(strings.clone_to_cstring(url, context.temp_allocator)) {
			logLine(state, .Warning, fmt.aprintf("Couldn't open %s: %s", folder, sdl.GetError()))
		}
	case .Copy_Path:
		_ = sdl.SetClipboardText(strings.clone_to_cstring(absolute, context.temp_allocator))
	case .Copy_Relative_Path:
		relative, err := filepath.rel(state.project.rootPath, absolute, context.temp_allocator)
		_ = sdl.SetClipboardText(strings.clone_to_cstring(err == nil ? relative : v.path, context.temp_allocator))
	}
}

@(private="file")
nodeCommand :: proc(state: ^State, op: NodeCommand) {
	scene := &state.project.scenes[state.currentScene]
	roots := Selection_Roots(state)
	switch op {
	case .Toggle_Visible:
		show := false
		for r in roots do if !scene.nodes[r].visible do show = true
		for r in roots do scene.nodes[r].visible = show
	case .Reset_Position:
		for r in roots do scene.nodes[r].position = {}
	case .Reset_Rotation:
		for r in roots do scene.nodes[r].rotation = 0
	case .Reset_Scale:
		for r in roots do scene.nodes[r].scale = {1, 1}
	case .Reset_Transform:
		for r in roots do scene.nodes[r].position, scene.nodes[r].rotation, scene.nodes[r].scale = {}, 0, {1, 1}
	case .Bring_Forward:
		for r in roots do scene.nodes[r].zIndex += 1
	case .Send_Backward:
		for r in roots do scene.nodes[r].zIndex -= 1
	case .Move_Up, .Move_Down:
		node := state.selectedNode
		if node < 0 || node >= len(scene.nodes) do break
		before, after := nodeSiblings(scene, node)
		target, position := before, DropPosition.Before
		if op == .Move_Down do target, position = after, .After
		if target < 0 do break
		if moved, ok := Scene_MoveNode(scene, node, target, position); ok {
			clear(&state.selection)
			state.selectedNode = moved
			state.selectionSet = true
			Selection_Set(state, {moved}, moved)
		}
	case .Select_Children:
		children := make([dynamic]int, context.temp_allocator)
		for r in roots do for n, i in scene.nodes do if n.parent == r do append(&children, i)
		if len(children) > 0 {
			for r in roots do scene.nodes[r].expanded = true
			Selection_Set(state, children[:], children[0])
		}
	case .Select_Parent:
		parents := make([dynamic]int, context.temp_allocator)
		for r in roots do if p := scene.nodes[r].parent; p >= 0 && !slice.contains(parents[:], p) do append(&parents, p)
		if len(parents) > 0 do Selection_Set(state, parents[:], parents[0])
	case .Copy_Path:
		node := state.selectedNode
		if node < 0 || node >= len(scene.nodes) do break
		path := Scene_NodePath(scene, -1, node, context.temp_allocator)
		_ = sdl.SetClipboardText(strings.clone_to_cstring(path, context.temp_allocator))
		logLine(state, .Info, fmt.aprintf("Copied %s", path))
	case .Expand_All:
		for &n in scene.nodes do n.expanded = true
	case .Collapse_All:
		for &n in scene.nodes do n.expanded = false
	}
}

// Paste, then move the pasted nodes so the first lands at `world` (the rest keep their places
// relative to it)
@(private="file")
pasteHere :: proc(state: ^State, world: [2]f32) {
	if len(state.clipboard) == 0 do return
	scene := &state.project.scenes[state.currentScene]
	roots := Scene_PasteNodes(scene, state.clipboard[:], -1)
	if len(roots) == 0 do return
	transforms := Scene_WorldTransforms(scene)
	shift := world - e.Transform2D_Apply(transforms[roots[0]], {0, 0})
	for r in roots {
		node := &scene.nodes[r]
		parentWorld := node.parent >= 0 ? transforms[node.parent] : e.TRANSFORM2D_IDENTITY
		at := e.Transform2D_Apply(transforms[r], {0, 0}) + shift
		local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), at)
		node.position = {math_tidy(local.x), math_tidy(local.y)}
	}
	Selection_Set(state, roots, roots[0])
	logLine(state, .Info, fmt.aprintf("Pasted %s", describeNodes(scene, roots)))
}

// A coordinate rounded to a hundredth (short numbers in scene files)
math_tidy :: proc(v: f32) -> f32 {
	return f32(int(v * 100 + (v >= 0 ? 0.5 : -0.5))) / 100
}

@(private="file")
tabCommand :: proc(state: ^State, v: Tab_Command) -> skald.Command(Msg) {
	if v.code {
		if v.index < 0 || v.index >= len(state.codeTabs) do return {}
		path := strings.clone(state.codeTabs[v.index], context.temp_allocator)
		switch v.op {
		case .Save:
			CodeTabs_SaveFile(state, path)
		case .Show_In_Browser:
			Browser_RevealFile(state, path)
		case .Close:
			return skald.cmd_now(Msg(Code_Tab_Close_Requested(v.index)))
		case .Close_Others, .Close_Right, .Close_All, .Close_Saved:
			// Tabs with unsaved changes stay (closing them one by one asks)
			kept := 0
			for i := len(state.codeTabs) - 1; i >= 0; i -= 1 {
				close := false
				#partial switch v.op {
				case .Close_Others: close = i != v.index
				case .Close_Right:  close = i > v.index
				case .Close_All, .Close_Saved: close = true
				}
				if !close do continue
				if CodeTabs_IsDirty(state, state.codeTabs[i]) {
					kept += 1
					continue
				}
				CodeTabs_Close(state, i)
			}
			if kept > 0 && v.op != .Close_Saved do logLine(state, .Info, fmt.aprintf("Kept %d tab%s with unsaved changes open", kept, kept == 1 ? "" : "s"))
		}
		return {}
	}
	if v.index < 0 || v.index >= len(state.project.scenes) do return {}
	switch v.op {
	case .Save:
		return skald.cmd_now(Msg(Action.Save_Project))
	case .Show_In_Browser:
		Browser_RevealScene(state, v.index)
	case .Close:
		// By its place in the strip, as its × does (a component with unsaved changes asks)
		if position := slice_index(ViewportTabScenes(state), v.index); position >= 0 do return skald.cmd_now(Msg(Scene_Tab_Closed(position)))
	case .Close_Others, .Close_Right, .Close_All, .Close_Saved:
		open := slice.clone(ViewportTabScenes(state), context.temp_allocator)
		position := slice_index(open, v.index)
		kept := 0
		for scene, i in open {
			close := false
			#partial switch v.op {
			case .Close_Others: close = scene != v.index
			case .Close_Right:  close = position >= 0 && i > position
			case .Close_All:    close = true
			}
			if !close || len(ViewportTabScenes(state)) < 2 do continue
			// A component with unsaved changes stays (its × asks)
			if Scene_IsComponent(&state.project.scenes[scene]) && Scene_IsDirty(state, scene) {
				kept += 1
				continue
			}
			closeSceneTab(state, scene)
		}
		if kept > 0 do logLine(state, .Info, fmt.aprintf("Kept %d component tab%s with unsaved changes open", kept, kept == 1 ? "" : "s"))
	}
	return {}
}

// The folder a browser folder's files are in, relative to the project ("": the project's own)
BrowserFolder_Path :: proc(folder: BrowserFolder) -> string {
	switch folder {
	case .Scenes:       return "scenes"
	case .Scripts:      return SCRIPTS_FOLDER
	case .Images, .Audio, .Music, .Fonts, .Levels, .Translations: return ASSETS_FOLDER
	case .Data:         return DATA_FOLDER
	case .Components:   return COMPONENT_FOLDER
	case .Animations:   return ANIMATION_FOLDER
	case .Themes:       return THEME_FOLDER
	case .Shaders:      return SHADERS_FOLDER
	case .Materials:    return MATERIAL_FOLDER
	case .Atlases:      return ATLAS_FOLDER
	case .Dialogues:    return DIALOGUE_FOLDER
	}
	return ""
}

// Selects a scene's row in the browser (its folder opened)
Browser_RevealScene :: proc(state: ^State, scene: int) {
	if scene < 0 || scene >= len(state.project.scenes) do return
	if component := state.project.scenes[scene].component; component != "" {
		for asset, i in state.project.assets do if asset.path == component {
			state.browserOpen[.Components] = true
			state.browserSelection = {kind = .Asset, folder = .Components, index = i}
			return
		}
		return
	}
	state.browserOpen[.Scenes] = true
	state.browserSelection = {kind = .Scene, folder = .Scenes, index = scene}
}

// Selects a file's row in the browser (a script or an asset; its folder opened), if it has one
Browser_RevealFile :: proc(state: ^State, path: string) {
	for file, i in state.scriptFiles {
		if projectFilePath(state, file) == path || file == path {
			state.browserOpen[.Scripts] = true
			state.browserSelection = {kind = .Script, folder = .Scripts, index = i}
			return
		}
	}
	for asset, i in state.project.assets {
		if projectFilePath(state, asset.path) == path || asset.path == path {
			folder := AssetFolder(asset.kind)
			state.browserOpen[folder] = true
			state.browserSelection = {kind = .Asset, folder = folder, index = i}
			return
		}
	}
}
