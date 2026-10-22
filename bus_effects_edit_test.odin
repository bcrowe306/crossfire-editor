package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// Bus effects (bus_effects_edit.odin) and MusicPlayer layers (music_layers_edit.odin) in the
// editor: added, changed, moved, removed, undone, saved and read back

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
freshState :: proc(dir: string) -> State {
	os.make_directory("build")
	removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1,
		materialSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(test)
bus_effects_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_bus_effects"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	sendTo(&state, Bus_Added{})
	testing.expect_value(t, len(state.project.buses), 2)

	// The Mixer's FX button shows the bus in the inspector
	sendTo(&state, Bus_Effects_Opened(1))
	testing.expect_value(t, state.busSelection, 1)
	bus := &state.project.buses[1]

	// Added in order, at most AUDIO_MAX_EFFECTS
	sendTo(&state, Bus_Effect_Added{1, .LowPass})
	sendTo(&state, Bus_Effect_Added{1, .Reverb})
	testing.expect_value(t, bus.effectCount, 2)
	testing.expect_value(t, bus.effects[0], e.AudioEffect_Make(.LowPass))
	testing.expect_value(t, bus.effects[1].kind, e.AudioEffectKind.Reverb)

	// Changed, clamped and rounded
	sendTo(&state, Bus_Effect_Changed{1, 0, .Cutoff, 900.4, false})
	sendTo(&state, Bus_Effect_Changed{1, 0, .Resonance, 50, false})
	sendTo(&state, Bus_Effect_Changed{1, 1, .Mix, 0.123456, false})
	sendTo(&state, Bus_Effect_Changed{1, 1, .Bypass, 0, true})
	testing.expect_value(t, bus.effects[0].cutoff, 900)
	testing.expect_value(t, bus.effects[0].resonance, 10)
	testing.expect_value(t, bus.effects[1].mix, 0.123)
	testing.expect(t, bus.effects[1].bypass, "bypassed")

	// Moved: the reverb first
	sendTo(&state, Bus_Effect_Moved{1, 1, -1})
	testing.expect_value(t, bus.effects[0].kind, e.AudioEffectKind.Reverb)
	testing.expect_value(t, bus.effects[1].kind, e.AudioEffectKind.LowPass)
	// Out of range: nothing
	sendTo(&state, Bus_Effect_Moved{1, 1, 1})
	testing.expect_value(t, bus.effects[1].kind, e.AudioEffectKind.LowPass)

	// Undone a step at a time (the move, then the bypass)
	sendTo(&state, Action.Undo)
	bus = &state.project.buses[1]
	testing.expect_value(t, bus.effects[0].kind, e.AudioEffectKind.LowPass)
	sendTo(&state, Action.Redo)
	bus = &state.project.buses[1]
	testing.expect_value(t, bus.effects[0].kind, e.AudioEffectKind.Reverb)

	// Master takes effects too; saved and read back
	sendTo(&state, Bus_Effect_Added{0, .Echo})
	sendTo(&state, Bus_Effect_Changed{0, 0, .Delay, 0.5, false})
	testing.expect_value(t, Project_Save(&state.project), "")
	text, _ := os.read_entire_file(joinPath(state.project.rootPath, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `<effect kind="Echo" delay="0.5"/>`), "Master's echo is written with only what differs")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, busesEqual(state.project.buses[:], loaded.buses[:]), "effects survive saving")

	// Removed
	sendTo(&state, Bus_Effect_Removed{1, 0})
	testing.expect_value(t, state.project.buses[1].effectCount, 1)
	testing.expect_value(t, state.project.buses[1].effects[0].kind, e.AudioEffectKind.LowPass)
	testing.expect_value(t, state.project.buses[1].effects[1], e.AudioEffect{})

	// Selecting a node closes the bus
	sendTo(&state, Add_Node_Kind_Chosen(.Node2D))
	testing.expect_value(t, state.busSelection, -1)
}

@(test)
music_layers_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_music_layers"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	append(&state.project.assets, AssetDef{path = strings.clone("assets/drums.ogg"), kind = .Music})
	sendTo(&state, Add_Node_Kind_Chosen(.MusicPlayer))
	scene := &state.project.scenes[state.currentScene]
	index := state.selectedNode
	testing.expect(t, index >= 0 && scene.nodes[index].kind == .MusicPlayer, "a MusicPlayer")

	sendTo(&state, Music_Layer_Added{})
	sendTo(&state, Music_Layer_Added{})
	layers := &state.project.scenes[state.currentScene].nodes[index].musicLayers
	testing.expect_value(t, len(layers), 2)
	testing.expect_value(t, layers[0].name, "layer")
	testing.expect_value(t, layers[1].name, "layer 2")
	sendTo(&state, Music_Layer_Changed{index = 0, field = .Name, text = "drums"})
	sendTo(&state, Music_Layer_Changed{index = 0, field = .Sound, text = "assets/drums.ogg"})
	sendTo(&state, Music_Layer_Changed{index = 0, field = .Volume, value = 0.004})
	layers = &state.project.scenes[state.currentScene].nodes[index].musicLayers
	testing.expect_value(t, layers[0], MusicLayerDef{"drums", "assets/drums.ogg", 0})
	sendTo(&state, Music_Layer_Removed(1))
	layers = &state.project.scenes[state.currentScene].nodes[index].musicLayers
	testing.expect_value(t, len(layers), 1)

	// Undo brings the second layer back; redo removes it again
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(state.project.scenes[state.currentScene].nodes[index].musicLayers), 2)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, len(state.project.scenes[state.currentScene].nodes[index].musicLayers), 1)

	// Saved as <layer> and read back; copies are deep
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	found := false
	for &s in loaded.scenes do for &n in s.nodes do if n.kind == .MusicPlayer {
		found = true
		testing.expect(t, MusicLayers_Equal(n.musicLayers, state.project.scenes[state.currentScene].nodes[index].musicLayers), "layers survive saving")
	}
	testing.expect(t, found, "the player is read back")
	copy := NodeDef_Clone(state.project.scenes[state.currentScene].nodes[index])
	defer NodeDef_Destroy(&copy)
	testing.expect(t, raw_data(copy.musicLayers[0].name) != raw_data(state.project.scenes[state.currentScene].nodes[index].musicLayers[0].name), "a clone owns its strings")
}
