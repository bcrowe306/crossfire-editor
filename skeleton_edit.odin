package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Skeletons in the editor (the engine's skeleton.odin and dragonbones.odin): Skeleton2D, Bone2D,
SkinnedMesh and IKChain nodes.

- **Bones** are nodes: moved, turned and keyed like any (the Timeline keys their rotation,
  position, scale). A Bone2D's **Length** is where its tip is; **Add Bone** (a Skeleton2D's or a
  bone's) adds one at the tip (`Skeleton_Bone_Added`). The viewport draws every bone as a wedge
  from its origin to its tip (`Skeleton_DrawOverlay`), the selected one highlighted.
- **The scene's pose is the rest pose:** a SkinnedMesh binds to its bones as the scene has them,
  so moving a bone in the editor doesn't bend the mesh (the preview binds again every frame:
  `Skeleton_PreviewBind`); playing the Timeline, and IK, do.
- **SkinnedMesh:** its picture (an image, or an atlas and its region), **Make Mesh** (a grid of
  `meshColumns` x `meshRows` cells over the picture, cells with no visible pixel left out:
  `Mesh_FromPicture`), **Bind to Bones** (every Bone2D of its skeleton, each vertex weighted by
  its nearness to them, up to four: `Mesh_AutoWeights`). Selected, the viewport draws its
  triangles where they are now.
- **IKChain:** Tip (a bone), Target (any node), Bones (how many up from the tip), Bend, Enabled;
  the preview solves it every frame, so dragging the target bends the chain at once.
- **DragonBones:** importing a `_ske.json` (`DragonBones_Import`) converts its armature into a
  component (`components/<name>.component.xml`) and its texture atlas into an atlas asset
  (`atlases/<name>.atlas.xml` and its picture), with its animations as an Animator's clips.

Widget keys: `inspector-skel-<Field>-<node>`, `inspector-bone-add-<node>`,
`inspector-mesh-make-<node>`, `inspector-mesh-bind-<node>`.
*/

// A skeleton node's setting
SkeletonField :: enum {
	Bone_Length,
	IK_Tip,
	IK_Target,
	IK_Length,
	IK_Bend,
	IK_Enabled,
	Mesh_Columns,
	Mesh_Rows,
}

// A setting of the selected skeleton node changed
Skeleton_Setting_Changed :: struct {
	field: SkeletonField,
	value: f32,
	text: string,
	flag: bool,
}
// Add a bone under the selected Skeleton2D or Bone2D (at a bone's tip)
Skeleton_Bone_Added :: struct {}
// Make the selected SkinnedMesh's mesh from its picture (a grid)
Mesh_Made :: struct {}
// Bind the selected SkinnedMesh to its skeleton's bones, weighted by nearness
Mesh_Bound :: struct {}

// A mesh grid's cells (Make Mesh), kept per editor run
@(private="file")
meshGrid := [2]int{4, 4}

// The IK bend choices
@(private="file")
IK_BENDS := [2]string{"Positive (clockwise)", "Negative"}

