package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Collision from a sprite (the engine's collision_trace.odin): a body's inspector traces the opaque
pixels of a Sprite or AnimatedSprite under it into CollisionShape polygons, so the body fits what
it draws instead of a box.

- **Settings** (`State.trace`, view state, not saved or undone): which sprite (the body's first
  under it by default), the alpha threshold (pixels at least that opaque are solid) and the detail
  (how far, in pixels, the outline may stray from the pixels: larger is fewer points).
- **Make Shapes** (`Collision_Traced`, one `.Scene` undo step): the body's earlier traced shapes
  (direct children named `Traced...`) are removed, then one Polygon CollisionShape per convex
  piece is added under the body, placed where the sprite draws (its position, rotation and scale
  under the body; centered as a Sprite draws; an AnimatedSprite's first frame). They're ordinary
  shapes: move points, delete some, or trace again.
*/

// The sprite choice for "the first sprite under the body"
TRACE_SPRITE_FIRST :: "(the first sprite under it)"

// The trace settings
TraceSettings :: struct {
	// The sprite node chosen (-1: the first under the body)
	sprite: int,
	// Pixels at least this opaque (1-255) are solid
	threshold: int,
	// How far (pixels) the outline may stray from the pixels
	detail: f32,
}

DEFAULT_TRACE_SETTINGS :: TraceSettings{sprite = -1, threshold = 128, detail = 1.5}

// A trace setting (number fields: TraceNumber)
TraceField :: enum {
	Threshold,
	Detail,
}

// The trace settings' number fields' target (number_field.odin)
TraceNumber :: distinct TraceField

// A trace setting changed
Trace_Setting_Changed :: struct {
	field: TraceField,
	value: f32,
}
// The sprite to trace (a node index; -1 the first under the body)
Trace_Sprite_Chosen :: distinct int
// Make Shapes for the selected body
Collision_Traced :: struct {}

// The Sprite and AnimatedSprite nodes under a body (its subtree), in tree order
Trace_Sprites :: proc(scene: ^SceneDef, body: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	if body < 0 || body >= len(scene.nodes) do return out[:]
	end := body + 1 + Scene_DescendantCount(scene, body)
	for i in body + 1 ..< end {
		if Trace_Picture(&scene.nodes[i]) != "" do append(&out, i)
	}
	return out[:]
}

// The picture a sprite's trace reads: a Sprite's texture, an AnimatedSprite's first animation's
// sheet ("": none)
Trace_Picture :: proc(node: ^NodeDef) -> string {
	#partial switch node.kind {
	case .Sprite: return node.texture
	case .AnimatedSprite: return len(node.animations) > 0 ? node.animations[0].sheet : ""
	}
	return ""
}

// The sprite a trace of `body` uses (-1: none)
Trace_SpriteFor :: proc(scene: ^SceneDef, body: int, settings: TraceSettings) -> int {
	sprites := Trace_Sprites(scene, body)
	for i in sprites do if i == settings.sprite do return i
	return len(sprites) > 0 ? sprites[0] : -1
}

/*
The convex pieces a sprite's pixels make, in the body's space.

Returns:
- The pieces (temp allocated), and "" or why there are none
*/
Trace_Pieces :: proc(project: ^Project, scene: ^SceneDef, body, sprite: int, settings: TraceSettings) -> ([][][2]f32, string) {
	node := &scene.nodes[sprite]
	picture := Trace_Picture(node)
	pixels, w, h, ok := Image_LoadRGBA(joinPath(project.rootPath, picture, allocator = context.temp_allocator))
	if !ok do return nil, fmt.tprintf("Couldn't read %s", picture)
	// An AnimatedSprite draws one cell of its sheet: the first animation's first, cut by its grid
	if node.kind == .AnimatedSprite && len(node.animations) > 0 {
		first := node.animations[0]
		rect := e.SheetGrid_CellRect(first.grid, {f32(w), f32(h)}, max(first.start, 0))
		cx, cy, cw, ch := int(rect.x), int(rect.y), int(rect.w), int(rect.h)
		if cw <= 0 || ch <= 0 || cx < 0 || cy < 0 || cx + cw > w || cy + ch > h do return nil, "The sheet's grid doesn't fit the image"
		crop := make([]u8, cw * ch * 4, context.temp_allocator)
		for y in 0 ..< ch do copy(crop[y * cw * 4:][:cw * 4], pixels[((cy + y) * w + cx) * 4:][:cw * 4])
		pixels, w, h = crop, cw, ch
	}
	pieces := e.Image_CollisionPolygons(pixels, w, h, u8(clamp(settings.threshold, 1, 255)), max(settings.detail, 0), offset = {-f32(w) / 2, -f32(h) / 2})
	if len(pieces) == 0 do return nil, fmt.tprintf("%s has no pixels at least %d opaque", picture, settings.threshold)
	// Where the sprite draws, in the body's space
	world := Scene_WorldTransforms(scene)
	toBody := e.Transform2D_Multiply(e.Transform2D_Inverse(world[body]), world[sprite])
	for piece in pieces do for &p in piece do p = e.Transform2D_Apply(toBody, p)
	return pieces, ""
}

/*
Make Shapes: replaces the body's traced shapes with new ones from its sprite.

Returns:
- How many shapes were made, and "" or why none
*/
Trace_MakeShapes :: proc(project: ^Project, scene: ^SceneDef, body: int, settings: TraceSettings) -> (int, string) {
	if body < 0 || body >= len(scene.nodes) || !Node_IsBodyKind(scene.nodes[body].kind) do return 0, "Select a body"
	sprite := Trace_SpriteFor(scene, body, settings)
	if sprite < 0 do return 0, "Put a Sprite (or AnimatedSprite) with an image under the body"
	pieces, problem := Trace_Pieces(project, scene, body, sprite, settings)
	if problem != "" do return 0, problem
	// The earlier traced shapes go (direct children named Traced...), last first
	for i := body + 1 + Scene_DescendantCount(scene, body) - 1; i > body; i -= 1 {
		n := &scene.nodes[i]
		if n.parent == body && n.kind == .CollisionShape && strings.has_prefix(n.name, "Traced") do Scene_RemoveNode(scene, i)
	}
	for piece, i in pieces {
		index := Scene_InsertNode(scene, i == 0 ? "Traced" : fmt.tprintf("Traced%d", i + 1), .CollisionShape, body)
		shape := &scene.nodes[index]
		shape.shape = .Polygon
		clear(&shape.points)
		append(&shape.points, ..piece)
	}
	return len(pieces), ""
}

// Whether a node kind is a body with shapes (what a trace makes shapes for)
Node_IsBodyKind :: proc(kind: NodeKind) -> bool {
	#partial switch kind {
	case .StaticBody, .DynamicBody, .CharacterMover, .Area: return true
	}
	return false
}

