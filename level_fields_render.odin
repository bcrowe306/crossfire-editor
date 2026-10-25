package crossfire_editor

/*
Field values drawn on the Level mode's canvas, as LDtk's editor draws them (display/
FieldInstanceRender.hx, EntityRender.renderFields, WorldRender.renderFields; 1.5.3):

- **Which fields:** an entity's fields in its definition's order, grouped by `editorDisplayPos`
  (Above, Center, Beneath its box); a level's fields over the level. A field shows unless its
  `editorDisplayMode` is Hidden, or it's on its default (an empty array) without
  `editorAlwaysShow`; in the world view only fields with `editorShowInWorld`. A layer with
  `hideFieldsWhenInactive` hides them (and the entity's name) while another layer is selected;
  otherwise they're at the layer's inactive opacity then.
- **How** (`editorDisplayMode`): ValueOnly and NameAndValue ("name =") write the values
  (FieldInstance.getForDisplay: numbers with `editorTextPrefix` / `editorTextSuffix`, strings
  quoted and cut to 70 characters and two lines with `editorCutLongValues`, booleans as `+name` /
  `-name` when only the value shows, colors as a disc, tiles and enum values with an icon as the
  icon, references as `@(Type)` or `@(Type in Level)`, arrays comma-separated, strings, paths and
  references one a line); ArrayCountWithLabel / NoLabel the count; RadiusPx / RadiusGrid a circle
  around the pivot; RefLinkBetweenCenters / Pivots a link to each referenced entity in its
  `editorLinkStyle` (ZigZag, StraightArrow, CurvedArrow, ArrowsLine, DashedLine; cut short when the
  target is in another world or depth); Points, PointStar, PointPath, PointPathLoop a diamond per
  point and the lines between them.
- **Colors:** the field's `editorDisplayColor`, else the entity's (or level's) smart color; labels
  and values pulled toward white as LDtk does, outlined in its darker shade (LDtk's Outline style:
  its other, Table, is an app setting). Sizes are the screen's (LDtk scales by 1 / zoom), times
  the field's `editorDisplayScale`.

Not drawn: LDtk's value errors in red (a missing required value, a lost reference: the Level and
Entities tabs say so), its Table style.
*/

import "core:math"
import "core:strconv"
import "core:strings"
import "gui:skald"

// Where a field's row goes around its entity (`editorDisplayPos`)
LevelFieldPos :: enum u8 {
	Above,
	Center,
	Beneath,
}

// One value of a field's row: a text, a color disc, or an icon (a tileset image's rectangle)
LevelFieldItem :: struct {
	text: string,
	disc: bool,
	color: skald.Color,
	icon: string,
	iconSrc: [4]f32,
}

// A field's row: its label (none: only the value, centered), values, colors and scale
LevelFieldRow :: struct {
	pos: LevelFieldPos,
	label: string,
	items: []LevelFieldItem,
	// One value a line (strings, paths, references in an array)
	vertical: bool,
	labelColor, valueColor, outline: skald.Color,
	scale: f32,
}

// How a link ends (LDtk's LinkEndingStyle): whole, or cut short near its origin or its target
LevelLinkEnding :: enum u8 {
	Full,
	Cut_At_Origin,
	Cut_At_Target,
}

// A shape a field draws in the world (`from` / `to` / `radius` in world pixels)
LevelFieldMarkKind :: enum u8 {
	// A circle around `from`
	Radius,
	// A reference's link (renderRefLink: its ends pulled in by the style)
	Ref,
	// A line between points (renderSimpleLink)
	Line,
	// A point's diamond at `from`
	Point,
}

// A shape of a field: a radius, a link, a line or a point
LevelFieldMark :: struct {
	kind: LevelFieldMarkKind,
	from, to: [2]f32,
	radius: f32,
	color: skald.Color,
	style: string,
	ending: LevelLinkEnding,
}

// What an entity's or level's fields draw: rows of values, shapes, at an opacity
LevelFields :: struct {
	rows: []LevelFieldRow,
	marks: []LevelFieldMark,
	alpha: f32,
}

