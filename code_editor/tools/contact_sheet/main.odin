// contact_sheet — tiles a directory of visual-test screenshots into one
// labelled PNG so a whole suite can be reviewed at a glance.
//
//   contact_sheet <dir> [--crop-height N] [--scale F] [--cols N]
//
// Writes <dir>/contact_sheet.png. Each cell is the top part of a
// screenshot, scaled by `scale` (default 0.5) and captioned with the file
// name minus its NN_ prefix. The crop height is the lowest row with
// content (anything that isn't the editor background, right of the
// gutter) across the suite's screenshots, at least 340 px — so docked UI
// like the problems panel stays in frame while short fixtures don't waste
// space. `--crop-height N` forces a height. Uses only SDL3 + SDL_ttf.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

LABEL_H :: 22
GAP :: 8

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: contact_sheet <dir> [--crop-height N] [--scale F] [--cols N]")
		os.exit(2)
	}
	dir := os.args[1]
	crop_h := -1 // auto
	scale: f32 = 0.5
	cols := 2
	for i := 2; i + 1 < len(os.args); i += 2 {
		switch os.args[i] {
		case "--crop-height": crop_h, _ = strconv.parse_int(os.args[i + 1])
		case "--scale": scale, _ = strconv.parse_f32(os.args[i + 1])
		case "--cols": cols, _ = strconv.parse_int(os.args[i + 1])
		}
	}

	pattern, _ := filepath.join({dir, "[0-9]*.png"}, context.temp_allocator)
	files, _ := filepath.glob(pattern)
	if len(files) == 0 {
		fmt.eprintln("contact_sheet: no NN_*.png screenshots in", dir)
		os.exit(1)
	}
	slice.sort(files)

	if !ttf.Init() {
		fmt.eprintln("ttf.Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer ttf.Quit()
	font: ^ttf.Font
	for f in ([]cstring{"/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"}) {
		if font = ttf.OpenFont(f, 15); font != nil {
			break
		}
	}

	// Cell size from the first image (all screenshots share the window size).
	first := sdl.LoadPNG(strings.clone_to_cstring(files[0], context.temp_allocator))
	if first == nil {
		fmt.eprintln("contact_sheet: cannot load", files[0], sdl.GetError())
		os.exit(1)
	}
	src_w, src_h := int(first.w), int(first.h)
	sdl.DestroySurface(first)
	if crop_h < 0 {
		crop_h = 340
		for path in files {
			crop_h = max(crop_h, content_bottom(path) + 8)
		}
	}
	crop_h = min(crop_h, src_h)

	cell_w := int(f32(src_w) * scale)
	cell_h := int(f32(crop_h) * scale)
	rows := (len(files) + cols - 1) / cols
	sheet_w := cols * cell_w + (cols + 1) * GAP
	sheet_h := rows * (cell_h + LABEL_H) + (rows + 1) * GAP

	sheet := sdl.CreateSurface(i32(sheet_w), i32(sheet_h), .RGBA8888)
	defer sdl.DestroySurface(sheet)
	sdl.FillSurfaceRect(sheet, nil, sdl.MapSurfaceRGB(sheet, 12, 12, 12))

	for path, i in files {
		img := sdl.LoadPNG(strings.clone_to_cstring(path, context.temp_allocator))
		if img == nil {
			continue
		}
		col, row := i % cols, i / cols
		x := GAP + col * (cell_w + GAP)
		y := GAP + row * (cell_h + LABEL_H + GAP)

		if font != nil {
			name := filepath.stem(path)
			if us := strings.index_byte(name, '_'); us >= 0 {
				name = name[us + 1:]
			}
			caption, _ := strings.replace_all(name, "_", " ", context.temp_allocator)
			label := ttf.RenderText_Blended(font, ([^]u8)(strings.clone_to_cstring(caption, context.temp_allocator)), 0, {230, 230, 230, 255})
			if label != nil {
				dst := sdl.Rect{i32(x), i32(y + 2), label.w, label.h}
				sdl.BlitSurface(label, nil, sheet, &dst)
				sdl.DestroySurface(label)
			}
		}

		src := sdl.Rect{0, 0, img.w, i32(crop_h)}
		dst := sdl.Rect{i32(x), i32(y + LABEL_H), i32(cell_w), i32(cell_h)}
		sdl.BlitSurfaceScaled(img, &src, sheet, &dst, .LINEAR)
		sdl.DestroySurface(img)
	}

	out, _ := filepath.join({dir, "contact_sheet.png"}, context.temp_allocator)
	if !sdl.SavePNG(sheet, strings.clone_to_cstring(out, context.temp_allocator)) {
		fmt.eprintln("contact_sheet: save failed:", sdl.GetError())
		os.exit(1)
	}
	fmt.println(out)
}

// content_bottom returns the last row (y) of `path` that has a pixel,
// right of the gutter, differing noticeably from the editor background
// colour sampled near the top-right corner.
content_bottom :: proc(path: string) -> int {
	img := sdl.LoadPNG(strings.clone_to_cstring(path, context.temp_allocator))
	if img == nil {
		return 0
	}
	defer sdl.DestroySurface(img)
	rgba := sdl.ConvertSurface(img, .RGBA32)
	if rgba == nil {
		return int(img.h)
	}
	defer sdl.DestroySurface(rgba)
	pixels := ([^]u8)(rgba.pixels)
	pitch := int(rgba.pitch)
	w, h := int(rgba.w), int(rgba.h)
	bg := pixels[2 * pitch + (w - 3) * 4:][:3]
	for y := h - 1; y >= 0; y -= 1 {
		row := pixels[y * pitch:]
		for x := 64; x < w - 8; x += 2 {
			p := row[x * 4:]
			d := abs(int(p[0]) - int(bg[0])) + abs(int(p[1]) - int(bg[1])) + abs(int(p[2]) - int(bg[2]))
			if d > 40 {
				return y
			}
		}
	}
	return 0
}
