package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The docs window's state and messages (its view: view_docs.odin; its pages: docs.odin). A popup
over the editor showing one page of the bundled docs at a time, with a history (back, forward),
a search box and "Open on crossfireengine.io" for the page that shows.

Ways in, each with the address it opens:
- Help > User Manual and F1 outside a code tab (`.User_Manual`): the page of the panel under the
  pointer (`Docs_HelpAddress`: the selected node's guide over the inspector, a bottom tab's page,
  the viewport's, the scene tree's, the browser selection's), else the manual's contents
- F1 in a code tab (`Code_Help_Requested`, code_providers.odin): the engine name under the caret's
  API entry, else the manual's code editor page
- a code tab's right-click "Open Docs" (the code menu provider, code_providers.odin): the name
  under the pointer, through its type for a variable or field (`CodeProviders_DocsAt`)
- "Open Docs" in the right-click menus of nodes, scenes, components and assets
  (context_menus.odin), and the panels' Manual buttons (`Manual_Opened`)

Every one sends `Docs_Opened` with the address.
*/

// The docs window (`State.docs`)
DocsWindow :: struct {
	open: bool,
	// The pages shown, oldest first (owned addresses), and which one shows
	history: [dynamic]string,
	at: int,
	// The search box's text (owned); while it isn't empty the results show
	search: string,
}

// Opens the docs window at an address ("" the page it showed last, else the manual's contents)
Docs_Opened :: distinct string
// A link on the page was clicked (its target as written)
Docs_Link_Clicked :: distinct string
// A search result or a contents entry was picked: its address; `clear` ends the search (a
// narrow window shows the results instead of the page)
Docs_Hit_Chosen :: struct {
	address: string,
	clear: bool,
}
Docs_Back :: struct {}
Docs_Forward :: struct {}
Docs_Closed :: struct {}
Docs_Search_Changed :: distinct string
// The page that shows, on crossfireengine.io in the browser
Docs_Open_On_Web :: struct {}

// The address showing ("" none)
Docs_Current :: proc(docs: ^DocsWindow) -> string {
	if docs.at < 0 || docs.at >= len(docs.history) do return ""
	return docs.history[docs.at]
}

// Frees what the window owns
DocsWindow_Destroy :: proc(docs: ^DocsWindow) {
	for h in docs.history do delete(h)
	delete(docs.history)
	delete(docs.search)
	docs^ = {}
}

// The most pages the history keeps
DOCS_HISTORY_MAX :: 100

/*
Shows an address: it becomes the newest page of the history (the pages after the one showing are
dropped, as a browser does), and the window opens.
*/
Docs_Navigate :: proc(docs: ^DocsWindow, address: string) {
	docs.open = true
	if address == "" {
		if Docs_Current(docs) == "" do Docs_Navigate(docs, "/manual/")
		return
	}
	for len(docs.history) > docs.at + 1 do delete(pop(&docs.history))
	if len(docs.history) >= DOCS_HISTORY_MAX {
		delete(docs.history[0])
		ordered_remove(&docs.history, 0)
	}
	append(&docs.history, strings.clone(address))
	docs.at = len(docs.history) - 1
	// The same address again scrolls to it again
	docsScrollAgain = true
}

// Set when the view should scroll to the current address's anchor even if it showed already
@(private)
docsScrollAgain: bool

/*
The docs messages (from `update`).

Returns:
- The command, and whether the message was one of these
*/
Docs_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	docs := &state.docs
	#partial switch v in m {
	case Docs_Opened:
		Docs_Navigate(docs, string(v))
	case Docs_Hit_Chosen:
		Docs_Navigate(docs, v.address)
		if v.clear {
			delete(docs.search)
			docs.search = ""
		}
	case Docs_Link_Clicked:
		address, external := Docs_ResolveLink(Docs_Current(docs), string(v))
		if address != "" do Docs_Navigate(docs, address)
		else if external != "" do Links_Open(state, external)
	case Docs_Back:
		if docs.at > 0 {
			docs.at -= 1
			docsScrollAgain = true
		}
	case Docs_Forward:
		if docs.at + 1 < len(docs.history) {
			docs.at += 1
			docsScrollAgain = true
		}
	case Docs_Closed:
		docs.open = false
	case Docs_Search_Changed:
		delete(docs.search)
		docs.search = strings.clone(string(v))
	case Docs_Open_On_Web:
		if current := Docs_Current(docs); current != "" do Links_Open(state, Docs_URL(current))
	case:
		return {}, false
	}
	return {}, true
}

// The panel F1 is pressed over (the view sets it each frame from the pointer: `Docs_TrackPointer`)
DocsPanel :: enum {
	None,
	Viewport,
	Scene_Tree,
	Inspector,
	Browser,
	Bottom,
	Code,
	// The Level mode's world map and level panel (level_mode.odin)
	Level,
	// The sprite sheet slicer's tab (view_slicer.odin)
	Slicer,
}

@(private)
docsPointerPanel: DocsPanel

