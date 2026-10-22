package crossfire_editor

import "gui:skald"

// Font Awesome 6 Free Solid (SIL OFL 1.1, see assets/fonts/LICENSE.fa.txt). Registered as a
// fallback of the default font, so these glyphs work in any text, button or tree label
ICON_FONT :: #load("assets/fonts/fa-solid-900.ttf", []byte)

ICON_FILE        :: "\uf15b"
ICON_FOLDER      :: "\uf07b"
ICON_FOLDER_OPEN :: "\uf07c"
ICON_SAVE        :: "\uf0c7"
ICON_XMARK       :: "\uf00d"
ICON_CHECK       :: "\uf00c"
ICON_DOWNLOAD    :: "\uf019"
ICON_UNDO        :: "\uf2ea"
ICON_REDO        :: "\uf2f9"
ICON_POINTER     :: "\uf245"
ICON_MOVE        :: "\uf047"
ICON_ROTATE      :: "\uf2f1"
ICON_SCALE       :: "\uf424"
ICON_HAND        :: "\uf256"
// Skeletons (skeleton_edit.odin)
ICON_BONE        :: "\uf5d7"
ICON_PERSON      :: "\uf183"
ICON_DRAW_POLYGON :: "\uf5ee"
ICON_CROSSHAIRS  :: "\uf05b"
ICON_GAMEPAD     :: "\uf11b"
ICON_WAND        :: "\uf0d0"
ICON_PEN         :: "\uf304"
ICON_WIND        :: "\uf72e"
ICON_CIRCLE_DOT  :: "\uf192"
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
// A filled circle: a tab with unsaved changes
ICON_CIRCLE      :: "\uf111"
ICON_GRID        :: "\uf00a"
ICON_STOPWATCH   :: "\uf2f2"
ICON_PALETTE     :: "\uf53f"
ICON_LIGHTBULB   :: "\uf0eb"
ICON_MOUNTAIN    :: "\uf6fc"
ICON_VECTOR_SQUARE :: "\uf5cb"
ICON_TV          :: "\uf26c"
ICON_ROUTE       :: "\uf4d7"
ICON_PERSON_WALKING :: "\uf554"
ICON_SHADOW      :: "\uf5c7"
ICON_SQUARE_FULL :: "\uf45c"
ICON_HAND_POINTER :: "\uf25a"
ICON_BARS_PROGRESS :: "\uf828"
ICON_I_CURSOR    :: "\uf246"
ICON_SCROLL      :: "\uf70e"
ICON_PARAGRAPH   :: "\uf1dd"
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
ICON_CODE_BRANCH :: "\uf126"
ICON_REFRESH     :: "\uf021"
ICON_UPLOAD      :: "\uf0ee"
ICON_MAP         :: "\uf279"

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
	case .LDtkLevel:      return ICON_MAP
	case .TileMap:        return ICON_GRID
	case .Animator:       return ICON_STOPWATCH
	case .Panel:          return ICON_SQUARE_FULL
	case .Button:         return ICON_HAND_POINTER
	case .ProgressBar:    return ICON_BARS_PROGRESS
	case .TextField:      return ICON_I_CURSOR
	case .ScrollBox:      return ICON_SCROLL
	case .RichText:       return ICON_PARAGRAPH
	case .Light2D:        return ICON_LIGHTBULB
	case .LightOccluder:  return ICON_SHADOW
	case .NavRegion:      return ICON_ROUTE
	case .StateMachine:   return ICON_SITEMAP
	case .ParallaxLayer:  return ICON_MOUNTAIN
	case .CameraZone:     return ICON_VECTOR_SQUARE
	case .CameraView:     return ICON_TV
	case .NavAgent:       return ICON_PERSON_WALKING
	case .VirtualJoystick: return ICON_GAMEPAD
	case .TouchButton:    return ICON_CIRCLE_DOT
	case .ScreenEffect:   return ICON_WAND
	case .Line2D:         return ICON_PEN
	case .Skeleton2D:     return ICON_PERSON
	case .Bone2D:         return ICON_BONE
	case .SkinnedMesh:    return ICON_DRAW_POLYGON
	case .IKChain:        return ICON_CROSSHAIRS
	case .Trail2D:        return ICON_WIND
	}
	return ICON_CUBE
}
