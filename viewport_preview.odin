package editor

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import e "engine:."
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

/*
The viewport's live preview: the open scene rendered by the engine itself, so sprites,
animations, text and menus look exactly as they do in the game (and future engine features,
like particles, show up without editor work).

The engine draws with a GPU renderer of SDL's (Vulkan, OpenGL...: SDL's choice, as the game
gets) into a render-target texture, owned by a hidden window of its own, and the pixels are read
back; the view uploads them to a Skald image when `Preview_FrameKey` says the picture changed.
Skald draws with Vulkan in a context SDL's renderer can't share, hence the round trip. Without
SDL video (unit tests), when the GPU renderer can't be made, or with EDITOR_PREVIEW_SOFTWARE
set, it draws with SDL's software renderer into a surface instead (slower: a whole forest level
took about 38 ms; and it has had its own bugs, see the engine's LDtk tile drawing).
The preview keeps SDL resources, so it lives here as package state, not in `State`:
- The engine scene is rebuilt only when the scene's structure changes (node kinds, textures, text,
  animation settings...), detected with `sceneSignature`.
- Transforms, visibility and layers are copied to the engine nodes every frame, so dragging is
  cheap and animations don't restart. So are particle settings: an emitter keeps its particles
  while its settings are edited, and one that emits once replays when its particles are gone.
- The render target (or surface) only grows; growing the GPU target keeps the renderer, its game
  and its textures.
*/

@(private="file")
Preview :: struct {
	failed: bool,
	// Software: the surface the renderer draws into
	surface: ^sdl.Surface,
	// GPU: the hidden window owning the renderer, the texture it draws into, and whether the GPU
	// renderer couldn't be made (then software for good)
	window: ^sdl.Window,
	target: ^sdl.Texture,
	gpuFailed: bool,
	renderer: ^sdl.Renderer,
	game: ^e.Game,
	scene: ^e.Scene,
	// Engine node for each editor node of the previewed scene, same order
	nodes: [dynamic]^e.Node,
	signature: u64,
	animated: bool,
	lastFrame: time.Tick,
	pixels: [dynamic]u8,
	// The LDtk files the game read, and their modification times then (forgetChangedLDtk)
	ldtkModified: map[string]time.Time,
}

@(private="file")
preview: Preview

/*
Renders the open scene and returns its pixels: RGBA8, `size.x * size.y * 4` bytes, valid until the
next call.

Inputs:
- s: Editor state (scene, view, animation toggle)
- size: Image size in physical pixels
- pixelScale: Physical pixels per logical pixel

Returns:
- The pixels, and false if the preview couldn't render
*/
Preview_Render :: proc(s: ^State, size: [2]int, pixelScale: f32) -> ([]u8, bool) {
	if preview.failed || size.x <= 0 || size.y <= 0 do return nil, false
	if !ensureSurface(size) do return nil, false

	scene := &s.project.scenes[s.currentScene]
	signature := sceneSignature(s, scene)
	if preview.scene == nil || signature != preview.signature {
		rebuild(s, scene)
		preview.signature = signature
	}
	syncTransforms(scene)
	// The animation open in the Animation panel plays on its sprite
	if s.bottomTab == .Animation && s.layout.bottomOpen {
		if _, animation, _ := AnimEdit_Selection(s); animation != nil {
			if node := Preview_Node(s.selectedNode); node != nil && e.Node_Is(node, e.AnimatedSprite) {
				player := &(cast(^e.AnimatedSprite)node).animation
				if e.AnimationPlayer_CurrentName(player) != animation.name do e.AnimationPlayer_Play(player, animation.name)
			}
		}
	}

	// Animations advance in real time while enabled
	now := time.tick_now()
	dt := preview.lastFrame == {} ? 0 : min(time.duration_seconds(time.tick_diff(preview.lastFrame, now)), 0.1)
	preview.lastFrame = now
	if s.viewport.animate && dt > 0 {
		e.Scene_Update(preview.scene, nil, dt)
	}

	r := preview.renderer
	if preview.target != nil do sdl.SetRenderTarget(r, preview.target)
	viewport := sdl.Rect{0, 0, i32(size.x), i32(size.y)}
	sdl.SetRenderViewport(r, &viewport)
	sdl.SetRenderClipRect(r, &viewport)
	sdl.SetRenderDrawColor(r, 16, 18, 24, 255)
	sdl.RenderClear(r)

	// The game area in the project's background color, then the scene
	view := Viewport_Transform(&s.viewport, pixelScale)
	topLeft := e.Transform2D_Apply(view, {0, 0})
	bottomRight := e.Transform2D_Apply(view, s.project.gameSize)
	game := sdl.FRect{topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y}
	bg := s.project.background
	sdl.SetRenderDrawColor(r, bg.r, bg.g, bg.b, 255)
	sdl.RenderFillRect(r, &game)
	e.Scene_DrawWithView(preview.scene, r, view, screenLayersUseView = true, positionOnlyScale = s.viewport.zoom * pixelScale)

	// SDL batches draw commands; run them before reading the surface
	sdl.FlushRenderer(r)
	return copyPixels(size), true
}