/*
Handles the trace messages (Collision_Traced edits the scene: a `.Scene` undo step).

Returns:
- Whether the message was this file's
*/
TraceEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Trace_Setting_Changed:
		switch v.field {
		case .Threshold: s.trace.threshold = clamp(int(v.value), 1, 255)
		case .Detail:    s.trace.detail = clamp(v.value, 0, 32)
		}
	case Trace_Sprite_Chosen:
		s.trace.sprite = int(v)
	case Collision_Traced:
		scene := &s.project.scenes[s.currentScene]
		count, problem := Trace_MakeShapes(&s.project, scene, s.selectedNode, s.trace)
		if problem != "" {
			logLine(s, .Warning, fmt.aprintf("Collision from sprite: %s", problem))
		} else {
			logLine(s, .Info, fmt.aprintf("Collision from sprite: %d shape%s under %s", count, count == 1 ? "" : "s", scene.nodes[s.selectedNode].name))
		}
	case:
		return false
	}
	return true
}

/*
The Collision from sprite rows of a body's inspector: the sprite, the threshold, the detail, Make
Shapes. Keys `inspector-trace-sprite-<node>`, `inspector-trace-Threshold-<node>`,
`inspector-trace-Detail-<node>`, `inspector-trace-make-<node>`.
*/
traceInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, scene: ^SceneDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text("Collision from sprite", th.color.fg, th.font.size_sm))
	sprites := Trace_Sprites(scene, key)
	if len(sprites) == 0 {
		append(&rows, skald.text("Put a Sprite with an image under this body to make shapes that fit it.", th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
		return rows[:]
	}
	settings := s.trace
	if settings.threshold <= 0 do settings = DEFAULT_TRACE_SETTINGS
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, TRACE_SPRITE_FIRST)
	for i in sprites do append(&choices, Scene_NodePath(scene, key, i, context.temp_allocator))
	current := TRACE_SPRITE_FIRST
	for i in sprites do if i == settings.sprite do current = Scene_NodePath(scene, key, i, context.temp_allocator)
	Payload :: struct { sprites: []int, choices: []string }
	payload := Payload{sprites, choices[:]}
	append(&rows, inspectorRow(ctx, "Sprite", skald.select(ctx, current, choices[:], payload,
		proc(p: Payload, v: string) -> Msg {
			for c, i in p.choices do if c == v && i > 0 do return Trace_Sprite_Chosen(p.sprites[i - 1])
			return Trace_Sprite_Chosen(-1)
		}, id = skald.hash_id(fmt.tprintf("inspector-trace-sprite-%d", key)), width = controlWidth)))
	append(&rows,
		inspectorRow(ctx, "Alpha threshold", numberField(ctx, s, fmt.tprintf("inspector-trace-Threshold-%d", key), TraceNumber(.Threshold), f64(settings.threshold), 16, 0, numberWidth, 1, 255)),
		inspectorRow(ctx, "Detail", numberField(ctx, s, fmt.tprintf("inspector-trace-Detail-%d", key), TraceNumber(.Detail), f64(settings.detail), 0.5, 1, numberWidth, 0, 32)),
		inspectorRow(ctx, "", skald.button(ctx, "Make Shapes", Msg(Collision_Traced{}),
			id = skald.hash_id(fmt.tprintf("inspector-trace-make-%d", key)), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm)),
		skald.text("Traces the sprite's opaque pixels into polygon shapes under the body (replacing earlier traced ones). Detail: how far the outline may stray from the pixels; larger makes fewer, simpler shapes.",
			th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)),
	)
	return rows[:]
}