/*
Handles the skeleton messages.

Returns:
- Whether the message was this file's
*/
SkeletonEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	scene := &s.project.scenes[s.currentScene]
	node := selectedNode(s)
	#partial switch v in m {
	case Skeleton_Setting_Changed:
		switch v.field {
		case .Mesh_Columns: meshGrid.x = clamp(int(v.value), 1, 32)
		case .Mesh_Rows:    meshGrid.y = clamp(int(v.value), 1, 32)
		case .Bone_Length:  if node != nil do node.boneLength = clamp(math.round(v.value * 10) / 10, 0, 10000)
		case .IK_Tip:
			if node == nil do break
			delete(node.ikTip)
			node.ikTip = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
		case .IK_Target:
			if node == nil do break
			delete(node.ikTarget)
			node.ikTarget = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
		case .IK_Length:  if node != nil do node.ik.length = clamp(int(v.value), 1, 32)
		case .IK_Bend:    if node != nil do node.ik.bendPositive = v.text == IK_BENDS[0]
		case .IK_Enabled: if node != nil do node.ik.enabled = v.flag
		}
	case Skeleton_Bone_Added:
		if node == nil || (node.kind != .Skeleton2D && node.kind != .Bone2D) do break
		parent := s.selectedNode
		at := [2]f32{}
		if node.kind == .Bone2D do at = {node.boneLength, 0}
		index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, "Bone"), .Bone2D, parent)
		scene.nodes[index].position = at
		s.selectedNode = index
	case Mesh_Made:
		if node == nil || node.kind != .SkinnedMesh do break
		mesh, problem := Mesh_FromPicture(&s.project, node.texture, node.region, meshGrid)
		if problem != "" {
			logLine(s, .Warning, strings.clone(problem))
			break
		}
		e.MeshData_Destroy(&node.mesh)
		node.mesh = mesh
		logLine(s, .Info, fmt.aprintf("%s: a mesh of %d points and %d triangles (Bind to Bones next)", node.name, len(mesh.vertices), len(mesh.triangles) / 3))
	case Mesh_Bound:
		if node == nil || node.kind != .SkinnedMesh do break
		bones := Mesh_AutoWeights(scene, s.selectedNode)
		if bones == 0 do logLine(s, .Warning, fmt.aprintf("%s: no Bone2D in its skeleton to bind to", node.name))
		else do logLine(s, .Info, fmt.aprintf("%s: bound to %d bone%s", node.name, bones, bones == 1 ? "" : "s"))
	case:
		return false
	}
	return true
}

/*
A grid mesh over a picture: `grid` cells, centered on the node's origin (as a Sprite draws), the
cells with no visible pixel left out (and their unused points).

Returns:
- The mesh (owned), or why there's none
*/
Mesh_FromPicture :: proc(project: ^Project, texture, region: string, grid: [2]int) -> (e.MeshData, string) {
	if texture == "" do return {}, "Choose its picture first"
	image := texture
	rect := [4]int{}
	if Asset_IsAtlas(texture) {
		i := Project_FindAtlas(project, texture)
		if i < 0 do return {}, fmt.tprintf("%s isn't in the project", texture)
		r, found := e.Atlas_Find(&project.atlases[i].data, region)
		if !found do return {}, "Choose its region first"
		image, rect = project.atlases[i].data.image, r.rect
	}
	pixels, w, h, ok := Image_LoadRGBA(joinPath(project.rootPath, image, allocator = context.temp_allocator))
	if !ok do return {}, fmt.tprintf("Couldn't read %s", image)
	if rect[2] == 0 do rect = {0, 0, w, h}
	size := [2]f32{f32(rect[2]), f32(rect[3])}
	cols, rows := max(grid.x, 1), max(grid.y, 1)
	// A cell is kept when a pixel in it isn't transparent
	visible :: proc(pixels: []u8, w: int, rect: [4]int, x0, y0, x1, y1: int) -> bool {
		for y in max(y0, 0) ..< min(y1, rect[3]) do for x in max(x0, 0) ..< min(x1, rect[2]) {
			if pixels[((rect[1] + y) * w + rect[0] + x) * 4 + 3] > 8 do return true
		}
		return false
	}
	index := make(map[[2]int]i32, context.temp_allocator)
	mesh := e.MeshData{vertices = make([dynamic][2]f32), uvs = make([dynamic][2]f32), triangles = make([dynamic]i32), bones = make([dynamic]string), weights = make([dynamic]VertexWeights)}
	point :: proc(mesh: ^e.MeshData, index: ^map[[2]int]i32, c: [2]int, cols, rows: int, size: [2]f32) -> i32 {
		if i, found := index[c]; found do return i
		uv := [2]f32{size.x * f32(c.x) / f32(cols), size.y * f32(c.y) / f32(rows)}
		append(&mesh.vertices, uv - size * 0.5)
		append(&mesh.uvs, uv)
		i := i32(len(mesh.vertices) - 1)
		index[c] = i
		return i
	}
	for row in 0 ..< rows do for col in 0 ..< cols {
		x0, y0 := rect[2] * col / cols, rect[3] * row / rows
		x1, y1 := rect[2] * (col + 1) / cols, rect[3] * (row + 1) / rows
		if !visible(pixels, w, rect, x0, y0, x1, y1) do continue
		a := point(&mesh, &index, {col, row}, cols, rows, size)
		b := point(&mesh, &index, {col + 1, row}, cols, rows, size)
		c := point(&mesh, &index, {col + 1, row + 1}, cols, rows, size)
		d := point(&mesh, &index, {col, row + 1}, cols, rows, size)
		append(&mesh.triangles, a, b, c, a, c, d)
	}
	if len(mesh.triangles) == 0 {
		e.MeshData_Destroy(&mesh)
		return {}, "The picture has no visible pixels"
	}
	return mesh, ""
}

