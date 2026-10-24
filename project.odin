package crossfire_editor

import "core:fmt"
import "core:hash"
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
	// Format 13 (the engine's Node fields of the same names): whether it updates while the scene
	// is paused, how it blends, its draw order in its layer, whether its children draw by their y
	processMode: e.ProcessMode,
	blendMode: e.BlendMode,
	zIndex: i32,
	ySort: bool,
	// Its groups, comma-separated ("enemies,flying"; "" for none), as the scene file writes them
	groups: string,
	// Editor-only: whether its children are shown in the scene tree
	expanded: bool,

	// Sprite, ParticleEmitter (Texture shape), SkinnedMesh: image path relative to the project
	// folder (an AnimatedSprite's sheets are its animations')
	texture: string,
	// Label
	text: string,
	fontSize: f32,
	color: sdl.Color,
	centered: bool,
	// Camera: its zoom, and how it follows its target, its limits and shake (a plain value), and
	// the node it follows by itself (a path from it, "" none; owned): camera_edit.odin
	zoom: f32,
	camera: e.CameraSettings,
	cameraTarget: string,
	// AnimatedSprite: its animations (at least one), each a range of the cells of its own sheet,
	// and autoplay names the one it starts with ("" = the first). See the Animation panel
	animations: [dynamic]AnimationDef,
	autoplay: string,
	// An animation asset it plays instead of its own sheet and animations ("" for its own; owned)
	animationSet: string,
	// Sprite, AnimatedSprite showing an Aseprite file: the layers drawn ("" every visible one),
	// the slice whose pivot is on the origin; a Sprite's 9-patch slice and size (owned;
	// aseprite_edit.odin)
	asepriteLayers: string,
	pivotSlice: string,
	nineSlice: string,
	nineSize: [2]f32,
	// Sprite: the region of the atlas its `texture` names ("" for none; owned; atlas_edit.odin)
	region: string,
	// CollisionShape: the Aseprite slice of its sprite it follows ("" for none; owned)
	slice: string,
	// Menu
	items: [dynamic]MenuItemDef,
	// Any kind: the script attached to it ("" for none) and its exported field values, as text
	// (scripts.odin). Values for fields the script doesn't have are kept, not shown
	script: string,
	props: [dynamic]ScriptPropDef,
	// Any kind: more scripts after `script`, one of each (the engine runs them in this order;
	// owned): the inspector's More scripts
	moreScripts: [dynamic]NodeScriptDef,
	// A node type game code registers (the engine's `e.NodeType_Register`: a struct embedding
	// `kind`'s type), "" for none: the node is built as it, `kind` being its base. Written
	// `kind="Player" baseKind="Sprite"`. Its exported fields' values are `customProps` (owned)
	customKind: string,
	customProps: [dynamic]ScriptPropDef,
	// Any kind: scripts listening to its events (the engine's `<listener event target handler/>`;
	// strings owned; node_events.odin): the inspector's Events section
	listeners: [dynamic]e.NodeListenerData,

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
	// Only its top stops what comes down on it (format 13)
	oneWay: bool,
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
	// Component: the component it's an instance of (its file, relative to the project)
	component: string,
	// AudioPlayer, AudioPlayer2D, MusicPlayer (mixer.odin): the sound or music asset, the bus
	// ("" for Master), and the rest (a plain value)
	sound: string,
	bus: string,
	audio: e.AudioSettings,
	// MusicPlayer: its layers, played in step with its music (music_layers_edit.odin; owned)
	musicLayers: [dynamic]MusicLayerDef,
	// Bodies: a physics material (`.material.xml`, material_edit.odin) replacing their friction,
	// restitution and density ("" none; owned)
	material: string,
	// LDtkLevel (ldtk_edit.odin): the .ldtk file, the level, collision, entity components... (owned)
	ldtk: e.LDtkLevelSettings,
	// A TileMap's settings (strings owned: tilemap_edit.odin)
	tilemap: e.TileMapSettings,
	// An Animator's clips, autoplay and speed (owned: the engine's AnimatorSettings_Clone /
	// _Destroy; timeline_edit.odin)
	animator: e.AnimatorSettings,
	// A UI control's settings (owned strings: the engine's UISettings_Clone / _Destroy; ui_edit.odin)
	ui: e.UISettings,
	// A Light2D's settings (a plain value: light_edit.odin)
	light: e.LightSettings,
	// A NavRegion's or NavAgent's settings (a plain value: nav_edit.odin); a region's area is
	// shapeSize
	nav: e.NavSettings,
	// A VirtualJoystick's or TouchButton's settings (a plain value) and its input actions,
	// comma-separated (owned): touch_edit.odin
	touch: e.TouchControlSettings,
	touchActions: string,
	// Any node: its shader ("builtin:<name>", a project `.frag`, "" none) and its parameters'
	// values as text (only those set; owned): shader_edit.odin
	shader: string,
	shaderParams: [dynamic]ScriptPropDef,
	// ScreenEffect: it covers the screen layers too
	effectScreenLayers: bool,
	// Line2D and Trail2D: the engine's `e.LineSettings` (a plain value; a line's points are
	// `points`, its image `texture`): line_edit.odin
	line: e.LineSettings,
	// Skeletons (skeleton_edit.odin): a Bone2D's length; a SkinnedMesh's mesh (owned: its
	// `texture` / `region` are the picture); an IKChain's settings and paths (owned)
	boneLength: f32,
	mesh: e.MeshData,
	ik: e.IKSettings,
	ikTip, ikTarget: string,
	// DialogueBox (dialogue_edit.odin): its dialogue asset and start node (owned), and the engine's
	// settings (its font owned)
	dialogue, dialogueStart: string,
	dialogueBox: e.DialogueBoxSettings,
	// A StateMachine's states, transitions and parameters (owned: state_machine_edit.odin)
	stateMachine: e.StateMachineSettings,
	// ParallaxLayer, CameraZone, CameraView settings (plain) and a CameraView's camera (owned):
	// camera_tools_edit.odin
	cameraTools: e.CameraToolSettings,
	viewCamera: string,
}

