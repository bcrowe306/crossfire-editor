#!/usr/bin/env python3
"""Makes the Level mode's painting fixture (tests/fixtures/ldtk_paint/), from LDtk's JSON schema 1.5.3.

    python3 tests/fixtures/ldtk_paint/make_paint.py

paint.ldtk: one Free world, two levels:
- Room (320 x 192, 20 x 12 cells of 16 px): empty, every layer, for painting from nothing.
- Hall (256 x 128): tiles in Decor, a few IntGrid cells in Ground (no auto-layer tiles yet), entities.

Layers, top first:
- Entities (Entities)
- Decor (Tiles, tileset Tiles)
- Ground (IntGrid with the tileset: an auto-layer): values grass 1, stone 2 and dirt 3 (group
  Solid), water 4; rule groups Surface (grass's top edge with random tiles and a 30% chance, grass,
  any Solid value by its group, water at 70% alpha that doesn't break on match, a wall at the
  level's left edge with an out-of-bounds value, a mirrored corner) and Flowers (optional, turned
  on in Room: a 2x2 stamp over grass where nothing is above, with a Perlin mask)
- Shade (AutoLayer of Ground, its tiles killed by Decor's): a half-transparent shadow under Solid
  values, every other column (a modulo with a checker)

Entities: Hero (fields: speed, a target that chains, a path of points, a home point), Box
(resizable, 16 to 96 px), Coin (2 per level, the oldest discarded; in the table of contents),
Key (1 per layer, more refused), Flag (1 per level, the last one moved; drawn by its tile), Link
(an array of references and a symmetrical one).

tiles.png (128 x 64, 8 x 4 tiles of 16 px) is generated: tiles 0-15 opaque, 16-31 with transparent
pixels (so tile stacking and break-on-match locks are both exercised).

The JSON is written as LDtk writes it (its JsonPretty "Compact" layout, ported below), so a value
the editor writes back reads the same as the rest of the file.
"""

import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GRID = 16
HEADER = {
	"fileType": "LDtk Project JSON", "app": "LDtk", "doc": "https://ldtk.io/json",
	"schema": "https://ldtk.io/files/JSON_SCHEMA.json", "appAuthor": "Sebastien 'deepnight' Benard",
	"appVersion": "1.5.3", "url": "https://ldtk.io",
}


# --- LDtk's JsonPretty (deepnightLibs dn.data.JsonPretty), Compact ---------------------------------

def _is_num(v):
	return isinstance(v, (int, float)) and not isinstance(v, bool)


def _num(v):
	if isinstance(v, float) and v == int(v) and abs(v) < 2**31:
		return str(int(v))
	if isinstance(v, float):
		return repr(v)
	return str(v)


def _length(v, depth=0):
	if v is None: return 4
	if isinstance(v, bool): return 4 if v else 5
	if isinstance(v, int): return 4
	if isinstance(v, float): return 4 if v == int(v) else 5
	if isinstance(v, str): return len(v) + 2
	if isinstance(v, dict):
		if depth <= 0 and len(v) <= 5:
			return sum(_length(x, depth + 1) for x in v.values())
		return len(v) * 10
	if isinstance(v, list):
		if not v: return 2
		if len(v) < 50 and _is_num(v[0]): return len(v)
		if len(v) > 5 or depth > 0: return 99
		return sum(_length(x, depth + 1) for x in v)
	return 1