// Where an entity is, for the references to it (world pixels)
LevelFieldTarget :: struct {
	center, pivot: [2]f32,
	identifier, level: string,
	world, depth: int,
}

// LDtk's dn.Col.toWhite: `c` pulled `ratio` of the way to white
@(private="file")
toWhite :: proc(c: skald.Color, ratio: f32) -> skald.Color {
	return {c.r + (1 - c.r) * ratio, c.g + (1 - c.g) * ratio, c.b + (1 - c.b) * ratio, c.a}
}

// LDtk's dn.Col.toBlack
@(private="file")
toBlack :: proc(c: skald.Color, ratio: f32) -> skald.Color {
	return {c.r * (1 - ratio), c.g * (1 - ratio), c.b * (1 - ratio), c.a}
}

// createText's `col.lightness = 1`: the color at full brightness, its hue kept
@(private="file")
bright :: proc(c: skald.Color) -> skald.Color {
	m := max(c.r, c.g, c.b)
	if m <= 0 do return {1, 1, 1, c.a}
	return {c.r / m, c.g / m, c.b / m, c.a}
}

// A tileset's image path and a rectangle in it (from a tile's JSON: `tilesetUid`, `x`...)
@(private="file")
tileIcon :: proc(doc: ^LDtkDoc, json: ^JsonDoc, tile: int) -> (string, [4]f32, bool) {
	if Json_Kind(json, tile) != .Object do return "", {}, false
	main := LDtkDoc_Main(doc)
	td := LDtkDoc_DefByUid(doc, "tilesets", Json_Int(json, Json_Get(json, tile, "tilesetUid"), -1))
	rel := Json_String(main, Json_Get(main, td, "relPath"))
	if rel == "" do return "", {}, false
	src := [4]f32{f32(Json_Int(json, Json_Get(json, tile, "x"))), f32(Json_Int(json, Json_Get(json, tile, "y"))), f32(Json_Int(json, Json_Get(json, tile, "w"))), f32(Json_Int(json, Json_Get(json, tile, "h")))}
	return joinPath(LDtkDoc_Folder(doc), rel, allocator = context.temp_allocator), src, true
}

// A field definition's enum (its `type`: `F_Enum(uid)`), -1 for other types
@(private="file")
fieldEnumUid :: proc(main: ^JsonDoc, fd: int) -> int {
	t := Json_String(main, Json_Get(main, fd, "type"))
	if !strings.has_prefix(t, "F_Enum(") || !strings.has_suffix(t, ")") do return -1
	v, ok := strconv.parse_int(t[len("F_Enum("):len(t) - 1])
	return ok ? v : -1
}

