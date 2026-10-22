package crossfire_editor

import "core:fmt"
import "gui:skald"
import e "engine:."

/*
The inspector's sound node settings (AudioPlayer, AudioPlayer2D, MusicPlayer): the sound (or
music) asset, the bus, volume, pitch and pan, loop and autostart, the hearing range of a 2D
player, music's fades, and Preview (the sound as the node plays it, without its bus).

Widget keys: `inspector-sound-<node>`, `inspector-bus-<node>`, `inspector-open-mixer-<node>`, `inspector-audio-<Field>-<node>`
(sliders), `inspector-audio-<Flag>-<node>`, `inspector-audio-preview-<node>`.
*/
audioInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	a := node.audio
	music := node.kind == .MusicPlayer

	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	onAudio :: proc(field: AudioField, value: f32) -> Msg { return Audio_Field_Changed{field, value} }
	onFlag :: proc(flag: AudioFlag, value: bool) -> Msg { return Audio_Flag_Changed{flag, value} }
	slider :: proc(ctx: ^skald.Ctx(Msg), key: int, field: AudioField, value, lo, hi, step, def: f32, decimals: int, width: f32) -> skald.View {
		return valueSlider(ctx, fmt.tprintf("inspector-audio-%v-%d", field, key), value, field, onAudio, lo, hi,
			step = step, decimals = decimals, defaultValue = def, width = width)
	}
	flag :: proc(ctx: ^skald.Ctx(Msg), key: int, flag: AudioFlag, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", flag, onFlag, id = skald.hash_id(fmt.tprintf("inspector-audio-%v-%d", flag, key)))
	}

	// Sounds load whole; music streams (the browser's menu switches a file between the two)
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == (music ? AssetKind.Music : .Audio) do append(&choices, asset.path)
	append(&rows, inspectorRow(ctx, music ? "Music" : "Sound", skald.select(ctx, node.sound == "" ? TEXTURE_NONE : node.sound, choices[:],
		NodeTextField.Sound, onText, id = skald.hash_id(fmt.tprintf("inspector-sound-%d", key)), width = controlWidth,
		placeholder = music ? "Choose music" : "Choose a sound")))
	if len(choices) == 1 {
		hint := music ? "No music yet: import audio, then right-click it > Use as Music" : "No sounds yet: import one into the project"
		append(&rows, skald.text(hint, th.color.fg_muted, th.font.size_xs))
	}

	bus := node.bus == "" ? e.MASTER_BUS : node.bus
	append(&rows, inspectorRow(ctx, "Bus", skald.select(ctx, bus, Project_BusNames(&s.project), NodeTextField.Bus, onText,
		id = skald.hash_id(fmt.tprintf("inspector-bus-%d", key)), width = controlWidth)))
	known := false
	for b in s.project.buses do if b.name == bus do known = true
	if !known do append(&rows, skald.text(fmt.tprintf("No bus is called %s: it plays on Master", bus), th.color.warning, th.font.size_xs))
	mixer := skald.button(ctx, fmt.tprintf("%s  Open Mixer", ICON_SLIDERS), Msg(Bottom_Tab_Changed(int(BottomTab.Mixer))),
		id = skald.hash_id(fmt.tprintf("inspector-open-mixer-%d", key)),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, inspectorRow(ctx, "", mixer))

	append(&rows,
		inspectorRow(ctx, "Volume", slider(ctx, key, .Volume, a.volume, 0, 2, 0.01, 1, 2, controlWidth)),
		inspectorRow(ctx, music ? "Speed" : "Pitch", slider(ctx, key, .Pitch, a.pitch, 0.1, 4, 0.01, 1, 2, controlWidth)),
		inspectorRow(ctx, "Pan", slider(ctx, key, .Pan, a.pan, -1, 1, 0.01, 0, 2, controlWidth)),
		inspectorRow(ctx, "Loop", flag(ctx, key, .Loop, a.loop)),
		inspectorRow(ctx, "Autostart", flag(ctx, key, .Autostart, a.autostart)),
	)
	if node.kind == .AudioPlayer2D {
		// Heard fully at the listener (the camera), fading out to nothing at the range
		append(&rows,
			inspectorRow(ctx, "Range", slider(ctx, key, .Max_Distance, a.maxDistance, 1, 5000, 1, e.DEFAULT_AUDIO_SETTINGS.maxDistance, 0, controlWidth)),
			inspectorRow(ctx, "Falloff", slider(ctx, key, .Attenuation, a.attenuation, 0.1, 8, 0.01, e.DEFAULT_AUDIO_SETTINGS.attenuation, 2, controlWidth)),
		)
	}
	if music {
		append(&rows,
			inspectorRow(ctx, "Fade in (s)", slider(ctx, key, .Fade_In, a.fadeIn, 0, 10, 0.1, 0, 1, controlWidth)),
			inspectorRow(ctx, "Fade out (s)", slider(ctx, key, .Fade_Out, a.fadeOut, 0, 10, 0.1, 0, 1, controlWidth)),
		)
	}

	if music do append(&rows, ..musicLayerRows(ctx, s, node, controlWidth))

	// Preview: Play becomes Stop while this node's sound plays
	path := node.sound == "" ? "" : joinPath(s.project.rootPath, node.sound, allocator = context.temp_allocator)
	playing := path != "" && AudioPreview_IsLoaded(path) && AudioPreview_IsPlaying()
	if playing do skald.send(ctx, Msg(Preview_Tick{}))
	preview := skald.button(ctx, playing ? fmt.tprintf("%s  Stop", ICON_STOP) : fmt.tprintf("%s  Preview", ICON_PLAY),
		Msg(Audio_Preview_Requested(!playing)), id = skald.hash_id(fmt.tprintf("inspector-audio-preview-%d", key)),
		disabled = path == "", bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2},
		font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, inspectorRow(ctx, "", skald.tooltip(ctx, preview, "Plays it with this node's volume, pitch and pan (not its bus)",
		id = skald.hash_id(fmt.tprintf("inspector-audio-preview-tip-%d", key)))))
	return rows[:]
}