/*
Notes which panel the pointer is over, from the panels' rects last frame (called by `view`, so
F1's `.User_Manual` knows where it was pressed).
*/
Docs_TrackPointer :: proc(ctx: ^skald.Ctx(Msg), mode := EditorMode.Scene, slicer := false) {
	p := ctx.input.mouse_pos
	inside :: proc(ctx: ^skald.Ctx(Msg), key: string, p: [2]f32) -> bool {
		st, ok := ctx.widgets.states[skald.hash_id(key)]
		r := st.last_rect
		return ok && r.w > 0 && p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
	}
	docsPointerPanel = .None
	// Another mode's panels keep their last rects in Skald's store: only the shown mode's count
	if mode == .Level {
		switch {
		case inside(ctx, "browser-scroll", p): docsPointerPanel = .Browser
		case:
			docsPointerPanel = .Level
			if st, ok := ctx.widgets.states[skald.hash_id("level-bottom-tabs-scroll")]; ok {
				r := st.last_rect
				if r.w > 0 && p.y >= r.y && p.x >= r.x - 8 && p.x < r.x + r.w + 200 do docsPointerPanel = .Bottom
			}
		}
		return
	}
	switch {
	// The slicer's tab hides the viewport and the code (whose rects stay in Skald's store)
	case slicer && (inside(ctx, "slicer-canvas", p) || inside(ctx, "slicer-scroll", p)): docsPointerPanel = .Slicer
	case inside(ctx, "code-editor", p):       docsPointerPanel = .Code
	case inside(ctx, "viewport-canvas", p):   docsPointerPanel = .Viewport
	case inside(ctx, "scene-tree-scroll", p): docsPointerPanel = .Scene_Tree
	case inside(ctx, "inspector-scroll", p):  docsPointerPanel = .Inspector
	case inside(ctx, "browser-scroll", p):    docsPointerPanel = .Browser
	case:
		// The bottom panel: its tabs' strip and everything below it in its column
		if st, ok := ctx.widgets.states[skald.hash_id("bottom-tabs-scroll")]; ok {
			r := st.last_rect
			if r.w > 0 && p.y >= r.y && p.x >= r.x - 8 && p.x < r.x + r.w + 200 do docsPointerPanel = .Bottom
		}
	}
}

/*
Where Help > User Manual (F1 outside a code tab) goes: the page of the panel under the pointer.

Returns:
- The address (temp allocated)
*/
Docs_HelpAddress :: proc(state: ^State, panel: DocsPanel) -> string {
	scene := state.currentScene >= 0 && state.currentScene < len(state.project.scenes) ? &state.project.scenes[state.currentScene] : nil
	selected := scene != nil && state.selectedNode >= 0 && state.selectedNode < len(scene.nodes) ? &scene.nodes[state.selectedNode] : nil
	switch panel {
	case .Inspector:
		if selected != nil do return Docs_NodeKindAddress(selected.kind)
		return Docs_ManualAddress(DOCS_INSPECTOR_PAGE)
	case .Viewport:
		if selected != nil do return Docs_NodeKindAddress(selected.kind)
		return Docs_ManualAddress(DOCS_VIEWPORT_PAGE)
	case .Scene_Tree:
		return Docs_ManualAddress(DOCS_SCENE_TREE_PAGE)
	case .Bottom:
		return Docs_ManualAddress(DOCS_BOTTOM_TAB_PAGES[Mode_BottomTab(state)])
	case .Level:
		return Docs_ManualAddress(EDITOR_MODES[.Level].manual)
	case .Slicer:
		return Docs_ManualAddress(DOCS_SLICER_PAGE)
	case .Browser:
		if address := Docs_BrowserAddress(state); address != "" do return address
		return Docs_ManualAddress(DOCS_BROWSER_PAGE)
	case .Code:
		return Docs_ManualAddress(DOCS_CODE_PAGE)
	case .None:
	}
	return "/manual/"
}

// The page of the browser's selected row: a scene's, an asset kind's, a script's ("" none)
Docs_BrowserAddress :: proc(state: ^State) -> string {
	sel := state.browserSelection
	#partial switch sel.kind {
	case .Scene:
		return Docs_ManualAddress(DOCS_SCENE_PAGE)
	case .Asset:
		if sel.index >= 0 && sel.index < len(state.project.assets) do return Docs_AssetKindAddress(state.project.assets[sel.index].kind)
	case .Script:
		return Docs_ManualAddress(DOCS_SCRIPT_PAGE)
	}
	return ""
}

// "Open Docs" for a menu: its item, opening an address
Docs_MenuItem :: proc(address: string) -> skald.Menu_Item(Msg) {
	return {label = "Open Docs", msg = Msg(Docs_Opened(strings.clone(address, context.temp_allocator)))}
}

// The window's title line: the page's title ("" while nothing shows)
Docs_Title :: proc(state: ^State) -> string {
	p := DocsLibrary_Find(Docs_Library(), Docs_Current(&state.docs))
	if p == nil do return ""
	return fmt.tprintf("%s", p.title)
}
