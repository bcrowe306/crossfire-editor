package crossfire_editor

import "core:log"
import "core:os"
import ce "code_editor/editor"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

/*
The GPU renderer the viewport and the code tabs draw with: SDL's Vulkan renderer on Skald's own
device (`skald.renderer_vulkan_handles`), drawing into images Skald samples
(`skald.image_create_target`). Nothing is copied: the engine draws the scene, or the code editor
its text, straight into the image the canvas shows.

- One SDL renderer for both (`SharedGPU_Renderer`), on a hidden window of its own (an SDL
  renderer needs a window, though it never presents to it). Made the first time it's asked for,
  once the view has handed over Skald's renderer (`SharedGPU_SetSkald`).
- A `GPUTarget` is a Skald image wrapped as an SDL render target; it only grows (rounded up to
  256 px) and is drawn with `skald.draw_image_region(..., inset = false)` over the used corner.
  Drawing goes between `GPUTarget_Begin` and `GPUTarget_End`: End sets SDL's target back to the
  window, which leaves the image sampleable and submits the drawing (Skald's contract for target
  images: see its `image_create_target`).
- Everything runs on the main thread, as Skald's frames do, so the queue is never used by both
  at once.
- **Every target switch waits for the GPU:** SDL's Vulkan renderer submits and waits for its
  queue (`vkQueueWaitIdle`, SDL's VULKAN_IssueBatch) on each `SDL_SetRenderTarget`, and that
  queue is Skald's: Begin waits for Skald's last frame (about 0.7 ms here), End for what was
  drawn (3.4-3.9 ms for the demo's levels). Spans `gpu_target_begin` / `gpu_target_end`. Draw
  less and switch less (the viewport's draw key, the engine's reused light map); avoiding the
  wait itself would need a change to SDL.
- Without it (unit tests have no SDL video; `EDITOR_GPU_SHARE=0` or `EDITOR_PREVIEW_SOFTWARE`
  set; a machine where SDL's Vulkan renderer can't use Skald's device) the viewport falls back to
  its own GPU renderer with a readback, then software, and the code tabs to software renderers.
- `SharedGPU_Shutdown` (Skald's `App.on_shutdown`) frees it all before Skald destroys the device.
*/

@(private="file")
gpu: struct {
	skald: ^skald.Renderer,
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	// It was tried and couldn't be made (then never again)
	failed: bool,
}

// Hands over Skald's renderer (the view does each frame: it's what the shared renderer is made on)
SharedGPU_SetSkald :: proc(r: ^skald.Renderer) {
	gpu.skald = r
}

/*
The shared SDL renderer, made the first time it's asked for.

Returns:
- The renderer, or nil when there's none (no Skald renderer yet, no SDL video, turned off, or it
  couldn't be made): use another way to draw
*/
SharedGPU_Renderer :: proc() -> ^sdl.Renderer {
	if gpu.renderer != nil || gpu.failed do return gpu.renderer
	if gpu.skald == nil || sdl.WasInit({.VIDEO}) == {} do return nil
	gpu.failed = true
	if os.get_env("EDITOR_GPU_SHARE", context.temp_allocator) == "0" || os.get_env("EDITOR_PREVIEW_SOFTWARE", context.temp_allocator) != "" do return nil
	h := skald.renderer_vulkan_handles(gpu.skald)
	if h.device == nil do return nil
	gpu.window = sdl.CreateWindow("Crossfire GPU", 16, 16, {.HIDDEN, .VULKAN})
	if gpu.window == nil {
		log.warnf("Shared GPU renderer: no hidden window (%s)", sdl.GetError())
		return nil
	}
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	sdl.SetStringProperty(props, sdl.PROP_RENDERER_CREATE_NAME_STRING, "vulkan")
	sdl.SetPointerProperty(props, sdl.PROP_RENDERER_CREATE_WINDOW_POINTER, gpu.window)
	sdl.SetPointerProperty(props, sdl.PROP_RENDERER_CREATE_VULKAN_INSTANCE_POINTER, h.instance)
	sdl.SetPointerProperty(props, sdl.PROP_RENDERER_CREATE_VULKAN_PHYSICAL_DEVICE_POINTER, h.physical_device)
	sdl.SetPointerProperty(props, sdl.PROP_RENDERER_CREATE_VULKAN_DEVICE_POINTER, h.device)
	sdl.SetNumberProperty(props, sdl.PROP_RENDERER_CREATE_VULKAN_GRAPHICS_QUEUE_FAMILY_INDEX_NUMBER, i64(h.queue_family))
	sdl.SetNumberProperty(props, sdl.PROP_RENDERER_CREATE_VULKAN_PRESENT_QUEUE_FAMILY_INDEX_NUMBER, i64(h.queue_family))
	gpu.renderer = sdl.CreateRendererWithProperties(props)
	if gpu.renderer == nil {
		log.warnf("Shared GPU renderer: SDL's Vulkan renderer couldn't use the editor's device (%s)", sdl.GetError())
		sdl.DestroyWindow(gpu.window)
		gpu.window = nil
		return nil
	}
	gpu.failed = false
	log.info("Shared GPU renderer: the viewport and code tabs draw with SDL's Vulkan renderer on the editor's device")
	return gpu.renderer
}