// A script field's value: `<prop name="speed" value="250"/>` (both owned)
ScriptPropDef :: struct {
	name: string,
	value: string,
}

// One of a node's more scripts (`NodeDef.moreScripts`): its name and field values (owned)
NodeScriptDef :: struct {
	name: string,
	props: [dynamic]ScriptPropDef,
}

// A copy of a list of field values (owned)
Props_Clone :: proc(props: []ScriptPropDef) -> [dynamic]ScriptPropDef {
	copy := make([dynamic]ScriptPropDef, 0, len(props))
	for p in props do append(&copy, ScriptPropDef{strings.clone(p.name), strings.clone(p.value)})
	return copy
}

// Frees a list of field values
Props_Destroy :: proc(props: ^[dynamic]ScriptPropDef) {
	for p in props { delete(p.name); delete(p.value) }
	delete(props^)
	props^ = {}
}

// A copy of a node's more scripts (owned)
NodeScripts_Clone :: proc(scripts: []NodeScriptDef) -> [dynamic]NodeScriptDef {
	copy := make([dynamic]NodeScriptDef, 0, len(scripts))
	for s in scripts do append(&copy, NodeScriptDef{strings.clone(s.name), Props_Clone(s.props[:])})
	return copy
}

// Frees a node's more scripts
NodeScripts_Destroy :: proc(scripts: ^[dynamic]NodeScriptDef) {
	for &s in scripts { delete(s.name); Props_Destroy(&s.props) }
	delete(scripts^)
	scripts^ = {}
}

// Whether two nodes' more scripts are the same
NodeScripts_Equal :: proc(a, b: []NodeScriptDef) -> bool {
	if len(a) != len(b) do return false
	for s, i in a do if s.name != b[i].name || !propsEqual(s.props[:], b[i].props[:]) do return false
	return true
}

/*
A scene: a named tree of nodes.
*/
SceneDef :: struct {
	name: string,
	nodes: [dynamic]NodeDef,
	// A component (component_edit.odin): its file, relative to the project ("" for a scene). It's
	// edited like a scene, but isn't one: scene lists, the start scene and project.xml's scene
	// list leave it out (`Scene_IsComponent`)
	component: string,
	// Editor-only, components: open in a viewport tab
	opened: bool,
	// Editor-only, scenes: its viewport tab was closed (they start open; opening it shows it again)
	tabClosed: bool,
	// Editor-only: the viewport's guide lines (viewport_tools.odin), kept in .editor/guides.ini
	guides: [dynamic]Guide,
	// Scenes: their own settings (the engine's: screen layers, background, gravity), written on
	// the scene file's root. Components have none
	settings: e.SceneSettings,
	// Editor-only: a hash of its file's text as last loaded or saved (`Scene_MarkSaved`), and
	// whether it differs now, worked out once per history version (`Scene_IsDirty`)
	savedHash: u64,
	dirtyVersion: int,
	dirtyKnown, dirty: bool,
}

