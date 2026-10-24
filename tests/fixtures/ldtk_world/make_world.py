#!/usr/bin/env python3
"""Makes the LDtk tab's test projects (tests/fixtures/ldtk_world/), from LDtk's JSON schema 1.5.3.

    python3 tests/fixtures/ldtk_world/make_world.py

world.ldtk: three levels in a Free world (Start and Cave side by side, Tower below Start), the
layers Entities, Tiles and Walls (an IntGrid with three values), the entities Player (fields of
every simple type: speed, lives, name, mood, tint, home, friend), Coin (a value, in the table of
contents) and Door (an EntityRef to the Door of another level, locked), the enums Mood and
Weather, level fields (music, difficulty, weather), and every level's neighbours.

external.ldtk: two levels saved as separate files (external/*.ldtkl, "Save levels to separate
files"), in a GridVania world.

Both use ../ldtk/tiles.png (copied beside them). Written with tabs, like the other fixtures; the
tests check that the editor's edits keep them valid against the schema.
"""

import copy
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "ldtk", "world.ldtk")

HEADER = {
	"fileType": "LDtk Project JSON",
	"app": "LDtk",
	"doc": "https://ldtk.io/json",
	"schema": "https://ldtk.io/files/JSON_SCHEMA.json",
	"appAuthor": "Sebastien 'deepnight' Benard",
	"appVersion": "1.5.3",
	"url": "https://ldtk.io",
}

GRID = 16


def field_def(uid, identifier, ftype, json_type, default=None, can_be_null=True, toc=False, refs="Any", minv=None, maxv=None):
	return {
		"__type": json_type, "canBeNull": can_be_null, "identifier": identifier, "isArray": False,
		"type": ftype, "uid": uid, "allowOutOfLevelRef": True, "allowedRefTags": [], "allowedRefs": refs,
		"autoChainRef": True, "editorAlwaysShow": False, "editorCutLongValues": True,
		"editorDisplayMode": "RefLinkBetweenCenters" if ftype == "F_EntityRef" else "ValueOnly",
		"editorDisplayPos": "Above", "editorDisplayScale": 1, "editorLinkStyle": "CurvedArrow",
		"editorShowInWorld": True, "exportToToc": toc, "searchable": False, "symmetricalRef": False,
		"useForSmartColor": False, "defaultOverride": default, "acceptFileTypes": None,
		"arrayMaxLength": None, "arrayMinLength": None, "max": maxv, "min": minv, "regex": None,
		"tilesetUid": None, "textLanguageMode": None, "editorDisplayColor": None,
		"editorTextPrefix": None, "editorTextSuffix": None, "doc": None, "allowedRefsEntityUid": None,
	}


def value(kind, v):
	return {"id": kind, "params": [v]}


def field(fd, v, raw):
	"""A field instance: its value and LDtk's editor value (None: the default)"""
	return {
		"__identifier": fd["identifier"], "__type": fd["__type"], "__value": v, "__tile": None,
		"defUid": fd["uid"], "realEditorValues": [] if raw is None else [raw],
	}


