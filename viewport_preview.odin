package editor

import "core:hash"
import "core:log"
import "core:strings"
import "core:time"
import e "engine:."
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

/*
The viewport's live preview: the open scene rendered by the engine itself, so sprites,
animations, text and menus look exactly as they do in the game (and future engine features,
like particles, show up without editor work).

The engine draws with SDL's software renderer into a surface; the view uploads those pixels to a
Skald image when `Preview_FrameKey` says the picture changed (the upload is the slow part). The preview keeps SDL resources, so it lives here as package state, not
in `State`:
- The engine scene is rebuilt only when the scene's structure changes (node kinds, textures, text,
  animation settings...), detected with `sceneSignature`.
- Transforms, visibility and layers are copied to the engine nodes every frame, so dragging is
  cheap and animations don't restart.
- The surface only grows, so resizing the panel doesn't reload textures each time.
*/

@(private="file")
Preview :: struct {
	failed: bool,
	surface: ^sdl.Surface,
	renderer: ^sdl.Renderer,
	game: ^e.Game,
	scene: ^e.Scene,
	// Engine node for each editor node of the previewed scene, same order
	nodes: [dynamic]^e.Node,
	signature: u64,
	animated: bool,
	lastFrame: time.Tick,
	pixels: [dynamic]u8,
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

	// Animations advance in real time while enabled
	now := time.tick_now()
	dt := preview.lastFrame == {} ? 0 : min(time.duration_seconds(time.tick_diff(preview.lastFrame, now)), 0.1)
	preview.lastFrame = now
	if s.viewport.animate && dt > 0 {
		e.Scene_Update(preview.scene, nil, dt)
	}

	r := preview.renderer
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
		t := struct { position: [2]f32, rotation: f32, scale: [2]f32, visible: bool, layer: int }{node.position, node.rotation, node.scale, node.visible, node.layer}
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

// Grows the surface (and recreates the renderer for it) when the view gets bigger
@(private="file")
ensureSurface :: proc(size: [2]int) -> bool {
	if preview.surface != nil && preview.surface.w >= i32(size.x) && preview.surface.h >= i32(size.y) do return true

	// Round up so small resizes don't recreate everything
	w := (size.x + 255) / 256 * 256
	h := (size.y + 255) / 256 * 256
	destroyAll()

	if ttf.WasInit() == 0 && !ttf.Init() {
		log.errorf("Viewport preview: SDL_ttf init failed: %s", sdl.GetError())
		preview.failed = true
		return false
	}
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
	preview.scene.game = preview.game

	data := toSceneData(scene)
	// Scripts don't run in the viewport
	created := e.Scene_Build(preview.scene, &data, s.project.rootPath, attachScripts = false)
	e.Scene_ProcessQueues(preview.scene)

	clear(&preview.nodes)
	append(&preview.nodes, ..created)
	preview.animated = false
	for node in scene.nodes do if node.kind == .AnimatedSprite do preview.animated = true
}

// Copies what changes while editing (transforms, visibility, layers) to the engine nodes
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
	}
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
			texture = node.texture, text = node.text, fontSize = node.fontSize, color = node.color,
			centered = node.centered, zoom = node.zoom, columns = node.columns, rows = node.rows,
			fps = node.fps, loop = node.loop, playMode = node.playMode, items = items,
		})
	}
	return data
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
		strings.write_string(&b, node.texture)
		strings.write_string(&b, node.text)
		strings.write_f32(&b, node.fontSize, 'g')
		strings.write_bytes(&b, node.color[:])
		strings.write_byte(&b, node.centered ? 1 : 0)
		strings.write_f32(&b, node.zoom, 'g')
		strings.write_int(&b, node.columns)
		strings.write_int(&b, node.rows)
		strings.write_f32(&b, node.fps, 'g')
		strings.write_byte(&b, node.loop ? 1 : 0)
		strings.write_int(&b, int(node.playMode))
		for item in node.items {
			strings.write_string(&b, item.label)
			strings.write_string(&b, item.action)
		}
	}
	return hash.fnv64a(b.buf[:])
}

// The top-left `size` region of the surface as tightly packed RGBA8
@(private="file")
copyPixels :: proc(size: [2]int) -> []u8 {
	surface := preview.surface
	resize(&preview.pixels, size.x * size.y * 4)
	src := ([^]u8)(surface.pixels)
	row := size.x * 4
	for y in 0..<size.y {
		copy(preview.pixels[y * row:][:row], src[int(y) * int(surface.pitch):][:row])
	}
	return preview.pixels[:]
}

@(private="file")
destroyAll :: proc() {
	if preview.scene != nil {
		e.Scene_Destroy(preview.scene)
		free(preview.scene)
		preview.scene = nil
	}
	if preview.game != nil {
		preview.game.resourceManager->destroy()
		free(preview.game)
		preview.game = nil
	}
	if preview.renderer != nil do sdl.DestroyRenderer(preview.renderer)
	if preview.surface != nil do sdl.DestroySurface(preview.surface)
	preview.renderer = nil
	preview.surface = nil
	preview.signature = 0
	clear(&preview.nodes)
}
