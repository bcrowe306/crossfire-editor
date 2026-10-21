package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
TileMap nodes in the editor (the engine's tilemap.odin builds them): the tilemap layers of an
Aseprite file, with collision from its tiles' properties.

- **Data:** `NodeDef.tilemap` is the engine's `e.TileMapSettings` (its strings owned); edits are one
  message, `TileMap_Setting_Changed`, each a node undo step.
- **Inspector:** the file (Aseprite files with tilemap layers first), the frame, each tilemap
  layer's checkbox (all off: every visible one, as the engine builds it), Collision, the
  generated bodies' layers and surface, and what each layer becomes: its grid, its tileset, how
  many tiles are solid, one-way and in which areas (`TileMapEdit_LayerInfo`, the engine's rules).
- **Viewport:** the engine builds it; its rebuild signature includes the file's time, so saving in
  Aseprite shows at once. Dropping an Aseprite file that has tilemap layers adds a TileMap
  (`Scene_AddTileMapAt`).

Widget keys: `inspector-tilemap-file-<node>`, `inspector-tilemap-frame-<node>`,
`inspector-tilemap-layer-<layer>-<node>`, `inspector-tilemap-collision-<node>`.
*/

// What a TileMap_Setting_Changed message changes
TileMapSettingField :: enum {
	// The file (text; TEXTURE_NONE for none)
	File,
	// The frame (value)
	Frame,
	// A layer's checkbox (name; flag)
	Layer,
	// Collision from the tiles' properties (flag)
	Collision,
}

TileMap_Setting_Changed :: struct {
	field: TileMapSettingField,
	text: string,
	value: f64,
	flag: bool,
}

// A copy of a TileMap's settings (owning its strings)
TileMapSettings_Clone :: proc(settings: e.TileMapSettings) -> e.TileMapSettings {
	copy := settings
	copy.file = strings.clone(settings.file)
	copy.layers = strings.clone(settings.layers)
	return copy
}

// Frees a TileMap's settings' strings
TileMapSettings_Destroy :: proc(settings: ^e.TileMapSettings) {
	delete(settings.file)
	delete(settings.layers)
}

// Whether an Aseprite file has tilemap layers (what a TileMap draws)
TileMapEdit_HasTilemaps :: proc(root, path: string) -> bool {
	if !e.Aseprite_IsFile(path) do return false
	ase := AsepriteEdit_File(root, path)
	if ase == nil do return false
	for layer in ase.layers do if layer.type == .Tilemap do return true
	return false
}

/*
Handles TileMap messages (the selected node's).

Returns:
- A command, and whether `m` was one of them
*/
TileMapEdit_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	v, ok := m.(TileMap_Setting_Changed)
	if !ok do return {}, false
	node := selectedNode(state)
	if node == nil || node.kind != .TileMap do return {}, true
	settings := &node.tilemap
	switch v.field {
	case .File:
		delete(settings.file)
		settings.file = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
		// Another file's layers have other names
		delete(settings.layers)
		settings.layers = strings.clone("")
	case .Frame:
		settings.frame = max(int(v.value), 0)
	case .Collision:
		settings.collision = v.flag
	case .Layer:
		// From the layers it builds now (none named: every visible one), with this one ticked or not
		ase := AsepriteEdit_File(state.project.rootPath, settings.file)
		if ase == nil do break
		names := make([dynamic]string, context.temp_allocator)
		for layer, i in ase.layers {
			if layer.type != .Tilemap do continue
			on := layer.name == v.text ? v.flag : TileMapEdit_LayerBuilt(settings, ase, i)
			if on do append(&names, layer.name)
		}
		// It draws something: the last layer stays
		if len(names) == 0 {
			logLine(state, .Warning, fmt.aprintf("%s keeps %s: a TileMap draws at least one layer", node.name, v.text))
			break
		}
		delete(settings.layers)
		settings.layers = strings.join(names[:], ",")
	}
	return {}, true
}

// Whether a TileMap builds a layer: named in its settings, or (none named) shown in Aseprite
TileMapEdit_LayerBuilt :: proc(settings: ^e.TileMapSettings, ase: ^e.Aseprite, layer: int) -> bool {
	if settings.layers == "" do return e.Aseprite_LayerShown(ase, layer)
	for name in strings.split(settings.layers, ",", context.temp_allocator) do if strings.trim_space(name) == ase.layers[layer].name do return true
	return false
}

/*
What a tilemap layer becomes, as the engine builds it: its grid and tileset, and its tiles'
collision ("40 x 12 tiles of 16 x 16 (Terrain, 24 tiles): 120 solid, 8 one-way, 6 in spikes").

Returns:
- The line (temp allocated)
*/
TileMapEdit_LayerInfo :: proc(ase: ^e.Aseprite, layer, frame: int) -> string {
	l := &ase.layers[layer]
	if l.tileset < 0 || l.tileset >= len(ase.tilesets) do return "no tileset"
	tileset := &ase.tilesets[l.tileset]
	cel := e.Aseprite_Cel(ase, clamp(frame, 0, max(len(ase.frames) - 1, 0)), layer)
	if cel == nil do return fmt.tprintf("empty in this frame (%s, %d tiles of %d x %d)", tileset.name, tileset.count - 1, tileset.tileWidth, tileset.tileHeight)
	solid, oneWay, placed := 0, 0, 0
	areas := make(map[string]int, 0, context.temp_allocator)
	for tile in cel.tiles {
		if tile & e.ASEPRITE_TILE_ID == 0 do continue
		placed += 1
		kind, area := e.TileMap_TileCollision(tileset, tile)
		switch kind {
		case .Solid:   solid += 1
		case .One_Way: oneWay += 1
		case .Area:    areas[area == "" ? "Area" : area] += 1
		case .None:
		}
	}
	parts := make([dynamic]string, context.temp_allocator)
	if solid > 0 do append(&parts, fmt.tprintf("%d solid", solid))
	if oneWay > 0 do append(&parts, fmt.tprintf("%d one-way", oneWay))
	for name, count in areas do append(&parts, fmt.tprintf("%d in %s", count, name))
	collision := len(parts) > 0 ? strings.join(parts[:], ", ", context.temp_allocator) : "no collision (give tiles a collision property in Aseprite)"
	return fmt.tprintf("%d x %d tiles of %d x %d (%s, %d tiles), %d placed: %s", cel.width, cel.height, tileset.tileWidth, tileset.tileHeight,
		tileset.name == "" ? "its tileset" : tileset.name, tileset.count - 1, placed, collision)
}

// The inspector's TileMap rows
tileMapInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := &node.tilemap
	small :: proc(ctx: ^skald.Ctx(Msg), text: string, color: skald.Color, width: f32) -> skald.View {
		return skald.text(text, color, ctx.theme.font.size_xs, max_width = width)
	}
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	// Aseprite files with tilemap layers, then the other ones
	files := make([dynamic]string, context.temp_allocator)
	append(&files, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Image && TileMapEdit_HasTilemaps(s.project.rootPath, asset.path) do append(&files, asset.path)
	for asset in s.project.assets do if asset.kind == .Image && e.Aseprite_IsFile(asset.path) && !TileMapEdit_HasTilemaps(s.project.rootPath, asset.path) do append(&files, asset.path)
	append(&rows, inspectorRow(ctx, "Tilemap file", skald.select(ctx, settings.file == "" ? TEXTURE_NONE : settings.file, files[:],
		proc(v: string) -> Msg { return TileMap_Setting_Changed{field = .File, text = v} },
		id = skald.hash_id(fmt.tprintf("inspector-tilemap-file-%d", key)), width = controlWidth)))
	if len(files) == 1 do append(&rows, small(ctx, "No Aseprite files yet: import one with tilemap layers (File > Import Asset).", th.color.fg_muted, width))
	if settings.file == "" do return rows[:]
	ase := AsepriteEdit_File(s.project.rootPath, settings.file)
	if ase == nil {
		append(&rows, small(ctx, fmt.tprintf("%s can't be read.", settings.file), th.color.warning, width))
		return rows[:]
	}
	if len(ase.frames) > 1 {
		append(&rows, inspectorRow(ctx, "Frame", numberField(ctx, s, fmt.tprintf("inspector-tilemap-frame-%d", key), TileMapFrameTarget{}, f64(settings.frame), 1, 0, numberWidth, 0, f64(len(ase.frames) - 1))))
	}
	// Its tilemap layers: built or not, and what each becomes
	count := 0
	for layer, i in ase.layers do if layer.type == .Tilemap {
		count += 1
		built := TileMapEdit_LayerBuilt(settings, ase, i)
		name := strings.clone(layer.name, context.temp_allocator)
		append(&rows, skald.checkbox(ctx, built, layer.visible ? name : fmt.tprintf("%s (hidden in Aseprite)", name), name,
			proc(name: string, on: bool) -> Msg { return TileMap_Setting_Changed{field = .Layer, text = name, flag = on} },
			id = skald.hash_id(fmt.tprintf("inspector-tilemap-layer-%s-%d", layer.name, key))))
		append(&rows, small(ctx, TileMapEdit_LayerInfo(ase, i, settings.frame), built ? th.color.fg_muted : th.color.border, width))
	}
	if count == 0 {
		append(&rows, small(ctx, fmt.tprintf("%s has no tilemap layers: make one in Aseprite (Layer > New > New Tilemap Layer).", filepath.base(settings.file)), th.color.warning, width))
		return rows[:]
	}
	if settings.layers == "" do append(&rows, small(ctx, "None ticked: every layer visible in Aseprite.", th.color.fg_muted, width))
	append(&rows, inspectorRow(ctx, "Tile collision", skald.checkbox(ctx, settings.collision, "", proc(on: bool) -> Msg { return TileMap_Setting_Changed{field = .Collision, flag = on} },
		id = skald.hash_id(fmt.tprintf("inspector-tilemap-collision-%d", key)))))
	if settings.collision {
		append(&rows, small(ctx, "Tiles with a collision property (solid, one-way, area) or an area name become a StaticBody and Areas.", th.color.fg_muted, width))
		append(&rows, ..bodySurfaceRows(ctx, s, node, key, controlWidth, numberWidth))
	}
	return rows[:]
}

// A number field target: the TileMap's frame
TileMapFrameTarget :: struct {}

/*
Adds a TileMap of an Aseprite file, named after it, as a child of `parent` (the selection; -1 for
the top level) with its top-left corner at a point in the world.

Returns:
- The new node's index
*/
Scene_AddTileMapAt :: proc(scene: ^SceneDef, path: string, parent: int, world: [2]f32) -> int {
	parent := parent
	if parent >= len(scene.nodes) do parent = -1
	parent = Scene_ParentFor(scene, parent)
	name := filepath.stem(filepath.base(path))
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, name == "" ? "TileMap" : name), .TileMap, parent)
	node := &scene.nodes[index]
	delete(node.tilemap.file)
	node.tilemap.file = strings.clone(path)
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	node.position = {f32(int(local.x)), f32(int(local.y))}
	return index
}
