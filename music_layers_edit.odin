package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
A MusicPlayer's layers in the editor (the engine's music_layers.odin): extra music files that
play in step with the main one (stems of one song), each with a name scripts fade it by
(`e.MusicPlayer_SetLayerVolume(music, "drums", 1, seconds = 2)`) and a starting volume.

- **Data:** `NodeDef.musicLayers` (owned strings), from the scene file's `<layer>` children of a
  MusicPlayer and written back.
- **Edits** (`Music_Layer_Added` / `_Removed` / `_Changed`) are node undo steps; typing a name
  and dragging a volume merge.
- The editor's Preview plays the main music only: layers play in the game (Play).
*/

// A MusicPlayer's layer: `<layer name="drums" sound="music/drums.ogg" volume="0"/>`
MusicLayerDef :: struct {
	// Its name (scripts fade it by name), owned
	name: string,
	// Its music asset, relative to the project folder, owned
	sound: string,
	// Its volume when the music starts (0 silent: fade it in from a script)
	volume: f32,
}

// What a `Music_Layer_Changed` sets
MusicLayerField :: enum {
	Name,
	Sound,
	Volume,
}

// A layer added to the selected MusicPlayer, removed (its index), or changed
Music_Layer_Added :: struct {}
Music_Layer_Removed :: distinct int
Music_Layer_Changed :: struct {
	index: int,
	field: MusicLayerField,
	text: string,
	value: f32,
}

// Copies of layers (strings owned)
MusicLayers_Clone :: proc(layers: [dynamic]MusicLayerDef) -> [dynamic]MusicLayerDef {
	out := make([dynamic]MusicLayerDef, 0, len(layers))
	for l in layers do append(&out, MusicLayerDef{strings.clone(l.name), strings.clone(l.sound), l.volume})
	return out
}

// Frees layers and their strings
MusicLayers_Destroy :: proc(layers: ^[dynamic]MusicLayerDef) {
	for l in layers {
		delete(l.name)
		delete(l.sound)
	}
	delete(layers^)
	layers^ = nil
}

// Whether two lists of layers are the same
MusicLayers_Equal :: proc(a, b: [dynamic]MusicLayerDef) -> bool {
	if len(a) != len(b) do return false
	for l, i in a do if l != b[i] do return false
	return true
}

// A name no layer of the list has ("layer", "layer 2", ...)
MusicLayers_UniqueName :: proc(layers: [dynamic]MusicLayerDef) -> string {
	taken :: proc(layers: [dynamic]MusicLayerDef, name: string) -> bool {
		for l in layers do if l.name == name do return true
		return false
	}
	if !taken(layers, "layer") do return "layer"
	for n := 2; ; n += 1 {
		name := fmt.tprintf("layer %d", n)
		if !taken(layers, name) do return name
	}
}

// The layer messages, on the selected MusicPlayer; returns whether `m` was one
MusicLayers_Update :: proc(s: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Music_Layer_Added:
		node := selectedNode(s)
		if node == nil || node.kind != .MusicPlayer do return true
		append(&node.musicLayers, MusicLayerDef{name = strings.clone(MusicLayers_UniqueName(node.musicLayers)), volume = 1})
	case Music_Layer_Removed:
		node := selectedNode(s)
		if node == nil || node.kind != .MusicPlayer || int(v) < 0 || int(v) >= len(node.musicLayers) do return true
		l := node.musicLayers[int(v)]
		delete(l.name)
		delete(l.sound)
		ordered_remove(&node.musicLayers, int(v))
	case Music_Layer_Changed:
		node := selectedNode(s)
		if node == nil || node.kind != .MusicPlayer || v.index < 0 || v.index >= len(node.musicLayers) do return true
		l := &node.musicLayers[v.index]
		switch v.field {
		case .Name:
			delete(l.name)
			l.name = strings.clone(v.text)
		case .Sound:
			delete(l.sound)
			l.sound = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
		case .Volume:
			// Short numbers in scene files
			l.volume = clamp(math.round(v.value * 100) / 100, 0, 2)
		}
	case:
		return false
	}
	return true
}

/*
A MusicPlayer's Layers rows: each layer's name, music and volume with a remove button, then Add
Layer. Keys `inspector-layer-<i>-name` / `-sound` / `-volume` / `-remove`, `inspector-layer-add`.
*/
musicLayerRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, controlWidth: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.divider(ctx), uiText(th, .Value, "Layers"))
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Music do append(&choices, asset.path)
	key :: proc(i: int, field: string) -> skald.Widget_ID { return skald.hash_id(fmt.tprintf("inspector-layer-%d-%s", i, field)) }
	onName :: proc(i: int, v: string) -> Msg { return Music_Layer_Changed{index = i, field = .Name, text = v} }
	onSound :: proc(i: int, v: string) -> Msg { return Music_Layer_Changed{index = i, field = .Sound, text = v} }
	onVolume :: proc(i: int, v: f32) -> Msg { return Music_Layer_Changed{index = i, field = .Volume, value = v} }
	for l, i in node.musicLayers {
		remove := skald.button(ctx, ACTION_ICONS[.Delete], Msg(Music_Layer_Removed(i)), id = key(i, "remove"),
			bg = th.color.surface, fg = th.color.fg_muted, font_size = th.font.size_xs, padding = {tk.xs, tk.hair})
		append(&rows,
			skald.row(uiText(th, .Muted, fmt.tprintf("Layer %d", i + 1)), skald.flex(1, skald.spacer(0)), remove,
				cross_align = .Center, width = inspectorRowWidth(controlWidth)),
			inspectorRow(ctx, "Layer name", skald.text_input(ctx, l.name, i, onName, id = key(i, "name"), width = controlWidth,
				placeholder = "drums", padding = InspectorFieldPadding(ctx))),
			inspectorRow(ctx, "Layer music", skald.select(ctx, l.sound == "" ? TEXTURE_NONE : l.sound, choices[:], i, onSound,
				id = key(i, "sound"), width = controlWidth, placeholder = "Choose music")),
			inspectorRow(ctx, "Layer volume", valueSlider(ctx, fmt.tprintf("inspector-layer-%d-volume", i), l.volume, i, onVolume, 0, 2,
				step = 0.01, decimals = 2, defaultValue = 1, width = controlWidth)),
		)
		if l.name == "" do append(&rows, uiText(th, .Muted, "A layer needs a name: scripts fade it by name.", color = th.color.warning))
		for other, j in node.musicLayers do if j < i && other.name == l.name && l.name != "" {
			append(&rows, uiText(th, .Muted, fmt.tprintf("Another layer is called %s: the game keeps the last one.", l.name), color = th.color.warning))
			break
		}
	}
	add := skald.button(ctx, fmt.tprintf("%s  Add Layer", ACTION_ICONS[.Add]), Msg(Music_Layer_Added{}), id = skald.hash_id("inspector-layer-add"),
		bg = th.color.surface, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, inspectorRow(ctx, "", skald.tooltip(ctx, add, "A music file that plays in step with this one (a stem: drums, strings); fade it from a script",
		id = skald.hash_id("inspector-layer-add-tip"))))
	append(&rows, uiText(th, .Muted, "Layers play in step with the music in the game, at their volume times the player's. Scripts fade them: e.MusicPlayer_SetLayerVolume(music, \"drums\", 1, seconds = 2).", max_width = inspectorRowWidth(controlWidth)))
	return rows[:]
}
