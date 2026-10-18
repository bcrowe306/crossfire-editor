package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import e "engine:."
import sdl "vendor:sdl3"

/*
Node types. Shared with the engine's project format, so every kind the editor can place is one
the engine can load.
*/
NodeKind :: e.SceneNodeKind

/*
A button in a Menu node. `action` is `scene:<SceneName>` or `quit`.
*/
MenuItemDef :: struct {
	label: string,
	action: string,
}

/*
A node in a scene, as the editor stores it. This is plain data: saving writes it to the
project's XML files, and the engine's player builds engine nodes from those.

Nodes live in their scene's `nodes` array in depth-first order: every node's children come
right after it, so a scene can be walked top to bottom without recursion.
*/
NodeDef :: struct {
	name: string,
	kind: NodeKind,
	// Index of the parent node in the scene, -1 for top-level nodes
	parent: int,
	// Position relative to the parent (format version 2). Rotation and scale are relative too;
	// `Scene_WorldTransforms` combines them down the tree
	position: [2]f32,
	// Degrees, clockwise
	rotation: f32,
	scale: [2]f32,
	layer: int,
	// Invisible nodes, and their children, are not created when the game runs
	visible: bool,
	// Editor-only: whether its children are shown in the scene tree
	expanded: bool,

	// Sprite, AnimatedSprite, ParticleEmitter (Texture shape): image path relative to the project folder
	texture: string,
	// Label
	text: string,
	fontSize: f32,
	color: sdl.Color,
	centered: bool,
	// Camera
	zoom: f32,
	// AnimatedSprite: the texture is a columns x rows grid of frames (margin pixels around it,
	// spacing between cells); its animations are named ranges of them (at least one), and
	// autoplay names the one it starts with ("" = the first). See the Animation panel
	columns: int,
	rows: int,
	margin: f32,
	spacing: f32,
	animations: [dynamic]AnimationDef,
	autoplay: string,
	// Menu
	items: [dynamic]MenuItemDef,
	// Any kind: the script attached to it ("" for none) and its exported field values, as text
	// (scripts.odin). Values for fields the script doesn't have are kept, not shown
	script: string,
	props: [dynamic]ScriptPropDef,

	// Physics (the engine's SceneNodeData has the same fields; physics_nodes.odin there).
	// Bodies: layers it's on and collides with (bit sets), surface
	collisionLayer: u64,
	collisionMask: u64,
	friction: f32,
	restitution: f32,
	density: f32,
	// DynamicBody
	gravityScale: f32,
	linearDamping: f32,
	angularDamping: f32,
	fixedRotation: bool,
	bullet: bool,
	// CharacterMover
	floorMaxAngle: f32,
	// CollisionShape: Rectangle width/height (shapeSize), Circle radius, Capsule radius and
	// height (shapeSize.y), Polygon/Segment points
	shape: e.CollisionShapeKind,
	shapeSize: [2]f32,
	radius: f32,
	points: [dynamic][2]f32,
	disabled: bool,
	// RayCast (collisionMask is what it hits)
	target: [2]f32,
	enabled: bool,
	excludeParent: bool,
	// Joint: kind, the bodies by name (bodyA "" = the body above it, or the world), Distance's
	// second anchor, limits, motor, spring
	jointKind: e.JointKind,
	bodyA: string,
	bodyB: string,
	jointOffset: [2]f32,
	enableLimit: bool,
	lower: f32,
	upper: f32,
	enableMotor: bool,
	motorSpeed: f32,
	maxMotor: f32,
	enableSpring: bool,
	hertz: f32,
	dampingRatio: f32,
	collideConnected: bool,
	// ParticleEmitter: every setting (a plain value; `texture` is its Texture shape's image)
	particles: e.ParticleSettings,
}

// A script field's value: `<prop name="speed" value="250"/>` (both owned)
ScriptPropDef :: struct {
	name: string,
	value: string,
}

/*
A scene: a named tree of nodes.
*/
SceneDef :: struct {
	name: string,
	nodes: [dynamic]NodeDef,
}