/*
A hash of everything the rendered image depends on: the scene (structure and transforms), the
view, the image size and, while animations play, the animation frame. Equal keys mean the last
rendered image is still right.
*/
Preview_FrameKey :: proc(s: ^State, size: [2]int, pixelScale: f32) -> u64 {
	scene := &s.project.scenes[s.currentScene]
	State :: struct {
		signature: u64,
		size: [2]int,
		pixelScale: f32,
		center: [2]f32,
		zoom: f32,
		animationFrame: int,
		background: [4]u8,
	}
	key := State{
		signature = sceneSignature(s, scene),
		size = size,
		pixelScale = pixelScale,
		center = s.viewport.center,
		zoom = s.viewport.zoom,
		animationFrame = s.viewport.animate ? s.viewport.animationFrame : -1,
		background = transmute([4]u8)s.project.background,
	}
	h := hash.fnv64a(([^]u8)(&key)[:size_of(key)])
	for node in scene.nodes {
		t := struct { position: [2]f32, rotation: f32, scale: [2]f32, visible: bool, layer: int, zIndex: i32, blendMode: e.BlendMode, ySort: bool }{node.position, node.rotation, node.scale, node.visible, node.layer, node.zIndex, node.blendMode, node.ySort}
		h = hash.fnv64a(([^]u8)(&t)[:size_of(t)], h)
	}
	return h
}

/*
The engine node built for an editor node of the previewed scene, or nil (not built yet, or a
different scene). Used for picking and selection boxes.
*/
Preview_Node :: proc(index: int) -> ^e.Node {
	if index < 0 || index >= len(preview.nodes) do return nil
	return preview.nodes[index]
}

// Whether the previewed scene has anything animated, so the view keeps frames coming
Preview_IsAnimated :: proc() -> bool {
	return preview.animated
}

/*
Makes sure there's something to draw into at least `size` big: the GPU renderer's target (made
the first time, with its hidden window and game; a bigger target later keeps them), else a
software renderer's surface (made again, with a new game, when it grows).
*/
@(private="file")
ensureSurface :: proc(size: [2]int) -> bool {
	// Round up so small resizes don't recreate everything
	w := (size.x + 255) / 256 * 256
	h := (size.y + 255) / 256 * 256
	if ttf.WasInit() == 0 && !ttf.Init() {
		log.errorf("Viewport preview: SDL_ttf init failed: %s", sdl.GetError())
		preview.failed = true
		return false
	}

	if preview.window == nil && !preview.gpuFailed && preview.surface == nil do startGPU()
	if preview.window != nil {
		if preview.target != nil && preview.target.w >= i32(size.x) && preview.target.h >= i32(size.y) do return true
		if preview.target != nil do sdl.DestroyTexture(preview.target)
		preview.target = sdl.CreateTexture(preview.renderer, .RGBA32, .TARGET, i32(w), i32(h))
		if preview.target != nil do return true
		log.warnf("Viewport preview: no %dx%d render target (%s); drawing in software", w, h, sdl.GetError())
		destroyAll()
		preview.gpuFailed = true
	}

	if preview.surface != nil && preview.surface.w >= i32(size.x) && preview.surface.h >= i32(size.y) do return true
	destroyAll()
	preview.surface = sdl.CreateSurface(i32(w), i32(h), .RGBA32)
	if preview.surface != nil do preview.renderer = sdl.CreateSoftwareRenderer(preview.surface)
	if preview.renderer == nil {
		log.errorf("Viewport preview: couldn't create a software renderer: %s", sdl.GetError())
		preview.failed = true
		return false
	}
	preview.game = new(e.Game)
	preview.game.renderer = preview.renderer
	e.ResourceManager_Init(&preview.game.resourceManager, preview.renderer, nil)
	return true
}