// A hash of the text a scene or component saves as
Scene_Hash :: proc(scene: ^SceneDef) -> u64 {
	text := SceneToXML(scene, context.temp_allocator)
	return hash.fnv64a(transmute([]u8)text)
}

// Notes that a scene's file now has what it holds (loaded, or just written)
Scene_MarkSaved :: proc(scene: ^SceneDef) {
	scene.savedHash = Scene_Hash(scene)
	scene.dirtyKnown = false
}

/*
Whether a scene or component has changes its file doesn't (its tab shows a dot; closing a
component's tab asks). Worked out from its saved text once per history version.

Inputs:
- state: The editor state
- index: The scene's index in the project

Returns:
- true when it has unsaved changes
*/
Scene_IsDirty :: proc(state: ^State, index: int) -> bool {
	if index < 0 || index >= len(state.project.scenes) do return false
	scene := &state.project.scenes[index]
	if !scene.dirtyKnown || scene.dirtyVersion != state.history.version {
		scene.dirty = Scene_Hash(scene) != scene.savedHash
		scene.dirtyVersion, scene.dirtyKnown = state.history.version, true
	}
	return scene.dirty
}

AssetKind :: enum {
	Image,
	Audio,
	Font,
	// A data resource (`.data.json`, project_data.odin)
	Data,
	// Music: a sound file a MusicPlayer streams (Audio's are sounds, loaded whole); the browser's
	// menu switches between the two
	Music,
	// A component: a saved node tree (`.component.xml`, component_edit.odin)
	Component,
	// An LDtk project (`.ldtk`: ldtk_edit.odin); LDtkLevel nodes show its levels
	LDtk,
	// A translation table (`.csv`, the engine's localization.odin): the game loads every one
	Translation,
	// An animation asset (`.anim.xml`, animation_sets_edit.odin): animations AnimatedSprites share
	Animation,
	// A UI theme (`.theme.xml`, theme_edit.odin): how UI controls look
	Theme,
	// A physics material (`.material.xml`, material_edit.odin): bodies' friction, bounce, density
	PhysicsMaterial,
	// A GLSL fragment shader (`.frag`, shader_edit.odin), compiled beside it as `.frag.shader`
	Shader,
	// A texture atlas (`.atlas.xml`, atlas_edit.odin): images packed into one picture
	Atlas,
	// A dialogue (`.dialogue.xml`, dialogue_edit.odin): a conversation's nodes and steps
	Dialogue,
}