AssetKind :: enum {
	Image,
	Audio,
	Font,
	// A data resource (`.data.json`, project_data.odin)
	Data,
}

/*
A file in the project's `assets/` folder.
*/
AssetDef :: struct {
	// Path relative to the project root, always with `/`
	path: string,
	kind: AssetKind,
}

/*
Everything the editor saves for a game project.
*/
Project :: struct {
	name: string,
	// Folder the project is saved in (project.xml, scenes/, assets/)
	rootPath: string,
	// Game resolution, as in the engine's `Game.size`
	gameSize: [2]f32,
	scaleMode: e.ScaleMode,
	background: sdl.Color,
	// Name of the scene the game starts in
	startScene: string,
	scenes: [dynamic]SceneDef,
	assets: [dynamic]AssetDef,
	// Physics: pixels per meter, gravity (px/s²), debug drawing in the game
	physics: e.PhysicsSettings,
	// Scene files the editor loaded or saved (relative paths), so Save can delete the files of
	// scenes that were renamed or removed, and nothing else (project_scenes.odin)
	sceneFiles: [dynamic]string,
	// Export targets and their settings, saved in export.ini (export.odin)
	exports: ExportSettings,
	// Global scripts, in start order, and data resources (project_data.odin)
	globals: [dynamic]GlobalDef,
	data: [dynamic]DataDef,
	// Input actions, in order (input_actions.odin)
	actions: [dynamic]ActionDef,
}

// Path of a scene's file inside the project folder
SceneFilePath :: proc(scene: ^SceneDef, allocator := context.allocator) -> string {
	return fmt.aprintf("scenes/%s.scene.xml", scene.name, allocator = allocator)
}

/*
A node with the default property values for its kind.

Inputs:
- name: Node name; copied
- kind: Node type
- parent: Parent node index, or -1

Returns:
- The node. Its strings are heap-allocated; free with `NodeDef_Destroy`
*/
NodeDef_Make :: proc(name: string, kind: NodeKind, parent: int) -> NodeDef {
	defaults := e.DEFAULT_SCENE_NODE
	node := NodeDef{
		name = strings.clone(name),
		kind = kind,
		parent = parent,
		scale = {1, 1},
		visible = true,
		expanded = true,
		texture = strings.clone(""),
		text = strings.clone(kind == .Label ? "Label" : ""),
		fontSize = defaults.fontSize,
		color = defaults.color,
		centered = defaults.centered,
		zoom = defaults.zoom,
		columns = defaults.columns,
		rows = defaults.rows,
		autoplay = strings.clone(""),
		script = strings.clone(""),
		collisionLayer = defaults.collisionLayer,
		collisionMask = defaults.collisionMask,
		friction = defaults.friction,
		restitution = defaults.restitution,
		density = defaults.density,
		gravityScale = defaults.gravityScale,
		floorMaxAngle = defaults.floorMaxAngle,
		shape = defaults.shape,
		shapeSize = defaults.shapeSize,
		radius = defaults.radius,
		target = defaults.target,
		enabled = defaults.enabled,
		excludeParent = defaults.excludeParent,
		bodyA = strings.clone(""),
		bodyB = strings.clone(""),
		jointOffset = defaults.jointOffset,
		dampingRatio = defaults.dampingRatio,
		particles = defaults.particles,
	}
	if kind == .AnimatedSprite do append(&node.animations, AnimationDef_Default())
	if kind == .Menu {
		append(&node.items, MenuItemDef{strings.clone("Button"), strings.clone("quit")})
	}
	return node
}

/*
An AnimatedSprite's animation: a named range of its sheet's cells (the engine's
`e.AnimationData`; `end` -1 is the last cell).
*/
AnimationDef :: struct {
	// Owned
	name: string,
	start: int,
	end: int,
	fps: f32,
	loop: bool,
	playMode: e.AnimationPlayMode,
}

// The animation a new AnimatedSprite gets: every cell, looping (name owned)
AnimationDef_Default :: proc(name := "default") -> AnimationDef {
	return {strings.clone(name), 0, -1, e.DEFAULT_SCENE_NODE.fps, true, .Forward}
}

