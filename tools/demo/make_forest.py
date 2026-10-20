#!/usr/bin/env python3
"""Makes the demo project's LDtk platformer level (examples/demo_project/assets/forest/).

Run once to (re)create it from the asset packs; after that the level is edited in LDtk and this
script is only needed to start over:

    python3 -I tools/demo/make_forest.py [<Legacy-Fantasy folder>] [<GameSounds folder>]

(defaults: ../Legacy-Fantasy and ../GameSounds, beside the editor's checkout). Needs ImageMagick
(magick) for the images.

What it makes:
- the images: the tileset, the sky (mirrored into a wide strip), the tree strips, combined
  sheets (the hero: idle, run, jump and attack rows of 96 x 80 cells, feet on one line; the
  boar: idle, walk, run, hit; the bee: fly, attack, hit; the snail: walk, hide, dead), and single
  items cut from the tileset (coin, key, chest, open chest, the gate's log)
- the sounds, copied under short names
- forest.ldtk: an LDtk 1.5.3 project, built from LDtk's own JSON schema (every object gets every
  key the schema requires) and checked against it. Its ground is an IntGrid layer with auto-layer
  RULES (edges, corners, grass tips, planks), and the tiles saved with it are what those rules
  make, so painting ground in LDtk tiles it the same way. Also: a Decor tile layer, two parallax
  tree layers, the sky as the level background, and entities with fields (the hero's speed, coin
  values, enemies' patrols, speeds and health, the key's EntityRef to the gate).
"""
import json, os, random, shutil, subprocess, sys, uuid

EDITOR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKSPACE = os.path.dirname(EDITOR)
PACK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORKSPACE, "Legacy-Fantasy")
SOUNDS = sys.argv[2] if len(sys.argv) > 2 else os.path.join(WORKSPACE, "GameSounds")
OUT = os.path.join(EDITOR, "examples", "demo_project", "assets", "forest")
SCHEMA = os.path.join(WORKSPACE, "ldtk", "docs", "JSON_SCHEMA.json")

G = 16                  # grid size
W, H = 200, 30          # level size in cells
TILES_COLS = 25         # tiles.png: 400 / 16


def magick(*args):
    subprocess.run(["magick", *args], check=True)


# --- Images and sounds -----------------------------------------------------------------------

def sheet(out, cell, rows, columns):
    """Combines sprite sheets into one of `cell` (w, h) cells, a row per sheet: rows are
    (path, frames, frame w, frame h, feet). Frames are centered across; with `feet` the sheet's
    lowest opaque pixel goes to that y, else frames are centered down too."""
    cw, ch = cell
    parts = []
    for row, (path, frames, fw, fh, feet) in enumerate(rows):
        src = os.path.join(PACK, path)
        if feet is not None:
            bottom = int(subprocess.run(["magick", src, "-trim", "-format", "%[fx:page.y+h]", "info:"], capture_output=True, text=True, check=True).stdout)
            dy = feet - bottom
        else:
            dy = (ch - fh) // 2
        dx = (cw - fw) // 2
        for i in range(frames):
            parts += ["(", src, "-crop", f"{fw}x{fh}+{i * fw}+0", "+repage", "-background", "none", "-extent", f"{cw}x{ch}{-dx:+d}{-dy:+d}", "-repage", f"+{i * cw}+{row * ch}", ")"]
    magick("-size", f"{columns * cw}x{len(rows) * ch}", "xc:none", *parts, "-background", "none", "-layers", "flatten", os.path.join(OUT, out))


