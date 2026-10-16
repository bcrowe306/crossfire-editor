package editor

import "gui:skald"

// Font Awesome 6 Free Solid (SIL OFL 1.1, see assets/fonts/LICENSE.fa.txt). Registered as a
// fallback of the default font, so these glyphs work in any text, button or tree label
ICON_FONT :: #load("assets/fonts/fa-solid-900.ttf", []byte)

ICON_FILE        :: "\uf15b"
ICON_FOLDER      :: "\uf07b"
ICON_FOLDER_OPEN :: "\uf07c"
ICON_SAVE        :: "\uf0c7"
ICON_UNDO        :: "\uf2ea"
ICON_REDO        :: "\uf2f9"
ICON_POINTER     :: "\uf245"
ICON_MOVE        :: "\uf047"
ICON_ROTATE      :: "\uf2f1"
ICON_SCALE       :: "\uf424"
ICON_PLAY        :: "\uf04b"
ICON_PAUSE       :: "\uf04c"
ICON_STOP        :: "\uf04d"
ICON_EXPORT      :: "\uf56e"
ICON_PLUS        :: "\uf067"
ICON_TRASH       :: "\uf1f8"
ICON_IMAGE       :: "\uf03e"
ICON_MUSIC       :: "\uf001"
ICON_FONT_GLYPH  :: "\uf031"
ICON_FILM        :: "\uf008"
ICON_CHEVRON_DOWN :: "\uf078"
ICON_CHEVRON_UP  :: "\uf077"
ICON_CUBE        :: "\uf1b2"
ICON_CAMERA      :: "\uf030"
ICON_LIST        :: "\uf03a"
ICON_SITEMAP     :: "\uf0e8"
ICON_FILE_LINES  :: "\uf15c"
ICON_CIRCLE_INFO :: "\uf05a"
ICON_GRID        :: "\uf00a"
ICON_MAGNET      :: "\uf076"
ICON_LINK        :: "\uf0c1"
ICON_FILE_CODE   :: "\uf1c9"
ICON_CODE        :: "\uf121"
ICON_LINK_SLASH  :: "\uf127"

@(private="file")
iconFontRegistered: bool

// Registers the icon font the first time a frame has a live renderer
ensureIconFont :: proc(ctx: ^skald.Ctx(Msg)) {
	if iconFontRegistered || ctx.renderer == nil do return
	font := skald.font_load(ctx.renderer, "fa-solid", ICON_FONT)
	skald.font_add_fallback(ctx.renderer, skald.font_default(ctx.renderer), font)
	iconFontRegistered = true
}

// Icon shown for each node type in the scene tree and viewport
NodeKindIcon :: proc(kind: NodeKind) -> string {
	switch kind {
	case .Node2D:         return ICON_CUBE
	case .Sprite:         return ICON_IMAGE
	case .AnimatedSprite: return ICON_FILM
	case .Camera:         return ICON_CAMERA
	case .Label:          return ICON_FONT_GLYPH
	case .Menu:           return ICON_LIST
	}
	return ICON_CUBE
}