// Frees a node's strings and lists
NodeDef_Destroy :: proc(node: ^NodeDef) {
	delete(node.name)
	delete(node.texture)
	delete(node.text)
	for item in node.items { delete(item.label); delete(item.action) }
	delete(node.items)
	delete(node.script)
	for prop in node.props { delete(prop.name); delete(prop.value) }
	delete(node.props)
	delete(node.points)
	delete(node.bodyA)
	delete(node.bodyB)
	for a in node.animations do delete(a.name)
	delete(node.animations)
	delete(node.autoplay)
}

/*
Number of a node's descendants: the nodes that follow it in depth-first order and are
deeper than it.

Inputs:
- scene: The scene
- index: The node

Returns:
- How many nodes after `index` belong to its subtree
*/
Scene_DescendantCount :: proc(scene: ^SceneDef, index: int) -> int {
	depth := Scene_NodeDepth(scene, index)
	count := 0
	for i := index + 1; i < len(scene.nodes) && Scene_NodeDepth(scene, i) > depth; i += 1 {
		count += 1
	}
	return count
}

/*
Whether a node has any children.

Inputs:
- scene: The scene
- index: The node

Returns:
- true if the next node in depth-first order is its child
*/
Scene_HasChildren :: proc(scene: ^SceneDef, index: int) -> bool {
	return index + 1 < len(scene.nodes) && scene.nodes[index + 1].parent == index
}

/*
Adds a new node as the last child of `parent` (or as the last top-level node), keeping the
depth-first order.

Inputs:
- scene: The scene
- name: Node name; copied
- kind: Node type
- parent: Parent node index, or -1 for a top-level node

Returns:
- The new node's index
*/
Scene_InsertNode :: proc(scene: ^SceneDef, name: string, kind: NodeKind, parent: int) -> int {
	// Insert after the parent's whole subtree, so the new node becomes its last child
	at := len(scene.nodes)
	if parent >= 0 {
		at = parent + 1 + Scene_DescendantCount(scene, parent)
	}

	// A new child starts at its parent's origin (local position 0, 0)
	node := NodeDef_Make(name, kind, parent)
	if parent >= 0 {
		node.layer = scene.nodes[parent].layer
		scene.nodes[parent].expanded = true
	}
	inject_at(&scene.nodes, at, node)

	// Nodes after the insertion point moved down by one
	for i in at + 1..<len(scene.nodes) {
		if scene.nodes[i].parent >= at do scene.nodes[i].parent += 1
	}
	return at
}

/*
Removes a node and all its descendants.

Inputs:
- scene: The scene
- index: The node to remove
*/
Scene_RemoveNode :: proc(scene: ^SceneDef, index: int) {
	count := 1 + Scene_DescendantCount(scene, index)
	for i in index..<index + count {
		NodeDef_Destroy(&scene.nodes[i])
	}
	remove_range(&scene.nodes, index, index + count)

	// Nodes after the removed range moved up
	for i in index..<len(scene.nodes) {
		if scene.nodes[i].parent >= index + count do scene.nodes[i].parent -= count
	}
}

/*
Each node's world transform: its local position, rotation and scale combined with its
ancestors', the same way the engine combines them.

Inputs:
- scene: The scene

Returns:
- One transform per node, in node order (temp allocated)
*/
Scene_WorldTransforms :: proc(scene: ^SceneDef) -> []e.Transform2D {
	world := make([]e.Transform2D, len(scene.nodes), context.temp_allocator)
	for node, i in scene.nodes {
		local := e.Transform2D_Make(node.position, node.rotation, node.scale)
		// Depth-first order: a parent always comes before its children
		world[i] = node.parent >= 0 ? e.Transform2D_Multiply(world[node.parent], local) : local
	}
	return world
}

/*
How deep a node is in its scene's tree. Top-level nodes are 0.

Inputs:
- scene: The scene
- index: The node

Returns:
- The number of ancestors
*/
Scene_NodeDepth :: proc(scene: ^SceneDef, index: int) -> int {
	depth := 0
	for p := scene.nodes[index].parent; p >= 0; p = scene.nodes[p].parent {
		depth += 1
	}
	return depth
}

