package crossfire_editor

import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."
import stbi "vendor:stb/image"

// Skeletons in the editor (skeleton_edit.odin): bones added and edited, a mesh made and bound,
// an IK chain solved in the viewport's preview, saved and read back, a DragonBones file imported

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
		materialSelection = -1, atlasSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(private="file")
writePNG :: proc(path: string, size: [2]int, color: [4]u8) {
	color := color
	pixels := make([]u8, size.x * size.y * 4, context.temp_allocator)
	for i in 0 ..< size.x * size.y do copy(pixels[i * 4:][:4], color[:])
	_ = stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(size.x), i32(size.y), 4, raw_data(pixels), i32(size.x * 4))
}

@(test)
skeletons_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	dir := "build/test_skeleton_edit"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	root := state.project.rootPath
	node :: proc(s: ^State, i: int) -> ^NodeDef { return &s.project.scenes[s.currentScene].nodes[i] }
	_ = os.make_directory_all(joinPath(root, "assets", allocator = context.temp_allocator))
	writePNG(joinPath(root, "assets/arm.png", allocator = context.temp_allocator), {40, 8}, {255, 255, 255, 255})
	_, _ = Project_ImportAsset(&state.project, joinPath(root, "assets/arm.png", allocator = context.temp_allocator))

	// A skeleton, a bone, a bone at its tip
	sendTo(&state, Add_Node_Kind_Chosen(.Skeleton2D))
	skeleton := state.selectedNode
	sendTo(&state, Skeleton_Bone_Added{})
	upper := state.selectedNode
	testing.expect_value(t, node(&state, upper).kind, NodeKind.Bone2D)
	testing.expect_value(t, node(&state, upper).parent, skeleton)
	sendTo(&state, Skeleton_Setting_Changed{field = .Bone_Length, value = 20})
	testing.expect_value(t, node(&state, upper).boneLength, 20)
	sendTo(&state, Skeleton_Bone_Added{})
	lower := state.selectedNode
	testing.expect_value(t, node(&state, lower).position, [2]f32{20, 0})
	sendTo(&state, Skeleton_Setting_Changed{field = .Bone_Length, value = 20})
	sendTo(&state, Action.Undo)
	testing.expect_value(t, node(&state, lower).boneLength, 32)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, node(&state, lower).boneLength, 20)

	// A mesh over the arm's picture, bound to both bones
	state.selectedNode = skeleton
	sendTo(&state, Add_Node_Kind_Chosen(.SkinnedMesh))
	mesh := state.selectedNode
	sendTo(&state, Node_Text_Changed{.Texture, "assets/arm.png"})
	sendTo(&state, Skeleton_Setting_Changed{field = .Mesh_Columns, value = 4})
	sendTo(&state, Skeleton_Setting_Changed{field = .Mesh_Rows, value = 1})
	sendTo(&state, Mesh_Made{})
	m := &node(&state, mesh).mesh
	testing.expect_value(t, len(m.vertices), 10)
	testing.expect_value(t, len(m.triangles), 24)
	testing.expect(t, m.vertices[0] == {-20, -4} && m.uvs[9] == {40, 8}, "centered on the node, the picture's pixels")
	// Placed along the bones (from 0 to 40 in x)
	node(&state, mesh).position = {20, 0}
	sendTo(&state, Mesh_Bound{})
	m = &node(&state, mesh).mesh
	testing.expect_value(t, len(m.bones), 2)
	testing.expect_value(t, m.bones[0], "../Bone")
	testing.expect_value(t, len(m.weights), 10)
	for w in m.weights {
		total: f32
		for k in 0 ..< 4 do if w.bones[k] >= 0 do total += w.weights[k]
		testing.expect(t, abs(total - 1) < 0.01, "weights sum to 1")
	}
	// The far end follows the second bone most
	// (the grid's points are numbered as cells are visited: the right end's top is 8)
	far := m.weights[8]
	testing.expectf(t, far.bones[0] == 1, "the tip's vertex on the lower bone: %v", far)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(node(&state, mesh).mesh.bones), 0)
	sendTo(&state, Action.Redo)

	// An IK chain reaching a target, solved in the preview
	state.selectedNode = skeleton
	sendTo(&state, Add_Node_Kind_Chosen(.Node2D))
	target := state.selectedNode
	node(&state, target).position = {20, 20}
	state.selectedNode = skeleton
	sendTo(&state, Add_Node_Kind_Chosen(.IKChain))
	ik := state.selectedNode
	sendTo(&state, Skeleton_Setting_Changed{field = .IK_Tip, text = "../Bone/Bone2"})
	sendTo(&state, Skeleton_Setting_Changed{field = .IK_Target, text = "../Node2D"})
	testing.expect(t, node(&state, ik).ikTip == "../Bone/Bone2" && node(&state, ik).ikTarget == "../Node2D", "tip and target")
	state.viewport = {center = {0, 0}, zoom = 1, size = {64, 64}}
	_, rendered := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, rendered, "rendered")
	if rendered {
		built := Preview_Node(lower)
		testing.expect(t, built != nil && e.Node_Is(built, e.Bone2D), "the bone built")
		if built != nil {
			tip := e.Bone2D_Tip(cast(^e.Bone2D)built)
			testing.expectf(t, math.abs(tip.x - 20) < 1 && math.abs(tip.y - 20) < 1, "the tip on the target: %v", tip)
		}
		testing.expect_value(t, node(&state, lower).rotation, 0)
	}

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	text, _ := os.read_entire_file(joinPath(root, "scenes", "Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `<mesh vertices=`), "the mesh element")
	testing.expect(t, strings.contains(string(text), `ikTip="../Bone/Bone2"`), "the IK chain")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for &n, i in loaded.scenes[0].nodes do testing.expectf(t, NodeDef_Equal(n, node(&state, i)^), "node %d (%s) read back", i, n.name)
}

@(test)
dragonbones_files_import_as_components :: proc(t: ^testing.T) {
	dir := "build/test_dragonbones_import"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	source := joinPath(dir, "source", allocator = context.temp_allocator)
	_ = os.make_directory_all(source)
	ske := `{"frameRate": 10, "name": "Robot", "armature": [{"name": "Robot", "frameRate": 10,
		"bone": [{"name": "root"}, {"name": "arm", "parent": "root", "length": 30, "transform": {"x": 10}}],
		"slot": [{"name": "hand", "parent": "arm"}],
		"skin": [{"slot": [{"name": "hand", "display": [{"name": "hand", "transform": {"x": 30}}]}]}],
		"animation": [{"name": "wave", "duration": 10, "playTimes": 0, "bone": [{"name": "arm", "rotateFrame": [{"duration": 10, "tweenEasing": 0, "rotate": 0}, {"duration": 0, "rotate": 90}]}]}]}]}`
	tex := `{"name": "Robot", "imagePath": "Robot_tex.png", "width": 16, "height": 16, "SubTexture": [{"name": "hand", "x": 0, "y": 0, "width": 8, "height": 8}]}`
	_ = os.write_entire_file(joinPath(source, "Robot_ske.json", allocator = context.temp_allocator), transmute([]byte)string(ske))
	_ = os.write_entire_file(joinPath(source, "Robot_tex.json", allocator = context.temp_allocator), transmute([]byte)string(tex))
	writePNG(joinPath(source, "Robot_tex.png", allocator = context.temp_allocator), {16, 16}, {255, 0, 0, 255})

	// Through the browser's import: a component and its atlas
	sendTo(&state, Asset_Import_Result{path = joinPath(source, "Robot_ske.json", allocator = context.temp_allocator)})
	component := Project_FindComponent(&state.project, "components/robot.component.xml")
	testing.expect(t, component >= 0, "a component")
	testing.expect_value(t, len(state.project.atlases), 1)
	testing.expect(t, os.exists(joinPath(state.project.rootPath, "atlases/robot.png", allocator = context.temp_allocator)), "the atlas's picture copied")
	if component < 0 do return
	nodes := state.project.scenes[component].nodes[:]
	testing.expect_value(t, nodes[0].kind, NodeKind.Skeleton2D)
	testing.expect_value(t, nodes[0].name, "robot")
	kinds := make(map[NodeKind]int, context.temp_allocator)
	for n in nodes do kinds[n.kind] += 1
	testing.expect(t, kinds[.Bone2D] == 2 && kinds[.Sprite] == 1 && kinds[.Animator] == 1, "bones, the hand, the animations")
	for n in nodes do if n.kind == .Sprite {
		testing.expect(t, n.texture == "atlases/robot.atlas.xml" && n.region == "hand", "the hand from the atlas")
	}
	for n in nodes do if n.kind == .Animator do testing.expect(t, len(n.animator.clips) == 1 && n.animator.clips[0].name == "wave", "the wave")
	// Its file reads back the same
	read, problem := Project_LoadComponent(state.project.rootPath, "components/robot.component.xml")
	defer SceneDef_Destroy(&read)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(read.nodes), len(nodes))
	// Not a DragonBones file
	_ = os.write_entire_file(joinPath(source, "Bad_ske.json", allocator = context.temp_allocator), transmute([]byte)string("{}"))
	_ = os.write_entire_file(joinPath(source, "Bad_tex.json", allocator = context.temp_allocator), transmute([]byte)string("{}"))
	_, _, bad := DragonBones_Import(&state.project, joinPath(source, "Bad_ske.json", allocator = context.temp_allocator))
	testing.expect(t, bad != "", "refused")
}
