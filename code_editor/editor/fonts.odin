// Font fallback: glyphs missing from the (monospace) editor font — emoji,
// CJK, many symbols — are looked up in fallback fonts attached with
// SDL_ttf's TTF_AddFallbackFont. font_add_system_fallbacks attaches the
// usual system fonts for the platform; the host keeps the returned handle
// alive for as long as it uses the main font.
package code_editor

import "core:os"
import "core:strings"
import ttf "vendor:sdl3/ttf"

Fallback_Fonts :: struct {
	fonts: [dynamic]^ttf.Font,
}

// Candidates in priority order; missing files are skipped.
@(private)
FALLBACK_FONT_PATHS := [?]string{
	// macOS
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Hiragino Sans GB.ttc",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	// Linux
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/usr/share/fonts/noto/NotoColorEmoji.ttf",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	// Windows
	"C:/Windows/Fonts/seguiemj.ttf",
	"C:/Windows/Fonts/seguisym.ttf",
	"C:/Windows/Fonts/msyh.ttc",
}

// font_add_system_fallbacks opens the platform's emoji/symbol/CJK fonts at
// `size` and attaches them to `font`. Release with font_fallbacks_destroy
// (safe in either order relative to closing `font`'s users, as long as
// `font` itself is still open: it detaches them first).
font_add_system_fallbacks :: proc(font: ^ttf.Font, size: f32) -> Fallback_Fonts {
	fb := Fallback_Fonts{fonts = make([dynamic]^ttf.Font)}
	if font == nil {
		return fb
	}
	for path in FALLBACK_FONT_PATHS {
		if !os.exists(path) {
			continue
		}
		f := ttf.OpenFont(strings.clone_to_cstring(path, context.temp_allocator), size)
		if f == nil {
			continue
		}
		if ttf.AddFallbackFont(font, f) {
			append(&fb.fonts, f)
		} else {
			ttf.CloseFont(f)
		}
	}
	return fb
}

font_fallbacks_destroy :: proc(fb: ^Fallback_Fonts, font: ^ttf.Font) {
	if font != nil && len(fb.fonts) > 0 {
		ttf.ClearFallbackFonts(font)
	}
	for f in fb.fonts {
		ttf.CloseFont(f)
	}
	delete(fb.fonts)
}