/*
Frees a project and everything it owns: scenes, nodes, assets and their strings.

Inputs:
- project: The project to free
*/
Project_Destroy :: proc(project: ^Project) {
	for &scene in project.scenes {
		for &node in scene.nodes do NodeDef_Destroy(&node)
		delete(scene.nodes)
		delete(scene.name)
	}
	delete(project.scenes)
	for asset in project.assets do delete(asset.path)
	delete(project.assets)
	delete(project.name)
	delete(project.rootPath)
	delete(project.startScene)
	for f in project.sceneFiles do delete(f)
	delete(project.sceneFiles)
	for &g in project.globals do GlobalDef_Destroy(&g)
	delete(project.globals)
	for &a in project.actions do ActionDef_Destroy(&a)
	delete(project.actions)
	for &d in project.data do DataDef_Destroy(&d)
	delete(project.data)
	project^ = {}
}

/*
Loads a project saved in a folder, using the engine's project format parser.

Inputs:
- rootPath: Folder containing project.xml

Returns:
- The project, and an error message ("" on success; temp allocated). On error the returned
  project is empty
*/
Project_Load :: proc(rootPath: string) -> (project: Project, message: string, warnings: []string) {
	projectFile, _ := filepath.join({rootPath, "project.xml"}, context.temp_allocator)
	data, err := e.LoadProjectFile(projectFile)
	if err != .None {
		return {}, fmt.tprintf("Couldn't load %s: %v", projectFile, err), nil
	}
	defer e.ProjectData_Destroy(&data)

	project = {
		name = strings.clone(data.name),
		rootPath = strings.clone(rootPath),
		gameSize = data.size,
		scaleMode = data.scaleMode,
		background = data.background,
		startScene = strings.clone(data.startScene),
		physics = data.physics,
		exports = ExportSettings_Default(),
	}
	// Export settings: optional, and a bad line only loses that setting
	exportsFile, _ := filepath.join({rootPath, EXPORT_SETTINGS_FILE}, context.temp_allocator)
	if text, readErr := os.read_entire_file(exportsFile, context.temp_allocator); readErr == nil {
		problems := ExportSettings_Parse(&project.exports, string(text))
		list := make([]string, len(problems), context.temp_allocator)
		for problem, i in problems do list[i] = fmt.tprintf("%s: %s", EXPORT_SETTINGS_FILE, problem)
		warnings = list
	}
	for asset in data.assets {
		kind := AssetKind.Image
		switch asset.kind {
		case "Audio": kind = .Audio
		case "Font":  kind = .Font
		case "Data":  kind = .Data
		}
		append(&project.assets, AssetDef{strings.clone(asset.path), kind})
		// A data resource's values come from its file
		if kind == .Data {
			def, problem := Project_LoadData(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
				def = DataDef{path = strings.clone(asset.path), type = strings.clone("")}
			}
			append(&project.data, def)
		}
	}
	for a in data.actions {
		action := ActionDef{name = strings.clone(a.name), deadzone = a.deadzone}
		append(&action.bindings, ..a.bindings[:])
		append(&project.actions, action)
	}
	for g in data.globals {
		global := GlobalDef{script = strings.clone(g.script)}
		for p in g.props do append(&global.props, ScriptPropDef{strings.clone(p.name), strings.clone(p.value)})
		append(&project.globals, global)
	}

	for ref in data.scenes {
		sceneFile, _ := filepath.join({rootPath, ref.path}, context.temp_allocator)
		sceneData, sceneErr := e.LoadSceneFile(sceneFile)
		if sceneErr != .None {
			Project_Destroy(&project)
			return {}, fmt.tprintf("Couldn't load scene %s: %v", sceneFile, sceneErr), nil
		}
		scene := SceneDef{name = strings.clone(ref.name)}
		for node in sceneData.nodes {
			def := NodeDef{
				name = strings.clone(node.name),
				kind = node.kind,
				parent = node.parent,
				position = node.position,
				rotation = node.rotation,
				scale = node.scale,
				layer = node.layer,
				visible = node.visible,
				expanded = true,
				texture = strings.clone(node.texture),
				text = strings.clone(node.text),
				fontSize = node.fontSize,
				color = node.color,
				centered = node.centered,
				zoom = node.zoom,
				columns = node.columns,
				rows = node.rows,
				margin = node.margin,
				spacing = node.spacing,
				autoplay = strings.clone(node.autoplay),
				collisionLayer = node.collisionLayer,
				collisionMask = node.collisionMask,
				friction = node.friction,
				restitution = node.restitution,
				density = node.density,
				gravityScale = node.gravityScale,
				linearDamping = node.linearDamping,
				angularDamping = node.angularDamping,
				fixedRotation = node.fixedRotation,
				bullet = node.bullet,
				floorMaxAngle = node.floorMaxAngle,
				shape = node.shape,
				shapeSize = node.shapeSize,
				radius = node.radius,
				disabled = node.disabled,
				target = node.target,
				enabled = node.enabled,
				excludeParent = node.excludeParent,
				jointKind = node.jointKind,
				bodyA = strings.clone(node.bodyA),
				bodyB = strings.clone(node.bodyB),
				jointOffset = node.jointOffset,
				enableLimit = node.enableLimit,
				lower = node.lower,
				upper = node.upper,
				enableMotor = node.enableMotor,
				motorSpeed = node.motorSpeed,
				maxMotor = node.maxMotor,
				enableSpring = node.enableSpring,
				hertz = node.hertz,
				dampingRatio = node.dampingRatio,
				collideConnected = node.collideConnected,
				particles = node.particles,
			}
			append(&def.points, ..node.points[:])
			if node.kind == .AnimatedSprite {
				for a in node.animations do append(&def.animations, AnimationDef{strings.clone(a.name), a.start, a.end, a.fps, a.loop, a.playMode})
				// Files before format 7: one animation of every cell, at the node's speed
				if len(def.animations) == 0 do append(&def.animations, AnimationDef{strings.clone("default"), 0, -1, node.fps, node.loop, node.playMode})
			}
			for item in node.items {
				append(&def.items, MenuItemDef{strings.clone(item.label), strings.clone(item.action)})
			}
			def.script = strings.clone(node.script)
			for prop in node.props {
				append(&def.props, ScriptPropDef{strings.clone(prop.name), strings.clone(prop.value)})
			}
			append(&scene.nodes, def)
		}
		e.SceneData_Destroy(&sceneData)
		append(&project.scenes, scene)
		append(&project.sceneFiles, strings.clone(ref.path))
	}
	return project, "", warnings
}

