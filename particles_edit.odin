package crossfire_editor

import "core:fmt"
import e "engine:."

/*
The Particles tab's model (the bottom panel's; view_particles.odin draws it): the
ParticleEmitter it shows, the category of settings it shows, the presets.

- **Which emitter:** `ParticlesEditor.node` follows the selection when a ParticleEmitter is
  selected (`Particles_Follow`, after every message in `update`) and stays when another node is
  selected, like the Timeline and States tabs. `Particles_Emitter` checks it's still an emitter of
  the open scene.
- **Edits go to `Particles_Target`:** the selected node when it's an emitter, else the tab's.
  The inspector shows an emitter (a summary, Emitting, a preset: view_inspector_particles.odin)
  only while it's selected, and then the tab shows the same one, so the messages
  (`Particle_Field_Changed`, `Particle_Axis_Changed`, `Ramp_Edited`, `Particles_Reset`,
  `Particles_Preset_Applied`) go to the same node, and each is a `.Node` undo step on it.
- **Opened from the inspector** (`Particles_Tab_Opened`): its Edit in the Particles tab button,
  or a category's link, shows the tab (the bottom panel opened) at that category.
- **Categories** are the engine's `group` tags (`e.ParticleSettings_Fields`: Emission, GPU, Shape,
  Rotation, Color, Motion, Forces, Collision), then All: a group added in the engine is a tab
  here with no editor change (`Particles_Categories`).
- **Presets** (`PARTICLE_PRESETS`: Fire, Smoke, Sparks, Dust, Rain) set every setting but where
  it runs (`gpu`, `gpuAmount`), one undo step (`Particles_Preset_Applied`).
- **Restart** (`Particles_Restart`) clears the viewport's emitter and starts it again
  (`Preview_RestartEmitter`; not an edit).
*/

// The Particles tab's own state (not undone)
ParticlesEditor :: struct {
	// The emitter shown: its scene and node index, once one was selected (`shown`)
	scene, node: int,
	shown: bool,
	// The category shown: an index into `Particles_Categories` (its last is All)
	category: int,
}

// The category that shows every setting, after the engine's groups
PARTICLES_ALL :: "All"

// A Particles tab category picked (an index into `Particles_Categories`)
Particles_Category_Picked :: distinct int
// The inspector's way to the Particles tab: it shows, at this category (an index into
// `Particles_Categories`; -1 keeps the one it shows)
Particles_Tab_Opened :: distinct int
// The Particles tab's Restart: the viewport's emitter starts again, its particles cleared
Particles_Restart :: struct {}
// A preset applied to the Particles tab's emitter (its name in `PARTICLE_PRESETS`)
Particles_Preset_Applied :: distinct string

/*
The Particles tab's categories: the engine's settings groups in their order, then All.

Returns:
- The names (temp allocated; the groups' strings are the engine's tags)
*/
Particles_Categories :: proc() -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for field in e.ParticleSettings_Fields() do if field.group != "" do append(&names, field.group)
	append(&names, PARTICLES_ALL)
	return names[:]
}

/*
The group each setting is in (the last `group` tag at or before it), by the setting's index in
`e.ParticleSettings_Fields`.

Returns:
- The groups (temp allocated)
*/
Particles_FieldGroups :: proc() -> []string {
	fields := e.ParticleSettings_Fields()
	groups := make([]string, len(fields), context.temp_allocator)
	group := ""
	for field, i in fields {
		if field.group != "" do group = field.group
		groups[i] = group
	}
	return groups
}

// The name of the Particles tab's category (All when out of range)
Particles_CategoryName :: proc(s: ^State) -> string {
	categories := Particles_Categories()
	return categories[clamp(s.particles.category, 0, len(categories) - 1)]
}

/*
The ParticleEmitter the Particles tab shows: the one it follows, when it's still an emitter of the
open scene.

Returns:
- The node and its index, or nil and -1
*/
Particles_Emitter :: proc(s: ^State) -> (^NodeDef, int) {
	ed := &s.particles
	if !ed.shown || ed.scene != s.currentScene || s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return nil, -1
	scene := &s.project.scenes[s.currentScene]
	if ed.node < 0 || ed.node >= len(scene.nodes) || scene.nodes[ed.node].kind != .ParticleEmitter do return nil, -1
	return &scene.nodes[ed.node], ed.node
}