// The GPU renderer: a hidden window with SDL's choice of renderer, and the game that draws with it.
// Only with SDL video running (the editor; not unit tests), and not a software renderer (then the
// surface path is the same thing, cheaper)
@(private="file")
startGPU :: proc() {
	preview.gpuFailed = true
	if os.get_env("EDITOR_PREVIEW_SOFTWARE", context.temp_allocator) != "" do return
	if sdl.WasInit({.VIDEO}) == {} do return
	preview.window = sdl.CreateWindow("Viewport preview", 64, 64, {.HIDDEN})
	if preview.window == nil {
		log.warnf("Viewport preview: no hidden window (%s); drawing in software", sdl.GetError())
		return
	}
	preview.renderer = sdl.CreateRenderer(preview.window, nil)
	name := preview.renderer != nil ? string(sdl.GetRendererName(preview.renderer)) : ""
	if preview.renderer == nil || name == "software" {
		log.warnf("Viewport preview: no GPU renderer (%s); drawing in software", preview.renderer == nil ? string(sdl.GetError()) : "SDL chose software")
		if preview.renderer != nil do sdl.DestroyRenderer(preview.renderer)
		sdl.DestroyWindow(preview.window)
		preview.renderer, preview.window = nil, nil
		return
	}
	preview.gpuFailed = false
	_ = sdl.SetRenderVSync(preview.renderer, 0)
	log.infof("Viewport preview: drawing with SDL's %s renderer", name)
	preview.game = new(e.Game)
	preview.game.renderer = preview.renderer
	e.ResourceManager_Init(&preview.game.resourceManager, preview.renderer, nil)
}

// Whether the preview draws on the GPU (tests, the status bar)
Preview_UsesGPU :: proc() -> bool {
	return preview.window != nil
}

// Builds a fresh engine scene from the editor scene
@(private="file")
rebuild :: proc(s: ^State, scene: ^SceneDef) {
	if preview.scene != nil {
		e.Scene_Destroy(preview.scene)
		free(preview.scene)
	}
	preview.game.size = s.project.gameSize
	preview.scene = new(e.Scene)
	e.Scene_Init(preview.scene)
	// Animations play in the preview (Scene_Update), but bodies don't fall: physics runs in Play
	preview.scene.physicsPaused = true
	preview.scene.game = preview.game

	data := toSceneData(scene)
	// Scripts don't run in the viewport. Instances are built from the components being edited
	// (unsaved changes included), not their files
	provideComponents(s, preview.game)
	forgetChangedLDtk(s, preview.game)
	created := e.Scene_Build(preview.scene, &data, s.project.rootPath, attachScripts = false)
	preview.game.components = nil
	e.Scene_ProcessQueues(preview.scene)

	clear(&preview.nodes)
	append(&preview.nodes, ..created)
	preview.animated = false
	for node in scene.nodes do if node.kind == .AnimatedSprite || node.kind == .ParticleEmitter || node.kind == .Component do preview.animated = true
}