/*
A file in the project's `assets/` folder.
*/
AssetDef :: struct {
	// Path relative to the project root, always with `/`
	path: string,
	kind: AssetKind,
	// Import settings (asset_import_edit.odin): an image's filtering (Default: the project's), a
	// TrueType font's MSDF atlas
	filter: e.TextureFilter,
	msdf: bool,
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
	// The renderer the game draws with (Auto: SDL's choice; the engine's render_backend.odin)
	renderer: e.RenderBackend,
	// How images are filtered unless their asset says (Default: smooth, Aseprite files pixels;
	// the engine's asset_import.odin)
	textureFilter: e.TextureFilter,
	background: sdl.Color,
	// Name of the scene the game starts in
	startScene: string,
	// The language the game starts in (a translation table's; "" for the player's: format 13)
	locale: string,
	// The game window's icon: an image asset's path ("" for the engine's, the Crossfire logo: format 13)
	icon: string,
	scenes: [dynamic]SceneDef,
	assets: [dynamic]AssetDef,
	// Physics: pixels per meter, gravity (px/s²), debug drawing in the game
	physics: e.PhysicsSettings,
	// The game's window: fullscreen, vsync, high-DPI (format 13)
	window: e.WindowSettings,
	// The format the game's sound output asks for (project.xml's audioFrequency, audioChannels;
	// the engine's AudioOutputSettings, `device` unused: it's the machine's, Settings > Editor)
	audioOutput: e.AudioOutputSettings,
	// The viewport grid for this project: cell size, major lines, opacities (format 13's <grid>)
	grid: e.GridSettings,
	// Scene files the editor loaded or saved (relative paths), so Save can delete the files of
	// scenes that were renamed or removed, and nothing else (project_scenes.odin)
	sceneFiles: [dynamic]string,
	// Export targets and their settings, saved in export.ini (export.odin)
	exports: ExportSettings,
	// Global scripts, in start order, and data resources (project_data.odin)
	globals: [dynamic]GlobalDef,
	data: [dynamic]DataDef,
	// Animation assets (`.anim.xml` files: animation_sets_edit.odin), one per asset of kind Animation
	animationSets: [dynamic]AnimationSetDef,
	// UI themes (`.theme.xml` assets: theme_edit.odin), and the project's (`uiTheme`; "" none)
	themes: [dynamic]ThemeDef,
	// Dialogues (dialogue_edit.odin), one per asset of kind Dialogue
	dialogues: [dynamic]DialogueDef,
	// Physics materials (`.material.xml` assets: material_edit.odin)
	materials: [dynamic]MaterialDef,
	// Texture atlases (atlas_edit.odin), one per asset of kind Atlas
	atlases: [dynamic]AtlasDef,
	uiTheme: string,
	// How scene changes look, and the loading scene ("" none; owned): scene_flow_edit.odin
	transition: e.Transition,
	loadingScene: string,
	// Input actions, in order (input_actions.odin)
	actions: [dynamic]ActionDef,
	// Mix buses (mixer.odin): Master first, always
	buses: [dynamic]BusDef,
	// Steam: the app ID and cloud saves, and the achievements (owned): steam_edit.odin
	steam: e.SteamSettings,
	achievements: [dynamic]AchievementDef,
	// Local players: how many, the keyboard, the join action (owned): players_edit.odin
	players: e.PlayerSettings,
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
		groups = strings.clone(""),
		text = strings.clone(kind == .Label ? "Label" : ""),
		fontSize = defaults.fontSize,
		color = defaults.color,
		centered = defaults.centered,
		zoom = defaults.zoom,
		camera = defaults.camera,
		cameraTarget = strings.clone(""),
		autoplay = strings.clone(""),
		component = strings.clone(""),
		sound = strings.clone(""),
		bus = strings.clone(""),
		material = strings.clone(""),
		audio = defaults.audio,
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
		ldtk = LDtkSettings_Clone(e.DEFAULT_LDTK_LEVEL_SETTINGS),
		tilemap = TileMapSettings_Clone(e.DEFAULT_TILEMAP_SETTINGS),
		animator = e.AnimatorSettings_Clone(e.DEFAULT_ANIMATOR_SETTINGS),
		ui = e.UISettings_Clone(e.DEFAULT_UI_SETTINGS),
		light = e.DEFAULT_LIGHT_SETTINGS,
		nav = e.DEFAULT_NAV_SETTINGS,
		cameraTools = e.DEFAULT_CAMERA_TOOL_SETTINGS,
		touch = e.TouchControl_Defaults(kind),
		effectScreenLayers = true,
		line = e.DEFAULT_LINE_SETTINGS,
		boneLength = defaults.boneLength,
		ik = defaults.ik,
		ikTip = strings.clone(""),
		ikTarget = strings.clone(""),
		dialogue = strings.clone(""),
		dialogueStart = strings.clone(""),
		dialogueBox = defaults.dialogueBox,
	}
	// A NavRegion covers a screenful to begin with; a StateMachine has a first state
	if kind == .NavRegion do node.shapeSize = {640, 360}
	if kind == .StateMachine do node.stateMachine = StateMachine_Default()
	// A camera zone covers a screenful, a camera view a small corner
	if kind == .CameraZone do node.shapeSize = {640, 360}
	if kind == .CameraView do node.shapeSize = {160, 90}
	if kind == .AnimatedSprite do append(&node.animations, AnimationDef_Default())
	if kind == .Menu {
		append(&node.items, MenuItemDef{strings.clone("Button"), strings.clone("quit")})
	}
	return node
}

/*
An AnimatedSprite's animation: a named range of the cells of its own sheet (the engine's
`e.AnimationData`; `end` -1 is the last cell).
*/
AnimationDef :: struct {
	// Owned
	name: string,
	// Its sprite sheet: an image path relative to the project folder ("" for none; owned)
	sheet: string,
	// How the sheet is cut into cells: columns x rows, or cells of a size (the engine's)
	grid: e.SheetGrid,
	// The sheet's cells as rectangles instead of the grid's (a sheet of uneven sprites, from the
	// sprite sheet slicer; owned); empty: the grid's cells
	rects: [dynamic]sdl.FRect,
	start: int,
	end: int,
	fps: f32,
	loop: bool,
	playMode: e.AnimationPlayMode,
	// Seconds per frame, overriding fps (Aseprite's frames each have their own; owned)
	durations: [dynamic]f32,
	// Times a non-looping animation plays (0 or 1: once)
	repeat: int,
	// Each frame's events, comma-separated ("" none; an Aseprite file's from its cels; owned)
	events: [dynamic]string,
}