/*
The emitter the particle messages edit: the selected node when it's an emitter (the inspector's),
else the Particles tab's.

Returns:
- The node and its index, or nil and -1
*/
Particles_Target :: proc(s: ^State) -> (^NodeDef, int) {
	if s.currentScene >= 0 && s.currentScene < len(s.project.scenes) {
		scene := &s.project.scenes[s.currentScene]
		if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && scene.nodes[s.selectedNode].kind == .ParticleEmitter {
			return &scene.nodes[s.selectedNode], s.selectedNode
		}
	}
	return Particles_Emitter(s)
}

/*
Keeps the Particles tab on the selected ParticleEmitter (after every message); another node
selected keeps the one it shows.
*/
Particles_Follow :: proc(s: ^State) {
	ed := &s.particles
	if s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && scene.nodes[s.selectedNode].kind == .ParticleEmitter {
		ed.node, ed.scene, ed.shown = s.selectedNode, s.currentScene, true
	}
	ed.category = clamp(ed.category, 0, len(Particles_Categories()) - 1)
}

/*
The Particles tab's messages that aren't settings (categories, the tab opened, Restart, presets).

Returns:
- Whether `m` was one
*/
Particles_Update :: proc(s: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Particles_Category_Picked:
		s.particles.category = clamp(int(v), 0, len(Particles_Categories()) - 1)
		return true
	case Particles_Tab_Opened:
		Mode_ShowBottomTab(s, .Particles)
		if int(v) >= 0 do s.particles.category = clamp(int(v), 0, len(Particles_Categories()) - 1)
		return true
	case Particles_Restart:
		if _, index := Particles_Target(s); index >= 0 do Preview_RestartEmitter(s, index)
		return true
	case Particles_Preset_Applied:
		node, _ := Particles_Target(s)
		if node == nil do return true
		if preset, ok := Particles_Preset(string(v)); ok {
			// Where it runs is the emitter's own choice, not the look's
			preset.gpu, preset.gpuAmount = node.particles.gpu, node.particles.gpuAmount
			node.particles = preset
		}
		return true
	}
	return false
}

// A preset: a name and the settings it gives
ParticlePreset :: struct {
	name: string,
	// What it looks like, for its tooltip
	about: string,
	make: proc() -> e.ParticleSettings,
}

/*
The Particles tab's presets, starting points to tune: each is a whole look (every setting but
`gpu` and `gpuAmount`). Few on purpose: a fire, smoke, sparks (a one-shot burst), dust and rain.
*/
PARTICLE_PRESETS := [?]ParticlePreset{
	{"Fire", "A flame rising from the emitter: yellow to red, fading out", presetFire},
	{"Smoke", "Gray puffs that grow, drift and fade as they rise", presetSmoke},
	{"Sparks", "A one-shot burst of spinning sparks falling under gravity (a hit, a welding torch)", presetSparks},
	{"Dust", "Slow motes floating in the air around the emitter", presetDust},
	{"Rain", "Streaks falling from a 640 px wide line: put the emitter above the view", presetRain},
}

/*
A preset's settings, by name.

Returns:
- The settings, and whether there's a preset of that name
*/
Particles_Preset :: proc(name: string) -> (e.ParticleSettings, bool) {
	for p in PARTICLE_PRESETS do if p.name == name do return p.make(), true
	return {}, false
}

// A ramp from `position:#color` text (the presets' ramps, which are valid)
@(private="file")
ramp :: proc(text: string) -> e.ColorRamp {
	r, ok := e.ParseColorRamp(text)
	fmt.assertf(ok, "a preset's ramp: %s", text)
	return r
}

