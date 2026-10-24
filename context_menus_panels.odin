package crossfire_editor

import "core:fmt"
import "core:strings"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

/*
The bottom panel's context menus (context_menus.odin): the States and Dialogue graphs, the
Timeline's tracks and keys, the Mixer's strips, the Git tab's changes and the Live tab's nodes.
Each panel's mouse handling selects what was right-clicked (as a left click would) and opens its
`Ctx_Graph`; the items send the panel's own messages, so they're undone and tested like the
panel's buttons.

	graph            item / sub            what it offers
	States           state / transition    start state, transitions to the others, animation, delete;
	                                       a transition's "at its end", delete; empty: add a state
	                                       there, add a parameter
	Dialogue         node                  start node, add a step of each kind, delete; empty: a new
	                                       node there
	Timeline_Track   track                 a key at the playhead or where clicked, step, remove
	Timeline_Key     track / key           delete, move to the playhead, ease
	Mixer_Bus        bus                   mute, effects, reset volume and pan, remove; add a bus
	Git_Change       change                stage or unstage, show changes, discard, keep mine /
	                                       take theirs, the file's items
	Live_Node        row                   show its properties, copy its name
*/

// A panel command from a context menu (none yet: the items send the panels' own messages)
GraphOp :: enum {
	None,
}

// A panel command from a context menu
Graph_Command :: struct {
	graph: GraphKind,
	op: GraphOp,
	item, sub: int,
}

// Copies text to the clipboard (a menu's Copy Name)
Text_Copied :: distinct string

// The panel menus' messages; true when `m` was one
ContextMenu_PanelUpdate :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Graph_Command:
		return {}, true
	case Text_Copied:
		_ = sdl.SetClipboardText(strings.clone_to_cstring(string(v), context.temp_allocator))
		return {}, true
	}
	return {}, false
}

// A panel's menu items for what was right-clicked
ContextMenu_PanelItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	switch t.graph {
	case .States:         statesItems(s, items, t)
	case .Dialogue:       dialogueItems(s, items, t)
	case .Timeline_Track: timelineTrackItems(s, items, t)
	case .Timeline_Key:   timelineKeyItems(s, items, t)
	case .Mixer_Bus:      mixerItems(s, items, t)
	case .Git_Change:     gitItems(s, items, t)
	case .Live_Node:      liveItems(s, items, t)
	case .Animation:
		append(items,
			msgItem(fmt.tprintf("Start at Frame %d", t.item), Msg(Anim_Frame_Clicked{t.item, false})),
			msgItem(fmt.tprintf("End at Frame %d", t.item), Msg(Anim_Frame_Clicked{t.item, true})))
	case .Dialogue_Step:  dialogueStepItems(s, items, t)
	case .Plugin:         pluginItems(s, items, t)
	}
}

@(private="file")
statesItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	machine, index := States_Machine(s)
	if machine == nil do return
	sm := &machine.stateMachine
	switch {
	case t.item >= 0 && t.item < len(sm.states):
		st := sm.states[t.item]
		name := strings.clone(st.name, context.temp_allocator)
		targets := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		for other in sm.states do if other.name != st.name {
			append(&targets, msgItem(strings.clone(other.name, context.temp_allocator), Msg(SM_Changed{op = .Transition_Added, text = strings.clone(other.name, context.temp_allocator)})))
		}
		animations := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		append(&animations, msgItem("None", Msg(SM_Changed{op = .State_Animation, text = ""}), checked = st.animation == ""))
		for a in States_Animations(s, &s.project.scenes[s.states.scene], index) {
			append(&animations, msgItem(a, Msg(SM_Changed{op = .State_Animation, text = a}), checked = a == st.animation))
		}
		append(items,
			msgItem("Start Here", Msg(SM_Changed{op = .Start_Set, text = name}), checked = st.name == sm.start),
			submenuItem("Add Transition To", targets[:]),
			msgItem("Add Transition From Any State", Msg(SM_Changed{op = .Transition_Added, text = "*"})),
			submenuItem("Animation", animations[:]),
			MENU_SEPARATOR,
			msgItem("Delete State", Msg(SM_Changed{op = .State_Removed})))
	case t.sub >= 0 && t.sub < len(sm.transitions):
		tr := sm.transitions[t.sub]
		append(items,
			msgItem("At Its Animation's End", Msg(SM_Changed{op = .Transition_On_Finished, flag = !tr.onFinished}), checked = tr.onFinished),
			msgItem("Ignores the Exit Guard", Msg(SM_Changed{op = .Transition_Interrupts, flag = !tr.interrupts}), checked = tr.interrupts),
			MENU_SEPARATOR,
			msgItem("Delete Transition", Msg(SM_Changed{op = .Transition_Removed})))
	case:
		append(items,
			msgItem("Add State Here", Msg(SM_Changed{op = .State_Added, position = t.local - STATE_BOX * 0.5})),
			msgItem("Add Parameter", Msg(SM_Changed{op = .Param_Added})))
	}
}

