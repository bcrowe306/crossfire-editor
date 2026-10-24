package crossfire_editor

import "core:strings"
import "core:testing"
import e "engine:."

// The Particles tab: its categories from the engine's groups, the emitter it follows, edits and
// presets through it as undo steps on that emitter, its layout at the three window sizes

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
particle_categories_come_from_the_engines_groups :: proc(t: ^testing.T) {
	categories := Particles_Categories()
	want := []string{"Emission", "GPU", "Shape", "Rotation", "Color", "Motion", "Forces", "Collision", PARTICLES_ALL}
	testing.expect_value(t, len(categories), len(want))
	if len(categories) == len(want) do for name, i in want do testing.expect_value(t, categories[i], name)
	// Every setting is in a group, the groups in the engine's order, and none is empty
	groups := Particles_FieldGroups()
	fields := e.ParticleSettings_Fields()
	counts := make(map[string]int, context.temp_allocator)
	for field, i in fields {
		testing.expectf(t, groups[i] != "", "%s has a group", field.name)
		counts[groups[i]] += 1
	}
	for name in categories[:len(categories) - 1] do testing.expectf(t, counts[name] > 0, "%s has settings", name)
	at :: proc(name: string) -> string {
		for f, i in e.ParticleSettings_Fields() do if f.name == name do return Particles_FieldGroups()[i]
		return ""
	}
	testing.expect_value(t, at("gpuAmount"), "GPU")
	testing.expect_value(t, at("localSpace"), "Emission")
	testing.expect_value(t, at("colorRamp"), "Color")
	testing.expect_value(t, at("elasticity"), "Collision")
	free_all(context.temp_allocator)
}