/*
One value as LDtk's renderValue shows it (getForDisplay, the icons, the color disc).

Inputs:
- base: the field's text color
- here: the level the field's entity is in (a reference to another level names it)
*/
@(private="file")
fieldItem :: proc(doc: ^LDtkDoc, json: ^JsonDoc, fd, value: int, base: skald.Color, targets: map[string]LevelFieldTarget, here: string) -> LevelFieldItem {
	main := LDtkDoc_Main(doc)
	t := Json_String(main, Json_Get(main, fd, "__type"))
	if strings.has_prefix(t, "Array<") do t = t[len("Array<"):len(t) - 1]
	identifier := Json_String(main, Json_Get(main, fd, "identifier"))
	null := Json_Kind(json, value) == .Null || value < 0
	// Icons: tiles, and enum values with a tile
	if !null && t == "Tile" {
		if icon, src, ok := tileIcon(doc, json, value); ok do return {icon = icon, iconSrc = src}
	}
	if !null && (strings.has_prefix(t, "LocalEnum.") || strings.has_prefix(t, "ExternEnum.")) {
		ed := LDtkDoc_DefByUid(doc, "enums", fieldEnumUid(main, fd))
		v := Json_String(json, value)
		for ev in Json_Items(main, Json_Get(main, ed, "values")) {
			if Json_String(main, Json_Get(main, ev, "id")) != v do continue
			if icon, src, ok := tileIcon(doc, main, Json_Get(main, ev, "tileRect")); ok do return {icon = icon, iconSrc = src}
		}
	}
	if !null && t == "Color" {
		c, _ := LDtk_ParseColor(Json_String(json, value))
		return {disc = true, color = skald.rgb(u32(c))}
	}
	text: string
	switch {
	case null:
		text = "null"
	case t == "Int" || t == "Float":
		n, _ := Json_Number(json, value)
		text = strings.concatenate({Json_String(main, Json_Get(main, fd, "editorTextPrefix")), LDtk_JsNumber(n), Json_String(main, Json_Get(main, fd, "editorTextSuffix"))}, context.temp_allocator)
	case t == "Bool":
		b := Json_Bool(json, value)
		text = Json_String(main, Json_Get(main, fd, "editorDisplayMode")) == "ValueOnly" ? strings.concatenate({b ? "+" : "-", identifier}, context.temp_allocator) : (b ? "true" : "false")
	case t == "String" || t == "Multilines" || t == "FilePath":
		text = strings.concatenate({"\"", Json_String(json, value), "\""}, context.temp_allocator)
	case t == "Point":
		text = strings.concatenate({LDtk_JsNumber(Json_Float(json, Json_Get(json, value, "cx"))), ",", LDtk_JsNumber(Json_Float(json, Json_Get(json, value, "cy")))}, context.temp_allocator)
	case t == "EntityRef":
		target, found := targets[Json_String(json, Json_Get(json, value, "entityIid"))]
		name := "Lost reference!"
		if found do name = target.level == here ? target.identifier : strings.concatenate({target.identifier, " in ", target.level}, context.temp_allocator)
		text = strings.concatenate({"@(", name, ")"}, context.temp_allocator)
	case t == "Tile":
		text = strings.concatenate({LDtk_JsNumber(Json_Float(json, Json_Get(json, value, "x"))), ",", LDtk_JsNumber(Json_Float(json, Json_Get(json, value, "y")))}, context.temp_allocator)
	case:
		// Enums (without an icon) and anything else: as written
		text = Json_Kind(json, value) == .String ? Json_String(json, value) : Json_Text(json, value)
	}
	if !null && Json_Bool(main, Json_Get(main, fd, "editorCutLongValues"), true) {
		cut := text[:min(len(text), 70)]
		lines := strings.split(cut, "\n", context.temp_allocator)
		text = strings.join(lines[:min(2, len(lines))], "\n", context.temp_allocator)
	}
	return {text = text}
}