// The animation a new AnimatedSprite gets: every cell of a sheet, looping (name and sheet owned)
AnimationDef_Default :: proc(name := "default", sheet := "", grid := e.DEFAULT_SHEET_GRID) -> AnimationDef {
	return {name = strings.clone(name), sheet = strings.clone(sheet), grid = grid, start = 0, end = -1, fps = e.DEFAULT_ANIMATION_FPS, loop = true, playMode = .Forward}
}

// Frees a node's strings and lists
NodeDef_Destroy :: proc(node: ^NodeDef) {
	delete(node.name)
	delete(node.groups)
	delete(node.texture)
	delete(node.text)
	for item in node.items { delete(item.label); delete(item.action) }
	delete(node.items)
	delete(node.script)
	for prop in node.props { delete(prop.name); delete(prop.value) }
	delete(node.props)
	NodeScripts_Destroy(&node.moreScripts)
	delete(node.customKind)
	Props_Destroy(&node.customProps)
	for l in node.listeners { delete(l.event); delete(l.target); delete(l.handler); delete(l.global) }
	delete(node.listeners)
	delete(node.points)
	e.MeshData_Destroy(&node.mesh)
	delete(node.ikTip)
	delete(node.ikTarget)
	delete(node.dialogue)
	delete(node.dialogueStart)
	delete(node.dialogueBox.font)
	delete(node.bodyA)
	delete(node.bodyB)
	for &a in node.animations do AnimationDef_Destroy(&a)
	delete(node.animations)
	delete(node.animationSet)
	MusicLayers_Destroy(&node.musicLayers)
	delete(node.asepriteLayers)
	delete(node.pivotSlice)
	delete(node.nineSlice)
	delete(node.region)
	delete(node.slice)
	TileMapSettings_Destroy(&node.tilemap)
	e.AnimatorSettings_Destroy(&node.animator)
	e.UISettings_Destroy(&node.ui)
	e.StateMachineSettings_Destroy(&node.stateMachine)
	delete(node.viewCamera)
	delete(node.cameraTarget)
	delete(node.touchActions)
	delete(node.shader)
	for p in node.shaderParams { delete(p.name); delete(p.value) }
	delete(node.shaderParams)
	delete(node.autoplay)
	delete(node.component)
	delete(node.sound)
	delete(node.bus)
	delete(node.material)
	e.LDtkLevelSettings_Destroy(&node.ldtk)
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
- parent: Parent node index, or -1 for a top-level node (in a component that has a root: under
  the root, its only top-level node)

Returns:
- The new node's index
*/
Scene_InsertNode :: proc(scene: ^SceneDef, name: string, kind: NodeKind, parent: int) -> int {
	parent := Scene_ParentFor(scene, parent)
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
Where a node meant for the top level goes: there in a scene, under the root in a component (it
has one root: the engine builds only that one as the instance, so a node beside it would be lost).

Inputs:
- scene: The scene or component
- parent: The parent asked for (-1: the top level)

Returns:
- The parent to use
*/
Scene_ParentFor :: proc(scene: ^SceneDef, parent: int) -> int {
	if parent < 0 && Scene_IsComponent(scene) && len(scene.nodes) > 0 do return 0
	return parent
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
	for &scene in project.scenes do SceneDef_Destroy(&scene)
	delete(project.scenes)
	for asset in project.assets do delete(asset.path)
	delete(project.assets)
	delete(project.name)
	delete(project.rootPath)
	delete(project.startScene)
	delete(project.locale)
	delete(project.icon)
	for f in project.sceneFiles do delete(f)
	delete(project.sceneFiles)
	for &g in project.globals do GlobalDef_Destroy(&g)
	delete(project.globals)
	for &a in project.actions do ActionDef_Destroy(&a)
	delete(project.actions)
	for b in project.buses do delete(b.name)
	delete(project.buses)
	for &d in project.data do DataDef_Destroy(&d)
	for &set in project.animationSets do AnimationSetDef_Destroy(&set)
	delete(project.animationSets)
	for &t in project.themes do ThemeDef_Destroy(&t)
	for &d in project.dialogues do DialogueDef_Destroy(&d)
	delete(project.dialogues)
	delete(project.themes)
	for &m in project.materials do MaterialDef_Destroy(&m)
	delete(project.materials)
	for &a in project.atlases do AtlasDef_Destroy(&a)
	delete(project.atlases)
	delete(project.uiTheme)
	delete(project.loadingScene)
	Achievements_Destroy(&project.achievements)
	delete(project.players.joinAction)
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
		// Resolved, so what's derived from it matches the code tabs' paths (absolutePath)
		rootPath = strings.clone(absolutePath(rootPath)),
		gameSize = data.size,
		scaleMode = data.scaleMode,
		renderer = data.renderer,
		textureFilter = data.textureFilter,
		background = data.background,
		startScene = strings.clone(data.startScene),
		locale = strings.clone(data.locale),
		uiTheme = strings.clone(data.uiTheme),
		transition = data.transition,
		loadingScene = strings.clone(data.loadingScene),
		icon = strings.clone(data.icon),
		physics = data.physics,
		window = data.window,
		grid = data.grid,
		audioOutput = {frequency = data.audioOutput.frequency, channels = data.audioOutput.channels},
		steam = data.steam,
		achievements = Achievements_Clone(data.achievements[:]),
		players = PlayerSettings_Clone(data.players),
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
		case "Music": kind = .Music
		case "Font":  kind = .Font
		case "Data":  kind = .Data
		case "Component": kind = .Component
		case "LDtk": kind = .LDtk
		case "Translation": kind = .Translation
		case "Animation": kind = .Animation
		case "Theme": kind = .Theme
		case "PhysicsMaterial": kind = .PhysicsMaterial
		case "Shader": kind = .Shader
		case "Atlas": kind = .Atlas
		case "Dialogue": kind = .Dialogue
		}
		append(&project.assets, AssetDef{path = strings.clone(asset.path), kind = kind, filter = asset.filter, msdf = asset.msdf})
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
		// An animation asset's sheet and animations come from its file
		if kind == .Animation {
			set, problem := Project_LoadAnimationSet(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
			}
			append(&project.animationSets, set)
		}
		// An atlas's regions come from its file
		if kind == .Atlas {
			atlas, problem := Project_LoadAtlas(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
			}
			append(&project.atlases, atlas)
		}
		// A material's values come from its file
		if kind == .PhysicsMaterial {
			material, problem := Project_LoadMaterial(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
			}
			append(&project.materials, material)
		}
		// A theme's font and values come from its file
		if kind == .Dialogue {
			dialogue, problem := Project_LoadDialogue(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
			}
			append(&project.dialogues, dialogue)
		}
		if kind == .Theme {
			theme, problem := Project_LoadTheme(rootPath, asset.path)
			if problem != "" {
				list := make([dynamic]string, context.temp_allocator)
				append(&list, ..warnings)
				append(&list, problem)
				warnings = list[:]
			}
			append(&project.themes, theme)
		}
	}
	project.buses = Buses_FromData(data.buses[:])
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
		scene := SceneDef{name = strings.clone(ref.name), settings = sceneData.settings}
		for node in sceneData.nodes do append(&scene.nodes, NodeDef_FromData(node))
		e.SceneData_Destroy(&sceneData)
		append(&project.scenes, scene)
		append(&project.sceneFiles, strings.clone(ref.path))
	}
	// What the files have: unchanged scenes show no dot
	for &scene in project.scenes do Scene_MarkSaved(&scene)
	// Components: edited like scenes, after them in the list (component_edit.odin)
	for asset in project.assets {
		if asset.kind != .Component do continue
		scene, problem := Project_LoadComponent(rootPath, asset.path)
		if problem != "" {
			list := make([dynamic]string, context.temp_allocator)
			append(&list, ..warnings)
			append(&list, problem)
			warnings = list[:]
		}
		Scene_MarkSaved(&scene)
		append(&project.scenes, scene)
	}
	Guides_Load(&project)
	return project, "", warnings
}