def prepare_assets():
    os.makedirs(os.path.join(OUT, "sounds"), exist_ok=True)
    shutil.copy(os.path.join(PACK, "Assets", "Tiles.png"), os.path.join(OUT, "tiles.png"))
    shutil.copy(os.path.join(PACK, "Trees", "Background.png"), os.path.join(OUT, "trees.png"))
    # The sky three times across, the middle one mirrored, so it joins up: a wide level covers
    # with it at a smaller scale
    sky = os.path.join(PACK, "Background", "Background.png")
    magick(sky, "(", sky, "-flop", ")", sky, "+append", os.path.join(OUT, "sky.png"))

    # Single items from the tileset: (x, y, w, h) in pixels
    tiles = os.path.join(PACK, "Assets", "Tiles.png")
    for name, (x, y, w, h) in {
        "coin": (15 * G, 21 * G, 16, 16),
        "key": (15 * G, 20 * G, 16, 16),
        "chest": (18 * G, 17 * G, 32, 32),
        "chest_open": (20 * G, 17 * G, 32, 32),
        # A tree trunk: too tall to jump over
        "gate": (10 * G, 3 * G, 32, 112),
    }.items():
        magick(tiles, "-crop", f"{w}x{h}+{x}+{y}", "+repage", os.path.join(OUT, f"{name}.png"))

    # The hero: 15 columns of 96 x 80 cells; rows idle, run, jump, attack; feet at y 76
    sheet("hero.png", (96, 80), [
        ("Character/Idle/Idle-Sheet.png", 4, 64, 80, 76),
        ("Character/Run/Run-Sheet.png", 8, 80, 80, 76),
        ("Character/Jumlp-All/Jump-All-Sheet.png", 15, 64, 64, 76),
        ("Character/Attack-01/Attack-01-Sheet.png", 8, 96, 80, 76),
    ], 15)
    # The boar (faces left): 6 columns of 48 x 32; idle, walk, run, hit (white flashes)
    sheet("boar.png", (48, 32), [
        ("Mob/Boar/Idle/Idle-Sheet.png", 4, 48, 32, 32),
        ("Mob/Boar/Walk/Walk-Base-Sheet.png", 6, 48, 32, 32),
        ("Mob/Boar/Run/Run-Sheet.png", 6, 48, 32, 32),
        ("Mob/Boar/Hit-Vanish/Hit-Sheet.png", 4, 48, 32, 32),
    ], 6)
    # The bee (faces left): 4 columns of 64 x 64; fly, attack, hit
    sheet("bee.png", (64, 64), [
        ("Mob/Small Bee/Fly/Fly-Sheet.png", 4, 64, 64, None),
        ("Mob/Small Bee/Attack/Attack-Sheet.png", 4, 64, 64, None),
        ("Mob/Small Bee/Hit/Hit-Sheet.png", 4, 64, 64, None),
    ], 4)
    # The snail (faces left): 8 columns of 48 x 32; walk, hide (in its shell), dead
    sheet("snail.png", (48, 32), [
        ("Mob/Snail/walk-Sheet.png", 8, 48, 32, None),
        ("Mob/Snail/Hide-Sheet.png", 8, 48, 32, None),
        ("Mob/Snail/Dead-Sheet.png", 8, 48, 32, None),
    ], 8)

    for name, (folder, file) in {
        "jump": ("SWIPES - SLASHES - WHOOSHES - (58)", "SWIPE Whoosh 01.ogg"),
        "swing": ("SWIPES - SLASHES - WHOOSHES - (58)", "SWIPE Whoosh 03.ogg"),
        "hit": ("SWIPES - SLASHES - WHOOSHES - (58)", "SWIPE Slash Splat 01.ogg"),
        "defeat": ("SPLATS - SQUELCHES - (36)", "SPLAT Squelch 03.ogg"),
        "hurt": ("VOCAL CUTE - CHARACTERS - (113)", "VOCAL CUTE Distress Pain 03.ogg"),
        "coin": ("COINS - MONEY - TREASURE - (26)", "COINS Collect Chime 01.ogg"),
        "stomp": ("SPLATS - SQUELCHES - (36)", "SPLAT Short 01.ogg"),
        "key": ("SUCCESS - PICKUPS - (109)", "SUCCESS PICKUP Collect Beep 05.ogg"),
        "gate": ("SQUEAKS - CREAKS - (28)", "SQUEAK Creaking 01.ogg"),
        "win": ("SUCCESS - TUNES - CHEERS - (64)", "SUCCESS CHEERS Win Cute Vocal Chime 01.ogg"),
    }.items():
        shutil.copy(os.path.join(SOUNDS, folder, file), os.path.join(OUT, "sounds", f"{name}.ogg"))


# --- LDtk objects from the schema ------------------------------------------------------------

schema = json.load(open(SCHEMA))
TYPES = schema["otherTypes"]


def resolve(prop):
    if "$ref" in prop:
        return TYPES[prop["$ref"].split("/")[-1]]
    return prop


def default_for(prop):
    prop = resolve(prop)
    if "enum" in prop:
        return None if None in prop["enum"] else prop["enum"][0]
    types = prop.get("type", [])
    if isinstance(types, str): types = [types]
    if "null" in types: return None
    if "array" in types: return []
    if "boolean" in types: return False
    if "integer" in types: return 0
    if "number" in types: return 0.0
    if "string" in types: return ""
    if "object" in types: return {}
    return None