/*
Drops the LDtk projects the preview game read whose files changed since (saved in LDtk), so the
build reads them again. Their nodes are gone: the scene was destroyed first.
*/
@(private="file")
forgetChangedLDtk :: proc(s: ^State, game: ^e.Game) {
	changed := make([dynamic]string, context.temp_allocator)
	for path in game.ldtk {
		modified := ldtkModified(joinPath(s.project.rootPath, path, allocator = context.temp_allocator))
		if known, found := preview.ldtkModified[path]; found && known == modified do continue
		append(&changed, strings.clone(path, context.temp_allocator))
	}
	for path in changed do e.Game_ForgetLDtk(game, path)
	// Each file's time as read (forgotten ones are read again by this build)
	for path, _ in preview.ldtkModified do delete(path)
	clear(&preview.ldtkModified)
	for &scene in s.project.scenes do for &node in scene.nodes {
		if node.kind != .LDtkLevel || node.ldtk.file == "" || node.ldtk.file in preview.ldtkModified do continue
		preview.ldtkModified[strings.clone(node.ldtk.file)] = ldtkModified(joinPath(s.project.rootPath, node.ldtk.file, allocator = context.temp_allocator))
	}
}

// Gives a game the project's components as they are in the editor, for building instances (temp
// allocated: unset it after building)
@(private="file")
provideComponents :: proc(s: ^State, game: ^e.Game) {
	game.components = make(map[string]^e.SceneData, context.temp_allocator)
	for &scene in s.project.scenes {
		if !Scene_IsComponent(&scene) || len(scene.nodes) == 0 do continue
		data := toSceneData(&scene)
		game.components[scene.component] = new_clone(data, context.temp_allocator)
	}
}

// The thumbnail renderer: its own surface, renderer and game (textures belong to one renderer)
@(private="file")
Thumbnail :: struct {
	surface: ^sdl.Surface,
	renderer: ^sdl.Renderer,
	game: ^e.Game,
	key: u64,
	pixels: [dynamic]u8,
}

@(private="file")
thumbnail: Thumbnail

/*
A picture of a component for the browser's preview: the engine draws it, fitted to `size`, on the
viewport's background. Cached until the component (or a component in it) or the size changes.

Returns:
- RGBA8 pixels (`size.x * size.y * 4`, valid until the next call), a key that changes when the
  picture does, and false if it couldn't render
*/
Preview_RenderComponent :: proc(s: ^State, sceneIndex: int, size: [2]int) -> (pixels: []u8, key: u64, ok: bool) {
	if sceneIndex < 0 || sceneIndex >= len(s.project.scenes) || size.x <= 0 || size.y <= 0 do return nil, 0, false
	component := &s.project.scenes[sceneIndex]
	key = hash.fnv64a(transmute([]u8)componentSignature(s, component, 0))
	sized := size
	key = hash.fnv64a(([^]u8)(&sized)[:size_of(sized)], key)
	if key == thumbnail.key && len(thumbnail.pixels) == size.x * size.y * 4 do return thumbnail.pixels[:], key, true

	t := &thumbnail
	if t.surface == nil || t.surface.w != i32(size.x) || t.surface.h != i32(size.y) {
		if t.game != nil {
			t.game.resourceManager->destroy()
			free(t.game)
			t.game = nil
		}
		if t.renderer != nil do sdl.DestroyRenderer(t.renderer)
		if t.surface != nil do sdl.DestroySurface(t.surface)
		t.renderer = nil
		if ttf.WasInit() == 0 && !ttf.Init() do return nil, 0, false
		t.surface = sdl.CreateSurface(i32(size.x), i32(size.y), .RGBA32)
		if t.surface != nil do t.renderer = sdl.CreateSoftwareRenderer(t.surface)
		if t.renderer == nil do return nil, 0, false
		t.game = new(e.Game)
		t.game.renderer = t.renderer
		e.ResourceManager_Init(&t.game.resourceManager, t.renderer, nil)
	}
	t.game.size = s.project.gameSize
	scene := new(e.Scene)
	e.Scene_Init(scene)
	scene.physicsPaused = true
	scene.game = t.game
	defer { e.Scene_Destroy(scene); free(scene) }
	data := toSceneData(component)
	provideComponents(s, t.game)
	e.Scene_Build(scene, &data, s.project.rootPath, attachScripts = false)
	t.game.components = nil
	e.Scene_ProcessQueues(scene)

	// Everything it draws, in its own space, fitted with a margin
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for node in scene.nodes {
		bounds, has := e.Node_GetLocalBounds(node)
		if !has do continue
		world := e.Node_GetWorldTransform(node)
		for corner in ([4][2]f32{{bounds.x, bounds.y}, {bounds.x + bounds.w, bounds.y}, {bounds.x, bounds.y + bounds.h}, {bounds.x + bounds.w, bounds.y + bounds.h}}) {
			p := e.Transform2D_Apply(world, corner)
			lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		}
	}
	if lo.x > hi.x do lo, hi = {-32, -32}, {32, 32}
	extent := [2]f32{max(hi.x - lo.x, 1), max(hi.y - lo.y, 1)}
	zoom := min(f32(size.x) / extent.x, f32(size.y) / extent.y) * 0.85
	center := (lo + hi) * 0.5
	view := e.Transform2D{x = {zoom, 0}, y = {0, zoom}, origin = [2]f32{f32(size.x), f32(size.y)} * 0.5 - center * zoom}

	r := t.renderer
	sdl.SetRenderDrawColor(r, 16, 18, 24, 255)
	sdl.RenderClear(r)
	e.Scene_DrawWithView(scene, r, view, screenLayersUseView = true, positionOnlyScale = zoom)
	sdl.FlushRenderer(r)
	resize(&t.pixels, size.x * size.y * 4)
	src := ([^]u8)(t.surface.pixels)
	row := size.x * 4
	for y in 0 ..< size.y do copy(t.pixels[y * row:][:row], src[y * int(t.surface.pitch):][:row])
	t.key = key
	return t.pixels[:], key, true
}

