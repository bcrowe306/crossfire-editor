package editor

import "gui:skald"

// Font Awesome 6 Free Solid (SIL OFL 1.1, see assets/fonts/LICENSE.fa.txt). Registered as a
// fallback of the default font, so these glyphs work in any text, button or tree label
ICON_FONT :: #load("assets/fonts/fa-solid-900.ttf", []byte)

ICON_FILE        :: "\uf15b"
ICON_FOLDER      :: "\uf07b"
ICON_FOLDER_OPEN :: "\uf07c"
ICON_SAVE        :: "\uf0c7"
ICON_XMARK       :: "\uf00d"
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
ICON_PLAY_SCENE  :: "\uf144"
ICON_CODE        :: "\uf121"
ICON_LINK_SLASH  :: "\uf127"
// Physics node kinds
ICON_SQUARE      :: "\uf0c8"
ICON_BOX         :: "\uf466"
ICON_RUNNING     :: "\uf70c"
ICON_BULLSEYE    :: "\uf140"
ICON_POLYGON     :: "\uf5ee"
ICON_RAY         :: "\uf178"
ICON_JOINT       :: "\uf0c1"
ICON_DATABASE    :: "\uf1c0"
ICON_GLOBE       :: "\uf0ac"
ICON_FIRE        :: "\uf06d"
ICON_STAR        :: "\uf005"
ICON_CUBES       :: "\uf1b3"
ICON_VOLUME      :: "\uf028"
ICON_VOLUME_MUTE :: "\uf6a9"
ICON_LOCATION    :: "\uf3c5"
ICON_SLIDERS     :: "\uf1de"
ICON_COPY        :: "\uf0c5"
ICON_ARROW_UP    :: "\uf062"
ICON_ARROW_DOWN  :: "\uf063"

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
	case .StaticBody:     return ICON_SQUARE
	case .DynamicBody:    return ICON_BOX
	case .CharacterMover: return ICON_RUNNING
	case .Area:           return ICON_BULLSEYE
	case .CollisionShape: return ICON_POLYGON
	case .RayCast:        return ICON_RAY
	case .Joint:          return ICON_JOINT
	case .ParticleEmitter: return ICON_FIRE
	case .Component:      return ICON_CUBES
	case .AudioPlayer:    return ICON_VOLUME
	case .AudioPlayer2D:  return ICON_LOCATION
	case .MusicPlayer:    return ICON_MUSIC
	}
	return ICON_CUBE
}