// A node as the editor holds it, from the engine's parsed scene or component data (strings copied)
NodeDef_FromData :: proc(node: e.SceneNodeData) -> NodeDef {
		def := NodeDef{
			name = strings.clone(node.name),
			kind = node.kind,
			parent = node.parent,
			position = node.position,
			rotation = node.rotation,
			scale = node.scale,
			layer = node.layer,
			visible = node.visible,
			processMode = node.processMode,
			blendMode = node.blendMode,
			zIndex = node.zIndex,
			ySort = node.ySort,
			groups = strings.join(node.groups[:], ","),
			expanded = true,
			texture = strings.clone(node.texture),
			text = strings.clone(node.text),
			fontSize = node.fontSize,
			color = node.color,
			centered = node.centered,
			zoom = node.zoom,
			camera = node.camera,
			cameraTarget = strings.clone(node.cameraTarget),
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
			oneWay = node.oneWay,
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
			// Older files' one sheet is every animation's already (the engine's parser)
			for a in node.animations do append(&def.animations, AnimationDef_FromData(a))
			// A sprite has an animation (not with an animation asset: its animations are the asset's)
			if len(def.animations) == 0 && node.animationSet == "" do append(&def.animations, AnimationDef_Default())
			def.animationSet = strings.clone(node.animationSet)
		}
		if node.kind == .Sprite || node.kind == .AnimatedSprite {
			def.asepriteLayers = strings.clone(node.asepriteLayers)
			def.pivotSlice = strings.clone(node.pivotSlice)
		}
		if node.kind == .Sprite {
			def.nineSlice = strings.clone(node.nineSlice)
			def.nineSize = node.nineSize
			def.region = strings.clone(node.region)
		}
		if node.kind == .CollisionShape {
			def.slice = strings.clone(node.slice)
		}
		for item in node.items {
			append(&def.items, MenuItemDef{strings.clone(item.label), strings.clone(item.action)})
		}
		def.script = strings.clone(node.script)
		for prop in node.props {
			append(&def.props, ScriptPropDef{strings.clone(prop.name), strings.clone(prop.value)})
		}
		for extra in node.moreScripts {
			more := NodeScriptDef{name = strings.clone(extra.name)}
			for prop in extra.props do append(&more.props, ScriptPropDef{strings.clone(prop.name), strings.clone(prop.value)})
			append(&def.moreScripts, more)
		}
		def.customKind = strings.clone(node.customKind)
		for prop in node.customProps do append(&def.customProps, ScriptPropDef{strings.clone(prop.name), strings.clone(prop.value)})
		for l in node.listeners do append(&def.listeners, Listener_Clone(l))
	def.component = strings.clone(node.component)
	def.sound = strings.clone(node.sound)
	def.bus = strings.clone(node.bus)
	def.material = strings.clone(node.material)
	def.audio = node.audio
	if node.kind == .MusicPlayer do for l in node.musicLayers do append(&def.musicLayers, MusicLayerDef{strings.clone(l.name), strings.clone(l.sound), l.volume})
	def.light = node.light
	def.nav = node.nav
	def.stateMachine = e.StateMachineSettings_Clone(node.stateMachine)
	def.cameraTools = node.cameraTools
	def.viewCamera = strings.clone(node.viewCamera)
	def.touch = node.touch
	def.touchActions = strings.clone(node.touchActions)
	def.shader = strings.clone(node.shader)
	for p in node.shaderParams do append(&def.shaderParams, ScriptPropDef{strings.clone(p.name), strings.clone(p.value)})
	def.effectScreenLayers = node.effectScreenLayers
	def.line = node.line
	def.boneLength = node.boneLength
	def.mesh = e.MeshData_Clone(node.mesh)
	def.ik = node.ik
	def.ikTip = strings.clone(node.ikTip)
	def.ikTarget = strings.clone(node.ikTarget)
	def.dialogue = strings.clone(node.dialogue)
	def.dialogueStart = strings.clone(node.dialogueStart)
	def.dialogueBox = node.dialogueBox
	def.dialogueBox.font = strings.clone(node.dialogueBox.font)
	def.ldtk = LDtkSettings_Clone(node.ldtk)
	def.tilemap = TileMapSettings_Clone(node.tilemap)
	def.animator = e.AnimatorSettings_Clone(node.animator)
	def.ui = e.UISettings_Clone(node.ui)
	return def
}