/*
Builds the sample project: a menu, a play scene with sprites and animations, and an options
screen. Its images ship in `examples/demo_project/assets`.

Inputs:
- rootPath: Folder the project is saved in

Returns:
- The sample project. Its strings are heap-allocated and owned by the project
*/
Project_CreateDemo :: proc(rootPath: string) -> Project {
	project := Project{
		name = strings.clone("Asteroids Demo"),
		rootPath = strings.clone(rootPath),
		gameSize = {1280, 720},
		scaleMode = .Letterbox,
		background = {15, 18, 30, 255},
		startScene = strings.clone("MenuScene"),
		physics = e.DEFAULT_PHYSICS,
		exports = ExportSettings_Default(),
	}
	TITLE_COLOR :: sdl.Color{235, 240, 255, 255}
	TEXT_COLOR :: sdl.Color{150, 160, 185, 255}

	menu := SceneDef{name = strings.clone("MenuScene")}
	setText(&menu, addNode(&menu, "Title", .Label, -1, {640, 180}), "ASTEROIDS", 80, TITLE_COLOR)
	mainMenu := addNode(&menu, "MainMenu", .Menu, -1, {640, 320})
	addItem(&menu, mainMenu, "Play", "scene:PlayScene")
	addItem(&menu, mainMenu, "Options", "scene:OptionsScene")
	addItem(&menu, mainMenu, "Quit", "quit")
	append(&project.scenes, menu)

	play := SceneDef{name = strings.clone("PlayScene")}
	// Positions are relative to the parent
	world := addNode(&play, "World", .Node2D, -1, {0, 0})
	addNode(&play, "Camera", .Camera, world, {640, 360})
	ship := addNode(&play, "Spaceship", .Sprite, world, {640, 430})
	setTexture(&play, ship, "assets/ship.png")
	// Rides along with the ship
	setAnimation(&play, addNode(&play, "ShipLight", .AnimatedSprite, ship, {0, 60}), "assets/light.png", 2, 1, 4, .Forward)
	play.nodes[len(play.nodes) - 1].scale = {0.4, 0.4}
	props := addNode(&play, "Props", .Node2D, world, {640, 360})
	setAnimation(&play, addNode(&play, "Balloon", .AnimatedSprite, props, {-340, -60}), "assets/balloons.png", 4, 1, 3, .Forward)
	setAnimation(&play, addNode(&play, "BalloonPingPong", .AnimatedSprite, props, {340, -100}), "assets/balloons.png", 4, 1, 5, .PingPong)
	setAnimation(&play, addNode(&play, "WarningLight", .AnimatedSprite, props, {-480, 260}), "assets/light.png", 2, 1, 2, .Forward)
	setAnimation(&play, addNode(&play, "WarningLight2", .AnimatedSprite, props, {480, 260}), "assets/light.png", 2, 1, 3, .Forward)
	hud := addNode(&play, "HUD", .Node2D, -1, {1240, 24})
	back := addNode(&play, "BackMenu", .Menu, hud, {-180, 0})
	addItem(&play, back, "Menu", "scene:MenuScene")
	play.nodes[hud].layer = 7
	play.nodes[back].layer = 7
	append(&project.scenes, play)

	options := SceneDef{name = strings.clone("OptionsScene")}
	setText(&options, addNode(&options, "Title", .Label, -1, {640, 120}), "Options", 64, TITLE_COLOR)
	setText(&options, addNode(&options, "Info", .Label, -1, {640, 260}), "Settings will live here.", 28, TEXT_COLOR)
	optionsMenu := addNode(&options, "OptionsMenu", .Menu, -1, {640, 420})
	addItem(&options, optionsMenu, "Back", "scene:MenuScene")
	append(&project.scenes, options)

	for path in ([]string{"assets/ship.png", "assets/balloons.png", "assets/light.png"}) {
		append(&project.assets, AssetDef{strings.clone(path), .Image})
	}
	project.actions = DefaultActions()
	return project
}