/*
The rows and shapes of one owner's fields (an entity's, else a level's), as FieldInstanceRender's
renderFields and renderField make them.

Inputs:
- defs: the field definitions (in order) and `instances` the owner's field instances, in `json`
- base: the owner's smart color
- entity: an entity's places (else nil: a level's fields, which draw no shapes)
- worldMode: the world view (only `editorShowInWorld` fields)

Returns:
- What to draw (temp allocated)
*/
LevelFields_Make :: proc(doc: ^LDtkDoc, json: ^JsonDoc, defs: []int, instances: int, base: skald.Color, worldMode: bool, entity: ^LevelFieldEntity, targets: map[string]LevelFieldTarget, here: string) -> LevelFields {
	main := LDtkDoc_Main(doc)
	rows := make([dynamic]LevelFieldRow, context.temp_allocator)
	marks := make([dynamic]LevelFieldMark, context.temp_allocator)
	for fd in defs {
		uid := Json_Int(main, Json_Get(main, fd, "uid"), -1)
		fi := -1
		for f in Json_Items(json, instances) do if Json_Int(json, Json_Get(json, f, "defUid"), -2) == uid do fi = f
		if fi < 0 do continue
		if worldMode && !Json_Bool(main, Json_Get(main, fd, "editorShowInWorld"), true) do continue
		mode := Json_String(main, Json_Get(main, fd, "editorDisplayMode"))
		if mode == "Hidden" do continue
		isArray := Json_Bool(main, Json_Get(main, fd, "isArray"))
		value := Json_Get(json, fi, "__value")
		values := isArray ? Json_Items(json, value) : []int{value}
		editor := Json_Get(json, fi, "realEditorValues")
		usingDefault := Json_Count(json, editor) == 0 || Json_Kind(json, Json_At(json, editor, 0)) == .Null
		always := Json_Bool(main, Json_Get(main, fd, "editorAlwaysShow"))
		if !always && (isArray && len(values) == 0 || !isArray && usingDefault) do continue
		color := base
		if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, fd, "editorDisplayColor"))); ok do color = skald.rgb(u32(c))
		identifier := Json_String(main, Json_Get(main, fd, "identifier"))
		row := LevelFieldRow{labelColor = bright(toWhite(color, 0.3)), valueColor = bright(toWhite(color, 0.25)), outline = toBlack(color, 0.66),
			scale = f32(Json_Float(main, Json_Get(main, fd, "editorDisplayScale"), 1))}
		row.outline.a = 0.6
		switch Json_String(main, Json_Get(main, fd, "editorDisplayPos")) {
		case "Center":  row.pos = .Center
		case "Beneath": row.pos = .Beneath
		}
		t := Json_String(main, Json_Get(main, fd, "__type"))
		if strings.has_prefix(t, "Array<") do t = t[len("Array<"):len(t) - 1]
		valueItems :: proc(doc: ^LDtkDoc, json: ^JsonDoc, fd: int, values: []int, isArray, always: bool, color: skald.Color, targets: map[string]LevelFieldTarget, here: string) -> []LevelFieldItem {
			items := make([dynamic]LevelFieldItem, context.temp_allocator)
			if isArray && len(values) == 0 && always do append(&items, LevelFieldItem{text = "--empty--"})
			for v, i in values {
				if !always && Json_Kind(json, v) == .Null do continue
				item := fieldItem(doc, json, fd, v, color, targets, here)
				if isArray && i < len(values) - 1 && item.text != "" do item.text = strings.concatenate({item.text, ","}, context.temp_allocator)
				append(&items, item)
			}
			return items[:]
		}
		switch mode {
		case "NameAndValue":
			row.label = strings.concatenate({identifier, " ="}, context.temp_allocator)
			row.items = valueItems(doc, json, fd, values, isArray, always, color, targets, here)
		case "ValueOnly":
			row.items = valueItems(doc, json, fd, values, isArray, always, color, targets, here)
		case "ArrayCountWithLabel", "ArrayCountNoLabel":
			if mode == "ArrayCountWithLabel" do row.label = strings.concatenate({identifier, ":"}, context.temp_allocator)
			row.labelColor, row.valueColor = bright(color), bright(color)
			items := make([]LevelFieldItem, 1, context.temp_allocator)
			items[0].text = strings.concatenate({LDtk_JsNumber(f64(len(values))), " value(s)"}, context.temp_allocator)
			row.items = items
		case "RadiusPx", "RadiusGrid":
			if entity == nil || len(values) == 0 do break
			n, _ := Json_Number(json, values[0])
			radius := f32(n)
			if mode == "RadiusGrid" do radius *= f32(entity.grid)
			append(&marks, LevelFieldMark{kind = .Radius, from = entity.pivot, radius = radius, color = {color.r, color.g, color.b, 0.33}})
		case "RefLinkBetweenCenters", "RefLinkBetweenPivots":
			if entity == nil do break
			centers := mode == "RefLinkBetweenCenters"
			for v in values {
				target, found := targets[Json_String(json, Json_Get(json, v, "entityIid"))]
				if !found do continue
				same := target.world == entity.world && target.depth == entity.depth
				append(&marks, LevelFieldMark{kind = .Ref, from = centers ? entity.center : entity.pivot, to = centers ? target.center : target.pivot,
					color = color, style = Json_String(main, Json_Get(main, fd, "editorLinkStyle")), ending = same ? .Full : .Cut_At_Origin})
			}
		case "Points", "PointStar", "PointPath", "PointPathLoop":
			if entity == nil do break
			style := Json_String(main, Json_Get(main, fd, "editorLinkStyle"))
			from := entity.pointOrigin
			start := from
			for v in values {
				if Json_Kind(json, v) != .Object do continue
				cell := [2]f32{f32(Json_Float(json, Json_Get(json, v, "cx"))), f32(Json_Float(json, Json_Get(json, v, "cy")))}
				to := entity.layerOrigin + {math.round((cell.x + 0.5) * f32(entity.grid)), math.round((cell.y + 0.5) * f32(entity.grid))}
				if mode != "Points" do append(&marks, LevelFieldMark{kind = .Line, from = from, to = to, color = color, style = style})
				append(&marks, LevelFieldMark{kind = .Point, from = to, color = color})
				if mode == "PointPath" || mode == "PointPathLoop" do from = to
			}
			if mode == "PointPathLoop" && len(values) > 1 do append(&marks, LevelFieldMark{kind = .Line, from = from, to = start, color = color, style = style})
		}
		if len(row.items) > 0 {
			row.vertical = isArray && (t == "String" || t == "Multilines" || t == "EntityRef")
			append(&rows, row)
		}
	}
	return {rows = rows[:], marks = marks[:], alpha = 1}
}