@(test)
particles_tab_follows_edits_and_undoes :: proc(t: ^testing.T) {
	root := joinPath(testTempBase(), "particles_tab", "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	sparks := Scene_InsertNode(scene, "Sparks", .ParticleEmitter, -1)
	ship := Scene_InsertNode(scene, "Ship", .Sprite, -1)

	// Nothing shown yet (a node 0 that's an emitter isn't shown before it's selected); edits do nothing
	node, shown := Particles_Emitter(&state)
	testing.expect(t, node == nil && shown == -1, "no emitter shown")
	sendTo(&state, Particle_Field_Changed{"amount", "90"})
	testing.expect_value(t, scene.nodes[sparks].particles.amount, e.DEFAULT_PARTICLE_SETTINGS.amount)
	testing.expect_value(t, len(state.history.undo), 0)

	// The tab shows in the Scene mode and follows the selected emitter
	sendTo(&state, Bottom_Tab_Changed(int(BottomTab.Particles)))
	testing.expect_value(t, Mode_BottomTab(&state), BottomTab.Particles)
	testing.expect(t, Mode_HasBottomTab(.Scene, .Particles) && !Mode_HasBottomTab(.Level, .Particles), "a Scene mode tab")
	testing.expect(t, strings.has_prefix(DOCS_BOTTOM_TAB_PAGES[.Particles], "particles#"), "F1 opens the particles page")
	state.selectedNode = sparks
	sendTo(&state, Particles_Category_Picked(1))
	_, shown = Particles_Emitter(&state)
	testing.expect_value(t, shown, sparks)
	testing.expect_value(t, Particles_CategoryName(&state), "GPU")
	sendTo(&state, Particles_Category_Picked(99))
	testing.expect_value(t, Particles_CategoryName(&state), PARTICLES_ALL)

	// Another node selected: the tab keeps the emitter, and its edits go to it
	state.selectedNode = ship
	sendTo(&state, Particles_Category_Picked(0))
	_, shown = Particles_Emitter(&state)
	testing.expect_value(t, shown, sparks)
	_, target := Particles_Target(&state)
	testing.expect_value(t, target, sparks)
	sendTo(&state, Particle_Field_Changed{"amount", "90"})
	sendTo(&state, Particle_Axis_Changed{"size", 1, 8})
	testing.expect_value(t, scene.nodes[sparks].particles.amount, 90)
	testing.expect_value(t, scene.nodes[sparks].particles.size, [2]f32{5, 8})
	testing.expect_value(t, len(state.history.undo), 2)
	last := state.history.undo[len(state.history.undo) - 1]
	change, isNode := last.change.(NodeChange)
	testing.expect(t, isNode && change.index == sparks, "a node step on the emitter, not the selection")
	testing.expect_value(t, last.label, "Change size of Sparks")

	// The ramp through the tab
	ramp := scene.nodes[sparks].particles.colorRamp
	at := e.ColorRamp_AddStop(&ramp, 0.75, {0, 255, 0, 255})
	sendTo(&state, Ramp_Edited{FormatRampText(ramp), at})
	testing.expect_value(t, scene.nodes[sparks].particles.colorRamp.count, 4)
	testing.expect_value(t, state.rampStop, at)

	// Restart isn't an edit (no preview here: nothing happens)
	steps := len(state.history.undo)
	sendTo(&state, Particles_Restart{})
	testing.expect_value(t, len(state.history.undo), steps)

	// A preset: every setting but where it runs, one step; undo puts the emitter back
	sendTo(&state, Particle_Field_Changed{"gpu", "true"})
	sendTo(&state, Particles_Preset_Applied("Sparks"))
	want, ok := Particles_Preset("Sparks")
	testing.expect(t, ok, "the preset")
	want.gpu, want.gpuAmount = true, e.DEFAULT_PARTICLE_SETTINGS.gpuAmount
	testing.expect_value(t, scene.nodes[sparks].particles, want)
	testing.expect_value(t, state.history.undo[len(state.history.undo) - 1].label, "Apply the Sparks preset to Sparks")
	sendTo(&state, Particles_Preset_Applied("Lava")) // Not a preset: nothing
	testing.expect_value(t, scene.nodes[sparks].particles, want)
	sendTo(&state, Action.Undo)
	scene = &state.project.scenes[0]
	testing.expect_value(t, scene.nodes[sparks].particles.amount, 90)
	testing.expect(t, scene.nodes[sparks].particles.gpu, "undone to the GPU edit")
	testing.expect_value(t, scene.nodes[sparks].particles.colorRamp.count, 4)
	sendTo(&state, Action.Redo)
	scene = &state.project.scenes[0]
	testing.expect_value(t, scene.nodes[sparks].particles, want)

	// Reset through the tab, with the sprite still selected
	state.selectedNode = ship
	sendTo(&state, Particles_Reset{})
	testing.expect_value(t, scene.nodes[sparks].particles, e.DEFAULT_PARTICLE_SETTINGS)
	testing.expect_value(t, scene.nodes[ship].kind, NodeKind.Sprite)
	free_all(context.temp_allocator)
}

// Every preset is valid: its ramp parsed, its numbers in the engine's ranges (sliders can show
// them), and it looks like something (particles that live and move or fall)
@(test)
particle_presets_are_in_range :: proc(t: ^testing.T) {
	testing.expect(t, len(PARTICLE_PRESETS) == 5, "five presets")
	for preset in PARTICLE_PRESETS {
		settings := preset.make()
		testing.expectf(t, settings.lifetime > 0 && settings.amount > 0, "%s emits", preset.name)
		if settings.useColorRamp do testing.expectf(t, settings.colorRamp.count >= 2, "%s has a ramp", preset.name)
		for field in e.ParticleSettings_Fields() {
			if !field.ranged do continue
			text, _ := e.ParticleSettings_Get(settings, field.name)
			for part in strings.split(text, ",", context.temp_allocator) {
				value := f32(0)
				if v, parsed := parseF32(part); parsed do value = v
				testing.expectf(t, value >= field.min && value <= field.max, "%s's %s (%s) is in %v..%v", preset.name, field.name, text, field.min, field.max)
			}
		}
		// Its text round trip (what a scene file stores)
		back: e.ParticleSettings
		back = e.DEFAULT_PARTICLE_SETTINGS
		for field in e.ParticleSettings_Fields() {
			text, _ := e.ParticleSettings_Get(settings, field.name)
			testing.expectf(t, e.ParticleSettings_Set(&back, field.name, text), "%s's %s reads back", preset.name, field.name)
		}
		testing.expectf(t, back == settings, "%s round-trips", preset.name)
	}
	free_all(context.temp_allocator)
}

// The tab's rows fit its column at a tiled window's panel (about 200 px), a short window's and a
// fullscreen one's: beside their label or stacked, never past the column
@(test)
particles_tab_rows_fit_their_column :: proc(t: ^testing.T) {
	settings := Settings_Default()
	theme := Settings_Theme(&settings)
	th := &theme
	for panel in ([]f32{200, 300, 400, 560, 760}) {
		l := Particles_TabLayout(th, panel)
		testing.expectf(t, l.compact == (panel < PARTICLES_TAB_ICONS_WIDTH), "%v: a choice only when narrow", panel)
		width := l.stacked ? l.controlWidth : l.controlWidth + INSPECTOR_LABEL_WIDTH + th.spacing.sm
		ramp := l.stacked ? l.rampWidth : l.rampWidth + INSPECTOR_LABEL_WIDTH + th.spacing.sm
		testing.expectf(t, width <= l.content + 0.5 && ramp <= l.content + 0.5, "%v: rows fit (%v, %v in %v)", panel, width, ramp, l.content)
		testing.expectf(t, l.sidebar + l.content + th.spacing.sm * 2 + INSPECTOR_SCROLLBAR_WIDTH <= panel + 0.5, "%v: the columns fit the panel", panel)
	}
	testing.expect(t, Particles_TabLayout(th, 200).stacked, "stacked in a tiled window")
	testing.expect(t, !Particles_TabLayout(th, 760).stacked && Particles_TabLayout(th, 760).names, "names, side by side, fullscreen")
}

@(private="file")
parseF32 :: proc(text: string) -> (f32, bool) {
	settings: e.ParticleSettings
	if !e.ParticleSettings_Set(&settings, "lifetime", text) do return 0, false
	return settings.lifetime, true
}
