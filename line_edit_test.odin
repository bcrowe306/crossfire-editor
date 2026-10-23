package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// Lines and trails (line_edit.odin) in the editor, and GPU particles needing the GPU renderer:
// edited, undone, saved and read back

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
lines_and_trails_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_line_edit"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	node :: proc(s: ^State, i: int) -> ^NodeDef { return &s.project.scenes[s.currentScene].nodes[i] }

	// A line: points typed, width, colors, joints, closed
	sendTo(&state, Add_Node_Kind_Chosen(.Line2D))
	line := state.selectedNode
	testing.expect_value(t, node(&state, line).line, e.DEFAULT_LINE_SETTINGS)
	sendTo(&state, Node_Points_Changed{0, "0,0 100,0 100,50"})
	testing.expect_value(t, len(node(&state, line).points), 3)
	sendTo(&state, Line_Setting_Changed{field = .Width, value = 8.04})
	sendTo(&state, Line_Setting_Changed{field = .Color, text = "#ff0000"})
	sendTo(&state, Line_Setting_Changed{field = .End_Opacity, value = 0.5})
	sendTo(&state, Line_Setting_Changed{field = .Joint, text = "Round"})
	sendTo(&state, Line_Setting_Changed{field = .Closed, flag = true})
	l := node(&state, line).line
	testing.expect_value(t, l.width, 8)
	testing.expect(t, l.color == {255, 0, 0, 255}, "red")
	testing.expect_value(t, l.endColor.a, u8(128))
	testing.expect_value(t, l.joint, e.LineJoint.Round)
	testing.expect(t, l.closed, "closed")
	sendTo(&state, Action.Undo)
	testing.expect(t, !node(&state, line).line.closed, "undone")
	sendTo(&state, Action.Redo)

	// A trail under a node
	sendTo(&state, Action.Deselect)
	sendTo(&state, Add_Node_Kind_Chosen(.Trail2D))
	trail := state.selectedNode
	sendTo(&state, Line_Setting_Changed{field = .Lifetime, value = 1.234})
	sendTo(&state, Line_Setting_Changed{field = .End_Width, value = 2})
	sendTo(&state, Line_Setting_Changed{field = .Emitting, flag = false})
	testing.expect_value(t, node(&state, trail).line.lifetime, 1.23)
	testing.expect(t, !node(&state, trail).line.emitting, "not emitting")

	// GPU particles count as needing the GPU renderer
	testing.expect(t, !Project_UsesShaders(&state.project), "nothing yet")
	sendTo(&state, Action.Deselect)
	sendTo(&state, Add_Node_Kind_Chosen(.ParticleEmitter))
	sendTo(&state, Particle_Field_Changed{"gpu", "true"})
	testing.expect(t, node(&state, state.selectedNode).particles.gpu, "on the GPU")
	testing.expect(t, Project_UsesShaders(&state.project), "the project needs the GPU renderer")

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	scene, _ := os.read_entire_file(joinPath(state.project.rootPath, "scenes", "Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(scene), `points="0,0 100,0 100,50"`), "the line's points")
	testing.expect(t, strings.contains(string(scene), `kind="Trail2D"`) && strings.contains(string(scene), `emitting="false"`), "the trail")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for &s in loaded.scenes do for &n in s.nodes {
		#partial switch n.kind {
		case .Line2D: testing.expect(t, NodeDef_Equal(n, node(&state, line)^), "the line read back")
		case .Trail2D: testing.expect(t, NodeDef_Equal(n, node(&state, trail)^), "the trail read back")
		}
	}
}

@(test)
line_edits_and_gpu_emitters_draw_the_viewport_again :: proc(t: ^testing.T) {
	// The viewport renders only when its frame key changes: a line's points and look, and a GPU
	// emitter switching renderers, are copied without a rebuild, so they must be in the key
	dir := "build/test_line_frame_key"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	key :: proc(s: ^State) -> u64 { return Preview_FrameKey(s, {640, 360}, 1) }
	sendTo(&state, Add_Node_Kind_Chosen(.Line2D))
	line := &state.project.scenes[state.currentScene].nodes[state.selectedNode]
	before := key(&state)
	append(&line.points, [2]f32{400, 300}, [2]f32{900, 300})
	testing.expect(t, key(&state) != before, "new points draw again")
	before = key(&state)
	line.line.width += 10
	testing.expect(t, key(&state) != before, "a new width draws again")

	sendTo(&state, Add_Node_Kind_Chosen(.ParticleEmitter))
	emitter := &state.project.scenes[state.currentScene].nodes[state.selectedNode]
	before = key(&state)
	emitter.particles.gpu = true
	testing.expect(t, key(&state) != before, "a GPU emitter switches the viewport's renderer at once")
}
