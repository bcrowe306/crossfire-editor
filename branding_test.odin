package editor

import "core:testing"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

@(test)
window_icon_decodes :: proc(t: ^testing.T) {
	surface := img.Load_IO(sdl.IOFromConstMem(raw_data(WINDOW_ICON), uint(len(WINDOW_ICON))), true)
	testing.expect(t, surface != nil, "the built-in icon is a PNG SDL_image reads")
	if surface == nil do return
	defer sdl.DestroySurface(surface)
	testing.expect_value(t, surface.w, 256)
	testing.expect_value(t, surface.h, 256)
	// Transparent around the logo: the top-left corner's pixel has no alpha
	details := sdl.GetPixelFormatDetails(surface.format)
	testing.expect(t, details != nil && details.bits_per_pixel == 32 && details.Amask != 0, "it has an alpha channel")
	r, g, b, a: u8
	testing.expect(t, sdl.ReadSurfacePixel(surface, 0, 0, &r, &g, &b, &a), "readable")
	testing.expect_value(t, a, 0)
}
