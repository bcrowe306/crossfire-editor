package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "gui:skald"
import e "engine:."

/*
Shaders in the editor (the engine's shaders.odin, screen_effects.odin, shader_compile.odin): a
node's Shader section (any built-in effect or the project's own `.frag` shaders, and their
parameters), ScreenEffect nodes, Shader assets (`.frag`, the browser's Shaders folder, New Shader),
compiling them, and the viewport showing them.

- **Data:** `NodeDef.shader` (a path) and `shaderParams` (only the values set, as text), written
  as the node's `shader` attribute and `<shaderParam>` children; project.xml's `shaders="true"`
  when a scene uses any (`Project_UsesShaders`: Auto then picks the GPU renderer).
- **Edits** (`Node_Shader_Changed`, `Node_Shader_Param_Changed`) are node undo steps; a slider's
  drag merges.
- **Compiling** (`Shaders_Compile`): every Shader asset whose `.frag` is newer than its
  `.frag.shader`, with the shader tools (`Toolchain_ShaderTools`), on Save, before Play and
  exports, and while a code tab is open (Code_Tick, at most once a second). Errors go to the
  Console with the file and line. The viewport's preview is rebuilt when one compiled.
- **The viewport** draws scenes with shaders with an offscreen SDL GPU renderer (read back), so
  it shows them as the game will (viewport_preview.odin: `Preview_UsesShaders`).
*/

// A node's shader changed ("" none: its parameters go too)
Node_Shader_Changed :: distinct string
// One of the selected node's shader parameters, as text ("" back to the shader's default)
Node_Shader_Param_Changed :: struct {
	name, value: string,
}
// New Shader: a `.frag` from the template in assets/shaders/, opened; `forSelected` gives it to
// the selected node too
Shader_New_Requested :: struct {
	forSelected: bool,
}

// Where New Shader puts them
SHADERS_FOLDER :: "assets/shaders"

// What a new shader starts as: a tint that pulses, with two parameters
SHADER_TEMPLATE :: `#version 450
// A fragment shader for Crossfire (GLSL). It colors each pixel of what its node draws from an
// image or text. The editor compiles it when you save (errors in the Console).
// Its parameters are the Params block's members: their comments give the inspector a default,
// a range and a label. time, texelSize and textureSize are filled by the engine.
layout(location = 0) in vec4 v_color;   // the node's tint and opacity
layout(location = 1) in vec2 v_uv;      // where in the picture (0 to 1)
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(set = 3, binding = 0) uniform Params {
	vec4 tint;        // color default=#4fc3f7 label=Tint
	float strength;   // default=0.5 min=0 max=1 label=Strength
	float speed;      // default=2 min=0 max=10 label=Pulse speed
	float time;       // filled by the engine: seconds the game has run
};
void main() {
	vec4 c = texture(u_texture, v_uv) * v_color;
	float pulse = 0.5 + 0.5 * sin(time * speed);
	o_color = vec4(mix(c.rgb, tint.rgb, strength * pulse), c.a);
}
`

// What the inspector calls each built-in effect
BUILTIN_SHADER_LABELS := [e.BuiltinShader]string{
	.hit_flash    = "Hit flash",
	.outline      = "Outline",
	.dissolve     = "Dissolve",
	.palette_swap = "Palette swap",
	.crt          = "CRT (screen)",
	.bloom        = "Bloom (screen)",
	.color_grade  = "Color grading",
}

// The choice meaning no shader
SHADER_NONE :: "(none)"

/*
Where the shader compilers are: next to the editor (releases: `shader_tools/`, a macOS bundle's
Resources), else the engine's (`tools/build_shader_tools.sh` builds them).
*/
Toolchain_ShaderTools :: proc() -> (e.ShaderTools, bool) {
	if exeDir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for dir in ([]string{joinPath(exeDir, "shader_tools", allocator = context.temp_allocator), joinPath(exeDir, "..", "Resources", "shader_tools", allocator = context.temp_allocator)}) {
			if tools, ok := e.ShaderTools_Find(dir); ok do return tools, true
		}
	}
	if engine, ok := Toolchain_EngineDir(); ok {
		if tools, found := e.ShaderTools_Find(joinPath(engine, "shader_tools", allocator = context.temp_allocator)); found do return tools, true
	}
	return {}, false
}

// Whether any scene or component uses a shader (a node's, or a ScreenEffect)
Project_UsesShaders :: proc(project: ^Project) -> bool {
	for &scene in project.scenes do for &n in scene.nodes do if n.shader != "" || n.kind == .ScreenEffect do return true
	return false
}

