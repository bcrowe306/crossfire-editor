package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The LDtkLevel inspector's read-only sections (ldtk_edit.odin has the settings): what the level
is, how the engine builds it, and what's in it. Every rule shown is the engine's own
(`e.LDtk_PlacedLevels`, `e.LDtk_EntityComponent`, `e.LDtk_IsCollisionValue`,
`e.LDtk_FieldMatches`), so the inspector says what the game does.

- Level: size (pixels, cells), world position, background, neighbours, its LDtk fields.
- How it's built: each layer in draw order and what it becomes (drawn tiles, auto-layer tiles,
  IntGrid colors, collision and from which values, entities).
- Entities: per type, how many, what each becomes and why (the mapped component, else code that
  spawns it, else its rectangle; the script it runs: the component's, else the one named like
  it), and which of its LDtk fields set which script fields.
- In the level: every entity with its position and fields; a click centers the viewport on it.

Widget keys: `inspector-ldtk-instances-toggle`, `inspector-ldtk-entity-<i>`.
*/

@(private="package")
ldtkLevelRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, project: ^e.LDtkProject, settings: ^e.LDtkLevelSettings, width: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	text :: proc(ctx: ^skald.Ctx(Msg), t: string, width: f32, color: skald.Color = {}) -> skald.View {
		c := color == {} ? ctx.theme.color.fg_muted : color
		return skald.text(t, c, ctx.theme.font.size_xs, max_width = width)
	}
	heading :: proc(ctx: ^skald.Ctx(Msg), t: string) -> skald.View {
		return uiSection(ctx.theme, uiTokens(ctx), t)
	}
	placed, _ := e.LDtk_PlacedLevels(project, settings^, context.temp_allocator)
	if len(placed) == 0 do return rows[:]

	// The level (or the world)
	append(&rows, heading(ctx, settings.allLevels ? fmt.tprintf("%s  World: %d levels", ICON_MAP, len(placed)) : fmt.tprintf("%s  Level", ICON_MAP)))
	for p in placed {
		level := p.level
		grid := 0
		for l in level.layers do if l.gridSize > 0 { grid = l.gridSize; break }
		cells := grid > 0 ? fmt.tprintf(" (%d x %d cells of %d px)", int(level.size.x) / grid, int(level.size.y) / grid, grid) : ""
		append(&rows, text(ctx, fmt.tprintf("%s: %.0f x %.0f px%s, at (%.0f, %.0f)", level.identifier, level.size.x, level.size.y, cells, p.position.x, p.position.y), width, th.color.fg))
		if !settings.allLevels {
			c := level.bgColor
			append(&rows, text(ctx, fmt.tprintf("Background #%02x%02x%02x%s", c.r, c.g, c.b, level.background.path != "" ? fmt.tprintf(", image %s", level.background.path) : ""), width))
			if len(level.neighbours) > 0 {
				names := make([dynamic]string, context.temp_allocator)
				for n in level.neighbours {
					other := e.LDtk_FindLevel(project, n.levelIid)
					append(&names, fmt.tprintf("%s (%s)", other != nil ? other.identifier : n.levelIid, n.dir))
				}
				append(&rows, text(ctx, fmt.tprintf("Neighbours: %s", strings.join(names[:], ", ", context.temp_allocator)), width))
			}
			// Its LDtk fields (scripts read them with e.LDtk_FieldValue)
			for f in level.fields {
				value, _ := e.LDtk_ValueText(f.value, grid)
				append(&rows, text(ctx, fmt.tprintf("%s = %s", f.identifier, value == "" ? "(none)" : value), width))
			}
		}
	}
	return rows[:]
}