// A component's content, and the content of the components it holds, as text (what its instances depend on)
@(private="file")
componentSignature :: proc(s: ^State, component: ^SceneDef, depth: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, SceneToXML(component, context.temp_allocator))
	if depth < 8 {
		for node in component.nodes {
			if node.kind != .Component do continue
			if i := Project_FindComponent(&s.project, node.component); i >= 0 do strings.write_string(&b, componentSignature(s, &s.project.scenes[i], depth + 1))
		}
	}
	return strings.to_string(b)
}

// Copies what changes while editing (transforms, visibility, layers, particle settings) to the engine nodes
@(private="file")
syncTransforms :: proc(scene: ^SceneDef) {
	for &def, i in scene.nodes {
		if i >= len(preview.nodes) || preview.nodes[i] == nil do continue
		node := preview.nodes[i]
		node.position = def.position
		node.rotation = def.rotation
		node.scale = def.scale
		node.visible = def.visible
		node.layer = e.RenderLayer(clamp(def.layer, 0, len(e.RenderLayer) - 1))
		node.zIndex = def.zIndex
		node.blendMode = def.blendMode
		node.ySort = def.ySort
		if def.kind == .ParticleEmitter && e.Node_Is(node, e.ParticleEmitter) {
			emitter := cast(^e.ParticleEmitter)node
			emitter.settings = def.particles
			// Emitting follows the checkbox; a one-shot emitter plays again once its particles are gone
			if !def.particles.emitting && emitter.emitting {
				e.ParticleEmitter_Stop(emitter)
			} else if def.particles.emitting && !emitter.emitting && e.ParticleEmitter_AliveCount(emitter) == 0 {
				e.ParticleEmitter_Start(emitter)
			}
		}
	}
}

// A node's comma-separated groups as a list (temp allocated)
@(private="file")
groupList :: proc(groups: string) -> [dynamic]string {
	list := make([dynamic]string, context.temp_allocator)
	for name in strings.split(groups, ",", context.temp_allocator) {
		if trimmed := strings.trim_space(name); trimmed != "" do append(&list, trimmed)
	}
	return list
}