/*
Compiles the project's shaders that changed (or all, `force`). Errors are logged in the Console.

Returns:
- Whether every one compiled
*/
Shaders_Compile :: proc(state: ^State, force := false) -> bool {
	any := false
	for asset in state.project.assets do if asset.kind == .Shader do any = true
	if !any do return true
	tools, found := Toolchain_ShaderTools()
	if !found {
		if !shaderToolsWarned {
			shaderToolsWarned = true
			logLine(state, .Warning, strings.clone("No shader compiler (Settings > Toolchain): the project's shaders aren't compiled"))
		}
		return false
	}
	ok := true
	compiledAny := false
	scratch := absolutePath(joinPath("build", "shaders", allocator = context.temp_allocator))
	for asset in state.project.assets do if asset.kind == .Shader {
		path := AssetFilePath(&state.project, asset)
		messages, good, compiled := e.Shader_CompileFile(tools, path, asset.path, scratch, force)
		if !good {
			ok = false
			for line in strings.split_lines(messages, context.temp_allocator) do if strings.trim_space(line) != "" do logLine(state, .Error, strings.clone(line))
			continue
		}
		if compiled {
			compiledAny = true
			logLine(state, .Info, fmt.aprintf("Compiled %s", asset.path))
		}
	}
	if compiledAny do Preview_ShadersChanged()
	return ok
}

@(private="file")
shaderToolsWarned: bool
@(private="file")
lastShaderWatch: time.Tick

// Compiles changed shaders at most once a second (Code_Tick: while code tabs are open)
ShaderEdit_Watch :: proc(state: ^State) {
	if time.tick_since(lastShaderWatch) < time.Second do return
	lastShaderWatch = time.tick_now()
	_ = Shaders_Compile(state)
}

/*
A shader's parameters (temp allocated): a built-in effect's from its bundle, a project shader's
read from its `.frag` (no compile needed).

Returns:
- The parameters, and what's wrong ("" when fine)
*/
ShaderEdit_Params :: proc(s: ^State, path: string) -> ([]e.ShaderParam, string) {
	if b, builtin := e.Shader_BuiltinOf(path); builtin {
		bundle, ok := e.Shader_BuiltinBundle(b)
		if !ok do return nil, "can't be read"
		return bundle.params, ""
	}
	full := joinPath(s.project.rootPath, path, allocator = context.temp_allocator)
	data, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil do return nil, fmt.tprintf("%s isn't there", path)
	params, _, problem := e.Shader_ParseParams(string(data))
	return params, problem
}

// The selected node's shader messages; returns whether `m` was one (and the command)
ShaderEdit_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Node_Shader_Changed:
		node := selectedNode(s)
		if node == nil do return {}, true
		path := string(v) == SHADER_NONE ? "" : string(v)
		if path == node.shader do return {}, true
		delete(node.shader)
		node.shader = strings.clone(path)
		for p in node.shaderParams { delete(p.name); delete(p.value) }
		clear(&node.shaderParams)
	case Node_Shader_Param_Changed:
		node := selectedNode(s)
		if node == nil || node.shader == "" do return {}, true
		for p, i in node.shaderParams do if p.name == v.name {
			delete(p.value)
			if v.value == "" {
				delete(p.name)
				ordered_remove(&node.shaderParams, i)
			} else {
				node.shaderParams[i].value = strings.clone(v.value)
			}
			return {}, true
		}
		if v.value != "" do append(&node.shaderParams, ScriptPropDef{strings.clone(v.name), strings.clone(v.value)})
	case Shader_New_Requested:
		path := shaderNewFile(s)
		if path == "" do return {}, true
		if v.forSelected {
			if node := selectedNode(s); node != nil {
				delete(node.shader)
				node.shader = strings.clone(path)
			}
		}
		_ = Shaders_Compile(s)
		return Script_Open(s, absolutePath(joinPath(s.project.rootPath, path, allocator = context.temp_allocator)), 1), true
	case:
		return {}, false
	}
	return {}, true
}