@(private="package")
ldtkBuildRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, project: ^e.LDtkProject, settings: ^e.LDtkLevelSettings, width: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	text :: proc(ctx: ^skald.Ctx(Msg), t: string, width: f32, color: skald.Color = {}) -> skald.View {
		c := color == {} ? ctx.theme.color.fg_muted : color
		return skald.text(t, c, ctx.theme.font.size_xs, max_width = width)
	}
	placed, _ := e.LDtk_PlacedLevels(project, settings^, context.temp_allocator)
	if len(placed) == 0 do return rows[:]
	level := placed[0].level
	append(&rows, uiText(th, .Value, fmt.tprintf("%s  How it's built%s", ICON_LIST, settings.allLevels ? fmt.tprintf(" (as %s; every level alike)", level.identifier) : "")))
	append(&rows, text(ctx, "Its layers, bottom first (LDtk lists them top first):", width))
	#reverse for &layer in level.layers {
		what: string
		switch layer.type {
		case .Tiles:
			what = fmt.tprintf("tiles: drawn (%d tiles)", len(layer.tiles))
		case .AutoLayer:
			what = fmt.tprintf("auto-layer: drawn (%d tiles from its rules)", len(layer.tiles))
		case .IntGrid:
			cells := 0
			for v in layer.intGrid do if v != 0 do cells += 1
			drawn := len(layer.tiles) > 0 ? fmt.tprintf("its rules' %d tiles drawn", len(layer.tiles)) : "its values' colors drawn"
			if layer.identifier == settings.collisionLayer {
				counts: [e.LDtkCollisionKind]int
				for v in layer.intGrid do counts[e.LDtk_CollisionKind(settings, int(v))] += 1
				made := make([dynamic]string, context.temp_allocator)
				if counts[.Solid] > 0 do append(&made, fmt.tprintf("%d solid", counts[.Solid]))
				if counts[.One_Way] > 0 do append(&made, fmt.tprintf("%d one-way", counts[.One_Way]))
				if counts[.Area] > 0 do append(&made, fmt.tprintf("%d in areas", counts[.Area]))
				if len(made) == 0 do append(&made, "none")
				what = fmt.tprintf("IntGrid: %s; COLLISION: %s of its %d cells (%s)", drawn, strings.join(made[:], ", ", context.temp_allocator), cells, collisionValuesText(project, &layer, settings))
			} else {
				what = fmt.tprintf("IntGrid: %s; %d cells, no collision (pick it as Collision above)", drawn, cells)
			}
		case .Entities:
			what = settings.spawnEntities ? fmt.tprintf("entities: %d, made as below", len(layer.entities)) : fmt.tprintf("entities: %d, not made (Entities is off)", len(layer.entities))
		}
		notes := make([dynamic]string, context.temp_allocator)
		if layer.parallax != {} do append(&notes, fmt.tprintf("parallax %.2f, %.2f", layer.parallax.x, layer.parallax.y))
		if layer.opacity < 1 do append(&notes, fmt.tprintf("opacity %.0f%%", layer.opacity * 100))
		if !layer.visible do append(&notes, "hidden in LDtk")
		extra := len(notes) > 0 ? fmt.tprintf(" (%s)", strings.join(notes[:], ", ", context.temp_allocator)) : ""
		append(&rows, text(ctx, fmt.tprintf("•  %s — %s%s", layer.identifier, what, extra), width, layer.type == .IntGrid && layer.identifier == settings.collisionLayer ? th.color.fg : {}))
	}
	return rows[:]
}

