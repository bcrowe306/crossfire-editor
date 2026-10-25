package crossfire_editor

// The command palette's matching, ranking and entries (command_palette.odin), and the breadcrumbs
// (breadcrumbs.odin). Run with: task test

import "core:strings"
import "core:testing"

// The demo project in memory, PlayScene open, nothing selected
@(private="file")
paletteState :: proc() -> State {
	state := State{
		project = Project_CreateTestProject("unused"),
		browserSelection = {kind = .None},
		currentScene = 1,
		selectedNode = -1,
		busSelection = -1,
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

@(private="file")
paletteSend :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
paletteFind :: proc(entries: []PaletteEntry, kind: PaletteKind, label: string) -> (PaletteEntry, bool) {
	for e in entries do if e.kind == kind && e.label == label do return e, true
	return {}, false
}

@(test)
palette_fuzzy_matches_rank_best_first :: proc(t: ^testing.T) {
	entries := []PaletteEntry{
		{kind = .Action, label = "Toggle bottom panel"},
		{kind = .Asset, label = "bottom.png"},
		{kind = .Node, label = "Bottom"},
		{kind = .Doc, label = "Scene changes"},
	}
	// A whole word: the shortest label first
	matches := Palette_Matches(entries, "bottom")
	testing.expect_value(t, len(matches), 3)
	testing.expect_value(t, entries[matches[0].entry].label, "Bottom")
	testing.expect_value(t, entries[matches[1].entry].label, "bottom.png")
	testing.expect_value(t, entries[matches[2].entry].label, "Toggle bottom panel")
	// Letters in order, case aside, word starts count: "tbp" is the action's initials
	matches = Palette_Matches(entries, "TBP")
	testing.expect_value(t, len(matches), 1)
	testing.expect_value(t, entries[matches[0].entry].label, "Toggle bottom panel")
	// Out of order, or missing letters: no match
	testing.expect_value(t, len(Palette_Matches(entries, "mottob")), 0)
	testing.expect_value(t, len(Palette_Matches(entries, "zzz")), 0)
	// An empty query lists everything by category, in the entries' order
	matches = Palette_Matches(entries, "")
	testing.expect_value(t, len(matches), 4)
	testing.expect_value(t, entries[matches[0].entry].kind, PaletteKind.Action)
	testing.expect_value(t, entries[matches[3].entry].kind, PaletteKind.Doc)
	// Equal scores: by category
	tie := []PaletteEntry{{kind = .Asset, label = "Play"}, {kind = .Action, label = "Play"}}
	matches = Palette_Matches(tie, "play")
	testing.expect_value(t, tie[matches[0].entry].kind, PaletteKind.Action)
}

@(test)
palette_prefixes_keep_one_category :: proc(t: ^testing.T) {
	kinds, text := Palette_ParseQuery("  ,row height ")
	testing.expect_value(t, kinds, bit_set[PaletteKind]{.Setting})
	testing.expect_value(t, text, "row height")
	kinds, text = Palette_ParseQuery(">build")
	testing.expect_value(t, kinds, bit_set[PaletteKind]{.Action, .Code})
	testing.expect_value(t, text, "build")
	kinds, text = Palette_ParseQuery("ship")
	testing.expect_value(t, kinds, ~bit_set[PaletteKind]{})
	testing.expect_value(t, text, "ship")
	entries := []PaletteEntry{{kind = .Node, label = "Ship"}, {kind = .Asset, label = "ship.png"}, {kind = .Doc, label = "Shipping a game"}}
	testing.expect_value(t, len(Palette_Matches(entries, "ship")), 3)
	only := Palette_Matches(entries, "#ship")
	testing.expect_value(t, len(only), 1)
	testing.expect_value(t, entries[only[0].entry].kind, PaletteKind.Asset)
	testing.expect_value(t, len(Palette_Matches(entries, "@")), 1)
	testing.expect_value(t, len(Palette_Matches(entries, "?ship")), 1)
}

@(test)
palette_entries_list_everything :: proc(t: ^testing.T) {
	state := paletteState()
	defer State_Destroy(&state)
	entries := Palette_Entries(&state, "")
	// Actions with their keys; not the palette itself
	play, found := paletteFind(entries, .Action, ACTION_LABELS[.Play])
	testing.expect(t, found, "Play is listed")
	testing.expect_value(t, play.detail, Chord_Format(Keymap_Shortcut(&state.settings.keymap, .Play)))
	playAction, isAction := play.msg.(Action)
	testing.expect(t, isAction && playAction == .Play, "sends Play")
	_, found = paletteFind(entries, .Action, ACTION_LABELS[.Command_Palette])
	testing.expect(t, !found, "the palette doesn't list itself")
	_, found = paletteFind(entries, .Action, "New scene")
	testing.expect(t, found, "the menus' other items")
	// Settings, the open scene's nodes with their path, scenes and assets, the docs
	_, found = paletteFind(entries, .Setting, "Row height")
	testing.expect(t, found, "a setting")
	ship: PaletteEntry
	ship, found = paletteFind(entries, .Node, "Spaceship")
	testing.expect(t, found, "a node")
	testing.expect(t, strings.contains(ship.detail, "World"), ship.detail)
	_, found = paletteFind(entries, .Asset, "PlayScene")
	testing.expect(t, found, "a scene")
	_, found = paletteFind(entries, .Asset, "ship.png")
	testing.expect(t, found, "an asset")
	if len(Docs_Library().pages) > 0 {
		docs := 0
		for e in entries do if e.kind == .Doc do docs += 1
		testing.expect(t, docs > 10, "the docs' pages")
	}
	// Another mode lists its own actions: no node editing in the Level mode
	state.mode = .Level
	_, found = paletteFind(Palette_Entries(&state, ""), .Action, ACTION_LABELS[.Add_Node])
	testing.expect(t, !found, "Add node is the Scene mode's")
	state.mode = .Scene
	_, found = paletteFind(Palette_Entries(&state, ""), .Action, ACTION_LABELS[.Add_Node])
	testing.expect(t, found, "Add node in the Scene mode")
}

@(test)
palette_runs_what_it_finds :: proc(t: ^testing.T) {
	state := paletteState()
	defer State_Destroy(&state)
	paletteSend(&state, Action.Command_Palette)
	testing.expect(t, state.palette.open, "opens")
	testing.expect_value(t, state.palette.query, "")
	// A node: selected, its parents opened
	scene := &state.project.scenes[1]
	ship := -1
	for n, i in scene.nodes do if n.name == "Spaceship" do ship = i
	scene.nodes[scene.nodes[ship].parent].expanded = false
	paletteSend(&state, Palette_Query_Changed("@spaceship"))
	paletteSend(&state, Palette_Confirmed{})
	testing.expect(t, !state.palette.open, "closes")
	testing.expect_value(t, state.selectedNode, ship)
	testing.expect(t, scene.nodes[scene.nodes[ship].parent].expanded, "its parent opened")
	// A setting: Settings on its tab, the row lit
	paletteSend(&state, Action.Command_Palette)
	paletteSend(&state, Palette_Query_Changed(",hot reload"))
	paletteSend(&state, Palette_Confirmed{})
	testing.expect(t, state.settingsDialog.open, "Settings opens")
	testing.expect_value(t, state.settingsDialog.tab, SettingsTab.Editor)
	testing.expect_value(t, state.settingsDialog.highlight, "Hot reload")
	paletteSend(&state, Settings_Cancelled{})
	settingsRevealWanted = false
	// The highlight moves within the matches and stops at the ends
	paletteSend(&state, Action.Command_Palette)
	paletteSend(&state, Palette_Query_Changed("#"))
	paletteSend(&state, Palette_Highlight_Moved(-1))
	testing.expect_value(t, state.palette.highlight, 0)
	paletteSend(&state, Palette_Highlight_Moved(1000))
	testing.expect_value(t, state.palette.highlight, min(len(Palette_Matches(Palette_Entries(&state, ""), "#")), PALETTE_SHOWN) - 1)
	// A category button types its prefix over the query's
	paletteSend(&state, Palette_Query_Changed(">play"))
	paletteSend(&state, Palette_Category_Picked(int(PaletteKind.Setting)))
	testing.expect_value(t, state.palette.query, ",play")
	paletteSend(&state, Palette_Category_Picked(-1))
	testing.expect_value(t, state.palette.query, "play")
	paletteSend(&state, Palette_Closed{})
	testing.expect(t, !state.palette.open, "Escape closes")
	// An action is sent as its message
	entry, _ := paletteFind(Palette_Entries(&state, ""), .Action, ACTION_LABELS[.About])
	command := Palette_Run(&state, entry)
	about, isAbout := command.msg.(Action)
	testing.expect(t, isAbout && about == .About, "sends About")
}

// Every row of the Settings dialog can be found
@(test)
palette_settings_cover_the_dialog :: proc(t: ^testing.T) {
	source := #load("view_settings.odin", string)
	MARK :: `settingRow(ctx, "`
	rest := source
	rows := 0
	for {
		at := strings.index(rest, MARK)
		if at < 0 do break
		rest = rest[at + len(MARK):]
		label := rest[:strings.index_byte(rest, '"')]
		if label == "" do continue
		rows += 1
		found := false
		for s in PALETTE_SETTINGS do if s.label == label do found = true
		testing.expectf(t, found, "Settings' %q row isn't in PALETTE_SETTINGS", label)
	}
	testing.expect(t, rows > 20, "the rows were found")
}

@(test)
breadcrumbs_follow_the_selection :: proc(t: ^testing.T) {
	state := paletteState()
	defer State_Destroy(&state)
	scene := &state.project.scenes[1]
	ship := -1
	for n, i in scene.nodes do if n.name == "Spaceship" do ship = i
	chain := Breadcrumbs_Chain(scene, ship)
	testing.expect_value(t, len(chain), 2)
	testing.expect_value(t, scene.nodes[chain[0]].name, "World")
	testing.expect_value(t, len(Breadcrumbs_Chain(scene, -1)), 0)
	testing.expect_value(t, Palette_NodePath(scene, ship), "World")
	// The scene, then the path; every crumb but the last selects (the scene's deselects)
	state.selectedNode = ship
	crumbs := Breadcrumbs_Scene(&state)
	testing.expect_value(t, len(crumbs), 3)
	testing.expect_value(t, crumbs[0].label, scene.name)
	deselect, isDeselect := crumbs[0].msg.(Action)
	testing.expect(t, isDeselect && deselect == .Deselect, "the scene deselects")
	picked, isPicked := crumbs[1].msg.(Node_Picked)
	testing.expect(t, isPicked && int(picked) == chain[0], "a parent selects it")
	testing.expect(t, crumbs[2].msg == nil, "the last is where it ends")
	paletteSend(&state, crumbs[1].msg)
	testing.expect_value(t, state.selectedNode, chain[0])
	state.selectedNode = -1
	testing.expect_value(t, len(Breadcrumbs_Scene(&state)), 1)
}

@(test)
breadcrumbs_drop_from_the_left :: proc(t: ^testing.T) {
	widths := []f32{50, 40, 40, 60}
	// 50 + 40 + 40 + 60 and three separators of 10: 220
	testing.expect_value(t, Breadcrumbs_Fit(widths, 10, 20, 220), 0)
	// The first goes behind an ellipsis (20 + 10 for it): 220 - 60 + 30 = 190
	testing.expect_value(t, Breadcrumbs_Fit(widths, 10, 20, 200), 1)
	testing.expect_value(t, Breadcrumbs_Fit(widths, 10, 20, 190), 1)
	testing.expect_value(t, Breadcrumbs_Fit(widths, 10, 20, 150), 2)
	// Never the last one, however narrow
	testing.expect_value(t, Breadcrumbs_Fit(widths, 10, 20, 10), 3)
	testing.expect_value(t, Breadcrumbs_Fit(widths[:1], 10, 20, 10), 0)
}
