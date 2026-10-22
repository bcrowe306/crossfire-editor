package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Physics materials in the editor (the engine's physics_material.odin): `.material.xml` assets of
kind PhysicsMaterial, a body's friction, bounce and density shared by every body that names it.

- **Data:** `Project.materials` (`MaterialDef`: the file and its `e.PhysicsMaterial`), loaded with
  the project and imports, written by `Project_Save` when changed (`Project_SaveMaterials`). A
  body names one in `NodeDef.material` (its `material` attribute).
- **Editing:** selecting a material in the browser shows it in the inspector
  (`materialInspector`, `State.materialSelection`): Friction, Bounce, Density sliders and the
  bodies using it. Edits are `.Project` undo steps (the snapshot holds every material), merged
  while a slider drags.
- **New Material** (the browser's menu, a body's inspector: `Material_Created`):
  `materials/material.material.xml` (numbered when taken) with a body's defaults; from a body
  the body gets it.
- **A body's inspector:** a Material choice; with one, its Friction / Bounce / Density rows give
  way to the material's values (they're the material's to change).
*/

// Where new materials go, and their extension
MATERIAL_FOLDER :: "materials"
MATERIAL_EXTENSION :: ".material.xml"

// The material choice for none (the body's own values)
MATERIAL_NONE :: "(the body's own)"

// A material asset: its file (owned) and values
MaterialDef :: struct {
	path: string,
	material: e.PhysicsMaterial,
}

// A material's value
MaterialField :: enum {
	Friction,
	Restitution,
	Density,
}

// A value of the selected material changed
Material_Field_Changed :: struct {
	field: MaterialField,
	value: f32,
}
// The browser's New Material; from a body's inspector (`forSelected`) the body gets it
Material_Created :: struct {
	forSelected: bool,
}

MaterialDef_Clone :: proc(m: MaterialDef) -> MaterialDef {
	return {strings.clone(m.path), m.material}
}

MaterialDef_Destroy :: proc(m: ^MaterialDef) {
	delete(m.path)
	m^ = {}
}

MaterialDef_Equal :: proc(a, b: MaterialDef) -> bool {
	return a.path == b.path && a.material == b.material
}

// Reads a `.material.xml` file (owned), or a body's defaults and why
Project_LoadMaterial :: proc(rootPath, path: string) -> (MaterialDef, string) {
	def := MaterialDef{path = strings.clone(path), material = e.DEFAULT_PHYSICS_MATERIAL}
	text, err := os.read_entire_file(joinPath(rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return def, fmt.tprintf("Couldn't read %s", path)
	parsed, parseErr := e.ParsePhysicsMaterial(string(text))
	if parseErr != .None do return def, fmt.tprintf("%s isn't a physics material file (%v)", path, parseErr)
	def.material = parsed
	return def, ""
}

// The project's material for a file (-1 if none)
Project_FindMaterial :: proc(project: ^Project, path: string) -> int {
	for m, i in project.materials do if m.path == path do return i
	return -1
}

// Writes every material's file (Project_Save); only changed files are touched
Project_SaveMaterials :: proc(project: ^Project) -> string {
	for &m in project.materials {
		text := e.FormatPhysicsMaterial(m.material, context.temp_allocator)
		full := joinPath(project.rootPath, m.path, allocator = context.temp_allocator)
		existing, readErr := os.read_entire_file(full, context.temp_allocator)
		if readErr == nil && string(existing) == text do continue
		_ = os.make_directory_all(filepath.dir(full))
		if err := os.write_entire_file(full, text); err != nil do return fmt.tprintf("Couldn't write %s: %v", m.path, err)
	}
	return ""
}

/*
Makes a new material, `materials/<name>.material.xml` (numbered when taken), with a body's default
values, and writes its file.

Returns:
- Its index in `project.materials`, or -1 and why
*/
Project_CreateMaterial :: proc(project: ^Project, name: string) -> (int, string) {
	base := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	if base == "" do base = "material"
	taken :: proc(project: ^Project, path: string) -> bool {
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", MATERIAL_FOLDER, base, MATERIAL_EXTENSION)
	for n := 2; taken(project, path); n += 1 do path = fmt.tprintf("%s/%s_%d%s", MATERIAL_FOLDER, base, n, MATERIAL_EXTENSION)
	def := MaterialDef{path = strings.clone(path), material = e.DEFAULT_PHYSICS_MATERIAL}
	full := joinPath(project.rootPath, path, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	if err := os.write_entire_file(full, e.FormatPhysicsMaterial(def.material, context.temp_allocator)); err != nil {
		MaterialDef_Destroy(&def)
		return -1, fmt.tprintf("Couldn't write %s: %v", path, err)
	}
	append(&project.assets, AssetDef{path = strings.clone(path), kind = .PhysicsMaterial})
	append(&project.materials, def)
	return len(project.materials) - 1, ""
}

// How many of the project's bodies (scenes and components) use a material
Material_Users :: proc(project: ^Project, path: string) -> int {
	count := 0
	for scene in project.scenes do for node in scene.nodes do if node.material == path do count += 1
	return count
}

/*
Handles the material messages.

Returns:
- Whether the message was this file's
*/
MaterialEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	selected: ^MaterialDef
	if s.materialSelection >= 0 && s.materialSelection < len(s.project.materials) do selected = &s.project.materials[s.materialSelection]
	#partial switch v in m {
	case Material_Field_Changed:
		if selected == nil do break
		// Three decimals: the file gets short numbers (a slider's drag lands between steps)
		value := math.round(v.value * 1000) / 1000
		switch v.field {
		case .Friction:    selected.material.friction = clamp(value, 0, 2)
		case .Restitution: selected.material.restitution = clamp(value, 0, 1)
		case .Density:     selected.material.density = clamp(value, 0, 100)
		}
	case Material_Created:
		index, problem := Project_CreateMaterial(&s.project, "material")
		if problem != "" {
			logLine(s, .Error, strings.clone(problem))
			break
		}
		s.session.assetsChanged = true
		path := s.project.materials[index].path
		logLine(s, .Info, fmt.aprintf("Made %s", path))
		scene := &s.project.scenes[s.currentScene]
		if v.forSelected && s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && NodeKind_HasMaterial(scene.nodes[s.selectedNode].kind) {
			node := &scene.nodes[s.selectedNode]
			delete(node.material)
			node.material = strings.clone(path)
			break
		}
		// Shown in the browser and the inspector
		for asset, i in s.project.assets do if asset.path == path do s.browserSelection = {kind = .Asset, index = i}
		s.materialSelection = index
		s.selectedNode = -1
	case:
		return false
	}
	return true
}

// Whether a node kind takes a physics material (bodies with a surface: not Areas)
NodeKind_HasMaterial :: proc(kind: NodeKind) -> bool {
	#partial switch kind {
	case .StaticBody, .DynamicBody, .CharacterMover: return true
	}
	return false
}

/*
The inspector for a material chosen in the browser: its values and how many bodies use it. Keys
`material-friction`, `material-restitution`, `material-density`.
*/
materialInspector :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	m := &s.project.materials[s.materialSelection]
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := min(max(sidebarWidth - th.spacing.md * 2 - INSPECTOR_LABEL_WIDTH - th.spacing.sm - INSPECTOR_SCROLLBAR_WIDTH, 80), INSPECTOR_MAX_TEXT_WIDTH)
	d := e.DEFAULT_PHYSICS_MATERIAL
	Payload :: struct { field: MaterialField }
	slide :: proc(p: Payload, v: f32) -> Msg { return Material_Field_Changed{p.field, v} }
	users := Material_Users(&s.project, m.path)
	return skald.col(
		skald.text(fmt.tprintf("%s  %s", ICON_CUBE, filepath.stem(filepath.stem(m.path))), th.color.fg, th.font.size_md),
		skald.text(fmt.tprintf("Physics material  ·  %s", m.path), th.color.fg_muted, th.font.size_xs, max_width = 260),
		skald.text(users == 0 ? "No body uses it yet: choose it in a body's Material." : fmt.tprintf("Used by %d bod%s.", users, users == 1 ? "y" : "ies"),
			th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH),
		skald.divider(ctx),
		inspectorRow(ctx, "Friction", valueSlider(ctx, "material-friction", m.material.friction, Payload{.Friction}, slide, 0, 1, step = 0.01, decimals = 2, defaultValue = d.friction, width = controlWidth)),
		inspectorRow(ctx, "Bounce", valueSlider(ctx, "material-restitution", m.material.restitution, Payload{.Restitution}, slide, 0, 1, step = 0.01, decimals = 2, defaultValue = d.restitution, width = controlWidth)),
		inspectorRow(ctx, "Density", valueSlider(ctx, "material-density", m.material.density, Payload{.Density}, slide, 0, 10, step = 0.05, decimals = 2, defaultValue = d.density, width = controlWidth)),
		skald.text("Friction: 0 ice, 1 rubber. Bounce: 0 none, 1 back as high. Density: kg per 100 x 100 px, for falling bodies' mass.",
			th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH),
		spacing = th.spacing.xs,
		padding = th.spacing.md,
	)
}

/*
The Material row of a body's inspector: the choice (and New), then, with a material, its values
in place of the body's own (read only: they're the material's).

Returns:
- The rows, and whether the body has a material (then the caller leaves out its own surface rows)
*/
materialBodyRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> ([]skald.View, bool) {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, MATERIAL_NONE)
	for m in s.project.materials do append(&choices, m.path)
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	append(&rows, inspectorRow(ctx, "Material", skald.select(ctx, node.material == "" ? MATERIAL_NONE : node.material, choices[:], NodeTextField.Material, onText,
		id = skald.hash_id(fmt.tprintf("inspector-material-%d", key)), width = controlWidth)))
	append(&rows, inspectorRow(ctx, "", skald.button(ctx, "New Material", Msg(Material_Created{forSelected = true}),
		id = skald.hash_id(fmt.tprintf("inspector-new-material-%d", key)), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm)))
	if node.material == "" do return rows[:], false
	index := Project_FindMaterial(&s.project, node.material)
	if index < 0 {
		append(&rows, skald.text(fmt.tprintf("%s isn't one of the project's materials: the body's own values are used.", node.material),
			th.color.warning, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH))
		return rows[:], false
	}
	m := s.project.materials[index].material
	append(&rows, skald.text(fmt.tprintf("Friction %.2f, bounce %.2f, density %.2f from the material (select it in the browser to change them).", m.friction, m.restitution, m.density),
		th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH))
	return rows[:], true
}