// The engine's per-vertex weights
VertexWeights :: e.VertexWeights

/*
Binds a SkinnedMesh to its skeleton's bones (the Bone2D nodes under its nearest Skeleton2D
ancestor, else the scene's): each vertex gets the nearest bones (up to four), weighted by the
inverse square of its distance to each bone's segment (origin to tip).

Returns:
- How many bones it's bound to
*/
Mesh_AutoWeights :: proc(scene: ^SceneDef, meshIndex: int) -> int {
	node := &scene.nodes[meshIndex]
	// Its skeleton: the nearest Skeleton2D above it, else the whole scene
	root := -1
	for p := node.parent; p >= 0; p = scene.nodes[p].parent do if scene.nodes[p].kind == .Skeleton2D {
		root = p
		break
	}
	under :: proc(scene: ^SceneDef, i, root: int) -> bool {
		if root < 0 do return true
		for p := scene.nodes[i].parent; p >= 0; p = scene.nodes[p].parent do if p == root do return true
		return false
	}
	world := Scene_WorldTransforms(scene)
	Segment :: struct { index: int, a, b: [2]f32 }
	bones := make([dynamic]Segment, context.temp_allocator)
	for &n, i in scene.nodes do if n.kind == .Bone2D && under(scene, i, root) {
		append(&bones, Segment{i, e.Transform2D_Apply(world[i], {0, 0}), e.Transform2D_Apply(world[i], {n.boneLength, 0})})
	}
	for b in node.mesh.bones do delete(b)
	clear(&node.mesh.bones)
	clear(&node.mesh.weights)
	if len(bones) == 0 do return 0
	for b in bones do append(&node.mesh.bones, Scene_NodePath(scene, meshIndex, b.index))
	distance :: proc(p, a, b: [2]f32) -> f32 {
		ab := b - a
		t := clamp(((p - a).x * ab.x + (p - a).y * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1e-6), 0, 1)
		d := p - (a + ab * t)
		return math.sqrt(d.x * d.x + d.y * d.y)
	}
	Near :: struct { bone: int, weight: f32 }
	for v in node.mesh.vertices {
		p := e.Transform2D_Apply(world[meshIndex], v)
		near := make([dynamic]Near, context.temp_allocator)
		for b, i in bones {
			d := distance(p, b.a, b.b)
			append(&near, Near{i, 1 / (d * d + 1)})
		}
		slice.sort_by(near[:], proc(a, b: Near) -> bool { return a.weight > b.weight })
		w := VertexWeights{bones = {-1, -1, -1, -1}}
		total: f32
		for k in 0 ..< min(4, len(near)) do total += near[k].weight
		for k in 0 ..< min(4, len(near)) {
			share := near[k].weight / total
			// Far bones' crumbs aren't worth keeping
			if share < 0.02 do continue
			// Three decimals: files hold them exactly
			w.bones[k], w.weights[k] = i32(near[k].bone), math.round(share * 1000) / 1000
		}
		append(&node.mesh.weights, w)
	}
	return len(bones)
}

