package editor

import "core:fmt"
import "core:strings"
import e "engine:."

/*
Mix buses (the engine's audio_nodes.odin): sound nodes (AudioPlayer, AudioPlayer2D, MusicPlayer)
go to a bus, every bus to Master; a bus has a volume, a pan and a mute. The bottom panel's Mixer
tab edits them (view_mixer.odin); a sound node's inspector picks its bus. Buses are project
settings: in project.xml as `<bus>`, in the `.Project` undo snapshot. Effects come later.
*/

// A bus: its name (owned), volume (0-2, 1 unchanged), pan (-1 to 1), mute
BusDef :: struct {
	name: string,
	volume: f32,
	pan: f32,
	mute: bool,
}

// The project's buses from its file: Master first (made if the file has none), then the rest (owned)
Buses_FromData :: proc(buses: []e.AudioBusData) -> [dynamic]BusDef {
	list := make([dynamic]BusDef)
	append(&list, BusDef{strings.clone(e.MASTER_BUS), 1, 0, false})
	for b in buses {
		if b.name == e.MASTER_BUS {
			list[0].volume, list[0].pan, list[0].mute = b.volume, b.pan, b.mute
			continue
		}
		append(&list, BusDef{strings.clone(b.name), b.volume, b.pan, b.mute})
	}
	return list
}

busesEqual :: proc(a, b: []BusDef) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// The bus choices for a sound node: Master, then the others (temp allocated)
Project_BusNames :: proc(project: ^Project) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for b in project.buses do append(&names, b.name)
	if len(names) == 0 do append(&names, e.MASTER_BUS)
	return names[:]
}

// Why a bus can't be called `name` ("" if it can)
BusNameProblem :: proc(project: ^Project, index: int, name: string) -> string {
	trimmed := strings.trim_space(name)
	if trimmed == "" do return "Give it a name"
	if trimmed != name do return "No spaces at the ends"
	for b, i in project.buses do if i != index && strings.equal_fold(b.name, name) do return "There's already a bus with that name"
	return ""
}

// Sound nodes going to a bus, in every scene and component ("" or Master: those on Master)
Bus_NodeCount :: proc(project: ^Project, name: string) -> int {
	count := 0
	master := name == "" || name == e.MASTER_BUS
	for &scene in project.scenes {
		for node in scene.nodes {
			if !isSoundKind(node.kind) do continue
			if master ? (node.bus == "" || node.bus == e.MASTER_BUS) : node.bus == name do count += 1
		}
	}
	return count
}

isSoundKind :: proc(kind: NodeKind) -> bool {
	return kind == .AudioPlayer || kind == .AudioPlayer2D || kind == .MusicPlayer
}

/*
Handles the Mixer tab's messages: the project's buses. Each is a `.Project` undo step
(History_Classify), merged while a slider is dragged.

Returns:
- Whether `m` was one of them
*/
Mixer_Update :: proc(state: ^State, m: Msg) -> bool {
	p := &state.project
	if len(p.buses) == 0 do p.buses = Buses_FromData(nil)
	bus :: proc(p: ^Project, i: int) -> ^BusDef {
		return i >= 0 && i < len(p.buses) ? &p.buses[i] : nil
	}
	#partial switch v in m {
	case Bus_Added:
		name := "Bus"
		for n := 2; BusNameProblem(p, -1, name) != ""; n += 1 do name = fmt.tprintf("Bus %d", n)
		append(&p.buses, BusDef{strings.clone(name), 1, 0, false})
		delete(state.busEdit.text)
		state.busEdit = {}
	case Bus_Removed:
		// Master stays; nodes on the bus go to Master
		i := int(v)
		if i <= 0 || i >= len(p.buses) do break
		name := strings.clone(p.buses[i].name, context.temp_allocator)
		for &scene in p.scenes {
			for &node in scene.nodes {
				if isSoundKind(node.kind) && node.bus == name {
					delete(node.bus)
					node.bus = strings.clone("")
				}
			}
		}
		delete(p.buses[i].name)
		ordered_remove(&p.buses, i)
		delete(state.busEdit.text)
		state.busEdit = {}
	case Bus_Renamed:
		// The typed name is kept until it's a valid one (the field shows it meanwhile)
		delete(state.busEdit.text)
		state.busEdit = {v.index, strings.clone(v.name)}
		b := bus(p, v.index)
		if b == nil || v.index == 0 || BusNameProblem(p, v.index, v.name) != "" do break
		// The nodes on it follow the name
		for &scene in p.scenes {
			for &node in scene.nodes {
				if isSoundKind(node.kind) && node.bus == b.name {
					delete(node.bus)
					node.bus = strings.clone(v.name)
				}
			}
		}
		delete(b.name)
		b.name = strings.clone(v.name)
	case Bus_Volume_Changed:
		if b := bus(p, v.index); b != nil do b.volume = clamp(v.value, 0, 2)
	case Bus_Pan_Changed:
		if b := bus(p, v.index); b != nil do b.pan = clamp(v.value, -1, 1)
	case Bus_Mute_Toggled:
		if b := bus(p, int(v)); b != nil do b.mute = !b.mute
	case:
		return false
	}
	return true
}