// The collision values with their LDtk names and kinds: "1 Walls solid, 2 Platforms one-way"
@(private="file")
collisionValuesText :: proc(project: ^e.LDtkProject, layer: ^e.LDtkLayer, settings: ^e.LDtkLevelSettings) -> string {
	def := e.LDtk_FindLayerDef(project, layer.identifier)
	if def == nil do return "every value solid"
	KIND_WORDS := [e.LDtkCollisionKind]string{.None = "nothing", .Solid = "solid", .One_Way = "one-way", .Area = "an Area"}
	parts := make([dynamic]string, context.temp_allocator)
	for v in def.intGridValues {
		name := v.identifier != "" ? fmt.tprintf("%d %s", v.value, v.identifier) : fmt.tprint(v.value)
		append(&parts, fmt.tprintf("%s %s", name, KIND_WORDS[e.LDtk_CollisionKind(settings, v.value)]))
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

/*
What a level node makes of an entity type, as the engine does it (e.LDtk_EntityComponent's doc):
the node and why, the script it runs and why, and its LDtk fields against the script's fields.

Returns:
- The lines, and whether it'll be a bare rectangle without a script (worth a warning)
*/
LDtkEdit_EntityPlan :: proc(s: ^State, settings: ^e.LDtkLevelSettings, identifier: string, sample: ^e.LDtkEntity) -> (lines: []string, bare: bool) {
	out := make([dynamic]string, context.temp_allocator)
	rule := e.LDtk_EntityRule(settings, identifier)
	made := e.LDtk_EntityMade(settings, identifier)
	script := ""
	scriptWhy := ""
	componentScript := false
	switch made {
	case .Skip:
		append(&out, "→ nothing: its entities aren't made")
		return out[:], false
	case .Component:
		component := e.LDtk_EntityComponent(settings, identifier)
		append(&out, fmt.tprintf("→ component %s (%s)", ComponentName(component), rule.make == .Auto ? "mapped" : "chosen"))
		if i := Project_FindComponent(&s.project, component); i >= 0 && len(s.project.scenes[i].nodes) > 0 {
			script = NodeDef_Script(&s.project, &s.project.scenes[i].nodes[0])
			if script != "" do scriptWhy, componentScript = "the component's", true
		}
	case .Code:
		append(&out, "→ what code makes (e.LDtk_RegisterEntity); its rectangle, with a warning, if nothing registered it")
	case .Auto, .Rectangle:
		if rule.make == .Rectangle do append(&out, "→ its rectangle and tile (chosen)")
		else do append(&out, "→ its rectangle and tile (nothing mapped; code can make it instead: e.LDtk_RegisterEntity)")
	}
	if !componentScript {
		name, chosen := e.LDtk_EntityScript(settings, identifier, false)
		if name != "" && (chosen || ScriptCatalog_Find(&s.scripts, name) != nil) {
			script, scriptWhy = name, chosen ? "chosen" : "named like the entity"
		}
	}
	switch {
	case script != "":
		missing := s.scripts.status == .Ready && ScriptCatalog_Find(&s.scripts, script) == nil
		append(&out, fmt.tprintf("   runs script %s (%s)%s", script, scriptWhy, missing ? ", but no script has that name" : ""))
	case rule.noScript:
		append(&out, "   no script (chosen)")
	case s.scripts.status != .Ready && len(s.scriptFiles) > 0:
		append(&out, fmt.tprintf("   a script named %s would run on it (build the scripts to see)", identifier))
	case:
		append(&out, fmt.tprintf("   no script (one named %s would run on it)", identifier))
	}
	// Its fields: which script field each sets
	if sample != nil && len(sample.fields) > 0 {
		desc := script != "" ? ScriptCatalog_Find(&s.scripts, script) : nil
		parts := make([dynamic]string, context.temp_allocator)
		for f in sample.fields {
			target := ""
			if desc != nil do for field in desc.fields do if e.LDtk_FieldMatches(field.name, f.identifier) do target = field.name
			switch {
			case target != "": append(&parts, fmt.tprintf("%s → %s.%s", f.identifier, script, target))
			case desc != nil:  append(&parts, fmt.tprintf("%s (no script field)", f.identifier))
			case:              append(&parts, f.identifier)
			}
		}
		append(&out, fmt.tprintf("   fields: %s", strings.join(parts[:], ", ", context.temp_allocator)))
	}
	// A bare rectangle chosen on purpose isn't worth a warning
	return out[:], made != .Component && made != .Code && script == "" && rule.make == .Auto && !rule.noScript
}

// The level's entities: each with its position (in the node) and fields; a click frames it
@(private="package")
ldtkInstanceRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: int, project: ^e.LDtkProject, settings: ^e.LDtkLevelSettings, width: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	placed, _ := e.LDtk_PlacedLevels(project, settings^, context.temp_allocator)
	total := 0
	for p in placed do for l in p.level.layers do total += len(l.entities)
	if total == 0 do return rows[:]
	// The button first: rows in the inspector's scroll aren't width-limited, and a long heading
	// pushed it under the scrollbar in a narrow window, where it can't be clicked
	append(&rows, skald.row(
		skald.button(ctx, s.ldtkInstancesOpen ? "Hide" : "Show", Msg(LDtk_Instances_Toggled{}), id = skald.hash_id("inspector-ldtk-instances-toggle"),
			bg = th.color.surface, fg = th.color.fg, padding = {tk.s, tk.hair}, font_size = th.font.size_xs, radius = th.radius.sm),
		uiText(th, .Value, fmt.tprintf("%s  In the level: %d entities", ICON_LOCATION, total), max_width = width - tk.fieldXS),
		spacing = th.spacing.sm,
		cross_align = .Center,
	))
	if !s.ldtkInstancesOpen do return rows[:]
	scene := &s.project.scenes[s.currentScene]
	world := Scene_WorldTransforms(scene)[node]
	i := 0
	for p in placed do for l in p.level.layers do for &entity in l.entities {
		fields := make([dynamic]string, context.temp_allocator)
		for f in entity.fields {
			value, _ := e.LDtk_ValueText(f.value, l.gridSize)
			append(&fields, fmt.tprintf("%s=%s", f.identifier, value))
		}
		at := p.position + entity.px
		label := fmt.tprintf("%s  (%.0f, %.0f)%s%s", entity.identifier, at.x, at.y, len(placed) > 1 ? fmt.tprintf("  %s", p.level.identifier) : "",
			len(fields) > 0 ? fmt.tprintf("  %s", strings.join(fields[:], " ", context.temp_allocator)) : "")
		id := skald.hash_id(fmt.tprintf("inspector-ldtk-entity-%d", i))
		hovered := skald.widget_hovered(ctx, id)
		append(&rows, skald.clickable(ctx,
			skald.col(skald.text(label, hovered ? th.color.primary : th.color.fg_muted, th.font.size_xs, max_width = width), padding = tk.hair),
			Msg(LDtk_Entity_Framed(e.Transform2D_Apply(world, at))), id = id, focusable = false))
		i += 1
	}
	return rows[:]
}