// Writes a new shader from the template (a free name) and adds its asset; returns its path
@(private="file")
shaderNewFile :: proc(s: ^State) -> string {
	folder := joinPath(s.project.rootPath, SHADERS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	name := "shader"
	for n := 2; os.exists(joinPath(folder, fmt.tprintf("%s.frag", name), allocator = context.temp_allocator)); n += 1 do name = fmt.tprintf("shader_%d", n)
	relative := fmt.tprintf("%s/%s.frag", SHADERS_FOLDER, name)
	if os.write_entire_file(joinPath(s.project.rootPath, relative, allocator = context.temp_allocator), transmute([]byte)string(SHADER_TEMPLATE)) != nil {
		logLine(s, .Error, fmt.aprintf("Couldn't write %s", relative))
		return ""
	}
	append(&s.project.assets, AssetDef{strings.clone(relative), .Shader})
	s.session.assetsChanged = true
	logLine(s, .Info, fmt.aprintf("New shader %s", relative))
	return relative
}

// The shader choices: none, the built-in effects (screen ones first for a ScreenEffect), the project's
@(private="file")
shaderChoices :: proc(s: ^State, screen: bool) -> (labels, paths: []string) {
	l := make([dynamic]string, context.temp_allocator)
	p := make([dynamic]string, context.temp_allocator)
	append(&l, SHADER_NONE)
	append(&p, "")
	for pass in 0 ..< 2 do for b in e.BuiltinShader {
		// The effects for this kind of node first
		if (pass == 0) != (e.BUILTIN_SHADER_INFO[b].screen == screen) do continue
		append(&l, fmt.tprintf("Built-in: %s", BUILTIN_SHADER_LABELS[b]))
		append(&p, fmt.tprintf("builtin:%v", b))
	}
	for asset in s.project.assets do if asset.kind == .Shader {
		append(&l, asset.path)
		append(&p, asset.path)
	}
	return l[:], p[:]
}

// The label a shader path shows as
@(private="file")
shaderLabel :: proc(path: string) -> string {
	if path == "" do return SHADER_NONE
	if b, ok := e.Shader_BuiltinOf(path); ok do return fmt.tprintf("Built-in: %s", BUILTIN_SHADER_LABELS[b])
	return strings.clone(path, context.temp_allocator)
}

// Whether a node kind can have a shader (it, or its children, draw pictures)
NodeKind_TakesShader :: proc(kind: NodeKind) -> bool {
	#partial switch kind {
	case .Node2D, .Sprite, .AnimatedSprite, .Label, .Menu, .TileMap, .LDtkLevel, .Component, .ParticleEmitter,
	     .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .ParallaxLayer,
	     .StaticBody, .DynamicBody, .CharacterMover, .Area, .TouchButton, .VirtualJoystick, .ScreenEffect:
		return true
	}
	return false
}