// Appends a node to the end of the scene and returns its index. Callers add children right
// after their parent, which keeps the depth-first order
@(private="file")
addNode :: proc(scene: ^SceneDef, name: string, kind: NodeKind, parent: int, position: [2]f32) -> int {
	node := NodeDef_Make(name, kind, parent)
	node.position = position
	if kind == .Menu {
		// Demo menus define their own buttons
		for item in node.items { delete(item.label); delete(item.action) }
		clear(&node.items)
	}
	append(&scene.nodes, node)
	return len(scene.nodes) - 1
}

@(private="file")
setText :: proc(scene: ^SceneDef, index: int, text: string, size: f32, color: sdl.Color) {
	node := &scene.nodes[index]
	delete(node.text)
	node.text = strings.clone(text)
	node.fontSize = size
	node.color = color
	node.layer = 7
}

@(private="file")
setTexture :: proc(scene: ^SceneDef, index: int, path: string) {
	node := &scene.nodes[index]
	delete(node.texture)
	node.texture = strings.clone(path)
}

@(private="file")
setAnimation :: proc(scene: ^SceneDef, index: int, path: string, columns, rows: int, fps: f32, mode: e.AnimationPlayMode) {
	setTexture(scene, index, path)
	node := &scene.nodes[index]
	node.columns = columns
	node.rows = rows
	node.animations[0].fps = fps
	node.animations[0].loop = true
	node.animations[0].playMode = mode
}

@(private="file")
addItem :: proc(scene: ^SceneDef, index: int, label, action: string) {
	append(&scene.nodes[index].items, MenuItemDef{strings.clone(label), strings.clone(action)})
}