def pretty(v, indent=0, header=None):
	out = []

	def value(v, ind, force=False):
		if v is None: out.append("null")
		elif isinstance(v, bool): out.append("true" if v else "false")
		elif _is_num(v): out.append(_num(v))
		elif isinstance(v, str): out.append('"' + v.replace("\n", " ").replace("\r", "").replace("\t", " ").replace('"', '\\"') + '"')
		elif isinstance(v, list): array(v, ind, force)
		elif isinstance(v, dict): obj(v, ind, force)

	def obj(o, ind, force):
		if not o:
			out.append("{}")
			return
		if _length(o) <= 85 and not force:
			out.append("{ ")
			for i, (k, x) in enumerate(o.items()):
				out.append('"%s": ' % k)
				value(x, ind)
				if i < len(o) - 1: out.append(", ")
			out.append(" }")
			return
		out.append("{\n")
		for i, (k, x) in enumerate(o.items()):
			out.append("\t" * (ind + 1) + '"%s": ' % k)
			value(x, ind + 1, k == "__header__")
			if i < len(o) - 1: out.append(",\n")
		out.append("\n" + "\t" * ind + "}")

	def array(a, ind, force):
		if not a:
			out.append("[]")
			return
		if _is_num(a[0]) and not force and len(a) > 85:
			out.append("[\n" + "\t" * (ind + 1))
			line = 0
			for i, x in enumerate(a):
				value(x, ind + 1)
				if i < len(a) - 1: out.append(",")
				line += 1
				if line >= 35:
					out.append("\n" + "\t" * (ind + 1))
					line = 0
			out.append("\n" + "\t" * ind + "]")
			return
		if _length(a) <= 85 and not force:
			if _is_num(a[0]): space = ""
			elif isinstance(a[0], bool): space = "" if len(a) > 5 else " "
			else: space = "" if len(a) == 1 else " "
			out.append("[" + space)
			for i, x in enumerate(a):
				value(x, ind)
				if i < len(a) - 1: out.append("," + space)
			out.append(space + "]")
			return
		out.append("[\n")
		for i, x in enumerate(a):
			out.append("\t" * (ind + 1))
			value(x, ind + 1)
			if i < len(a) - 1: out.append(",\n")
		out.append("\n" + "\t" * ind + "]")

	value(v, indent, True)
	return "".join(out)


# --- The tileset ------------------------------------------------------------------------------------

def png(path, w, h, pixels):
	raw = b"".join(b"\x00" + bytes(pixels[y * w * 4:(y + 1) * w * 4]) for y in range(h))
	def chunk(kind, data):
		return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
	data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
	tmp = path + ".tmp"
	with open(tmp, "wb") as f:
		f.write(data)
	os.replace(tmp, path)


