package crossfire_editor

import "core:fmt"
import "gui:skald"

/*
Navigation in the editor (the engine's navigation.odin): NavRegion nodes (where characters can
walk) and NavAgent nodes (path finders that move their parent).

- **Data:** `NodeDef.nav` is the engine's `e.NavSettings` (a plain value); a region's area is
  `shapeSize` (its Width and Height rows, the shape fields' messages), from its position (its
  top-left corner).
- **Messages:** `Nav_Setting_Changed{field, value, flag}`, a node step (numbers merge while typed).
- **Viewport:** a region is outlined; selected, its blocked cells are shaded (the preview builds
  its grid again every frame while it's selected, so moving a wall shows at once).
*/

// A navigation setting (`Nav_Setting_Changed`)
NavField :: enum {
	Cell_Size,
	Agent_Radius,
	Diagonal,
	Speed,
	Arrive_Distance,
	Avoid_Radius,
	Auto_Move,
}

// A change to the selected NavRegion's or NavAgent's settings
Nav_Setting_Changed :: struct {
	field: NavField,
	value: f64,
	flag: bool,
}

// The navigation number fields' target (number_field.odin)
NavNumberTarget :: distinct NavField

/*
Applies a navigation setting to the selected node.

Returns:
- Whether the message was this file's
*/
NavEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Nav_Setting_Changed)
	if !ok do return false
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return true
	n := &scene.nodes[s.selectedNode].nav
	x := f32(v.value)
	switch v.field {
	case .Cell_Size: n.cellSize = max(x, 1)
	case .Agent_Radius: n.agentRadius = max(x, 0)
	case .Diagonal: n.diagonal = v.flag
	case .Speed: n.speed = max(x, 0)
	case .Arrive_Distance: n.arriveDistance = max(x, 0)
	case .Avoid_Radius: n.avoidRadius = max(x, 0)
	case .Auto_Move: n.autoMove = v.flag
	}
	return true
}

/*
The inspector's rows for a NavRegion or a NavAgent.
*/
navInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	rows := make([dynamic]skald.View, context.temp_allocator)
	n := node.nav
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NavField, value: f32, step: f32, decimals: int, width: f32, lo: f64 = 0, hi: f64 = 100000) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-nav-%v-%d", field, key), NavNumberTarget(field), f64(value), f64(step), decimals, width, lo, hi)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), key: int, field: NavField, value: bool) -> skald.View {
		Payload :: struct { field: NavField }
		return skald.checkbox(ctx, value, "", Payload{field}, proc(p: Payload, v: bool) -> Msg { return Nav_Setting_Changed{field = p.field, flag = v} },
			id = skald.hash_id(fmt.tprintf("inspector-nav-%v-%d", field, key)))
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	if node.kind == .NavRegion {
		shape :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, width: f32) -> skald.View {
			return numberField(ctx, s, fmt.tprintf("inspector-%v-%d", field, key), field, f64(value), 16, 0, width, 1, 100000)
		}
		append(&rows, inspectorRow(ctx, "Area width", shape(ctx, s, key, .Shape_Width, node.shapeSize.x, numberWidth)))
		append(&rows, inspectorRow(ctx, "Area height", shape(ctx, s, key, .Shape_Height, node.shapeSize.y, numberWidth)))
		append(&rows, inspectorRow(ctx, "Cell size", number(ctx, s, key, .Cell_Size, n.cellSize, 1, 0, numberWidth, 1, 1000)))
		append(&rows, inspectorRow(ctx, "Agent radius", number(ctx, s, key, .Agent_Radius, n.agentRadius, 1, 0, numberWidth)))
		append(&rows, inspectorRow(ctx, "Diagonal moves", check(ctx, key, .Diagonal, n.diagonal)))
		columns := int(node.shapeSize.x / max(n.cellSize, 1) + 0.999)
		rowsCount := int(node.shapeSize.y / max(n.cellSize, 1) + 0.999)
		append(&rows, note(ctx, fmt.tprintf("%d x %d cells, from its position (its top-left corner). Static bodies' shapes block cells, grown by the agent radius; the shaded cells in the viewport are blocked.", columns, rowsCount), width))
	} else {
		append(&rows, inspectorRow(ctx, "Walk speed", number(ctx, s, key, .Speed, n.speed, 10, 0, numberWidth)))
		append(&rows, inspectorRow(ctx, "Arrive within", number(ctx, s, key, .Arrive_Distance, n.arriveDistance, 1, 0, numberWidth)))
		append(&rows, inspectorRow(ctx, "Keep apart", number(ctx, s, key, .Avoid_Radius, n.avoidRadius, 1, 0, numberWidth)))
		append(&rows, inspectorRow(ctx, "Move parent", check(ctx, key, .Auto_Move, n.autoMove)))
		scene := &s.project.scenes[s.currentScene]
		parent := node.parent >= 0 ? scene.nodes[node.parent].name : "nothing"
		append(&rows, note(ctx, fmt.tprintf("Moves %s along the paths it finds (scripts: e.NavAgent_SetTarget). It needs a NavRegion where it starts.", parent), width))
	}
	return rows[:]
}