def make(type_name, **values):
    """An LDtk object with every key its schema type requires (defaults for the ones not given)."""
    t = schema["LdtkJsonRoot"] if type_name == "LdtkJsonRoot" else TYPES[type_name]
    obj = {}
    for key in t.get("required", []):
        obj[key] = values.pop(key) if key in values else default_for(t["properties"][key])
    obj.update(values)
    return obj


def validate(value, prop, path, problems):
    """Checks a value against the schema: required keys, types, enums, nested references."""
    prop = resolve(prop)
    if "enum" in prop:
        if value not in prop["enum"]: problems.append(f"{path}: {value!r} not in {prop['enum']}")
        return
    types = prop.get("type", [])
    if isinstance(types, str): types = [types]
    if value is None:
        if types and "null" not in types: problems.append(f"{path}: null not allowed")
        return
    kinds = {bool: "boolean", int: "integer", float: "number", str: "string", list: "array", dict: "object"}
    kind = kinds.get(type(value))
    if types and kind not in types and not (kind == "integer" and "number" in types):
        problems.append(f"{path}: {kind} not one of {types}")
        return
    if kind == "array" and "items" in prop:
        for i, item in enumerate(value): validate(item, prop["items"], f"{path}[{i}]", problems)
    if kind == "object" and "properties" in prop:
        for key in prop.get("required", []):
            if key not in value: problems.append(f"{path}: missing {key}")
        for key, item in value.items():
            if key in prop["properties"]: validate(item, prop["properties"][key], f"{path}.{key}", problems)


uid_counter = [100]
def uid():
    uid_counter[0] += 1
    return uid_counter[0]


def iid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "crossfire-demo-forest/" + name))


# --- The level's cells -----------------------------------------------------------------------

GROUND, PLANK = 1, 2
grid = [[0] * W for _ in range(H)]


def fill(x0, x1, y0, y1, value=GROUND):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            grid[y][x] = value


# Heights: the hero jumps about 5 cells, so steps up are at most 4; the gate is 7 tall
fill(0, 22, 24, 29)           # the meadow
fill(0, 1, 8, 23)             # a cliff on the left
fill(14, 17, 22, 23)          # a mound
fill(26, 38, 22, 29)          # a raised step (a pit before it)
fill(30, 33, 18, 18, PLANK)
fill(39, 52, 24, 29)          # low ground: a boar's
fill(53, 58, 21, 21, PLANK)   # a bridge over a pit
fill(59, 75, 20, 29)          # a hill
fill(66, 69, 16, 16, PLANK)
fill(76, 104, 24, 29)         # a long flat: a boar, bees above
fill(80, 84, 20, 20, PLANK)   # platforms up to the key
fill(87, 91, 16, 16, PLANK)
fill(94, 99, 12, 12, PLANK)
fill(109, 125, 22, 29)        # raised ground after a pit
fill(112, 116, 17, 17, PLANK)
fill(126, 140, 25, 29)        # a dip: another boar
fill(141, 144, 22, 22, PLANK) # a bridge over a pit
fill(145, 160, 21, 29)        # a hill with bees
fill(155, 157, 19, 20)        # a mound on it
fill(161, 199, 24, 29)        # the last stretch: the gate, a boar, the chest
fill(165, 168, 20, 20, PLANK)
fill(198, 199, 8, 23)         # a cliff on the right


def at(x, y):
    """The cell's value; outside the level, the nearest cell's (the ground runs on past the
    level's edges, so they get no rocky edge, and pits stay open at the bottom)"""
    return grid[min(max(y, 0), H - 1)][min(max(x, 0), W - 1)]


def tid(cx, cy):
    return cx + cy * TILES_COLS