def tileset():
	w, h = 128, 64
	px = [0] * (w * h * 4)
	colors = [(80, 160, 70), (60, 140, 60), (100, 180, 80), (90, 120, 60), (130, 130, 140), (110, 110, 120), (60, 110, 200), (150, 90, 60),
		(230, 200, 60), (240, 120, 160), (200, 220, 240), (170, 120, 80), (90, 90, 90), (200, 60, 60), (60, 200, 200), (160, 80, 200)]
	for tile in range(32):
		tx, ty = (tile % 8) * GRID, (tile // 8) * GRID
		r, g, b = colors[tile % 16]
		for y in range(GRID):
			for x in range(GRID):
				a = 255
				if tile >= 16:
					# A shape on a transparent tile: a diamond, or (shadows, 24-31) half alpha
					a = 255 if abs(x - 7.5) + abs(y - 7.5) <= 7 else 0
					if tile >= 24: a = 128
				edge = x == 0 or y == 0
				i = ((ty + y) * w + tx + x) * 4
				px[i:i + 4] = [max(r - 30, 0) if edge else r, max(g - 30, 0) if edge else g, max(b - 30, 0) if edge else b, a]
	png(os.path.join(HERE, "tiles.png"), w, h, px)
	opaque = "".join("1" if t < 16 else "0" for t in range(32))
	return opaque


# --- The project ----------------------------------------------------------------------------------

def rule(uid, pattern, tiles, size=3, chance=1, break_on_match=True, alpha=1, flip_x=False, flip_y=False, oob=None, mode="Single",
		pivot=(0, 0), x_mod=1, y_mod=1, checker="None", perlin=False, perlin_seed=0):
	return {
		"uid": uid, "active": True, "size": size, "tileRectsIds": tiles, "alpha": alpha, "chance": chance,
		"breakOnMatch": break_on_match, "pattern": pattern, "flipX": flip_x, "flipY": flip_y, "xModulo": x_mod,
		"yModulo": y_mod, "xOffset": 0, "yOffset": 0, "tileXOffset": 0, "tileYOffset": 0, "tileRandomXMin": 0,
		"tileRandomXMax": 0, "tileRandomYMin": 0, "tileRandomYMax": 0, "checker": checker, "tileMode": mode,
		"pivotX": pivot[0], "pivotY": pivot[1], "outOfBoundsValue": oob, "invalidated": False,
		"perlinActive": perlin, "perlinSeed": perlin_seed, "perlinScale": 0.2, "perlinOctaves": 2,
	}


def group(uid, name, rules, optional=False):
	return {"uid": uid, "name": name, "color": None, "icon": None, "active": True, "isOptional": optional, "rules": rules,
		"usesWizard": False, "requiredBiomeValues": [], "biomeRequirementMode": 0}


def layer_def(uid, identifier, kind, tileset=None, values=None, groups=None, source=None, killed=None, value_groups=None, inactive=1):
	return {
		"__type": kind, "identifier": identifier, "type": kind, "uid": uid, "doc": None, "uiColor": None, "gridSize": GRID,
		"guideGridWid": 0, "guideGridHei": 0, "displayOpacity": 1, "inactiveOpacity": inactive, "hideInList": False,
		"hideFieldsWhenInactive": False, "canSelectWhenInactive": True, "renderInWorldView": True, "pxOffsetX": 0,
		"pxOffsetY": 0, "parallaxFactorX": 0, "parallaxFactorY": 0, "parallaxScaling": True, "requiredTags": [],
		"excludedTags": [], "autoTilesKilledByOtherLayerUid": killed, "uiFilterTags": [], "useAsyncRender": False,
		"intGridValues": values or [], "intGridValuesGroups": value_groups or [], "autoRuleGroups": groups or [],
		"autoSourceLayerDefUid": source, "tilesetDefUid": tileset, "tilePivotX": 0, "tilePivotY": 0, "biomeFieldUid": None,
	}


def field_def(uid, identifier, ftype, json_type, default=None, can_be_null=True, toc=False, refs="Any", array=False, chain=False, symmetrical=False):
	return {
		"identifier": identifier, "doc": None, "__type": json_type, "uid": uid, "type": ftype, "isArray": array,
		"canBeNull": can_be_null, "arrayMinLength": None, "arrayMaxLength": None, "editorDisplayMode": "RefLinkBetweenCenters" if ftype == "F_EntityRef" else ("PointPath" if ftype == "F_Point" else "ValueOnly"),
		"editorDisplayScale": 1, "editorDisplayPos": "Above", "editorLinkStyle": "CurvedArrow", "editorDisplayColor": None,
		"editorAlwaysShow": False, "editorShowInWorld": True, "editorCutLongValues": True, "editorTextSuffix": None,
		"editorTextPrefix": None, "useForSmartColor": False, "exportToToc": toc, "searchable": False, "min": None, "max": None,
		"regex": None, "acceptFileTypes": None, "defaultOverride": default, "textLanguageMode": None, "symmetricalRef": symmetrical,
		"autoChainRef": chain, "allowOutOfLevelRef": True, "allowedRefs": refs, "allowedRefsEntityUid": None,
		"allowedRefTags": [], "tilesetUid": None,
	}


def entity_def(uid, identifier, color, w, h, pivot, fields=(), resizable=False, max_count=0, scope="PerLevel", behavior="MoveLastOne",
		toc=False, render="Rectangle", tile=None, min_size=None, max_size=None):
	return {
		"identifier": identifier, "uid": uid, "tags": [], "exportToToc": toc, "allowOutOfBounds": False, "doc": None,
		"width": w, "height": h, "resizableX": resizable, "resizableY": resizable,
		"minWidth": min_size, "maxWidth": max_size, "minHeight": min_size, "maxHeight": max_size,
		"keepAspectRatio": False, "tileOpacity": 1, "fillOpacity": 0.4, "lineOpacity": 1, "hollow": False, "color": color,
		"renderMode": render, "showName": True, "tilesetId": 10 if tile else None, "tileRenderMode": "FitInside", "tileRect": tile,
		"uiTileRect": None, "nineSliceBorders": [], "maxCount": max_count, "limitScope": scope, "limitBehavior": behavior,
		"pivotX": pivot[0], "pivotY": pivot[1], "fieldDefs": list(fields),
	}


def main():
	opaque = tileset()
	ANY = 1000001
	SOLID = 2000  # group 1's rule value: (uid + 1) * 1000
	surface = group(50, "Surface", [
		# Grass's top edge: random tiles at 30%, then grass, a solid value by its group
		rule(51, [0, -1, 0, 0, 1, 0, 0, 0, 0], [[0], [1], [2]], chance=0.3),
		rule(52, [0, 0, 0, 0, 1, 0, 0, 0, 0], [[3]], size=3),
		rule(53, [0, 0, 0, 0, SOLID, 0, 0, 0, 0], [[4], [5]]),
		# Water: 70% alpha, doesn't break on match (the next rule may add under it)
		rule(54, [0, 0, 0, 0, 4, 0, 0, 0, 0], [[6]], alpha=0.7, break_on_match=False),
		# A wall at the level's left edge: the outside counts as stone
		rule(55, [0, 0, 0, 2, ANY, 0, 0, 0, 0], [[7]], oob=2),
		# A corner, mirrored
		rule(56, [0, -ANY, 0, -ANY, 3, 0, 0, 0, 0], [[11]], flip_x=True, break_on_match=False),
	])
	flowers = group(60, "Flowers", [
		rule(61, [0, -ANY, 0, 0, 1, 0, 0, 0, 0], [[8, 9, 16, 17]], mode="Stamp", pivot=(0, 1), break_on_match=False, perlin=True, perlin_seed=1234567),
	], optional=True)
	shade = group(70, "Shade", [
		rule(71, [0, SOLID, 0, 0, -ANY, 0, 0, 0, 0], [[24], [25]], alpha=0.5, x_mod=2, y_mod=2, checker="Horizontal", break_on_match=True),
	])
	values = [
		{"value": 1, "identifier": "grass", "color": "#55AA44", "tile": None, "groupUid": 0},
		{"value": 2, "identifier": "stone", "color": "#8C8C99", "tile": None, "groupUid": 1},
		{"value": 3, "identifier": "dirt", "color": "#8B5A2B", "tile": None, "groupUid": 1},
		{"value": 4, "identifier": "water", "color": "#3070D0", "tile": None, "groupUid": 0},
	]
	layers = [
		layer_def(1, "Entities", "Entities", inactive=0.6),
		layer_def(2, "Decor", "Tiles", tileset=10),
		layer_def(3, "Ground", "IntGrid", tileset=10, values=values, groups=[surface, flowers],
			value_groups=[{"uid": 1, "identifier": "Solid", "color": "#808080"}]),
		layer_def(4, "Shade", "AutoLayer", tileset=10, groups=[shade], source=3, killed=2),
	]
	path_point = field_def(31, "path", "F_Point", "Array<Point>", array=True)
	hero = entity_def(20, "Hero", "#5BC0EB", 16, 32, (0.5, 1), fields=[
		field_def(30, "speed", "F_Float", "Float", {"id": "V_Float", "params": [100]}, can_be_null=False),
		field_def(32, "target", "F_EntityRef", "EntityRef", chain=True),
		path_point,
		field_def(33, "home", "F_Point", "Point"),
	])
	box = entity_def(21, "Box", "#C08040", 32, 32, (0, 0), resizable=True, min_size=16, max_size=96)
	coin = entity_def(22, "Coin", "#FFD700", 8, 8, (0.5, 0.5), max_count=2, scope="PerLevel", behavior="DiscardOldOnes", toc=True,
		fields=[field_def(34, "value", "F_Int", "Int", {"id": "V_Int", "params": [1]}, can_be_null=False, toc=True)])
	key = entity_def(23, "Key", "#E0E040", 16, 16, (0.5, 0.5), max_count=1, scope="PerLayer", behavior="PreventAdding")
	flag = entity_def(24, "Flag", "#E04040", 16, 16, (0.5, 1), max_count=1, scope="PerLevel", behavior="MoveLastOne", render="Tile",
		tile={"tilesetUid": 10, "x": 0, "y": 16, "w": 16, "h": 16})
	link = entity_def(25, "Link", "#A070E0", 16, 16, (0.5, 0.5), fields=[
		field_def(35, "next", "F_EntityRef", "Array<EntityRef>", array=True),
		field_def(36, "mate", "F_EntityRef", "EntityRef", refs="OnlySame", symmetrical=True),
	])
	tileset_def = {
		"__cWid": 8, "__cHei": 4, "identifier": "Tiles", "uid": 10, "relPath": "tiles.png", "embedAtlas": None,
		"pxWid": 128, "pxHei": 64, "tileGridSize": GRID, "spacing": 0, "padding": 0, "tags": [], "tagsSourceEnumUid": None,
		"enumTags": [], "customData": [], "savedSelections": [], "cachedPixelData": {"opaqueTiles": opaque, "averageColors": "f888" * 32},
	}
	defs = {"layers": layers, "entities": [hero, box, coin, key, flag, link], "tilesets": [tileset_def], "enums": [], "externalEnums": [], "levelFields": []}

	def layer_instance(level_iid, uid, li_def, cw, ch, seed, optional=()):
		return {
			"__identifier": li_def["identifier"], "__type": li_def["type"], "__cWid": cw, "__cHei": ch, "__gridSize": GRID,
			"__opacity": 1, "__pxTotalOffsetX": 0, "__pxTotalOffsetY": 0,
			"__tilesetDefUid": li_def["tilesetDefUid"], "__tilesetRelPath": "tiles.png" if li_def["tilesetDefUid"] else None,
			"iid": "%s-%s" % (level_iid, li_def["identifier"].lower()), "levelId": uid, "layerDefUid": li_def["uid"], "pxOffsetX": 0,
			"pxOffsetY": 0, "visible": True, "optionalRules": list(optional),
			"intGridCsv": [0] * (cw * ch) if li_def["type"] == "IntGrid" else [],
			"autoLayerTiles": [], "seed": seed, "overrideTilesetUid": None, "gridTiles": [], "entityInstances": [],
		}

	def level(identifier, iid, uid, x, w, h, optional=()):
		cw, ch = w // GRID, h // GRID
		return {
			"identifier": identifier, "iid": iid, "uid": uid, "worldX": x, "worldY": 0, "worldDepth": 0, "pxWid": w, "pxHei": h,
			"__bgColor": "#40465B", "bgColor": None, "useAutoIdentifier": False, "bgRelPath": None, "bgPos": None,
			"bgPivotX": 0.5, "bgPivotY": 0.5, "__smartColor": "#9699A5", "__bgPos": None, "externalRelPath": None,
			"fieldInstances": [],
			"layerInstances": [layer_instance(iid, uid, d, cw, ch, 1000 + uid * 7 + d["uid"], optional if d["uid"] == 3 else ()) for d in layers],
			"__neighbours": [],
		}

	room = level("Room", "lvl-room", 100, 0, 320, 192, optional=(60,))
	hall = level("Hall", "lvl-hall", 101, 320, 256, 128)
	room["__neighbours"] = [{"levelIid": "lvl-hall", "dir": "e"}]
	hall["__neighbours"] = [{"levelIid": "lvl-room", "dir": "w"}]
	# Hall: tiles in Decor, a strip of stone in Ground (no auto-layer tiles yet), entities
	hcw = 256 // GRID
	decor = hall["layerInstances"][1]
	for x in range(4):
		decor["gridTiles"].append({"px": [x * GRID, 0], "src": [x * GRID, 0], "f": 0, "t": x, "d": [x], "a": 1})
	decor["gridTiles"].append({"px": [5 * GRID, 0], "src": [0, 16], "f": 1, "t": 8, "d": [5], "a": 1})
	ground = hall["layerInstances"][2]
	for x in range(hcw):
		ground["intGridCsv"][7 * hcw + x] = 2

	def field(fd, v, raw=None):
		return {"__identifier": fd["identifier"], "__type": fd["__type"], "__value": v, "__tile": None, "defUid": fd["uid"], "realEditorValues": [] if raw is None else raw}

	def entity(lv, d, iid, px, fields, w=None, h=None):
		ents = lv["layerInstances"][0]
		inst = {
			"__identifier": d["identifier"], "__grid": [(px[0] + (-1 if d["pivotX"] == 1 else 0)) // GRID, (px[1] + (-1 if d["pivotY"] == 1 else 0)) // GRID],
			"__pivot": [d["pivotX"], d["pivotY"]], "__tags": [], "__tile": d["tileRect"], "__smartColor": d["color"],
			"iid": iid, "width": w or d["width"], "height": h or d["height"], "defUid": d["uid"], "px": px, "fieldInstances": fields,
			"__worldX": lv["worldX"] + px[0], "__worldY": lv["worldY"] + px[1],
		}
		ents["entityInstances"].append(inst)
		return inst

	fd = {f["identifier"]: f for e in defs["entities"] for f in e["fieldDefs"]}
	entity(hall, hero, "hero1", [40, 96], [field(fd["speed"], 100), field(fd["target"], None), field(fd["path"], [{"cx": 4, "cy": 2}, {"cx": 6, "cy": 2}],
		[{"id": "V_String", "params": ["4,2"]}, {"id": "V_String", "params": ["6,2"]}]), field(fd["home"], {"cx": 1, "cy": 5}, [{"id": "V_String", "params": ["1,5"]}])])
	entity(hall, box, "box1", [96, 48], [])
	entity(hall, coin, "coin1", [136, 40], [field(fd["value"], 1)])
	entity(hall, link, "link1", [184, 40], [field(fd["next"], []), field(fd["mate"], None)])
	entity(hall, link, "link2", [216, 40], [field(fd["next"], []), field(fd["mate"], None)])

	toc = [{"identifier": "Coin", "instances": [], "instancesData": [{
		"iids": {"worldIid": "world-paint", "levelIid": "lvl-hall", "layerIid": "lvl-hall-entities", "entityIid": "coin1"},
		"worldX": 320 + 136, "worldY": 40, "widPx": 8, "heiPx": 8, "fields": {"value": 1},
	}]}]
	root = {
		"__header__": HEADER, "iid": "proj-paint", "jsonVersion": "1.5.3", "appBuildId": 473703, "nextUid": 200,
		"identifierStyle": "Capitalize", "toc": toc, "worldLayout": "Free", "worldGridWidth": 256, "worldGridHeight": 256,
		"defaultLevelWidth": 256, "defaultLevelHeight": 256, "defaultPivotX": 0, "defaultPivotY": 0, "defaultGridSize": GRID,
		"defaultEntityWidth": 16, "defaultEntityHeight": 16, "bgColor": "#40465B", "defaultLevelBgColor": "#696A79",
		"minifyJson": False, "externalLevels": False, "exportTiled": False, "simplifiedExport": False, "imageExportMode": "None",
		"exportLevelBg": True, "pngFilePattern": None, "backupOnSave": False, "backupLimit": 10, "backupRelPath": None,
		"levelNamePattern": "Level_%idx", "tutorialDesc": None, "customCommands": [], "flags": [], "defs": defs,
		"levels": [room, hall], "worlds": [], "dummyWorldIid": "world-paint",
	}
	text = pretty(root) + "\n"
	path = os.path.join(HERE, "paint.ldtk")
	tmp = path + ".tmp"
	with open(tmp, "w") as f:
		f.write(text)
	os.replace(tmp, path)


if __name__ == "__main__":
	main()