/*
A node's Shader rows: the shader, New Shader / Edit, its parameters (sliders, colors, text for
vectors), notes. A ScreenEffect's also say whether it covers the screen layers. Keys
`inspector-shader-<node>`, `inspector-shader-new-<node>`, `inspector-shader-edit-<node>`,
`inspector-shader-param-<name>-<node>`, `inspector-effect-screen-layers-<node>`.
*/
shaderInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	screen := node.kind == .ScreenEffect
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, warning := false) -> skald.View {
		return skald.text(text, warning ? ctx.theme.color.warning : ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	small :: proc(ctx: ^skald.Ctx(Msg), id, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(id), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	if !screen do append(&rows, skald.divider(ctx), skald.text("Shader", th.color.fg, th.font.size_sm))
	labels, paths := shaderChoices(s, screen)
	Choice :: struct { paths: []string, labels: []string }
	onChoice :: proc(c: Choice, v: string) -> Msg {
		for l, i in c.labels do if l == v do return Node_Shader_Changed(c.paths[i])
		return Node_Shader_Changed(SHADER_NONE)
	}
	append(&rows, inspectorRow(ctx, screen ? "Effect" : "Shader", skald.select(ctx, shaderLabel(node.shader), labels, Choice{paths, labels}, onChoice,
		id = skald.hash_id(fmt.tprintf("inspector-shader-%d", key)), width = controlWidth)))
	buttons := make([dynamic]skald.View, context.temp_allocator)
	append(&buttons, small(ctx, fmt.tprintf("inspector-shader-new-%d", key), fmt.tprintf("%s  New Shader", ICON_PLUS), Msg(Shader_New_Requested{forSelected = true})))
	if node.shader != "" && !strings.has_prefix(node.shader, e.SHADER_BUILTIN_PREFIX) {
		append(&buttons, small(ctx, fmt.tprintf("inspector-shader-edit-%d", key), fmt.tprintf("%s  Edit", ICON_CODE),
			Msg(Script_Open_File{file = absolutePath(joinPath(s.project.rootPath, node.shader, allocator = context.temp_allocator)), line = 1})))
	}
	append(&rows, inspectorRow(ctx, "", skald.row(..buttons[:], spacing = th.spacing.xs)))
	if b, builtin := e.Shader_BuiltinOf(node.shader); builtin do append(&rows, note(ctx, e.BUILTIN_SHADER_INFO[b].description, width))

	if screen {
		Payload :: struct {}
		append(&rows, inspectorRow(ctx, "Covers screen layers", skald.checkbox(ctx, node.effectScreenLayers, "", Payload{},
			proc(_: Payload, v: bool) -> Msg { return Node_Flag_Changed{.Effect_Screen_Layers, v} }, id = skald.hash_id(fmt.tprintf("inspector-effect-screen-layers-%d", key)))))
	}
	if node.shader == "" {
		append(&rows, note(ctx, screen ? "Choose an effect: it draws over the whole scene." : "A shader changes how this node and its children are drawn: hit flashes, outlines, dissolves, your own GLSL.", width))
		return rows[:]
	}

	params, problem := ShaderEdit_Params(s, node.shader)
	if problem != "" do append(&rows, note(ctx, fmt.tprintf("%s: %s", node.shader, problem), width, warning = true))
	value :: proc(node: ^NodeDef, p: e.ShaderParam) -> ([4]f32, bool) {
		for sp in node.shaderParams do if sp.name == p.name {
			if v, ok := e.ShaderParam_Parse(p.type, sp.value); ok do return v, true
		}
		return p.value, false
	}
	for p in params do if !p.builtin {
		label := p.label != "" ? p.label : p.name
		id := fmt.tprintf("inspector-shader-param-%s-%d", p.name, key)
		v, _ := value(node, p)
		Param :: struct { name: string, type: e.ShaderParamType, alpha: f32 }
		control: skald.View
		switch p.type {
		case .Float:
			control = valueSlider(ctx, id, v[0], Param{p.name, p.type, 0}, proc(pa: Param, x: f32) -> Msg {
				return Node_Shader_Param_Changed{pa.name, e.ShaderParam_Format(.Float, {x, 0, 0, 0})}
			}, p.min, p.max > p.min ? p.max : p.min + 1, step = (p.max - p.min) / 100, decimals = 2, defaultValue = p.value[0], width = controlWidth)
		case .Color:
			linear := skald.Color{v[0], v[1], v[2], 1}
			control = skald.color_picker(ctx, linear, Param{p.name, p.type, v[3]}, proc(pa: Param, c: skald.Color) -> Msg {
				return Node_Shader_Param_Changed{pa.name, e.ShaderParam_Format(.Color, {c.r, c.g, c.b, pa.alpha})}
			}, id = skald.hash_id(id))
		case .Vec2, .Vec3, .Vec4:
			control = skald.text_input(ctx, e.ShaderParam_Format(p.type, v), Param{p.name, p.type, 0}, proc(pa: Param, text: string) -> Msg {
				return Node_Shader_Param_Changed{pa.name, text}
			}, id = skald.hash_id(id), width = controlWidth, padding = InspectorFieldPadding(ctx))
		}
		append(&rows, shaderParamRow(ctx, label, control))
	}
	// Where they show: the GPU renderer
	if r := s.project.renderer; r != .Auto && r != .GPU {
		append(&rows, note(ctx, fmt.tprintf("The project draws with %v: shaders run only with the GPU renderer (Project Settings > General > Renderer: Auto or GPU).", r), width, warning = true))
	}
	if !strings.has_prefix(node.shader, e.SHADER_BUILTIN_PREFIX) {
		if _, found := Toolchain_ShaderTools(); !found do append(&rows, note(ctx, "No shader compiler (Settings > Toolchain): this shader can't be compiled.", width, warning = true))
		else if !os.exists(fmt.tprintf("%s.shader", joinPath(s.project.rootPath, node.shader, allocator = context.temp_allocator))) do append(&rows, note(ctx, "Not compiled yet: save (Ctrl+S) to compile it; errors show in the Console.", width, warning = true))
	}
	return rows[:]
}

// A parameter's row: its label (the shader's own words: no tooltip of the editor's)
@(private="file")
shaderParamRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	th := ctx.theme
	return skald.row(skald.col(skald.text(label, th.color.fg_muted, th.font.size_sm), width = INSPECTOR_LABEL_WIDTH), control,
		spacing = th.spacing.sm, cross_align = .Center)
}

// A Shader asset's browser preview: what it is, its parameters, Edit, who uses it
shaderPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth))
	params, problem := ShaderEdit_Params(s, asset.path)
	if problem != "" {
		append(&rows, skald.text(problem, th.color.warning, th.font.size_xs, max_width = previewTextWidth))
	} else {
		names := make([dynamic]string, context.temp_allocator)
		for p in params do if !p.builtin do append(&names, p.label != "" ? p.label : p.name)
		append(&rows, skald.text(len(names) > 0 ? fmt.tprintf("Parameters: %s", strings.join(names[:], ", ", context.temp_allocator)) : "No parameters",
			th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
	}
	compiled := os.exists(fmt.tprintf("%s.shader", AssetFilePath(&s.project, asset)))
	users := 0
	for &scene in s.project.scenes do for &n in scene.nodes do if n.shader == asset.path do users += 1
	append(&rows,
		skald.text(fmt.tprintf("%s. Used by %d node%s.", compiled ? "Compiled" : "Not compiled yet (save to compile)", users, users == 1 ? "" : "s"),
			th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
		skald.button(ctx, fmt.tprintf("%s  Edit", ICON_CODE), Msg(Script_Open_File{file = absolutePath(AssetFilePath(&s.project, asset)), line = 1}),
			id = skald.hash_id("shader-preview-edit"), bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
	)
	return skald.col(..rows[:], spacing = th.spacing.xs)
}