// The editor scene as engine scene data (strings borrowed; temp allocated)
@(private="file")
toSceneData :: proc(scene: ^SceneDef) -> e.SceneData {
	data := e.SceneData{name = scene.name, nodes = make([dynamic]e.SceneNodeData, context.temp_allocator)}
	for &node in scene.nodes {
		items := make([dynamic]e.MenuItemData, context.temp_allocator)
		for item in node.items do append(&items, e.MenuItemData{item.label, item.action})
		append(&data.nodes, e.SceneNodeData{
			kind = node.kind, name = node.name, parent = node.parent,
			position = node.position, rotation = node.rotation, scale = node.scale,
			layer = node.layer, visible = node.visible,
			processMode = node.processMode, blendMode = node.blendMode, zIndex = node.zIndex, ySort = node.ySort,
			groups = groupList(node.groups),
			texture = node.texture, text = node.text, fontSize = node.fontSize, color = node.color,
			centered = node.centered, zoom = node.zoom, columns = node.columns, rows = node.rows,
			margin = node.margin, spacing = node.spacing, animations = animationData(node.animations[:]), autoplay = node.autoplay, items = items,
			collisionLayer = node.collisionLayer, collisionMask = node.collisionMask,
			friction = node.friction, restitution = node.restitution, density = node.density,
			gravityScale = node.gravityScale, linearDamping = node.linearDamping, angularDamping = node.angularDamping,
			fixedRotation = node.fixedRotation, bullet = node.bullet, floorMaxAngle = node.floorMaxAngle,
			shape = node.shape, shapeSize = node.shapeSize, radius = node.radius, points = node.points,
			disabled = node.disabled, target = node.target, enabled = node.enabled, excludeParent = node.excludeParent,
			jointKind = node.jointKind, bodyA = node.bodyA, bodyB = node.bodyB, jointOffset = node.jointOffset,
			enableLimit = node.enableLimit, lower = node.lower, upper = node.upper, enableMotor = node.enableMotor,
			motorSpeed = node.motorSpeed, maxMotor = node.maxMotor, enableSpring = node.enableSpring,
			hertz = node.hertz, dampingRatio = node.dampingRatio, collideConnected = node.collideConnected,
				particles = node.particles, component = node.component,
				sound = node.sound, bus = node.bus, audio = node.audio, ldtk = node.ldtk,
		})
	}
	return data
}

// An AnimatedSprite's animations as engine data (names borrowed; temp allocated)
@(private="file")
animationData :: proc(animations: []AnimationDef) -> [dynamic]e.AnimationData {
	list := make([dynamic]e.AnimationData, 0, len(animations), context.temp_allocator)
	for a in animations do append(&list, e.AnimationData{a.name, a.start, a.end, a.fps, a.loop, a.playMode})
	return list
}

// A hash of everything that needs a rebuild when it changes (not transforms)
@(private="file")
sceneSignature :: proc(s: ^State, scene: ^SceneDef) -> u64 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, s.project.rootPath)
	strings.write_int(&b, s.currentScene)
	for &node in scene.nodes {
		strings.write_byte(&b, '|')
		strings.write_int(&b, int(node.kind))
		strings.write_int(&b, node.parent)
		// A level rebuilds when its settings change, or its file does (saved in LDtk)
		if node.kind == .LDtkLevel do LDtkSettings_Signature(&b, s.project.rootPath, &node.ldtk)
		// An instance rebuilds when its component changes
		if node.kind == .Component {
			strings.write_string(&b, node.component)
			if i := Project_FindComponent(&s.project, node.component); i >= 0 do strings.write_string(&b, componentSignature(s, &s.project.scenes[i], 0))
		}
		strings.write_string(&b, node.texture)
		strings.write_string(&b, node.text)
		strings.write_f32(&b, node.fontSize, 'g')
		strings.write_bytes(&b, node.color[:])
		strings.write_byte(&b, node.centered ? 1 : 0)
		strings.write_f32(&b, node.zoom, 'g')
		strings.write_int(&b, node.columns)
		strings.write_int(&b, node.rows)
		strings.write_f32(&b, node.margin, 'g')
		strings.write_f32(&b, node.spacing, 'g')
		strings.write_string(&b, node.autoplay)
		for a in node.animations {
			fmt.sbprintf(&b, "|%s %d %d %v %v %v", a.name, a.start, a.end, a.fps, a.loop, a.playMode)
		}
		for item in node.items {
			strings.write_string(&b, item.label)
			strings.write_string(&b, item.action)
		}
		// A shape's size is its bounds (picking, the selection box)
		if node.kind == .CollisionShape {
			strings.write_int(&b, int(node.shape))
			strings.write_f32(&b, node.shapeSize.x, 'g')
			strings.write_f32(&b, node.shapeSize.y, 'g')
			strings.write_f32(&b, node.radius, 'g')
			for p in node.points {
				strings.write_f32(&b, p.x, 'g')
				strings.write_f32(&b, p.y, 'g')
			}
		}
	}
	return hash.fnv64a(b.buf[:])
}