/*
Frees the shared renderer and its window. Whoever drew with it frees their textures and targets
first (the viewport's game, the code tabs' target); the code editor's glyph atlas goes here.
*/
SharedGPU_Shutdown :: proc() {
	if gpu.renderer != nil {
		ce.editor_forget_renderer(gpu.renderer)
		sdl.DestroyRenderer(gpu.renderer)
	}
	if gpu.window != nil do sdl.DestroyWindow(gpu.window)
	gpu = {}
}

// A Skald image the shared renderer draws into: `key` is its name in Skald, `size` its pixels
GPUTarget :: struct {
	key: string,
	texture: ^sdl.Texture,
	size: [2]int,
}

/*
Makes sure `t` is at least `size` big (rounded up to 256 px; it only grows).

Returns:
- false when it couldn't be made (it's left empty)
*/
GPUTarget_Ensure :: proc(t: ^GPUTarget, key: string, size: [2]int) -> bool {
	if t.texture != nil && t.key == key && t.size.x >= size.x && t.size.y >= size.y do return true
	r := SharedGPU_Renderer()
	if r == nil || size.x <= 0 || size.y <= 0 do return false
	GPUTarget_Destroy(t)
	w := (size.x + 255) / 256 * 256
	h := (size.y + 255) / 256 * 256
	image, ok := skald.image_create_target(gpu.skald, key, u32(w), u32(h))
	if !ok do return false
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_FORMAT_NUMBER, i64(sdl.PixelFormat.BGRA32))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_ACCESS_NUMBER, i64(sdl.TextureAccess.TARGET))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_WIDTH_NUMBER, i64(w))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, i64(h))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_VULKAN_TEXTURE_NUMBER, i64(uintptr(image)))
	sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_VULKAN_LAYOUT_NUMBER, i64(vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL))
	t.texture = sdl.CreateTextureWithProperties(r, props)
	if t.texture == nil {
		log.warnf("Shared GPU renderer: no %dx%d target (%s)", w, h, sdl.GetError())
		skald.image_release(gpu.skald, key)
		return false
	}
	t.key = key
	t.size = {w, h}
	return true
}

// Starts drawing into the target's top-left `size` (the viewport and clip set to it)
GPUTarget_Begin :: proc(t: ^GPUTarget, size: [2]int) {
	e.Trace_Scope("gpu_target_begin")
	sdl.SetRenderTarget(gpu.renderer, t.texture)
	rect := sdl.Rect{0, 0, i32(size.x), i32(size.y)}
	sdl.SetRenderViewport(gpu.renderer, &rect)
	sdl.SetRenderClipRect(gpu.renderer, &rect)
}

// Ends drawing: the image is ready for Skald to draw (and the drawing is submitted)
GPUTarget_End :: proc() {
	e.Trace_Scope("gpu_target_end")
	sdl.SetRenderTarget(gpu.renderer, nil)
}

// Frees the target (its SDL texture, then Skald's image)
GPUTarget_Destroy :: proc(t: ^GPUTarget) {
	if t.texture != nil do sdl.DestroyTexture(t.texture)
	if t.key != "" && gpu.skald != nil do skald.image_release(gpu.skald, t.key)
	t^ = {}
}

/*
Reads the target's top-left `size` back (tests and the driver's saved renders: never needed to
show it).

Returns:
- RGBA8 pixels, `size.x * size.y * 4` bytes, temp allocated; nil if it couldn't
*/
GPUTarget_ReadPixels :: proc(t: ^GPUTarget, size: [2]int) -> []u8 {
	if t.texture == nil || size.x <= 0 || size.y <= 0 do return nil
	sdl.SetRenderTarget(gpu.renderer, t.texture)
	rect := sdl.Rect{0, 0, i32(size.x), i32(size.y)}
	surface := sdl.RenderReadPixels(gpu.renderer, &rect)
	sdl.SetRenderTarget(gpu.renderer, nil)
	if surface == nil do return nil
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	if rgba == nil do return nil
	defer sdl.DestroySurface(rgba)
	pixels := make([]u8, size.x * size.y * 4, context.temp_allocator)
	src := ([^]u8)(rgba.pixels)
	row := size.x * 4
	for y in 0 ..< size.y do copy(pixels[y * row:][:row], src[y * int(rgba.pitch):][:row])
	return pixels
}

// Draws the used corner (`size` pixels) of a target into `rect` (logical pixels), 1:1
GPUTarget_Draw :: proc(r: ^skald.Renderer, key: string, rect: skald.Rect, size: [2]int) {
	skald.draw_image_region(r, key, rect, {0, 0, f32(size.x), f32(size.y)}, inset = false)
}