// An entity's places for its fields' shapes (world pixels): its pivot, center, the point fields'
// origin, its layer's origin and grid, its level's world and depth
LevelFieldEntity :: struct {
	pivot, center, pointOrigin, layerOrigin: [2]f32,
	grid, world, depth: int,
}

/*
Draws rows of fields around a box (screen pixels), as EntityRender.updateLayout places LDtk's
Above, Center and Beneath flows: centered on the box, Above's bottom at its top (over its name
when `nameShown`), Beneath's top at its bottom; labels right-aligned in one column before the
values.
*/
LevelFields_DrawRows :: proc(r: ^skald.Renderer, box: skald.Rect, rows: []LevelFieldRow, fontSize, alpha: f32, nameShown: bool) {
	for pos in LevelFieldPos {
		labelWidth, valueWidth, total: f32
		anyLabel := false
		Measured :: struct {
			label: f32,
			items: [dynamic]f32,
			width, height, line: f32,
		}
		measured := make([dynamic]Measured, context.temp_allocator)
		shown := make([dynamic]^LevelFieldRow, context.temp_allocator)
		for &row in rows {
			if row.pos != pos do continue
			size := fontSize * row.scale
			m := Measured{line = size + 2, items = make([dynamic]f32, context.temp_allocator)}
			if row.label != "" {
				m.label, _ = skald.measure_text(r, row.label, size)
				anyLabel = true
			}
			lines := f32(0)
			for item in row.items {
				w: f32
				h := size + 2
				switch {
				case item.icon != "":
					s := len(row.items) <= 1 ? size * 1.8 : size * 1.2
					w, h = s, s
				case item.disc:
					w, h = size, size
				case:
					for line in strings.split(item.text, "\n", context.temp_allocator) {
						lw, _ := skald.measure_text(r, line, size)
						w = max(w, lw)
					}
					h = f32(strings.count(item.text, "\n") + 1) * (size + 2)
				}
				append(&m.items, w)
				if row.vertical {
					m.width = max(m.width, w)
					lines += h + 4
				} else {
					m.width += w + (len(m.items) > 1 ? 2 : 0)
					lines = max(lines, h)
				}
			}
			m.height = max(lines, m.line)
			labelWidth = max(labelWidth, m.label)
			if row.label != "" do valueWidth = max(valueWidth, m.width)
			total += m.height
			append(&measured, m)
			append(&shown, &row)
		}
		if len(shown) == 0 do continue
		blockWidth := anyLabel ? labelWidth + 6 + valueWidth : 0
		for m in measured do blockWidth = max(blockWidth, (anyLabel ? labelWidth + 6 : 0) + m.width)
		y: f32
		switch pos {
		case .Above:
			y = box.y - total - (nameShown ? fontSize + 2 : 0)
		case .Center:
			y = box.y + (box.h - total) * 0.5
		case .Beneath:
			y = box.y + box.h
		}
		left := box.x + box.w * 0.5 - blockWidth * 0.5
		for row, i in shown {
			m := measured[i]
			size := fontSize * row.scale
			x := left
			if row.label != "" {
				outlinedText(r, row.label, x + labelWidth - m.label, y, row.labelColor, row.outline, size, alpha)
				x += labelWidth + 6
			} else {
				x = box.x + box.w * 0.5 - m.width * 0.5
			}
			ly := y
			for item, k in row.items {
				w := m.items[k]
				switch {
				case item.icon != "":
					s := w
					skald.draw_image_region(r, item.icon, {x, ly, s, s * item.iconSrc[3] / max(item.iconSrc[2], 1)}, {item.iconSrc[0], item.iconSrc[1], item.iconSrc[2], item.iconSrc[3]}, tint = {1, 1, 1, alpha})
				case item.disc:
					skald.draw_circle(r, {x + w * 0.5, ly + w * 0.5}, w * 0.5, {item.color.r, item.color.g, item.color.b, alpha}, aa = true)
					skald.draw_ring(r, {x + w * 0.5, ly + w * 0.5}, w * 0.5, 1, {0, 0, 0, 0.8 * alpha})
				case:
					for line, n in strings.split(item.text, "\n", context.temp_allocator) {
						outlinedText(r, line, x, ly + f32(n) * (size + 2), row.valueColor, row.outline, size, alpha)
					}
				}
				if row.vertical {
					ly += (item.icon != "" || item.disc ? w : f32(strings.count(item.text, "\n") + 1) * (size + 2)) + 4
				} else {
					x += w + 2
				}
			}
			y += m.height
		}
	}
}