# Auto-layer rules, LDtk's way: a 3 x 3 pattern around the cell (row by row; 0 anything, v the
# IntGrid value v, -v not v), the first matching rule (breakOnMatch) picks a tile, at random
# among its tiles. The tiles saved below come from the same rules.
ANY = 0
RULES = [
    # Grass tips over the ground's top edge: an empty cell with ground below
    ("tips", [ANY, ANY, ANY, ANY, -GROUND, ANY, ANY, GROUND, ANY], [tid(1, 0), tid(2, 0), tid(3, 0)]),
    # Ground: corners first, then edges, then the inside
    ("top-left", [ANY, -GROUND, ANY, -GROUND, GROUND, ANY, ANY, ANY, ANY], [tid(0, 1)]),
    ("top-right", [ANY, -GROUND, ANY, ANY, GROUND, -GROUND, ANY, ANY, ANY], [tid(4, 1)]),
    ("top", [ANY, -GROUND, ANY, ANY, GROUND, ANY, ANY, ANY, ANY], [tid(1, 1), tid(2, 1), tid(3, 1)]),
    ("bottom-left", [ANY, ANY, ANY, -GROUND, GROUND, ANY, ANY, -GROUND, ANY], [tid(0, 4)]),
    ("bottom-right", [ANY, ANY, ANY, ANY, GROUND, -GROUND, ANY, -GROUND, ANY], [tid(4, 4)]),
    ("bottom", [ANY, ANY, ANY, ANY, GROUND, ANY, ANY, -GROUND, ANY], [tid(1, 4), tid(2, 4), tid(3, 4)]),
    ("left", [ANY, ANY, ANY, -GROUND, GROUND, ANY, ANY, ANY, ANY], [tid(0, 2), tid(0, 3)]),
    ("right", [ANY, ANY, ANY, ANY, GROUND, -GROUND, ANY, ANY, ANY], [tid(4, 2), tid(4, 3)]),
    ("inside", [ANY, ANY, ANY, ANY, GROUND, ANY, ANY, ANY, ANY], [tid(1, 2), tid(2, 2), tid(3, 2), tid(1, 3), tid(2, 3), tid(3, 3)]),
    # Planks: ends and the middle
    ("plank-left", [ANY, ANY, ANY, -PLANK, PLANK, ANY, ANY, ANY, ANY], [tid(5, 6)]),
    ("plank-right", [ANY, ANY, ANY, ANY, PLANK, -PLANK, ANY, ANY, ANY], [tid(7, 6)]),
    ("plank", [ANY, ANY, ANY, ANY, PLANK, ANY, ANY, ANY, ANY], [tid(6, 6)]),
]