@(private="file")
presetFire :: proc() -> e.ParticleSettings {
	s := e.DEFAULT_PARTICLE_SETTINGS
	s.amount, s.lifetime, s.burst, s.spread = 80, 1, 0, {10, 2}
	s.shape, s.size, s.sizeVariance, s.sizeSpread = .Circle, {6, 6}, 0.5, 3
	s.scaleStart, s.scaleEnd = {1, 1}, {0.2, 0.2}
	s.useColorRamp = true
	s.colorRamp = ramp("0:#fff3a0 0.3:#ff9a2c 0.7:#d2321eb4 1:#3c282800")
	s.colorVariance = 0.1
	s.angle, s.angleVariance, s.angleSpread = 270, 1, 15
	s.velocity, s.velocityVariance, s.velocitySpread = 90, 0.5, 40
	s.gravityDirection, s.gravityVelocity = {0, 1}, -60
	return s
}

@(private="file")
presetSmoke :: proc() -> e.ParticleSettings {
	s := e.DEFAULT_PARTICLE_SETTINGS
	s.amount, s.lifetime, s.burst, s.spread = 40, 3, 0, {8, 2}
	s.shape, s.size, s.sizeVariance, s.sizeSpread = .Circle, {16, 16}, 0.5, 6
	s.scaleStart, s.scaleEnd = {0.4, 0.4}, {1, 1}
	s.useColorRamp = true
	s.colorRamp = ramp("0:#5a5a5a00 0.15:#5a5a5ac8 0.6:#8c8c8c78 1:#b4b4b400")
	s.colorVariance = 0.05
	s.angle, s.angleVariance, s.angleSpread = 270, 1, 20
	s.velocity, s.velocityVariance, s.velocitySpread = 35, 0.5, 15
	s.gravityDirection, s.gravityVelocity = {0, 1}, -20
	s.wind = {12, 0}
	return s
}

@(private="file")
presetSparks :: proc() -> e.ParticleSettings {
	s := e.DEFAULT_PARTICLE_SETTINGS
	s.continuous, s.amount, s.lifetime, s.burst = false, 40, 0.7, 1
	s.shape, s.size, s.sizeVariance, s.sizeSpread = .Rectangle, {3, 3}, 0.5, 1
	s.scaleStart, s.scaleEnd = {1, 1}, {0.3, 0.3}
	s.rotationVariance, s.rotationSpread = 1, 180
	s.torqueVariance, s.torqueSpread = 1, 600
	s.useColorRamp = true
	s.colorRamp = ramp("0:#ffffff 0.15:#ffd25a 0.6:#ff6a1e 1:#8c1e0a00")
	s.angle, s.angleVariance, s.angleSpread = 270, 1, 180
	s.velocity, s.velocityVariance, s.velocitySpread = 220, 1, 120
	s.gravityDirection, s.gravityVelocity = {0, 1}, 400
	return s
}

@(private="file")
presetDust :: proc() -> e.ParticleSettings {
	s := e.DEFAULT_PARTICLE_SETTINGS
	s.amount, s.lifetime, s.burst, s.spread = 30, 4, 0, {120, 40}
	s.shape, s.size, s.sizeVariance, s.sizeSpread = .Circle, {2, 2}, 1, 1.5
	s.useColorRamp = true
	s.colorRamp = ramp("0:#d2be9600 0.2:#d2be96b4 0.8:#d2be96b4 1:#d2be9600")
	s.angle, s.angleVariance, s.angleSpread = 0, 1, 180
	s.velocity, s.velocityVariance, s.velocitySpread = 8, 1, 8
	s.gravityDirection, s.gravityVelocity = {0, 1}, 0
	s.wind = {6, 0}
	return s
}

@(private="file")
presetRain :: proc() -> e.ParticleSettings {
	s := e.DEFAULT_PARTICLE_SETTINGS
	s.amount, s.lifetime, s.burst, s.spread = 150, 1.2, 0, {320, 0}
	s.shape, s.size, s.rotation = .Line, {14, 1}, 90
	s.scaleStart, s.scaleEnd = {1, 1}, {1, 1}
	s.useColorRamp = false
	s.particleColor, s.colorEnd = {160, 200, 255, 180}, {160, 200, 255, 120}
	s.angle, s.angleVariance, s.angleSpread = 90, 0, 0
	s.velocity, s.velocityVariance, s.velocitySpread = 600, 0.3, 100
	s.gravityDirection, s.gravityVelocity = {0, 1}, 300
	return s
}