// Text with LDtk's outline (h2d.filter.Outline: a darker shade around it)
@(private="file")
outlinedText :: proc(r: ^skald.Renderer, text: string, x, y: f32, color, outline: skald.Color, size, alpha: f32) {
	o := outline
	o.a *= alpha
	for d in ([4][2]f32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do drawTextTop(r, text, x + d.x, y + d.y, o, size)
	drawTextTop(r, text, x, y, {color.r, color.g, color.b, color.a * alpha}, size)
}

/*
Draws a field's shape (screen pixels: `toScreen` turns a world point into one, `zoom` the canvas's)
as FieldInstanceRender does: a radius's circle, a point's diamond, a link in its style.
*/
LevelFields_DrawMark :: proc(r: ^skald.Renderer, mark: LevelFieldMark, from, to: [2]f32, zoom, alpha: f32) {
	c := mark.color
	switch mark.kind {
	case .Radius:
		skald.draw_ring(r, from, mark.radius * zoom, 2, {c.r, c.g, c.b, c.a * alpha})
	case .Point:
		s := f32(4) * max(zoom, 1)
		pts := [][2]f32{{from.x, from.y - s}, {from.x + s, from.y}, {from.x, from.y + s}, {from.x - s, from.y}}
		dark := toBlack(c, 0.6)
		skald.draw_polygon(r, pts, {dark.r, dark.g, dark.b, alpha}, aa = true)
		closed := [][2]f32{pts[0], pts[1], pts[2], pts[3], pts[0]}
		skald.draw_polyline(r, closed, 1, {c.r, c.g, c.b, 0.66 * alpha}, aa = true)
	case .Ref:
		LevelFields_DrawLink(r, from, to, c, mark.style, mark.ending, alpha, true)
	case .Line:
		LevelFields_DrawLink(r, from, to, c, mark.style, .Full, alpha, false)
	}
}

/*
A link as LDtk's renderRefLink (`ref`: its ends pulled in for arrows) and renderSimpleLink draw it,
in screen pixels: ZigZag, StraightArrow, CurvedArrow, ArrowsLine or DashedLine, whole or cut short
(a 60 px stub with a bar across it).
*/
LevelFields_DrawLink :: proc(r: ^skald.Renderer, from, to: [2]f32, color: skald.Color, style: string, ending: LevelLinkEnding, alpha: f32, ref: bool) {
	f, t := from, to
	dist :: proc(a, b: [2]f32) -> f32 { d := b - a; return math.sqrt(d.x * d.x + d.y * d.y) }
	a := math.atan2(t.y - f.y, t.x - f.x)
	dir := [2]f32{math.cos(a), math.sin(a)}
	side := [2]f32{math.cos(a + math.PI * 0.5), math.sin(a + math.PI * 0.5)}
	col :: proc(c: skald.Color, alpha: f32) -> skald.Color { return {c.r, c.g, c.b, alpha} }
	if ref && ending == .Full {
		length := dist(f, t)
		switch style {
		case "ArrowsLine", "DashedLine":
			if length >= 12 {
				f += dir * 3
				t -= dir * 4
			}
		case "StraightArrow", "CurvedArrow":
			if length >= 20 do t -= dir * 4
		}
	}
	cut := min(f32(60), dist(f, t))
	switch ending {
	case .Full:
	case .Cut_At_Origin:
		t = f + dir * cut
		skald.draw_line(r, t - side * 4, t + side * 4, 1, col(color, 0.5 * alpha), aa = true)
	case .Cut_At_Target:
		f = t - dir * cut
		skald.draw_line(r, f - side * 4, f + side * 4, 1, col(color, alpha), aa = true)
	}
	length := dist(f, t)
	if length < 1 do return
	count := clamp(length / 4, 8, 30)
	dash := length / count
	n := int(math.ceil(count))
	switch style {
	case "ZigZag":
		sign := f32(1)
		p := f
		for i in 0 ..< n {
			ratio := f32(i) / max(count - 1, 1)
			start := min(ratio / 0.05, 1)
			q := f + dir * (f32(i) * dash) + side * sign * 2.1 * (1 - ratio) * start
			skald.draw_line(r, p, q, 2 - ratio, col(color, (0.3 + 0.7 * (1 - ratio)) * alpha), aa = true)
			p = q
			sign = -sign
		}
		skald.draw_line(r, p, t, 1, col(color, 0.3 * alpha), aa = true)
	case "ArrowsLine":
		step := f32(16)
		arrows := length / step
		for i := 0; f32(i) < arrows; i += 1 {
			ratio := f32(i) / max(arrows - 1, 1)
			p := f + dir * (f32(i) * step)
			c := col(color, (0.5 + 0.5 * (1 - ratio)) * alpha)
			w := 4 - 2 * ratio
			back := math.PI * f32(0.75)
			skald.draw_line(r, p + {math.cos(a + back), math.sin(a + back)} * 9, p, w, c, aa = true)
			skald.draw_line(r, p, p + {math.cos(a - back), math.sin(a - back)} * 9, w, c, aa = true)
		}
	case "DashedLine":
		p := f
		for i in 0 ..< n {
			ratio := f32(i) / max(count - 1, 1)
			skald.draw_line(r, p, p + dir * dash * 0.6, 4 - ratio * 2, col(color, (0.4 + 0.6 * (1 - ratio)) * alpha), aa = true)
			p = f + dir * (f32(i) * dash)
		}
	case "CurvedArrow", "StraightArrow":
		curved := style == "CurvedArrow"
		bend := clamp(length / 200, 2, 15)
		p := f
		last := a
		for i in 0 ..< n {
			ratio := f32(i) / max(count - 1, 1)
			q := f + dir * (f32(i) * dash)
			if curved do q += side * bend * math.sin(ratio * math.PI)
			if q != p do last = math.atan2(q.y - p.y, q.x - p.x)
			skald.draw_line(r, p, q, 1 + ratio * 3, col(color, (0.4 + 0.6 * ratio) * alpha), aa = true)
			p = q
		}
		head := f32(length <= 32 ? 10 : 12)
		ha := math.PI * f32(0.8)
		ang := curved ? last : a
		skald.draw_polygon(r, {p + {math.cos(ang + ha), math.sin(ang + ha)} * head, p + {math.cos(ang), math.sin(ang)} * 2, p + {math.cos(ang - ha), math.sin(ang - ha)} * head}, col(color, alpha), aa = true)
	case:
		skald.draw_line(r, f, t, 1.5, col(color, alpha), aa = true)
	}
}