def matches(pattern, x, y):
    for i, want in enumerate(pattern):
        if want == ANY: continue
        value = at(x + i % 3 - 1, y + i // 3 - 1)
        if want > 0 and value != want: return False
        if want < 0 and value == -want: return False
    return True


# --- forest.ldtk -----------------------------------------------------------------------------

def tile_rect(tileset, x, y, w, h):
    return make("TilesetRect", tilesetUid=tileset, x=x, y=y, w=w, h=h)


def make_level():
    prepare_assets()
    random.seed(7)
    TILES, TREES, HERO, SNAIL, BOAR, BEE = 1, 2, 3, 4, 5, 6
    def tileset(ident, uid_, rel, w, h):
        return make("TilesetDef", __cWid=w // G, __cHei=h // G, identifier=ident, uid=uid_, relPath=rel, pxWid=w, pxHei=h, tileGridSize=G)
    tilesets = [
        tileset("Tiles", TILES, "tiles.png", 400, 400),
        tileset("Trees", TREES, "trees.png", 896, 256),
        tileset("Hero", HERO, "hero.png", 1440, 320),
        tileset("Snail", SNAIL, "snail.png", 384, 96),
        tileset("Boar", BOAR, "boar.png", 288, 128),
        tileset("Bee", BEE, "bee.png", 256, 192),
    ]

    # Layer definitions (and their uids)
    L_ENTITIES, L_DECOR, L_COLLISIONS, L_NEAR, L_FAR = uid(), uid(), uid(), uid(), uid()
    rules = []
    for name, pattern, ids in RULES:
        rules.append(make("AutoRuleDef", uid=uid(), active=True, alpha=1.0, breakOnMatch=True, chance=1.0, checker="None",
                          pattern=pattern, size=3, tileMode="Single", tileRectsIds=[[i] for i in ids],
                          perlinOctaves=2.0, perlinScale=0.2, perlinSeed=float(uid()), pivotX=0.0, pivotY=0.0,
                          xModulo=1, yModulo=1, outOfBoundsValue=None))
    group = make("AutoLayerRuleGroup", active=True, isOptional=False, name="Ground", rules=rules, uid=uid(), usesWizard=False,
                 biomeRequirementMode=0, requiredBiomeValues=[], color=None, icon=None)
    def layer_def(uid_, ident, kind, **extra):
        values = dict(__type=kind, type=kind, identifier=ident, uid=uid_, gridSize=G, displayOpacity=1.0, inactiveOpacity=0.6,
                      parallaxFactorX=0.0, parallaxFactorY=0.0, parallaxScaling=True, pxOffsetX=0, pxOffsetY=0,
                      canSelectWhenInactive=True, renderInWorldView=True, hideFieldsWhenInactive=True, tilePivotX=0.0, tilePivotY=0.0,
                      autoSourceLayerDefUid=None, tilesetDefUid=None, doc=None, uiColor=None, guideGridWid=0, guideGridHei=0,
                      biomeFieldUid=None, autoTilesKilledByOtherLayerUid=None)
        values.update(extra)
        return make("LayerDef", **values)
    layer_defs = [
        layer_def(L_ENTITIES, "Entities", "Entities"),
        layer_def(L_DECOR, "Decor", "Tiles", tilesetDefUid=TILES),
        layer_def(L_COLLISIONS, "Collisions", "IntGrid", tilesetDefUid=TILES, autoRuleGroups=[group], intGridValues=[
            make("IntGridValueDef", value=GROUND, identifier="ground", color="#5B8A3C", groupUid=0, tile=None),
            make("IntGridValueDef", value=PLANK, identifier="plank", color="#8A5B3C", groupUid=0, tile=None),
        ]),
        layer_def(L_NEAR, "NearTrees", "Tiles", tilesetDefUid=TREES, parallaxFactorX=0.3, parallaxScaling=False),
        layer_def(L_FAR, "FarTrees", "Tiles", tilesetDefUid=TREES, parallaxFactorX=0.6, parallaxScaling=False, displayOpacity=0.85),
    ]

    # Entity definitions with their fields
    def field_def(ident, kind, type_, default=None, **extra):
        values = dict(identifier=ident, __type=type_, type=kind, uid=uid(), isArray=False, canBeNull=True,
                      editorDisplayMode="ValueOnly", editorDisplayPos="Above", editorLinkStyle="StraightArrow", editorDisplayScale=1.0,
                      allowedRefs="Any", allowedRefTags=[], allowOutOfLevelRef=True, autoChainRef=True, symmetricalRef=False,
                      editorAlwaysShow=False, editorCutLongValues=True, editorShowInWorld=True, exportToToc=False, searchable=False,
                      useForSmartColor=False, defaultOverride=default, acceptFileTypes=None, arrayMaxLength=None, arrayMinLength=None,
                      max=None, min=None, regex=None, tilesetUid=None, textLanguageMode=None, editorDisplayColor=None, editorTextPrefix=None,
                      editorTextSuffix=None, doc=None)
        values.update(extra)
        return make("FieldDef", **values)
    def entity_def(ident, w, h, color, pivot, tile, mode, fields, render="Tile"):
        values = dict(identifier=ident, uid=uid(), width=w, height=h, color=color, pivotX=pivot[0], pivotY=pivot[1],
                      renderMode=render, tileRect=tile, tilesetId=tile["tilesetUid"] if tile else None, tileRenderMode=mode,
                      tileOpacity=1.0, fillOpacity=0.08, lineOpacity=0.0 if render == "Tile" else 1.0, hollow=False,
                      showName=True, nineSliceBorders=[], maxCount=0, limitScope="PerLevel", limitBehavior="MoveLastOne",
                      keepAspectRatio=False, resizableX=False, resizableY=False, allowOutOfBounds=False, exportToToc=False,
                      tags=[], fieldDefs=fields, uiTileRect=None, doc=None, minWidth=None, maxWidth=None, minHeight=None, maxHeight=None)
        return make("EntityDef", **values)
    speed_def = field_def("speed", "F_Float", "Float", {"id": "V_Float", "params": [110.0]})
    value_def = field_def("value", "F_Int", "Int", {"id": "V_Int", "params": [1]})
    def enemy_fields(speed, health):
        return [field_def("patrol", "F_Point", "Point", None, editorDisplayMode="PointPath"),
                field_def("speed", "F_Float", "Float", {"id": "V_Float", "params": [speed]}),
                field_def("health", "F_Int", "Int", {"id": "V_Int", "params": [health]})]
    opens_def = field_def("opens", "F_EntityRef", "EntityRef", None, editorDisplayMode="RefLinkBetweenCenters", editorLinkStyle="CurvedArrow")
    E = {}
    E["Hero"] = entity_def("Hero", 16, 32, "#5BC0EB", (0.5, 1.0), tile_rect(HERO, 0, 0, 96, 80), "FullSizeUncropped", [speed_def])
    E["Coin"] = entity_def("Coin", 16, 16, "#FFD23F", (0.5, 0.5), tile_rect(TILES, 15 * G, 21 * G, 16, 16), "FitInside", [value_def])
    E["Snail"] = entity_def("Snail", 32, 20, "#E4572E", (0.5, 1.0), tile_rect(SNAIL, 0, 0, 48, 32), "FullSizeUncropped", enemy_fields(24.0, 2))
    E["Boar"] = entity_def("Boar", 32, 24, "#9C6644", (0.5, 1.0), tile_rect(BOAR, 0, 0, 48, 32), "FullSizeUncropped", enemy_fields(40.0, 3))
    E["Bee"] = entity_def("Bee", 20, 20, "#F9C74F", (0.5, 0.5), tile_rect(BEE, 0, 0, 64, 64), "FullSizeUncropped", enemy_fields(50.0, 1))
    E["Key"] = entity_def("Key", 16, 16, "#F4D35E", (0.5, 0.5), tile_rect(TILES, 15 * G, 20 * G, 16, 16), "FitInside", [opens_def])
    E["Gate"] = entity_def("Gate", 24, 112, "#8D6346", (0.5, 1.0), tile_rect(TILES, 10 * G, 3 * G, 32, 112), "FullSizeUncropped", [])
    E["Chest"] = entity_def("Chest", 32, 32, "#C08552", (0.5, 1.0), tile_rect(TILES, 18 * G, 17 * G, 32, 32), "FitInside", [])

    level_iid = iid("level")
    entities_iid = iid("layer-entities")
    world_iid = iid("world")

    def field(fdef, value, kind=None):
        return make("FieldInstance", __identifier=fdef["identifier"], __type=fdef["__type"], __value=value, defUid=fdef["uid"],
                    __tile=None, realEditorValues=[] if value is None else [{"id": kind, "params": [value]}] if kind else [])
    instances = []
    def entity(name, cx, cy, fields=(), key=None):
        d = E[name]
        assert at(cx, cy) == 0, f"{name} at {cx},{cy} is inside the ground"
        # px: where its pivot is (a pivot at the bottom stands on the cell's bottom edge)
        px = [int(cx * G + d["width"] * d["pivotX"]) if d["pivotX"] != 0.5 else cx * G + 8, int(cy * G + (G if d["pivotY"] == 1.0 else 8))]
        e = make("EntityInstance", __identifier=name, __grid=[cx, cy], __pivot=[d["pivotX"], d["pivotY"]], __smartColor=d["color"],
                 __tags=[], __tile=d["tileRect"], __worldX=px[0], __worldY=px[1], defUid=d["uid"], fieldInstances=list(fields),
                 height=d["height"], width=d["width"], iid=iid(key or f"{name}-{cx}-{cy}"), px=px)
        instances.append(e)
        return e

    entity("Hero", 4, 23, [field(speed_def, 160.0, "V_Float")])
    def enemy(name, cx, cy, to, speed, health):
        d = {f["identifier"]: f for f in E[name]["fieldDefs"]}
        entity(name, cx, cy, [field(d["patrol"], {"cx": to[0], "cy": to[1]}), field(d["speed"], speed, "V_Float"), field(d["health"], health, "V_Int")])
    # Snails crawl (stomp or hit them twice); boars charge when they see the hero (three hits);
    # bees fly their patrol and dive at the hero (one hit)
    for cx, cy, to in [(8, 23, (12, 23)), (29, 21, (37, 21)), (62, 19, (73, 19)), (113, 21, (124, 21)), (146, 20, (153, 20))]:
        enemy("Snail", cx, cy, to, 24.0, 2)
    for cx, cy, to in [(48, 23, (41, 23)), (92, 23, (79, 23)), (134, 24, (128, 24)), (184, 23, (194, 23))]:
        enemy("Boar", cx, cy, to, 40.0, 3)
    for cx, cy, to in [(78, 16, (86, 13)), (101, 9, (106, 15)), (118, 13, (124, 16)), (149, 14, (158, 12)), (176, 17, (190, 15))]:
        enemy("Bee", cx, cy, to, 50.0, 1)

    coins = [(19, 20), (20, 19), (21, 20)]                                    # over the meadow's mound and pit
    coins += [(x, 20) for x in range(27, 38, 2)] + [(31, 16), (32, 16)]      # the step and its plank
    coins += [(x, 19) for x in range(53, 59)]                                 # over the bridge
    coins += [(x, 18) for x in range(61, 75, 3)] + [(67, 14), (68, 14)]      # the hill
    coins += [(x, 22) for x in range(77, 104, 4)]                             # the long flat
    coins += [(82, 18), (89, 14)]                                             # up to the key
    coins += [(106, 19), (107, 18)]                                           # over the pit
    coins += [(x, 15) for x in range(112, 117)]                               # the plank
    coins += [(x, 23) for x in range(128, 140, 3)]                            # the dip
    coins += [(x, 20) for x in range(141, 145)]                               # the second bridge
    coins += [(x, 19) for x in range(146, 154, 2)] + [(159, 18)]              # the bee hill
    coins += [(x, 18) for x in range(165, 169)]                               # by the gate
    coins += [(x, 22) for x in range(176, 194, 3)]                            # the last stretch
    for cx, cy in coins:
        entity("Coin", cx, cy, [field(value_def, 1, "V_Int")])
    entity("Coin", 97, 8, [field(value_def, 5, "V_Int")], key="Coin-big")  # above the key: worth 5
    gate = entity("Gate", 172, 23, key="Gate")
    gate_ref = make("EntityReferenceInfos", entityIid=gate["iid"], layerIid=entities_iid, levelIid=level_iid, worldIid=world_iid)
    entity("Key", 97, 11, [field(opens_def, gate_ref)], key="Key")
    entity("Chest", 195, 23, key="Chest")

    # The ground's tiles, by the rules
    int_csv = [grid[y][x] for y in range(H) for x in range(W)]
    auto_tiles = []
    for y in range(H):
        for x in range(W):
            for r, (name, pattern, ids) in zip(rules, RULES):
                if matches(pattern, x, y):
                    t = random.choice(ids)
                    auto_tiles.append(make("Tile", px=[x * G, y * G], src=[(t % TILES_COLS) * G, (t // TILES_COLS) * G], f=0, t=t, a=1.0,
                                           d=[r["uid"], x + y * W]))
                    break

    # Decor: mushrooms, flowers, grass on the ground's top (cells above ground with ground below,
    # not where an entity stands); two-cell items take the cell above too
    decor = []
    tall = {"lavender": [(17, 17), (17, 18)], "blue flower": [(15, 17), (15, 18)]}
    small = [(15, 15), (15, 16), (20, 16), (16, 19), (22, 17), (16, 17)]
    taken = {(e["__grid"][0], e["__grid"][1]) for e in instances}
    for x in range(2, W - 2):
        for y in range(1, H):
            if at(x, y) != 0 or at(x, y + 1) != GROUND or (x, y) in taken: continue
            roll = random.random()
            if roll < 0.18:
                cx, cy = random.choice(small)
                decor.append((x, y, cx, cy))
            elif roll < 0.26:
                parts = random.choice(list(tall.values()))
                decor.append((x, y - 1, *parts[0]))
                decor.append((x, y, *parts[1]))
    decor_tiles = [make("Tile", px=[x * G, y * G], src=[cx * G, cy * G], f=random.choice([0, 1]) if cy != 17 else 0, t=tid(cx, cy), a=1.0, d=[x + y * W])
                   for x, y, cx, cy in decor]

    # The trees, their bottom on the meadow's ground line (row 24). trees.png has clusters of
    # trees (dark: columns 0-21, light: 22-43) and two seamless fills with jagged tops (dark:
    # 44-49, light: 50-55). The far layer is the light fill all across; the near one dark
    # clusters with gaps between them, where the far trees show.
    def strip(first_col, cols, every):
        tiles = []
        base = 24 - 16
        for start in range(0, W, every):
            for c in range(cols):
                for r in range(16):
                    x = start + c
                    if x >= W: continue
                    tiles.append(make("Tile", px=[x * G, (base + r) * G], src=[(first_col + c) * G, r * G], f=0, t=(first_col + c) + r * 56, a=1.0, d=[x + (base + r) * W]))
        return tiles

    def layer(ident, kind, def_uid, tileset=None, rel=None, grid_tiles=(), auto=(), csv=(), ents=(), opacity=1.0, key=None):
        return make("LayerInstance", __identifier=ident, __type=kind, __cWid=W, __cHei=H, __gridSize=G, __opacity=opacity,
                    __pxTotalOffsetX=0, __pxTotalOffsetY=0, __tilesetDefUid=tileset, __tilesetRelPath=rel, iid=key or iid("layer-" + ident),
                    levelId=0, layerDefUid=def_uid, pxOffsetX=0, pxOffsetY=0, visible=True, optionalRules=[], intGridCsv=list(csv),
                    autoLayerTiles=list(auto), seed=7, overrideTilesetUid=None, gridTiles=list(grid_tiles), entityInstances=list(ents))

    layers = [
        layer("Entities", "Entities", L_ENTITIES, ents=instances, key=entities_iid),
        layer("Decor", "Tiles", L_DECOR, TILES, "tiles.png", grid_tiles=decor_tiles),
        layer("Collisions", "IntGrid", L_COLLISIONS, TILES, "tiles.png", auto=auto_tiles, csv=int_csv),
        layer("NearTrees", "Tiles", L_NEAR, TREES, "trees.png", grid_tiles=strip(0, 22, 30)),
        layer("FarTrees", "Tiles", L_FAR, TREES, "trees.png", grid_tiles=strip(50, 6, 6), opacity=0.85),
    ]

    # The sky covers the level, its top showing (scaled to cover the width; cropped below)
    px_w, px_h = W * G, H * G
    SKY_W, SKY_H = 1440, 272
    scale = max(px_w / SKY_W, px_h / SKY_H)
    level = make("Level", identifier="Forest", iid=level_iid, uid=0, worldX=0, worldY=0, worldDepth=0, pxWid=px_w, pxHei=px_h,
                 __bgColor="#8FE1E3", bgColor="#8FE1E3", bgRelPath="sky.png", bgPos="Cover", bgPivotX=0.5, bgPivotY=0.0,
                 __bgPos=make("LevelBgPosInfos", cropRect=[0.0, 0.0, float(SKY_W), px_h / scale], scale=[scale, scale], topLeftPx=[0, 0]),
                 __smartColor="#8FE1E3", useAutoIdentifier=False, externalRelPath=None, fieldInstances=[], __neighbours=[], layerInstances=layers)

    defs = make("Definitions", layers=layer_defs, entities=list(E.values()), tilesets=tilesets, enums=[], externalEnums=[], levelFields=[])
    project = make("LdtkJsonRoot", __header__={"fileType": "LDtk Project JSON", "app": "LDtk", "doc": "https://ldtk.io/json",
                   "schema": "https://ldtk.io/files/JSON_SCHEMA.json", "appAuthor": "Sebastien 'deepnight' Benard", "appVersion": "1.5.3", "url": "https://ldtk.io"},
                   iid=iid("project"), jsonVersion="1.5.3", appBuildId=473703.0, nextUid=uid() + 1, identifierStyle="Capitalize",
                   toc=[], worldLayout="Free", worldGridWidth=256, worldGridHeight=256, defaultLevelWidth=px_w, defaultLevelHeight=px_h,
                   defaultPivotX=0.5, defaultPivotY=1.0, defaultGridSize=G, defaultEntityWidth=16, defaultEntityHeight=16,
                   bgColor="#40465B", defaultLevelBgColor="#8FE1E3", minifyJson=False, externalLevels=False, exportTiled=False,
                   simplifiedExport=False, imageExportMode="None", exportLevelBg=True, pngFilePattern=None, backupOnSave=False,
                   backupLimit=10, backupRelPath=None, levelNamePattern="Level_%idx", tutorialDesc=None, customCommands=[], flags=[],
                   defs=defs, levels=[level], worlds=[], dummyWorldIid=world_iid)

    problems = []
    validate(project, schema["LdtkJsonRoot"], "root", problems)
    for p in problems: print("schema:", p)
    if problems: sys.exit(1)
    with open(os.path.join(OUT, "forest.ldtk"), "w") as f:
        json.dump(project, f, indent="\t")
    print(f"Wrote {OUT}/forest.ldtk: {len(auto_tiles)} ground tiles, {len(decor_tiles)} decor tiles, {len(instances)} entities; valid against LDtk's schema")


if __name__ == "__main__":
    make_level()