def make(path, levels_spec, layout, external):
	t = json.load(open(TEMPLATE))
	root = {k: v for k, v in t.items() if k not in ("defs", "levels", "worlds")}
	root["__header__"] = HEADER
	root["iid"] = "proj-" + os.path.splitext(os.path.basename(path))[0]
	root["worldLayout"] = layout
	root["worldGridWidth"] = 256
	root["worldGridHeight"] = 128
	root["externalLevels"] = external
	root["dummyWorldIid"] = "world-" + root["iid"]
	defs = copy.deepcopy(t["defs"])
	walls = defs["layers"][2]
	walls["intGridValues"] = [
		{"value": 1, "identifier": "wall", "color": "#8C8C99", "tile": None, "groupUid": 0},
		{"value": 2, "identifier": "platform", "color": "#C08040", "tile": None, "groupUid": 0},
		{"value": 3, "identifier": "water", "color": "#3070D0", "tile": None, "groupUid": 0},
	]
	# Enums
	defs["enums"] = [
		{"identifier": "Mood", "uid": 30, "values": [
			{"id": "Happy", "tileRect": None, "color": 0x55CC55},
			{"id": "Sad", "tileRect": None, "color": 0x5555CC},
			{"id": "Angry", "tileRect": None, "color": 0xCC5555},
		], "iconTilesetUid": None, "externalRelPath": None, "externalFileChecksum": None, "tags": []},
		{"identifier": "Weather", "uid": 31, "values": [
			{"id": "Sunny", "tileRect": None, "color": 0xFFDD44},
			{"id": "Rainy", "tileRect": None, "color": 0x4488CC},
		], "iconTilesetUid": None, "externalRelPath": None, "externalFileChecksum": None, "tags": []},
	]
	player, coin = defs["entities"][0], defs["entities"][1]
	player["maxCount"] = 0
	player["fieldDefs"] = [
		field_def(40, "speed", "F_Float", "Float", value("V_Float", 120), minv=0, maxv=1000),
		field_def(41, "lives", "F_Int", "Int", value("V_Int", 3), can_be_null=False),
		field_def(42, "name", "F_String", "String", None),
		field_def(43, "mood", "F_Enum(30)", "LocalEnum.Mood", None),
		field_def(44, "tint", "F_Color", "Color", None, can_be_null=False),
		field_def(45, "home", "F_Point", "Point", None),
		field_def(46, "friend", "F_EntityRef", "EntityRef", None),
	]
	coin["exportToToc"] = True
	coin["fieldDefs"] = [field_def(47, "value", "F_Int", "Int", value("V_Int", 1), can_be_null=False, toc=True)]
	door = copy.deepcopy(coin)
	door.update({"identifier": "Door", "uid": 12, "color": "#B05030", "width": 16, "height": 32, "exportToToc": False, "pivotX": 0.5, "pivotY": 1})
	door["fieldDefs"] = [
		field_def(48, "target", "F_EntityRef", "EntityRef", None, refs="OnlySame"),
		field_def(49, "locked", "F_Bool", "Bool", value("V_Bool", False), can_be_null=False),
	]
	defs["entities"].append(door)
	defs["levelFields"] = [
		field_def(50, "music", "F_String", "String", None),
		field_def(51, "difficulty", "F_Int", "Int", value("V_Int", 1), can_be_null=False),
		field_def(52, "weather", "F_Enum(31)", "LocalEnum.Weather", None),
	]
	root["nextUid"] = 60
	root["defs"] = defs

	fd = {f["identifier"]: f for e in defs["entities"] for f in e["fieldDefs"]}
	level_fd = {f["identifier"]: f for f in defs["levelFields"]}
	template_level = t["levels"][0]
	levels = []
	for i, spec in enumerate(levels_spec):
		level = {k: copy.deepcopy(v) for k, v in template_level.items() if k != "layerInstances"}
		level.update({"identifier": spec["name"], "iid": spec["iid"], "uid": 100 + i, "worldX": spec["x"], "worldY": spec["y"], "pxWid": spec["w"], "pxHei": spec["h"]})
		level["fieldInstances"] = [
			field(level_fd["music"], spec.get("music"), value("V_String", spec["music"]) if spec.get("music") else None),
			field(level_fd["difficulty"], spec.get("difficulty", 1), value("V_Int", spec["difficulty"]) if "difficulty" in spec else None),
			field(level_fd["weather"], spec.get("weather"), value("V_String", spec["weather"]) if spec.get("weather") else None),
		]
		cw, ch = spec["w"] // GRID, spec["h"] // GRID
		layers = []
		for li in template_level["layerInstances"]:
			li = copy.deepcopy(li)
			li["iid"] = spec["iid"] + "-" + li["__identifier"].lower()
			li["levelId"] = 100 + i
			li["__cWid"], li["__cHei"] = cw, ch
			if li["__type"] == "IntGrid":
				csv = [0] * (cw * ch)
				for x in range(cw): csv[(ch - 1) * cw + x] = 1
				for x in range(2, 5): csv[(ch - 3) * cw + x] = 2
				li["intGridCsv"] = csv
			if li["__type"] == "Tiles":
				li["gridTiles"] = [{"px": [x * GRID, (ch - 1) * GRID], "src": [0, 0], "f": 0, "t": 0, "d": [(ch - 1) * cw + x], "a": 1} for x in range(cw)]
			if li["__type"] == "Entities":
				li["entityInstances"] = []
			layers.append(li)
		level["layerInstances"] = layers
		level["__neighbours"] = []
		levels.append(level)

	def entity(level_index, ident, iid, px, fields):
		level = levels[level_index]
		d = next(e for e in defs["entities"] if e["identifier"] == ident)
		layer = level["layerInstances"][0]
		instance = {
			"__identifier": ident, "__grid": [px[0] // GRID, (px[1] - (1 if d["pivotY"] == 1 else 0)) // GRID],
			"__pivot": [d["pivotX"], d["pivotY"]], "__tags": [], "__tile": None, "__smartColor": d["color"],
			"iid": iid, "width": d["width"], "height": d["height"], "defUid": d["uid"], "px": px, "fieldInstances": fields,
		}
		if layout in ("Free", "GridVania"):
			instance["__worldX"] = level["worldX"] + px[0]
			instance["__worldY"] = level["worldY"] + px[1]
		layer["entityInstances"].append(instance)
		return instance

	def ref(target, li, lv):
		return {"entityIid": target, "layerIid": levels[lv]["layerInstances"][0]["iid"], "levelIid": levels[lv]["iid"], "worldIid": root["dummyWorldIid"]}

	for i, spec in enumerate(levels_spec):
		for e in spec["entities"]:
			entity(i, e[0], e[1], e[2], [])
	# Fields, once every entity exists (references)
	by_iid = {ei["iid"]: (ei, li_index) for li_index, l in enumerate(levels) for ei in l["layerInstances"][0]["entityInstances"]}
	for iid, (ei, lv) in by_iid.items():
		if ei["__identifier"] == "Player":
			friend = "coin1" if "coin1" in by_iid else None
			ei["fieldInstances"] = [
				field(fd["speed"], 150, value("V_Float", 150)),
				field(fd["lives"], 3, None),
				field(fd["name"], "Hero", value("V_String", "Hero")),
				field(fd["mood"], "Happy", value("V_String", "Happy")),
				field(fd["tint"], "#FFCC00", value("V_Int", 0xFFCC00)),
				field(fd["home"], {"cx": 2, "cy": 5}, value("V_String", "2,5")),
				field(fd["friend"], ref(friend, 0, by_iid[friend][1]) if friend else None, value("V_String", friend) if friend else None),
			]
		elif ei["__identifier"] == "Coin":
			v = 5 if iid == "coin2" else 1
			ei["fieldInstances"] = [field(fd["value"], v, value("V_Int", v) if v != 1 else None)]
		elif ei["__identifier"] == "Door":
			other = next((o for o, (od, olv) in by_iid.items() if od["__identifier"] == "Door" and olv != lv), None)
			ei["fieldInstances"] = [
				field(fd["target"], ref(other, 0, by_iid[other][1]) if other else None, value("V_String", other) if other else None),
				field(fd["locked"], iid == "door2", value("V_Bool", True) if iid == "door2" else None),
			]

	# The table of contents: every Coin (exportToToc), with its value
	coins = [ei for ei, _ in by_iid.values() if ei["__identifier"] == "Coin"]
	root["toc"] = [{"identifier": "Coin", "instances": [], "instancesData": [{
		"iids": {"worldIid": root["dummyWorldIid"], "levelIid": levels[by_iid[c["iid"]][1]]["iid"], "layerIid": levels[by_iid[c["iid"]][1]]["layerInstances"][0]["iid"], "entityIid": c["iid"]},
		"worldX": levels[by_iid[c["iid"]][1]]["worldX"] + c["px"][0], "worldY": levels[by_iid[c["iid"]][1]]["worldY"] + c["px"][1],
		"widPx": c["width"], "heiPx": c["height"], "fields": {"value": c["fieldInstances"][0]["__value"]},
	} for c in coins]}]

	# Neighbours (LDtk's rule: touching levels of the same depth, by side)
	for l in levels:
		for o in levels:
			if o is l: continue
			x, y, w, h = l["worldX"], l["worldY"], l["pxWid"], l["pxHei"]
			ox, oy, ow, oh = o["worldX"], o["worldY"], o["pxWid"], o["pxHei"]
			overlap = x < ox + ow and x + w > ox and y < oy + oh and y + h > oy
			dx = max(ox - (x + w), x - (ox + ow), 0)
			dy = max(oy - (y + h), y - (oy + oh), 0)
			if overlap:
				l["__neighbours"].append({"levelIid": o["iid"], "dir": "o"})
			elif dx == 0 and dy == 0:
				d = "e" if ox >= x + w else "w" if ox + ow <= x else "n" if oy + oh <= y else "s"
				l["__neighbours"].append({"levelIid": o["iid"], "dir": d})

	root["levels"] = levels
	root["worlds"] = []
	ordered = {}
	for k in t.keys():
		if k in root: ordered[k] = root[k]
	for k in root:
		if k not in ordered: ordered[k] = root[k]
	ordered.pop("__header__", None)
	ordered = {"__header__": HEADER, **ordered}

	if external:
		folder = os.path.join(os.path.dirname(path), os.path.splitext(os.path.basename(path))[0])
		os.makedirs(folder, exist_ok=True)
		for i, level in enumerate(levels):
			name = "%04d-%s.ldtkl" % (i, level["identifier"])
			rel = os.path.basename(folder) + "/" + name
			full = {"__header__": HEADER, **{k: v for k, v in level.items()}}
			full["externalRelPath"] = None
			write(os.path.join(folder, name), full)
			level["externalRelPath"] = rel
			level["layerInstances"] = None
	write(path, ordered)


def write(path, data):
	text = json.dumps(data, indent="\t", ensure_ascii=False) + "\n"
	tmp = path + ".tmp"
	with open(tmp, "w") as f:
		f.write(text)
	os.replace(tmp, path)


def main():
	shutil.copyfile(os.path.join(HERE, "..", "ldtk", "tiles.png"), os.path.join(HERE, "tiles.png"))
	make(os.path.join(HERE, "world.ldtk"), [
		{"name": "Start", "iid": "lvl-start", "x": 0, "y": 0, "w": 256, "h": 128, "music": "intro", "difficulty": 1, "weather": "Sunny",
		 "entities": [("Player", "player1", [32, 96]), ("Coin", "coin1", [104, 72]), ("Door", "door1", [232, 112])]},
		{"name": "Cave", "iid": "lvl-cave", "x": 256, "y": 0, "w": 256, "h": 128, "music": "cave", "difficulty": 2,
		 "entities": [("Coin", "coin2", [64, 72]), ("Door", "door2", [24, 112])]},
		{"name": "Tower", "iid": "lvl-tower", "x": 0, "y": 128, "w": 128, "h": 128,
		 "entities": [("Coin", "coin3", [56, 56])]},
	], "Free", False)
	make(os.path.join(HERE, "external.ldtk"), [
		{"name": "North", "iid": "lvl-north", "x": 0, "y": 0, "w": 256, "h": 128, "music": "north",
		 "entities": [("Player", "player1", [32, 96]), ("Coin", "coin1", [104, 72])]},
		{"name": "South", "iid": "lvl-south", "x": 0, "y": 128, "w": 256, "h": 128,
		 "entities": [("Coin", "coin2", [64, 72])]},
	], "GridVania", True)


if __name__ == "__main__":
	main()