@(private="file")
dialogueItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	dialogue := Dialogue_Shown(s)
	if dialogue == nil do return
	data := &dialogue.data
	if t.item < 0 || t.item >= len(data.nodes) {
		append(items, msgItem("New Node Here", Msg(Dialogue_Changed{op = .Node_Added, position = t.local - DIALOGUE_BOX * 0.5})))
		return
	}
	n := data.nodes[t.item]
	steps := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	for kind in e.DialogueStepKind do append(&steps, msgItem(fmt.tprint(kind), Msg(Dialogue_Changed{op = .Step_Added, kind = kind, step = len(n.steps) - 1})))
	append(items,
		msgItem("Start Here", Msg(Dialogue_Changed{op = .Start_Set, text = strings.clone(n.name, context.temp_allocator)}), checked = n.name == data.start),
		submenuItem("Add Step", steps[:]),
		MENU_SEPARATOR,
		msgItem("Delete Node", Msg(Dialogue_Changed{op = .Node_Removed})))
}

@(private="file")
timelineTrackItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	clip := Timeline_Clip(s)
	if clip == nil do return
	if t.item < 0 || t.item >= len(clip.tracks) {
		append(items,
			msgItem("Key Every Track", Msg(Timeline_Changed{op = .Keys_Recorded}), disabled = len(clip.tracks) == 0),
			msgItem(s.timeline.playing ? "Pause" : "Play", Msg(Timeline_View{op = .Play_Toggled})),
			msgItem("Back to the Start", Msg(Timeline_View{op = .Rewound})))
		return
	}
	track := clip.tracks[t.item]
	append(items,
		msgItem(fmt.tprintf("Key at the Playhead (%.2fs)", s.timeline.playhead), Msg(Timeline_Changed{op = .Key_Added})),
		msgItem(fmt.tprintf("Key Here (%.2fs)", t.local.x), Msg(Timeline_Key_Here(t.local.x))),
		msgItem("Step (no blending)", Msg(Timeline_Changed{op = .Track_Step, flag = !track.step}), checked = track.step),
		MENU_SEPARATOR,
		msgItem("Remove Track", Msg(Timeline_Changed{op = .Track_Removed})))
}

@(private="file")
timelineKeyItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	clip := Timeline_Clip(s)
	if clip == nil || t.item < 0 || t.item >= len(clip.tracks) || t.sub < 0 || t.sub >= len(clip.tracks[t.item].keys) do return
	key := clip.tracks[t.item].keys[t.sub]
	eases := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	for ease in e.EaseType do append(&eases, msgItem(fmt.tprint(ease), Msg(Timeline_Changed{op = .Key_Ease, text = fmt.tprint(ease)}), checked = ease == key.ease))
	append(items,
		msgItem(fmt.tprintf("Move to the Playhead (%.2fs)", s.timeline.playhead), Msg(Timeline_Changed{op = .Key_Time, number = s.timeline.playhead})),
		submenuItem("Ease", eases[:]),
		MENU_SEPARATOR,
		msgItem("Delete Key", Msg(Timeline_Changed{op = .Key_Removed})))
}

@(private="file")
mixerItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	buses := s.project.buses[:]
	if t.item >= 0 && t.item < len(buses) {
		b := buses[t.item]
		append(items,
			msgItem("Mute", Msg(Bus_Mute_Toggled(t.item)), checked = b.mute),
			msgItem("Effects...", Msg(Bus_Effects_Opened(t.item))),
			MENU_SEPARATOR,
			msgItem("Reset Volume (0 dB)", Msg(Bus_Volume_Changed{t.item, 1}), disabled = b.volume == 1),
			msgItem("Center Pan", Msg(Bus_Pan_Changed{t.item, 0}), disabled = b.pan == 0),
			MENU_SEPARATOR,
			msgItem("Remove Bus", Msg(Bus_Removed(t.item)), disabled = t.item == 0),
			MENU_SEPARATOR)
	}
	append(items, msgItem("Add Bus", Msg(Bus_Added{})))
}