/*
The inspector's rows for skeleton nodes: a bone's length and Add Bone, a mesh's picture, Make
Mesh and Bind to Bones, an IK chain's tip, target, bones, bend and on/off.
*/
skeletonInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32, textureRow: skald.View) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	scene := &s.project.scenes[s.currentScene]
	width := inspectorRowWidth(controlWidth)
	Payload :: struct { field: SkeletonField }
	id :: proc(field: SkeletonField, key: int) -> string { return fmt.tprintf("inspector-skel-%v-%d", field, key) }
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	button :: proc(ctx: ^skald.Ctx(Msg), label, key, tip: string, msg: Msg) -> skald.View {
		th := ctx.theme
		b := skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
		return skald.tooltip(ctx, b, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}
	number :: proc(ctx: ^skald.Ctx(Msg), field: SkeletonField, key: int, value, lo, hi, step: f32, decimals: int, width: f32) -> skald.View {
		return valueSlider(ctx, id(field, key), value, Payload{field}, proc(p: Payload, v: f32) -> Msg { return Skeleton_Setting_Changed{field = p.field, value = v} },
			lo, hi, step = step, decimals = decimals, defaultValue = lo, width = width)
	}
	choice :: proc(ctx: ^skald.Ctx(Msg), field: SkeletonField, key: int, value: string, names: []string, width: f32) -> skald.View {
		return skald.select(ctx, value, names, Payload{field}, proc(p: Payload, v: string) -> Msg { return Skeleton_Setting_Changed{field = p.field, text = v} },
			id = skald.hash_id(id(field, key)), width = width)
	}
	switch node.kind {
	case .Skeleton2D:
		append(&rows, note(ctx, "Its Bone2D children are the skeleton. Pictures on bones (Sprites, SkinnedMeshes) move with them; key the bones in the Timeline.", width))
		append(&rows, inspectorRow(ctx, "", button(ctx, fmt.tprintf("%s  Add Bone", ICON_BONE), fmt.tprintf("inspector-bone-add-%d", key), "Add a bone under the skeleton", Msg(Skeleton_Bone_Added{}))))
	case .Bone2D:
		append(&rows, inspectorRow(ctx, "Length", number(ctx, .Bone_Length, key, node.boneLength, 0, 500, 1, 0, controlWidth)))
		append(&rows, inspectorRow(ctx, "", button(ctx, fmt.tprintf("%s  Add Bone", ICON_BONE), fmt.tprintf("inspector-bone-add-%d", key), "Add a bone at this one's tip, its child", Msg(Skeleton_Bone_Added{}))))
		append(&rows, note(ctx, "It points along its x axis. Turn it (rotation) to pose it; the scene's pose is the rest pose meshes bind to.", width))
	case .SkinnedMesh:
		append(&rows, textureRow)
		if Asset_IsAtlas(node.texture) {
			regions := make([dynamic]string, context.temp_allocator)
			append(&regions, REGION_NONE)
			append(&regions, ..Atlas_RegionNames(&s.project, node.texture))
			append(&rows, inspectorRow(ctx, "Region", skald.select(ctx, node.region == "" ? REGION_NONE : node.region, regions[:], proc(v: string) -> Msg { return Node_Text_Changed{.Region, v} },
				id = skald.hash_id(fmt.tprintf("inspector-region-%d", key)), width = controlWidth)))
		}
		m := &node.mesh
		append(&rows, note(ctx, len(m.vertices) == 0 ? "No mesh yet: Make Mesh covers the picture with a grid of triangles." :
			fmt.tprintf("%d points, %d triangles, bound to %d bone%s.", len(m.vertices), len(m.triangles) / 3, len(m.bones), len(m.bones) == 1 ? "" : "s"), width))
		append(&rows, inspectorRow(ctx, "Mesh columns", number(ctx, .Mesh_Columns, key, f32(meshGrid.x), 1, 32, 1, 0, controlWidth)))
		append(&rows, inspectorRow(ctx, "Mesh rows", number(ctx, .Mesh_Rows, key, f32(meshGrid.y), 1, 32, 1, 0, controlWidth)))
		append(&rows, inspectorRow(ctx, "", button(ctx, fmt.tprintf("%s  Make Mesh", ICON_DRAW_POLYGON), fmt.tprintf("inspector-mesh-make-%d", key), "Cover the picture with a grid of triangles (empty cells left out); its bones and weights go", Msg(Mesh_Made{}))))
		append(&rows, inspectorRow(ctx, "", button(ctx, fmt.tprintf("%s  Bind to Bones", ICON_BONE), fmt.tprintf("inspector-mesh-bind-%d", key), "Weight every point to the skeleton's nearest bones", Msg(Mesh_Bound{}))))
		if len(m.vertices) > 0 && len(m.bones) == 0 do append(&rows, skald.text("Not bound: it won't bend. Put it under a Skeleton2D with bones, then Bind to Bones.", th.color.warning, th.font.size_xs, max_width = width))
	case .IKChain:
		bones := make([dynamic]string, context.temp_allocator)
		targets := make([dynamic]string, context.temp_allocator)
		append(&bones, TEXTURE_NONE)
		append(&targets, TEXTURE_NONE)
		for &n, i in scene.nodes do if i != s.selectedNode {
			path := Scene_NodePath(scene, s.selectedNode, i, context.temp_allocator)
			if n.kind == .Bone2D do append(&bones, path)
			append(&targets, path)
		}
		append(&rows, inspectorRow(ctx, "Tip bone", choice(ctx, .IK_Tip, key, node.ikTip == "" ? TEXTURE_NONE : node.ikTip, bones[:], controlWidth)))
		append(&rows, inspectorRow(ctx, "IK target", choice(ctx, .IK_Target, key, node.ikTarget == "" ? TEXTURE_NONE : node.ikTarget, targets[:], controlWidth)))
		append(&rows, inspectorRow(ctx, "Bones", number(ctx, .IK_Length, key, f32(node.ik.length), 1, 8, 1, 0, controlWidth)))
		append(&rows, inspectorRow(ctx, "Bend", choice(ctx, .IK_Bend, key, IK_BENDS[node.ik.bendPositive ? 0 : 1], IK_BENDS[:], controlWidth)))
		append(&rows, inspectorRow(ctx, "Solve", skald.checkbox(ctx, node.ik.enabled, "", Payload{.IK_Enabled},
			proc(p: Payload, v: bool) -> Msg { return Skeleton_Setting_Changed{field = p.field, flag = v} }, id = skald.hash_id(id(.IK_Enabled, key)))))
		append(&rows, note(ctx, "Turns the tip bone and the ones above it so the tip reaches the target (2 bones: a knee or elbow bending the chosen way). Drag the target in the viewport to try it.", width))
		if node.ikTip != "" && Scene_ResolvePath(scene, s.selectedNode, node.ikTip) < 0 do append(&rows, skald.text("No bone at that path.", th.color.warning, th.font.size_xs, max_width = width))
		if node.ikTarget != "" && Scene_ResolvePath(scene, s.selectedNode, node.ikTarget) < 0 do append(&rows, skald.text("No node at the target's path.", th.color.warning, th.font.size_xs, max_width = width))
	case .Node2D, .Sprite, .AnimatedSprite, .Camera, .Label, .Menu, .StaticBody, .DynamicBody, .CharacterMover, .Area,
	     .CollisionShape, .RayCast, .Joint, .ParticleEmitter, .Component, .AudioPlayer, .AudioPlayer2D, .MusicPlayer,
	     .LDtkLevel, .TileMap, .Animator, .Light2D, .LightOccluder, .NavRegion, .NavAgent, .StateMachine, .ParallaxLayer, .CameraZone, .CameraView,
	     .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .VirtualJoystick, .TouchButton, .ScreenEffect, .Line2D, .Trail2D, .DialogueBox:
	}
	return rows[:]
}

