package crossfire_editor

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// Shaders in the editor (shader_edit.odin): a node's shader and parameters (undo, saving, the
// project's `shaders`), New Shader, compiling (when the shader tools are built), exports carrying
// the compiled file, ScreenEffect nodes

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
	// New Shader opens the file "in the external editor": nothing runs in tests
	state.settings.codeEditorPath = FixedText_Make("true")
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(test)
node_shaders_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_shader_edit"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	sendTo(&state, Add_Node_Kind_Chosen(.Sprite))
	index := state.selectedNode
	node :: proc(s: ^State, i: int) -> ^NodeDef { return &s.project.scenes[s.currentScene].nodes[i] }

	// A built-in effect, its parameters (only those set are kept), back to defaults
	sendTo(&state, Node_Shader_Changed("builtin:hit_flash"))
	testing.expect_value(t, node(&state, index).shader, "builtin:hit_flash")
	params, problem := ShaderEdit_Params(&state, "builtin:hit_flash")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(params), 2)
	sendTo(&state, Node_Shader_Param_Changed{"amount", "0.75"})
	testing.expect_value(t, len(node(&state, index).shaderParams), 1)
	// Undo takes it back (its own step: another parameter than the shader change)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(node(&state, index).shaderParams), 0)
	testing.expect_value(t, node(&state, index).shader, "builtin:hit_flash")
	sendTo(&state, Action.Redo)
	testing.expect_value(t, len(node(&state, index).shaderParams), 1)
	sendTo(&state, Node_Shader_Param_Changed{"flashColor", "#ff0000"})
	testing.expect_value(t, len(node(&state, index).shaderParams), 2)
	// Cleared: back to the shader's default (only the values set are kept)
	sendTo(&state, Node_Shader_Param_Changed{"flashColor", ""})
	testing.expect_value(t, len(node(&state, index).shaderParams), 1)
	testing.expect_value(t, node(&state, index).shaderParams[0].value, "0.75")

	// Saved: the node's shader and parameter, the project's `shaders`; read back
	testing.expect_value(t, Project_Save(&state.project), "")
	text, _ := os.read_entire_file(joinPath(state.project.rootPath, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `shaders="true"`), "the project says it uses shaders")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	found := false
	for &s in loaded.scenes do for &n in s.nodes do if n.kind == .Sprite {
		found = true
		testing.expect_value(t, n.shader, "builtin:hit_flash")
		testing.expect_value(t, len(n.shaderParams), 1)
		testing.expect(t, NodeDef_Equal(n, node(&state, index)^), "the same node")
	}
	testing.expect(t, found, "read back")

	// Another shader drops the parameters; none drops the shader
	sendTo(&state, Node_Shader_Changed("builtin:outline"))
	testing.expect_value(t, len(node(&state, index).shaderParams), 0)
	sendTo(&state, Node_Shader_Changed(SHADER_NONE))
	testing.expect_value(t, node(&state, index).shader, "")
	testing.expect(t, !Project_UsesShaders(&state.project), "no shaders now")

	// A ScreenEffect: an effect, covering the screen layers or not
	sendTo(&state, Action.Deselect)
	sendTo(&state, Add_Node_Kind_Chosen(.ScreenEffect))
	fx := state.selectedNode
	testing.expect(t, node(&state, fx).effectScreenLayers, "covers the screen layers by default")
	testing.expect(t, Project_UsesShaders(&state.project), "a ScreenEffect counts")
	sendTo(&state, Node_Shader_Changed("builtin:crt"))
	sendTo(&state, Node_Flag_Changed{.Effect_Screen_Layers, false})
	testing.expect(t, !node(&state, fx).effectScreenLayers, "off")
	testing.expect_value(t, Project_Save(&state.project), "")
	scene, _ := os.read_entire_file(joinPath(state.project.rootPath, "scenes", "Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(scene), `kind="ScreenEffect"`) && strings.contains(string(scene), `effectScreenLayers="false"`), "written")
}

@(test)
project_shaders_new_compile_and_export :: proc(t: ^testing.T) {
	dir := "build/test_shader_new"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	sendTo(&state, Add_Node_Kind_Chosen(.Sprite))
	index := state.selectedNode

	// New Shader: the template in assets/shaders, an asset, given to the node
	sendTo(&state, Shader_New_Requested{forSelected = true})
	path := "assets/shaders/shader.frag"
	testing.expect(t, os.exists(joinPath(state.project.rootPath, path, allocator = context.temp_allocator)), "written")
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[index].shader, path)
	shaders := 0
	for a in state.project.assets do if a.kind == .Shader do shaders += 1
	testing.expect_value(t, shaders, 1)
	testing.expect_value(t, AssetFolder(.Shader), BrowserFolder.Shaders)
	params, problem := ShaderEdit_Params(&state, path)
	testing.expect_value(t, problem, "")
	names := make([dynamic]string, context.temp_allocator)
	for p in params do if !p.builtin do append(&names, p.name)
	testing.expect_value(t, len(names), 3)
	// A second one gets another name
	sendTo(&state, Shader_New_Requested{})
	testing.expect(t, os.exists(joinPath(state.project.rootPath, "assets/shaders/shader_2.frag", allocator = context.temp_allocator)), "shader_2")

	// scripts/assets.odin: a path constant
	source := Scripts_AssetsSource(&state.project)
	testing.expect(t, strings.contains(source, `SHADER_SHADER :: "assets/shaders/shader.frag"`), "a constant")
	// Exports carry the compiled file
	files := Export_ProjectFiles(&state.project, context.temp_allocator)
	has := false
	for f in files do if f == "assets/shaders/shader.frag.shader" do has = true
	testing.expect(t, has, "the .frag.shader is exported")

	// Compiled (when the tools are built): beside it; a broken one logs where
	if _, found := Toolchain_ShaderTools(); !found do return
	testing.expect(t, os.exists(joinPath(state.project.rootPath, "assets/shaders/shader.frag.shader", allocator = context.temp_allocator)), "compiled when made")
	broken := joinPath(state.project.rootPath, "assets/shaders/shader_2.frag", allocator = context.temp_allocator)
	_ = os.write_entire_file(broken, transmute([]byte)string("#version 450\nvoid main() { nope; }\n"))
	before := len(LogList_Lines(&state.console))
	{
		context.logger = log.nil_logger()
		testing.expect(t, !Shaders_Compile(&state, force = true), "one doesn't compile")
	}
	logged := false
	for line in LogList_Lines(&state.console)[before:] do if strings.contains(line.text, "assets/shaders/shader_2.frag:2:") do logged = true
	testing.expect(t, logged, "the Console says where")
}

@(test)
shader_driver_labels_and_kinds :: proc(t: ^testing.T) {
	testing.expect(t, NodeKind_TakesShader(.Sprite) && NodeKind_TakesShader(.TileMap) && !NodeKind_TakesShader(.AudioPlayer), "which kinds")
	for b in e.BuiltinShader do testing.expect(t, BUILTIN_SHADER_LABELS[b] != "", "every effect has a label")
}