// The top-left `size` region of the surface as tightly packed RGBA8
@(private="file")
copyPixels :: proc(size: [2]int) -> []u8 {
	surface := preview.surface
	// GPU: read the target back (RGBA32 rows)
	readBack: ^sdl.Surface
	if preview.target != nil {
		rect := sdl.Rect{0, 0, i32(size.x), i32(size.y)}
		readBack = sdl.RenderReadPixels(preview.renderer, &rect)
		if readBack != nil && readBack.format != .RGBA32 {
			converted := sdl.ConvertSurface(readBack, .RGBA32)
			sdl.DestroySurface(readBack)
			readBack = converted
		}
		if readBack == nil {
			log.errorf("Viewport preview: couldn't read the render back: %s", sdl.GetError())
			resize(&preview.pixels, size.x * size.y * 4)
			return preview.pixels[:]
		}
		surface = readBack
	}
	defer if readBack != nil do sdl.DestroySurface(readBack)
	resize(&preview.pixels, size.x * size.y * 4)
	src := ([^]u8)(surface.pixels)
	row := size.x * 4
	for y in 0..<size.y {
		copy(preview.pixels[y * row:][:row], src[int(y) * int(surface.pitch):][:row])
	}
	return preview.pixels[:]
}

// Frees the preview and the thumbnail renderer (tests: each test has its own allocator)
/*
A picture of an LDtk level (or a whole world) for the browser and the inspector: the engine builds
it as an LDtkLevel node (as the editor does: no parallax, entities outlined) and it's fitted to
`size`. Each place it's shown (`slot`: LDtkThumbnailSlot) has its own cache, so the browser's world
map and the inspector's level don't redraw each other every frame; it's drawn again when the file
(its modification time), the level or the size changes.

Returns:
- RGBA8 pixels (`size.x * size.y * 4`, valid until the next call for that slot), a key that changes
  when the picture does, and false if it couldn't render
*/
Preview_RenderLDtk :: proc(s: ^State, slot: LDtkThumbnailSlot, file, level: string, allLevels: bool, size: [2]int) -> (pixels: []u8, key: u64, ok: bool) {
	if file == "" || size.x <= 0 || size.y <= 0 do return nil, 0, false
	modified := ldtkModified(joinPath(s.project.rootPath, file, allocator = context.temp_allocator))
	signature := fmt.tprintf("%s|%s|%v|%v|%v", file, level, allLevels, size, modified)
	key = hash.fnv64a(transmute([]u8)signature)
	t := &ldtkThumbnails[slot]
	if key == t.key && len(t.pixels) == size.x * size.y * 4 do return t.pixels[:], key, true
	if !thumbnailTarget(t, size) do return nil, 0, false
	// A changed file is read again (no scene of this game holds the old one: each is destroyed)
	e.Game_ForgetLDtk(t.game, file)
	t.game.size = s.project.gameSize
	scene := new(e.Scene)
	e.Scene_Init(scene)
	scene.physicsPaused = true
	scene.game = t.game
	defer { e.Scene_Destroy(scene); free(scene) }
	node := e.DEFAULT_SCENE_NODE
	node.kind = .LDtkLevel
	node.name = "Level"
	node.ldtk = e.DEFAULT_LDTK_LEVEL_SETTINGS
	node.ldtk.file = file
	node.ldtk.level = level
	node.ldtk.allLevels = allLevels
	data := e.SceneData{name = "LDtk", nodes = make([dynamic]e.SceneNodeData, context.temp_allocator)}
	append(&data.nodes, node)
	created := e.Scene_Build(scene, &data, s.project.rootPath, attachScripts = false)
	e.Scene_ProcessQueues(scene)
	bounds, has := e.Node_GetLocalBounds(created[0])
	if !has do bounds = {0, 0, 64, 64}
	zoom := min(f32(size.x) / max(bounds.w, 1), f32(size.y) / max(bounds.h, 1)) * 0.95
	center := [2]f32{bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5}
	view := e.Transform2D{x = {zoom, 0}, y = {0, zoom}, origin = [2]f32{f32(size.x), f32(size.y)} * 0.5 - center * zoom}
	r := t.renderer
	sdl.SetRenderDrawColor(r, 16, 18, 24, 255)
	sdl.RenderClear(r)
	e.Scene_DrawWithView(scene, r, view, screenLayersUseView = true, positionOnlyScale = zoom)
	sdl.FlushRenderer(r)
	resize(&t.pixels, size.x * size.y * 4)
	src := ([^]u8)(t.surface.pixels)
	row := size.x * 4
	for y in 0 ..< size.y do copy(t.pixels[y * row:][:row], src[y * int(t.surface.pitch):][:row])
	t.key = key
	return t.pixels[:], key, true
}