/*
Imports a DragonBones skeleton (`<name>_ske.json`, with `<name>_tex.json` and its picture beside
it): the picture copied into `atlases/`, an atlas asset of its regions, and a component of the
armature (bones, sprites, meshes, an Animator of its animations).

Returns:
- The component's asset index, what wasn't converted (temp allocated), or why it failed
*/
DragonBones_Import :: proc(project: ^Project, source: string) -> (index: int, warnings: []string, problem: string) {
	ske, err := os.read_entire_file(source, context.temp_allocator)
	if err != nil do return -1, nil, fmt.tprintf("Couldn't read %s", source)
	base := strings.trim_suffix(source, "_ske.json")
	tex, texErr := os.read_entire_file(fmt.tprintf("%s_tex.json", base), context.temp_allocator)
	if texErr != nil do return -1, nil, fmt.tprintf("%s needs its texture atlas beside it: %s_tex.json", filepath.base(source), filepath.base(base))
	name := filepath.base(base)
	// The atlas's picture: its imagePath, else <name>_tex.png
	picture := fmt.tprintf("%s_tex.png", base)
	if info := texImagePath(string(tex)); info != "" do picture = joinPath(filepath.dir(source), info, allocator = context.temp_allocator)
	if !os.exists(picture) do return -1, nil, fmt.tprintf("The atlas's picture isn't there: %s", picture)
	// Where they go: the atlas beside its picture, the component
	stem := strings.to_lower(sanitize(name), context.temp_allocator)
	atlasPath := fmt.tprintf("%s/%s%s", ATLAS_FOLDER, stem, e.ATLAS_EXTENSION)
	for n := 2; Project_FindAtlas(project, atlasPath) >= 0 || os.exists(joinPath(project.rootPath, atlasPath, allocator = context.temp_allocator)); n += 1 {
		atlasPath = fmt.tprintf("%s/%s_%d%s", ATLAS_FOLDER, stem, n, e.ATLAS_EXTENSION)
	}
	imagePath := fmt.tprintf("%s.png", strings.trim_suffix(atlasPath, e.ATLAS_EXTENSION))
	result, ok := e.DragonBones_Convert(string(ske), string(tex), atlasPath, imagePath)
	if !ok {
		e.SceneData_Destroy(&result.component)
		e.AtlasData_Destroy(&result.atlas)
		return -1, nil, fmt.tprintf("%s: %s", filepath.base(source), len(result.warnings) > 0 ? result.warnings[0] : "not a DragonBones file")
	}
	defer e.SceneData_Destroy(&result.component)
	// The picture and the atlas file
	full := joinPath(project.rootPath, imagePath, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	if copyErr := os.copy_file(full, picture); copyErr != nil {
		e.AtlasData_Destroy(&result.atlas)
		return -1, nil, fmt.tprintf("Couldn't copy %s: %v", picture, copyErr)
	}
	atlas := AtlasDef{path = strings.clone(atlasPath), data = result.atlas}
	if writeErr := os.write_entire_file(joinPath(project.rootPath, atlasPath, allocator = context.temp_allocator), e.FormatAtlas(atlas.data, context.temp_allocator)); writeErr != nil {
		AtlasDef_Destroy(&atlas)
		return -1, nil, fmt.tprintf("Couldn't write %s", atlasPath)
	}
	append(&project.assets, AssetDef{path = strings.clone(atlasPath), kind = .Atlas})
	append(&project.atlases, atlas)
	// The component
	componentPath := ComponentPathFor(project, name)
	component := SceneDef{name = strings.clone(ComponentName(componentPath)), component = strings.clone(componentPath)}
	for node in result.component.nodes do append(&component.nodes, NodeDef_FromData(node))
	if len(component.nodes) > 0 {
		delete(component.nodes[0].name)
		component.nodes[0].name = strings.clone(component.name)
	}
	if message := Project_WriteComponent(project, &component); message != "" {
		SceneDef_Destroy(&component)
		return -1, nil, message
	}
	append(&project.scenes, component)
	append(&project.assets, AssetDef{path = strings.clone(componentPath), kind = .Component})
	return len(project.assets) - 1, result.warnings, ""
}

// A DragonBones atlas's imagePath ("" when it has none)
@(private="file")
texImagePath :: proc(tex: string) -> string {
	key := "\"imagePath\""
	i := strings.index(tex, key)
	if i < 0 do return ""
	rest := tex[i + len(key):]
	open := strings.index_byte(rest, '"')
	if open < 0 do return ""
	rest = rest[open + 1:]
	close := strings.index_byte(rest, '"')
	if close < 0 do return ""
	return rest[:close]
}

// Whether a file is a DragonBones skeleton (its export's `_ske.json`)
DragonBones_IsSkeleton :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), "_ske.json")
}