/*
Builds the built-in outline of the demo project, for when the editor has no shipped copy of
`examples/demo_project` to open (release archives and bundles ship it; see `Editor_DemoProject`):
its title screen and options made of UI controls (no images: those ship with the full demo),
and an empty level to start from.

Inputs:
- rootPath: Folder the project is saved in

Returns:
- The project. Its strings are heap-allocated and owned by the project
*/
Project_CreateDemo :: proc(rootPath: string) -> Project {
	project := Project{
		name = strings.clone("Legacy of the Wardens"),
		rootPath = strings.clone(absolutePath(rootPath)),
		gameSize = {1280, 720},
		scaleMode = .Letterbox,
		background = {42, 32, 80, 255},
		startScene = strings.clone("TitleScene"),
		physics = e.DEFAULT_PHYSICS,
		window = e.DEFAULT_WINDOW_SETTINGS,
		grid = e.DEFAULT_GRID_SETTINGS,
		players = e.DEFAULT_PLAYER_SETTINGS,
		audioOutput = e.DEFAULT_AUDIO_OUTPUT,
		exports = ExportSettings_Default(),
	}
	project.transition = e.DEFAULT_TRANSITION
	project.transition.kind = .Fade

	title := SceneDef{name = strings.clone("TitleScene")}
	heading := addNode(&title, "Title", .RichText, -1, {0, 120})
	setControl(&title, heading, "[size=72][color=#ffe7b8]Legacy of the Wardens[/color][/size]", .Top)
	note := addNode(&title, "Note", .RichText, -1, {0, 230})
	setControl(&title, note, "[color=#d8c8f0]The built-in outline of the demo: the full game ships beside the editor (examples/demo_project).[/color]", .Top)
	title.nodes[note].ui.size.x = 900
	title.nodes[note].ui.textAlign = .Center
	menu := addNode(&title, "Menu", .Panel, -1, {0, 90})
	setControl(&title, menu, "", .Center)
	title.nodes[menu].ui.layout = .Column
	title.nodes[menu].ui.align = .Stretch
	title.nodes[menu].ui.size.x = 280
	for item in ([?][3]string{{"Play", "Play", "scene:LevelScene"}, {"Options", "Options", "push:OptionsScene"}, {"Quit", "Quit", "quit"}}) {
		button := addNode(&title, item[0], .Button, menu, {0, 0})
		setControl(&title, button, item[1], .Top_Left)
		delete(title.nodes[button].ui.action)
		title.nodes[button].ui.action = strings.clone(item[2])
	}
	append(&project.scenes, title)

	options := SceneDef{name = strings.clone("OptionsScene")}
	panel := addNode(&options, "Panel", .Panel, -1, {0, 0})
	setControl(&options, panel, "", .Center)
	options.nodes[panel].ui.layout = .Column
	options.nodes[panel].ui.align = .Stretch
	options.nodes[panel].ui.size.x = 420
	setControl(&options, addNode(&options, "Heading", .RichText, panel, {0, 0}), "[size=40]Options[/size]", .Top_Left)
	music := addNode(&options, "Music", .Slider, panel, {0, 0})
	setControl(&options, music, "", .Top_Left)
	options.nodes[music].ui.value = 0.8
	options.nodes[music].ui.step = 0.05
	options.nodes[music].ui.showValue = true
	setControl(&options, addNode(&options, "Fullscreen", .CheckBox, panel, {0, 0}), "Fullscreen", .Top_Left)
	back := addNode(&options, "Back", .Button, panel, {0, 0})
	setControl(&options, back, "Back", .Top_Left)
	delete(options.nodes[back].ui.action)
	options.nodes[back].ui.action = strings.clone("pop")
	append(&project.scenes, options)

	level := SceneDef{name = strings.clone("LevelScene")}
	level.settings.screenLayers = {.Layer8}
	addNode(&level, "Camera", .Camera, -1, {640, 360})
	setControl(&level, addNode(&level, "Hint", .RichText, -1, {0, 0}), "[size=36]Your first level: add an LDtkLevel or a TileMap[/size]", .Center)
	toTitle := addNode(&level, "Title", .Button, -1, {0, -24})
	setControl(&level, toTitle, "Back to the title", .Bottom)
	delete(level.nodes[toTitle].ui.action)
	level.nodes[toTitle].ui.action = strings.clone("scene:TitleScene")
	append(&project.scenes, level)

	project.buses = Buses_FromData(nil)
	project.actions = DefaultActions()
	return project
}

// A UI control's text and anchor, on layer 8 (the level's camera leaves it alone: a screen layer)
@(private="file")
setControl :: proc(scene: ^SceneDef, index: int, text: string, anchor: e.UIAnchor) {
	node := &scene.nodes[index]
	delete(node.text)
	node.text = strings.clone(text)
	node.ui.anchor = anchor
	node.layer = 7
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