// Where an LDtk picture is shown (each has its own cache)
LDtkThumbnailSlot :: enum {
	Browser,
	Inspector,
}

@(private="file")
ldtkThumbnails: [LDtkThumbnailSlot]Thumbnail

// A thumbnail's surface, software renderer and game at a size (made again when the size changes)
@(private="file")
thumbnailTarget :: proc(t: ^Thumbnail, size: [2]int) -> bool {
	if t.surface != nil && t.surface.w == i32(size.x) && t.surface.h == i32(size.y) && t.renderer != nil do return true
	thumbnailDestroy(t)
	if ttf.WasInit() == 0 && !ttf.Init() do return false
	t.surface = sdl.CreateSurface(i32(size.x), i32(size.y), .RGBA32)
	if t.surface != nil do t.renderer = sdl.CreateSoftwareRenderer(t.surface)
	if t.renderer == nil do return false
	t.game = new(e.Game)
	t.game.renderer = t.renderer
	e.ResourceManager_Init(&t.game.resourceManager, t.renderer, nil)
	return true
}

@(private="file")
thumbnailDestroy :: proc(t: ^Thumbnail) {
	if t.game != nil {
		e.Game_ForgetLDtk(t.game)
		t.game.resourceManager->destroy()
		free(t.game)
	}
	if t.renderer != nil do sdl.DestroyRenderer(t.renderer)
	if t.surface != nil do sdl.DestroySurface(t.surface)
	delete(t.pixels)
	t^ = {}
}

Preview_Destroy :: proc() {
	destroyAll()
	delete(preview.pixels)
	delete(preview.nodes)
	for path in preview.ldtkModified do delete(path)
	delete(preview.ldtkModified)
	preview = {}
	thumbnailDestroy(&thumbnail)
	for &t in ldtkThumbnails do thumbnailDestroy(&t)
}

@(private="file")
destroyAll :: proc() {
	if preview.scene != nil {
		e.Scene_Destroy(preview.scene)
		free(preview.scene)
		preview.scene = nil
	}
	if preview.game != nil {
		e.Game_ForgetLDtk(preview.game)
		preview.game.resourceManager->destroy()
		free(preview.game)
		preview.game = nil
	}
	if preview.target != nil do sdl.DestroyTexture(preview.target)
	if preview.renderer != nil do sdl.DestroyRenderer(preview.renderer)
	if preview.window != nil do sdl.DestroyWindow(preview.window)
	if preview.surface != nil do sdl.DestroySurface(preview.surface)
	preview.target = nil
	preview.renderer = nil
	preview.window = nil
	preview.surface = nil
	preview.signature = 0
	clear(&preview.nodes)
}