@(private="file")
gitItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	snapshot := &s.git.snapshot
	if t.item < 0 || t.item >= len(snapshot.changes) do return
	change := snapshot.changes[t.item]
	path := strings.clone(change.path, context.temp_allocator)
	busy := s.git.busy
	conflicted := Git_IsConflicted(change)
	if conflicted {
		append(items,
			msgItem("Keep Mine", Msg(Git_Op_Requested{op = .Resolve_Mine, arg = path}), disabled = busy),
			msgItem("Take Theirs", Msg(Git_Op_Requested{op = .Resolve_Theirs, arg = path}), disabled = busy))
	} else if Git_IsStaged(change) {
		append(items, msgItem("Unstage", Msg(Git_Op_Requested{op = .Unstage, arg = path}), disabled = busy))
	} else {
		append(items, msgItem("Stage", Msg(Git_Op_Requested{op = .Stage, arg = path}), disabled = busy))
	}
	append(items,
		msgItem("Show Changes", Msg(Git_Diff_Requested(path)), checked = s.git.diffPath == change.path),
		msgItem("Discard Changes...", Msg(Git_Discard_Asked(path)), disabled = busy || conflicted || snapshot.merging),
		MENU_SEPARATOR,
		msgItem("Stage All", Msg(Git_Op_Requested{op = .Stage_All}), disabled = busy),
		msgItem("Unstage All", Msg(Git_Op_Requested{op = .Unstage_All}), disabled = busy),
		MENU_SEPARATOR)
	fileItems(items, path)
}

@(private="file")
liveItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	if t.item < 0 || t.item >= len(s.live.nodes) do return
	n := s.live.nodes[t.item]
	append(items,
		msgItem("Show Its Properties", Msg(Live_Selected(strings.clone(n.id, context.temp_allocator))), checked = s.live.selected == n.id),
		msgItem("Copy Name", Msg(Text_Copied(strings.clone(n.name, context.temp_allocator)))),
		MENU_SEPARATOR,
		msgItem(s.live.paused ? "Resume the Game" : "Pause the Game", Msg(Live_Command(s.live.paused ? "resume" : "pause"))))
}

@(private="file")
dialogueStepItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	dialogue := Dialogue_Shown(s)
	if dialogue == nil || s.dialogue.node < 0 || s.dialogue.node >= len(dialogue.data.nodes) do return
	steps := dialogue.data.nodes[s.dialogue.node].steps[:]
	if t.item < 0 || t.item >= len(steps) do return
	kinds := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	for kind in e.DialogueStepKind do append(&kinds, msgItem(fmt.tprint(kind), Msg(Dialogue_Changed{op = .Step_Added, kind = kind, step = t.item})))
	append(items,
		msgItem("Move Up", Msg(Dialogue_Changed{op = .Step_Moved, step = t.item, delta = -1}), disabled = t.item == 0),
		msgItem("Move Down", Msg(Dialogue_Changed{op = .Step_Moved, step = t.item, delta = 1}), disabled = t.item == len(steps) - 1),
		submenuItem("Insert After", kinds[:]))
	if steps[t.item].kind == .Options do append(items, msgItem("Add Option", Msg(Dialogue_Changed{op = .Option_Added, step = t.item})))
	append(items, MENU_SEPARATOR, msgItem("Delete Step", Msg(Dialogue_Changed{op = .Step_Removed, step = t.item})))
}

@(private="file")
pluginItems :: proc(s: ^State, items: ^MenuItems, t: Ctx_Graph) {
	list := Plugins_List()
	if t.item < 0 || t.item >= len(list) do return
	p := list[t.item]
	if p.status == .Loaded {
		for c, k in p.commands do append(items, msgItem(strings.clone(c.name, context.temp_allocator), Msg(Plugin_Command_Run{t.item, k})))
		if len(p.commands) > 0 do append(items, MENU_SEPARATOR)
	}
	folder := fmt.tprintf("%s/%s", PLUGINS_FOLDER, p.folder)
	main := fmt.tprintf("%s/%s.odin", folder, p.folder)
	append(items,
		msgItem("Open Its Code", Msg(Script_Open_File{file = projectFilePath(s, main), line = 1})),
		msgItem("Rebuild All", Msg(Plugins_Rebuild_Requested{})),
		MENU_SEPARATOR,
		msgItem("Show in File Manager", Msg(File_Command{.Show_In_Folder, folder})),
		msgItem("Copy Path", Msg(File_Command{.Copy_Path, folder})))
}
