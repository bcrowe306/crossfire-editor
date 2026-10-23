#!/usr/bin/env python3
"""Makes the demo project's art and its LDtk levels (examples/demo_project/assets/).

The demo, "Legacy of the Wardens", is a platformer: run it to (re)create the pictures from the
asset pack and the three levels from the layouts below; after that the levels are meant to be
edited in LDtk, and this script is only needed to start over:

    python3 -I tools/demo/make_demo.py [<Legacy-Fantasy folder>]

(default: ../Legacy-Fantasy beside the editor's checkout). Needs ImageMagick (`magick`) and
Aseprite (`aseprite`, for the hero's file: tools/demo/hero.lua). The sounds and music are made by
tools/demo/make_sounds.py.

What it makes:
- art: the hero as one Aseprite file (every animation tagged, feet aligned, a pivot slice, frame
  events: hero.lua); the boar's and bee's Aseprite files as the pack has them (one per
  animation: animations/*.anim.xml put them together); the snail's sheets; the tileset, the tree
  strips and big trees, skies for day, dusk and night (tinted), props (rune stones, a mine, a
  gate, a platform, candles, pots), items (coin, gem, potion), UI pieces from the HUD sheet
  (parchment and wood panels, icons, bar fills), and the icons LDtk shows entities with
- levels/legacy.ldtk: an LDtk 1.5.3 project with three levels (Forest, Hollow, Lair), built from
  LDtk's own JSON schema (every object gets every key the schema requires) and checked against
  it. The Ground IntGrid layer has auto-layer RULES (grass and stone edges, corners, grass tips,
  planks, water), and the tiles saved with it are what those rules make; values: 1 grass and
  3 stone (solid), 2 planks (one-way), 4 water (an Area: it hurts). Also a Decor tile layer, a
  BackWall layer (the caves' rock behind the hero; the forest behind is the scenes' ParallaxLayer
  nodes), and entities with
  fields (patrols, speeds, health, coin values, platforms' paths, signs' dialogue nodes, exits'
  next scenes).
"""
import json, os, random, shutil, subprocess, sys, tempfile, uuid

EDITOR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKSPACE = os.path.dirname(EDITOR)
PACK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORKSPACE, "Legacy-Fantasy")
ASSETS = os.path.join(EDITOR, "examples", "demo_project", "assets")
SCHEMA = os.path.join(WORKSPACE, "ldtk", "docs", "JSON_SCHEMA.json")
HERE = os.path.dirname(os.path.abspath(__file__))

G = 16                  # grid size
TILES_COLS = 25         # tiles.png: 400 / 16


def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)


def out(*parts):
    path = os.path.join(ASSETS, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def pack(*parts):
    return os.path.join(PACK, *parts)


def crop(src, x, y, w, h, dst, *extra):
    magick(src, "-crop", f"{w}x{h}+{x}+{y}", "+repage", *extra, dst)


# --- Art ---------------------------------------------------------------------------------------

def make_art():
    # The hero: one Aseprite file, every animation a tag (hero.lua)
    subprocess.run(["aseprite", "-b", "--script-param", f"pack={PACK}", "--script-param", f"out={out('characters', 'hero.aseprite')}",
                    "--script", os.path.join(HERE, "hero.lua")], check=True)

    # Mobs: the pack's own Aseprite files, one per animation (they face left)
    for name, path in {
        "idle": "Mob/Boar/Idle/Idle.aseprite", "walk": "Mob/Boar/Walk/Walk-Base.aseprite",
        "run": "Mob/Boar/Run/Run.aseprite", "hit": "Mob/Boar/Hit-Vanish/Hit.aseprite",
    }.items():
        shutil.copy(pack(path), out("mobs", f"boar_{name}.aseprite"))
    for name, path in {
        "fly": "Mob/Small Bee/Fly/Fly.aseprite", "attack": "Mob/Small Bee/Attack/Attack.aseprite",
        "hit": "Mob/Small Bee/Hit/Hit.aseprite",
    }.items():
        shutil.copy(pack(path), out("mobs", f"bee_{name}.aseprite"))
    for name, path in {"walk": "Mob/Snail/walk-Sheet.png", "hide": "Mob/Snail/Hide-Sheet.png", "dead": "Mob/Snail/Dead-Sheet.png"}.items():
        shutil.copy(pack(path), out("mobs", f"snail_{name}.png"))

    # Tiles
    tiles = pack("Assets", "Tiles.png")
    shutil.copy(tiles, out("tiles", "tiles.png"))

    # Skies: the pack's sky three times across (the middle one mirrored, so it joins up), then
    # tinted for the hollow's dusk and the lair's blood-red night
    sky = pack("Background", "Background.png")
    day = out("backgrounds", "sky_day.png")
    magick(sky, "(", sky, "-flop", ")", sky, "+append", "+repage", day)
    # Dusk and night: its shades mapped (lightest at the horizon) from a color above to one below
    magick(day, "-colorspace", "gray", "-auto-level", "-negate", "+level-colors", "#2a2050,#e09a78", out("backgrounds", "sky_dusk.png"))
    magick(day, "-colorspace", "gray", "-auto-level", "-negate", "+level-colors", "#16040c,#9a2836", out("backgrounds", "sky_night.png"))
    # The far forest for the title screen: the light seamless tree fill, and the dark one
    trees = pack("Trees", "Background.png")
    crop(trees, 50 * G, 0, 6 * G, 256, out("backgrounds", "forest_far.png"))
    crop(trees, 44 * G, 0, 6 * G, 256, out("backgrounds", "forest_near.png"))
    # The title screen's ground: grass tips, the grass edge and earth, seamless across
    crop(pack("Assets", "Tiles.png"), G, 0, 3 * G, 4 * G, out("backgrounds", "ground.png"))

    # Props
    props = pack("Assets", "Props-Rocks.png")
    crop(props, 70, 188, 44, 72, out("props", "runestone.png"), "-trim", "+repage")
    # The rune carved on a stone: dark, and lit (blue)
    crop(props, 0, 16 * G, G, G, out("props", "rune_dark.png"))
    crop(props, 9 * G, 16 * G, G, G, out("props", "rune_lit.png"))
    crop(props, 8 * G, 12 * G, 2 * G, 3 * G, out("props", "lorestone.png"), "-trim", "+repage")
    crop(pack("Assets", "Buildings.png"), 272, 212, 128, 156, out("props", "mine.png"))
    crop(tiles, 10 * G, 3 * G, 2 * G, 7 * G, out("props", "gate.png"))
    crop(tiles, 5 * G, 6 * G, 3 * G, G, out("props", "platform.png"))
    crop(tiles, 21 * G, 16 * G, G, G, out("props", "candle.png"))
    crop(tiles, 21 * G, 19 * G, G, 2 * G, out("props", "pot.png"))

    # Items
    crop(tiles, 15 * G, 21 * G, G, G, out("items", "coin.png"), "-trim", "+repage")
    crop(tiles, 15 * G, 22 * G, G, G, out("items", "potion.png"), "-trim", "+repage")
    hud = pack("HUD", "Base-01.png")
    crop(hud, 4 * G, 8 * G, G, G, out("items", "gem.png"), "-trim", "+repage")

    # UI pieces from the HUD sheet: 9-patch panels, the heart icon
    crop(hud, 0, 0, 64, 64, out("ui", "parchment.png"))
    crop(hud, G + 2, 14 * G, 62, 62, out("ui", "wood.png"))
    crop(hud, 4 * G, 9 * G, G, G, out("ui", "icon_heart.png"), "-trim", "+repage")

    # What LDtk shows each entity as: 32 x 32 cells
    icons = [
        ("hero", out("characters", "hero.aseprite") + "[0]", "-crop", "32x48+32+28"),
        ("snail", pack("Mob/Snail/walk-Sheet.png"), "-crop", "32x32+8+0"),
        ("boar", pack("Mob/Boar/Idle/Idle-Sheet.png"), "-crop", "48x32+0+0"),
        ("bee", pack("Mob/Small Bee/Fly/Fly-Sheet.png"), "-crop", "64x64+0+0"),
        ("coin", out("items", "coin.png")), ("gem", out("items", "gem.png")), ("potion", out("items", "potion.png")),
        ("pot", out("props", "pot.png")), ("runestone", out("props", "runestone.png")), ("lorestone", out("props", "lorestone.png")),
        ("platform", out("props", "platform.png")), ("mine", out("props", "mine.png")), ("candle", out("props", "candle.png")),
        ("gate", out("props", "gate.png")), ("boss", pack("Mob/Boar/Run/Run-Sheet.png"), "-crop", "48x32+0+0", "-modulate", "80,70,0"),
        ("portal", out("props", "rune_lit.png")), ("trigger", hud, "-crop", f"{G}x{G}+0+{16 * G}"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        cells = []
        for i, (name, src, *ops) in enumerate(icons):
            cell = os.path.join(tmp, f"{i:02}.png")
            magick(src, *ops, "+repage", "-trim", "+repage", "-resize", "32x32>", "-background", "none", "-gravity", "center", "-extent", "32x32", cell)
            cells.append(cell)
        magick(*cells, "+append", out("levels", "entities.png"))
    ICONS.update({name: i for i, (name, *_) in enumerate(icons)})


ICONS = {}


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
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "crossfire-demo-legacy/" + name))


# --- Ground and its auto-layer rules -----------------------------------------------------------

EMPTY, GRASS, PLANK, STONE, WATER = 0, 1, 2, 3, 4
SOLID_GROUP = 1                      # grass and stone: the solid group
SOLID = (SOLID_GROUP + 1) * 1000     # LDtk's rule value for "any value of the group"
ANY = 0


def tid(cx, cy):
    return cx + cy * TILES_COLS


def edge_rules(value, top_row, tips):
    """Rules for a block of ground in the tileset whose top edge is `top_row` (its tips the row
    above, its sides the two rows below, its bottom the row under them). Edges are where the
    ground meets anything that isn't solid (grass and stone count as one)."""
    r = top_row
    rules = []
    if tips:
        # Grass tips over the top edge: a non-solid cell with this ground below
        rules.append((f"tips-{value}", [ANY, ANY, ANY, ANY, -SOLID, ANY, ANY, value, ANY], [tid(1, r - 1), tid(2, r - 1), tid(3, r - 1)], None))
    rules += [
        (f"top-left-{value}", [ANY, -SOLID, ANY, -SOLID, value, ANY, ANY, ANY, ANY], [tid(0, r)], value),
        (f"top-right-{value}", [ANY, -SOLID, ANY, ANY, value, -SOLID, ANY, ANY, ANY], [tid(4, r)], value),
        (f"top-{value}", [ANY, -SOLID, ANY, ANY, value, ANY, ANY, ANY, ANY], [tid(1, r), tid(2, r), tid(3, r)], value),
        (f"bottom-left-{value}", [ANY, ANY, ANY, -SOLID, value, ANY, ANY, -SOLID, ANY], [tid(0, r + 3)], value),
        (f"bottom-right-{value}", [ANY, ANY, ANY, ANY, value, -SOLID, ANY, -SOLID, ANY], [tid(4, r + 3)], value),
        (f"bottom-{value}", [ANY, ANY, ANY, ANY, value, ANY, ANY, -SOLID, ANY], [tid(1, r + 3), tid(2, r + 3), tid(3, r + 3)], value),
        (f"left-{value}", [ANY, ANY, ANY, -SOLID, value, ANY, ANY, ANY, ANY], [tid(0, r + 1), tid(0, r + 2)], value),
        (f"right-{value}", [ANY, ANY, ANY, ANY, value, -SOLID, ANY, ANY, ANY], [tid(4, r + 1), tid(4, r + 2)], value),
        (f"inside-{value}", [ANY, ANY, ANY, ANY, value, ANY, ANY, ANY, ANY], [tid(1, r + 1), tid(2, r + 1), tid(3, r + 1), tid(1, r + 2), tid(2, r + 2), tid(3, r + 2)], value),
    ]
    return rules


# (name, 3 x 3 pattern row by row, tiles to pick from, value outside the level: None makes
# the rule fail there, as LDtk does)
RULES = edge_rules(GRASS, 1, True) + edge_rules(STONE, 6, False) + [
    ("plank-left", [ANY, ANY, ANY, -PLANK, PLANK, ANY, ANY, ANY, ANY], [tid(5, 6)], PLANK),
    ("plank-right", [ANY, ANY, ANY, ANY, PLANK, -PLANK, ANY, ANY, ANY], [tid(7, 6)], PLANK),
    ("plank", [ANY, ANY, ANY, ANY, PLANK, ANY, ANY, ANY, ANY], [tid(6, 6)], PLANK),
    ("water-surface", [ANY, -WATER, ANY, ANY, WATER, ANY, ANY, ANY, ANY], [tid(6, 19), tid(7, 19), tid(8, 19), tid(9, 19)], WATER),
    ("water", [ANY, ANY, ANY, ANY, WATER, ANY, ANY, ANY, ANY], [tid(6, 20), tid(7, 20), tid(8, 20), tid(9, 20)], WATER),
]
GROUP_OF = {GRASS: SOLID_GROUP, STONE: SOLID_GROUP}


class Map:
    def __init__(self, name, w, h):
        self.name, self.w, self.h = name, w, h
        self.grid = [[EMPTY] * w for _ in range(h)]
        self.back = set()           # cells of the BackWall layer
        self.entities = []          # (name, cx, cy, fields: dict, key)
        self.decor = []             # (x, y, tile cx, tile cy, flip)

    def fill(self, x0, x1, y0, y1, value=GRASS):
        for y in range(max(y0, 0), min(y1, self.h - 1) + 1):
            for x in range(max(x0, 0), min(x1, self.w - 1) + 1):
                self.grid[y][x] = value

    def wall(self, x0, x1, y0, y1):
        """Cave rock behind the hero (the BackWall layer) over a rectangle's empty cells."""
        for y in range(max(y0, 0), min(y1, self.h - 1) + 1):
            for x in range(max(x0, 0), min(x1, self.w - 1) + 1):
                self.back.add((x, y))

    def at(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h: return self.grid[y][x]
        return None

    def matches(self, pattern, oob, x, y):
        """LDtk's check (AutoLayerRuleDef.matches): each pattern cell against the grid."""
        for i, want in enumerate(pattern):
            if want == ANY: continue
            value = self.at(x + i % 3 - 1, y + i // 3 - 1)
            if value is None: value = oob
            if value is None: return False
            if abs(want) > 999:
                in_group = GROUP_OF.get(value) == abs(want) // 1000 - 1
                if want > 0 and not in_group: return False
                if want < 0 and in_group: return False
            else:
                if want > 0 and value != want: return False
                if want < 0 and value == -want: return False
        return True

    def solid(self, x, y):
        return self.at(x, y) in (GRASS, STONE)

    def entity(self, name, cx, cy, key=None, **fields):
        assert self.at(cx, cy) in (EMPTY, None), f"{self.name}: {name} at {cx},{cy} is inside the ground"
        self.entities.append((name, cx, cy, fields, key))


# --- The levels ----------------------------------------------------------------------------------
#
# The hero jumps about 4.5 cells up and 7 across (at a run), so steps up are at most 4 and gaps
# at most 6; the camera shows about 27 x 15 cells.

def forest():
    """Level 1, the Whispering Woods: a sunny forest that teaches the moves, then tests them."""
    m = Map("Forest", 210, 30)
    f = m.fill
    f(0, 1, 6, 29, GRASS)              # a cliff on the left
    f(0, 30, 24, 29)                   # the meadow
    f(14, 17, 22, 23)                  # a mound
    f(35, 47, 22, 29)                  # a step up after the first pit
    f(39, 43, 18, 18, PLANK)
    f(48, 63, 24, 29)                  # the boar's hollow
    f(53, 56, 20, 20, PLANK)
    f(64, 67, 24, 29)                  # the pond's bank
    f(68, 77, 26, 27, WATER)           # the pond (it hurts)
    f(68, 77, 28, 29)
    f(78, 93, 24, 29)                  # bees over the meadow
    f(82, 85, 20, 20, PLANK)
    f(94, 99, 21, 29)                  # stairs up the hill
    f(100, 106, 18, 29)
    f(101, 104, 13, 13, PLANK)         # a gem above the stairs
    f(107, 118, 20, 29)
    f(109, 112, 16, 16, PLANK)
    # 119..131: a wide gorge, crossed on a moving platform
    f(132, 150, 22, 29)                # the far side: the second rune stone
    f(140, 143, 18, 18, PLANK)
    f(151, 155, 25, 29)                # a dip
    f(156, 186, 24, 29)                # the last stretch, under the bees
    f(160, 163, 20, 20, PLANK)
    f(167, 170, 17, 17, PLANK)
    f(174, 177, 20, 20, PLANK)
    f(187, 209, 23, 29)                # the mine's ledge
    f(208, 209, 6, 22, GRASS)          # a cliff on the right

    e = m.entity
    e("Hero", 5, 23)
    e("Lorestone", 9, 23, dialogue="Sign_Move")
    e("Lorestone", 25, 23, dialogue="Sign_Attack")
    e("Snail", 20, 23, speed=22.0, health=2)
    for x in (7, 8, 11, 12): e("Coin", x, 21)
    for x in (15, 16): e("Coin", x, 19)
    for x in (31, 32, 33): e("Coin", x, 20)          # over the first pit
    e("Runestone", 37, 21, key="cp-forest-1")
    for x in range(40, 43): e("Coin", x, 16)
    e("Gem", 41, 14, key="gem-forest-1")
    e("Pot", 45, 21, coins=3)
    e("Lorestone", 49, 23, dialogue="Sign_Stomp")
    e("Boar", 58, 23, patrol={"cx": 51, "cy": 23}, speed=38.0, health=3)
    for x in (54, 55): e("Coin", x, 18)
    e("Lorestone", 65, 23, dialogue="Sign_Water")
    e("Platform", 69, 23, path={"cx": 75, "cy": 23}, speed=40.0)
    for x in range(70, 76, 2): e("Coin", x, 21)
    e("Bee", 84, 16, patrol={"cx": 90, "cy": 15}, speed=45.0, health=1)
    e("Snail", 88, 23, speed=26.0, health=2)
    for x in range(83, 85): e("Coin", x, 18)
    e("Potion", 92, 23)
    for x in (96, 97): e("Coin", x, 19)
    e("Gem", 102, 11, key="gem-forest-2")
    e("Pot", 105, 17, coins=2)
    e("Bee", 113, 13, patrol={"cx": 117, "cy": 17}, speed=50.0, health=1)
    for x in (110, 111): e("Coin", x, 14)
    e("Boar", 115, 19, patrol={"cx": 108, "cy": 19}, speed=40.0, health=3)
    e("Platform", 120, 21, path={"cx": 129, "cy": 21}, speed=48.0)
    for x in range(121, 131, 3): e("Coin", x, 18)
    e("Runestone", 134, 21, key="cp-forest-2")
    e("Snail", 145, 21, speed=26.0, health=2)
    for x in range(141, 143): e("Coin", x, 16)
    e("Pot", 149, 21, coins=4)
    e("Boar", 166, 23, patrol={"cx": 158, "cy": 23}, speed=42.0, health=3)
    e("Bee", 162, 15, patrol={"cx": 170, "cy": 13}, speed=50.0, health=1)
    e("Bee", 176, 15, patrol={"cx": 182, "cy": 18}, speed=55.0, health=1)
    for x in range(161, 163): e("Coin", x, 18)
    for x in range(168, 170): e("Coin", x, 15)
    e("Gem", 168, 12, key="gem-forest-3")
    for x in range(175, 177): e("Coin", x, 18)
    e("Potion", 184, 23)
    e("Boar", 197, 22, patrol={"cx": 190, "cy": 22}, speed=44.0, health=4)
    e("Exit", 203, 22, next="HollowScene", kind="Mine")
    return m


def hollow():
    """Level 2, the Shadowed Hollow: a forest at dusk over a hill, a dark cave under it (lit by
    the hero's lantern and candles), bees that hunt her through the tunnels, and a climb back out
    of a chasm."""
    m = Map("Hollow", 180, 48)
    f = m.fill
    f(0, 1, 0, 47, STONE)              # the left edge
    f(0, 179, 18, 47, GRASS)           # the ground everywhere, carved below
    f(20, 25, 16, 17, GRASS)           # a step
    f(26, 140, 13, 17, GRASS)          # the hill over the cave
    f(40, 140, 18, 21, STONE)          # the cave's ceiling
    f(30, 33, 9, 9, PLANK)
    f(46, 49, 9, 9, PLANK)
    # The cave, carved out of the ground (the BackWall behind it)
    for y in range(22, 40):
        for x in range(40, 152): m.grid[y][x] = EMPTY
    f(40, 151, 40, 47, STONE)          # its floor
    m.wall(40, 151, 22, 39)
    # The shaft down from the hill, its planks to land on
    for y in range(13, 22):
        for x in range(60, 66): m.grid[y][x] = EMPTY
    f(56, 59, 18, 21, STONE)
    f(66, 69, 18, 21, STONE)
    m.wall(60, 65, 18, 21)
    f(60, 62, 26, 26, PLANK)
    f(63, 65, 31, 31, PLANK)
    # In the cave
    f(46, 50, 36, 39, STONE)           # a rock to climb
    f(74, 80, 38, 39, WATER)           # a pool
    f(76, 78, 33, 33, PLANK)
    f(84, 88, 22, 27, STONE)           # a hanging rock
    f(92, 97, 36, 39, STONE)
    f(99, 102, 32, 32, PLANK)
    f(106, 111, 22, 30, STONE)         # a pillar from the ceiling: a crawl under it
    f(114, 124, 37, 39, WATER)         # a wide pool, a platform over it
    f(128, 132, 36, 39, STONE)
    f(135, 138, 32, 32, PLANK)
    # The chasm at the end: open to the sky, climbed on a rising platform
    for y in range(0, 40):
        for x in range(141, 152): m.grid[y][x] = EMPTY
    # Planks up the chasm's sides (each a jump from the last), and the rising platform between
    f(141, 144, 36, 36, PLANK)
    f(148, 151, 32, 32, PLANK)
    f(141, 144, 28, 28, PLANK)
    f(148, 151, 24, 24, PLANK)
    f(148, 151, 20, 20, PLANK)
    f(178, 179, 0, 17, STONE)          # the right edge

    e = m.entity
    e("Hero", 5, 17)
    e("Lorestone", 8, 17, dialogue="Hollow_Intro")
    e("Snail", 15, 17, speed=28.0, health=2)
    for x in (22, 23): e("Coin", x, 14)
    e("Candle", 27, 12)
    for x in (31, 32): e("Coin", x, 7)
    e("Gem", 47, 7, key="gem-hollow-1")
    e("Boar", 52, 12, patrol={"cx": 36, "cy": 12}, speed=44.0, health=3)
    e("Lorestone", 58, 12, dialogue="Sign_Shaft")
    for y in (24, 29, 34): e("Coin", 62 if y != 29 else 64, y)
    e("Candle", 66, 39)
    e("Runestone", 70, 39, key="cp-hollow-1")
    e("Snail", 55, 39, speed=30.0, health=3)
    e("Candle", 44, 35)
    e("Pot", 42, 39, coins=3)
    for x in range(75, 80, 2): e("Coin", x, 31)
    e("Gem", 77, 30, key="gem-hollow-2")
    e("Bee", 82, 30, chase=True, speed=60.0, health=1)
    e("Boar", 90, 39, patrol={"cx": 82, "cy": 39}, speed=45.0, health=3)
    e("Candle", 98, 34)
    e("Pot", 103, 39, coins=3)
    for x in (100, 101): e("Coin", x, 29)
    e("Lorestone", 104, 39, dialogue="Sign_Hunters")
    e("Bee", 104, 26, chase=True, speed=60.0, health=1)
    e("Potion", 112, 39)
    e("Platform", 115, 35, path={"cx": 122, "cy": 35}, speed=40.0)
    e("Runestone", 126, 39, key="cp-hollow-2")
    e("Bee", 128, 27, chase=True, speed=62.0, health=1)
    e("Snail", 134, 39, speed=32.0, health=3)
    e("Candle", 139, 39)
    for x in (136, 137): e("Coin", x, 30)
    e("Gem", 150, 22, key="gem-hollow-3")
    e("Platform", 146, 39, path={"cx": 146, "cy": 19}, speed=45.0)
    e("Bee", 148, 16, chase=True, speed=60.0, health=1)
    # Over the hill
    for x in range(72, 100, 4): e("Coin", x, 11)
    e("Snail", 90, 12, speed=30.0, health=2)
    e("Bee", 118, 8, patrol={"cx": 126, "cy": 10}, speed=50.0, health=1)
    # The surface after the climb
    e("Boar", 166, 17, patrol={"cx": 156, "cy": 17}, speed=48.0, health=4)
    e("Potion", 158, 17)
    e("Exit", 173, 17, next="LairScene", kind="Portal")
    return m


def lair():
    """Level 3, the Heart of the Forest: a short road under a red night, then the arena where
    Grimtusk, the corrupted boar, waits."""
    m = Map("Lair", 112, 30)
    f = m.fill
    f(0, 1, 4, 29, STONE)
    f(0, 22, 24, 29)
    f(23, 27, 25, 29, WATER)
    f(23, 27, 28, 29)
    f(28, 41, 23, 29)
    f(31, 34, 19, 19, PLANK)
    f(42, 43, 4, 19, STONE)            # the arena's left wall (the gate closes under it)
    f(42, 105, 24, 29)                 # the arena's floor
    f(52, 57, 19, 19, PLANK)
    f(71, 76, 16, 16, PLANK)
    f(90, 95, 19, 19, PLANK)
    f(106, 111, 0, 29, STONE)          # its right wall
    f(42, 105, 0, 3, STONE)            # its roof

    e = m.entity
    e("Hero", 4, 23)
    e("Lorestone", 8, 23, dialogue="Lair_Road")
    e("Boar", 18, 23, patrol={"cx": 11, "cy": 23}, speed=46.0, health=4)
    for x in range(23, 28, 2): e("Coin", x, 21)
    e("Bee", 32, 15, chase=False, patrol={"cx": 38, "cy": 18}, speed=55.0, health=1)
    e("Potion", 33, 18)
    e("Runestone", 37, 22, key="cp-lair-1")
    e("Gate", 43, 23, key="gate")
    # The trigger closes the gate its "gate" field points at (an entity reference)
    e("BossTrigger", 47, 20, w=2, h=4, gate={"ref": "gate"})
    e("Boss", 88, 23)
    return m


# --- lair.ldtk --------------------------------------------------------------------------------

def tile_rect(tileset, x, y, w, h):
    return make("TilesetRect", tilesetUid=tileset, x=x, y=y, w=w, h=h)


def make_levels():
    random.seed(7)
    TILES, ICONSET = 1, 3
    def tileset(ident, uid_, rel, w, h):
        return make("TilesetDef", __cWid=w // G, __cHei=h // G, identifier=ident, uid=uid_, relPath=rel, pxWid=w, pxHei=h, tileGridSize=G)
    tilesets = [
        tileset("Tiles", TILES, "../tiles/tiles.png", 400, 400),
        make("TilesetDef", __cWid=len(ICONS), __cHei=1, identifier="Entities", uid=ICONSET, relPath="entities.png",
             pxWid=32 * len(ICONS), pxHei=32, tileGridSize=32),
    ]

    L_ENTITIES, L_DECOR, L_GROUND, L_BACK = uid(), uid(), uid(), uid()
    rules = []
    for name, pattern, ids, oob in RULES:
        rules.append(make("AutoRuleDef", uid=uid(), active=True, alpha=1.0, breakOnMatch=True, chance=1.0, checker="None",
                          pattern=pattern, size=3, tileMode="Single", tileRectsIds=[[i] for i in ids],
                          perlinOctaves=2.0, perlinScale=0.2, perlinSeed=float(uid()), pivotX=0.0, pivotY=0.0,
                          xModulo=1, yModulo=1, outOfBoundsValue=oob))
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
        layer_def(L_GROUND, "Ground", "IntGrid", tilesetDefUid=TILES, autoRuleGroups=[group],
                  intGridValuesGroups=[make("IntGridValueGroupDef", uid=SOLID_GROUP, identifier="solid", color="#5B8A3C")],
                  intGridValues=[
                      make("IntGridValueDef", value=GRASS, identifier="grass", color="#5B8A3C", groupUid=SOLID_GROUP, tile=None),
                      make("IntGridValueDef", value=PLANK, identifier="plank", color="#8A5B3C", groupUid=0, tile=None),
                      make("IntGridValueDef", value=STONE, identifier="stone", color="#6B6258", groupUid=SOLID_GROUP, tile=None),
                      make("IntGridValueDef", value=WATER, identifier="Water", color="#3C8FC4", groupUid=0, tile=None),
                  ]),
        layer_def(L_BACK, "BackWall", "Tiles", tilesetDefUid=TILES, displayOpacity=0.55),
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
    def icon(name):
        return tile_rect(ICONSET, ICONS[name] * 32, 0, 32, 32)
    def entity_def(ident, w, h, color, pivot, tile, fields, render="Tile", resizable=False):
        values = dict(identifier=ident, uid=uid(), width=w, height=h, color=color, pivotX=pivot[0], pivotY=pivot[1],
                      renderMode=render, tileRect=tile, tilesetId=tile["tilesetUid"] if tile else None, tileRenderMode="FitInside",
                      tileOpacity=1.0, fillOpacity=0.08, lineOpacity=0.0 if render == "Tile" else 1.0, hollow=False,
                      showName=True, nineSliceBorders=[], maxCount=0, limitScope="PerLevel", limitBehavior="MoveLastOne",
                      keepAspectRatio=False, resizableX=resizable, resizableY=resizable, allowOutOfBounds=False, exportToToc=False,
                      tags=[], fieldDefs=fields, uiTileRect=None, doc=None, minWidth=None, maxWidth=None, minHeight=None, maxHeight=None)
        return make("EntityDef", **values)
    def float_def(name, value): return field_def(name, "F_Float", "Float", {"id": "V_Float", "params": [value]})
    def int_def(name, value): return field_def(name, "F_Int", "Int", {"id": "V_Int", "params": [value]})
    def bool_def(name, value): return field_def(name, "F_Bool", "Bool", {"id": "V_Bool", "params": [value]})
    def string_def(name, value): return field_def(name, "F_String", "String", {"id": "V_String", "params": [value]})
    def point_def(name): return field_def(name, "F_Point", "Point", None, editorDisplayMode="PointPath")
    E = {}
    def add(ident, *args, **kw):
        E[ident] = entity_def(ident, *args, **kw)
    add("Hero", 16, 32, "#5BC0EB", (0.5, 1.0), icon("hero"), [float_def("speed", 175.0)])
    add("Coin", 16, 16, "#FFD23F", (0.5, 0.5), icon("coin"), [int_def("value", 1)])
    add("Gem", 16, 16, "#4EA8DE", (0.5, 0.5), icon("gem"), [])
    add("Potion", 16, 16, "#E4572E", (0.5, 1.0), icon("potion"), [])
    add("Pot", 16, 32, "#9AA36F", (0.5, 1.0), icon("pot"), [int_def("coins", 2)])
    add("Snail", 32, 20, "#E4572E", (0.5, 1.0), icon("snail"), [point_def("patrol"), float_def("speed", 24.0), int_def("health", 2)])
    add("Boar", 32, 24, "#9C6644", (0.5, 1.0), icon("boar"), [point_def("patrol"), float_def("speed", 40.0), int_def("health", 3)])
    add("Bee", 20, 20, "#F9C74F", (0.5, 0.5), icon("bee"), [point_def("patrol"), float_def("speed", 50.0), int_def("health", 1), bool_def("chase", False)])
    add("Runestone", 32, 48, "#4EA8DE", (0.5, 1.0), icon("runestone"), [])
    add("Lorestone", 16, 24, "#B8A07E", (0.5, 1.0), icon("lorestone"), [string_def("dialogue", "")])
    add("Platform", 48, 16, "#8A5B3C", (0.5, 1.0), icon("platform"), [point_def("path"), float_def("speed", 40.0)])
    add("Candle", 16, 16, "#FFB347", (0.5, 1.0), icon("candle"), [])
    add("Exit", 32, 48, "#9B5DE5", (0.5, 1.0), icon("mine"), [string_def("next", ""), string_def("kind", "Mine")])
    add("Gate", 32, 112, "#8D6346", (0.5, 1.0), icon("gate"), [])
    gate_ref_def = field_def("gate", "F_EntityRef", "EntityRef", None, editorDisplayMode="RefLinkBetweenCenters", editorLinkStyle="CurvedArrow")
    add("BossTrigger", 32, 64, "#D7263D", (0.0, 0.0), None, [gate_ref_def], render="Rectangle", resizable=True)
    add("Boss", 96, 64, "#7B2D26", (0.5, 1.0), icon("boss"), [int_def("health", 36)])

    world_iid = iid("world")
    levels = []
    world_x = 0
    for index, m in enumerate((forest(), hollow(), lair())):
        level_iid = iid(f"level-{m.name}")
        entities_iid = iid(f"layer-{m.name}-entities")

        def field(fdef, value, kind=None):
            return make("FieldInstance", __identifier=fdef["identifier"], __type=fdef["__type"], __value=value, defUid=fdef["uid"],
                        __tile=None, realEditorValues=[] if value is None else [{"id": kind, "params": [value]}] if kind else [])
        instances = []
        for name, cx, cy, values, key in m.entities:
            d = E[name]
            defs = {fd["identifier"]: fd for fd in d["fieldDefs"]}
            fields = []
            w, h = d["width"], d["height"]
            if "w" in values: w = values.pop("w") * G
            if "h" in values: h = values.pop("h") * G
            for fname, fd in defs.items():
                if fname not in values: continue
                v = values[fname]
                kind = {"Float": "V_Float", "Int": "V_Int", "Bool": "V_Bool", "String": "V_String"}.get(fd["__type"])
                if fd["__type"] == "EntityRef":
                    ref = make("EntityReferenceInfos", entityIid=iid(f"{m.name}/{v['ref']}"), layerIid=entities_iid, levelIid=level_iid, worldIid=world_iid)
                    fields.append(make("FieldInstance", __identifier=fname, __type="EntityRef", __value=ref, defUid=fd["uid"], __tile=None, realEditorValues=[]))
                elif fd["__type"] == "Point":
                    fields.append(make("FieldInstance", __identifier=fname, __type="Point", __value=v, defUid=fd["uid"], __tile=None,
                                       realEditorValues=[{"id": "V_Int", "params": [v["cx"] + v["cy"] * m.w]}]))
                else:
                    fields.append(field(fd, float(v) if fd["__type"] == "Float" else v, kind))
            # px: where its pivot is (a pivot at the bottom stands on the cell's bottom edge)
            px = [cx * G + int(G * d["pivotX"]) if d["pivotX"] != 0.5 else cx * G + 8,
                  cy * G + (G if d["pivotY"] == 1.0 else 0 if d["pivotY"] == 0.0 else 8)]
            instances.append(make("EntityInstance", __identifier=name, __grid=[cx, cy], __pivot=[d["pivotX"], d["pivotY"]],
                                  __smartColor=d["color"], __tags=[], __tile=d["tileRect"], __worldX=world_x + px[0], __worldY=px[1],
                                  defUid=d["uid"], fieldInstances=fields, height=h, width=w,
                                  iid=iid(f"{m.name}/{key or f'{name}-{cx}-{cy}'}"), px=px))

        # The ground's tiles, by the rules
        rule_defs = rules
        auto_tiles = []
        for y in range(m.h):
            for x in range(m.w):
                for r, (name, pattern, ids, oob) in zip(rule_defs, RULES):
                    if m.matches(pattern, oob, x, y):
                        t = random.choice(ids)
                        auto_tiles.append(make("Tile", px=[x * G, y * G], src=[(t % TILES_COLS) * G, (t // TILES_COLS) * G], f=0, t=t, a=1.0,
                                               d=[r["uid"], x + y * m.w]))
                        break

        # Decor on the ground's top: mushrooms, flowers, grass (not where an entity stands)
        taken = {(cx, cy) for _, cx, cy, _, _ in m.entities} | {(cx, cy - 1) for _, cx, cy, _, _ in m.entities}
        tall = [[(17, 17), (17, 18)], [(15, 17), (15, 18)]]
        small = [(15, 15), (15, 16), (20, 16), (16, 19), (22, 17), (16, 17)]
        decor = []
        for x in range(2, m.w - 2):
            for y in range(1, m.h):
                if m.at(x, y) != EMPTY or m.at(x, y + 1) not in (GRASS,) or (x, y) in taken: continue
                if (x, y) in m.back: continue
                roll = random.random()
                if roll < 0.16:
                    decor.append((x, y) + random.choice(small))
                elif roll < 0.23 and m.at(x, y - 1) == EMPTY:
                    parts = random.choice(tall)
                    decor.append((x, y - 1) + parts[0])
                    decor.append((x, y) + parts[1])
        decor_tiles = [make("Tile", px=[x * G, y * G], src=[cx * G, cy * G], f=random.choice([0, 1]) if cy not in (17, 18) else 0,
                            t=tid(cx, cy), a=1.0, d=[x + y * m.w]) for x, y, cx, cy in decor]

        # The caves' back wall: the dark inside of the stone, where nothing solid is
        back_tiles = []
        for (x, y) in sorted(m.back):
            cx, cy = random.choice([(1, 7), (2, 7), (3, 7), (1, 8), (2, 8), (3, 8)])
            back_tiles.append(make("Tile", px=[x * G, y * G], src=[cx * G, cy * G], f=random.choice([0, 1, 2, 3]), t=tid(cx, cy), a=1.0, d=[x + y * m.w]))

        def layer(ident, kind, def_uid, tileset=None, rel=None, grid_tiles=(), auto=(), csv=(), ents=(), opacity=1.0, key=None):
            return make("LayerInstance", __identifier=ident, __type=kind, __cWid=m.w, __cHei=m.h, __gridSize=G, __opacity=opacity,
                        __pxTotalOffsetX=0, __pxTotalOffsetY=0, __tilesetDefUid=tileset, __tilesetRelPath=rel,
                        iid=key or iid(f"layer-{m.name}-{ident}"), levelId=index, layerDefUid=def_uid, pxOffsetX=0, pxOffsetY=0,
                        visible=True, optionalRules=[], intGridCsv=list(csv), autoLayerTiles=list(auto), seed=7 + index,
                        overrideTilesetUid=None, gridTiles=list(grid_tiles), entityInstances=list(ents))
        layers = [
            layer("Entities", "Entities", L_ENTITIES, ents=instances, key=entities_iid),
            layer("Decor", "Tiles", L_DECOR, TILES, "../tiles/tiles.png", grid_tiles=decor_tiles),
            layer("Ground", "IntGrid", L_GROUND, TILES, "../tiles/tiles.png", auto=auto_tiles, csv=[c for row in m.grid for c in row]),
            layer("BackWall", "Tiles", L_BACK, TILES, "../tiles/tiles.png", grid_tiles=back_tiles, opacity=0.55),
        ]
        color = {"Forest": "#8FE1E3", "Hollow": "#2A2A48", "Lair": "#2A0E16"}[m.name]
        levels.append(make("Level", identifier=m.name, iid=level_iid, uid=index, worldX=world_x, worldY=0, worldDepth=0,
                           pxWid=m.w * G, pxHei=m.h * G, __bgColor=color, bgColor=color, bgRelPath=None, bgPos=None,
                           bgPivotX=0.5, bgPivotY=0.0, __bgPos=None, __smartColor=color, useAutoIdentifier=False,
                           externalRelPath=None, fieldInstances=[], __neighbours=[], layerInstances=layers))
        print(f"  {m.name}: {m.w} x {m.h} cells, {len(auto_tiles)} ground tiles, {len(decor_tiles)} decor, {len(back_tiles)} back wall, {len(instances)} entities")
        world_x += m.w * G + 256

    defs = make("Definitions", layers=layer_defs, entities=list(E.values()), tilesets=tilesets, enums=[], externalEnums=[], levelFields=[])
    project = make("LdtkJsonRoot", __header__={"fileType": "LDtk Project JSON", "app": "LDtk", "doc": "https://ldtk.io/json",
                   "schema": "https://ldtk.io/files/JSON_SCHEMA.json", "appAuthor": "Sebastien 'deepnight' Benard", "appVersion": "1.5.3", "url": "https://ldtk.io"},
                   iid=iid("project"), jsonVersion="1.5.3", appBuildId=473703.0, nextUid=uid() + 1, identifierStyle="Capitalize",
                   toc=[], worldLayout="Free", worldGridWidth=256, worldGridHeight=256, defaultLevelWidth=256 * G, defaultLevelHeight=30 * G,
                   defaultPivotX=0.5, defaultPivotY=1.0, defaultGridSize=G, defaultEntityWidth=16, defaultEntityHeight=16,
                   bgColor="#40465B", defaultLevelBgColor="#8FE1E3", minifyJson=False, externalLevels=False, exportTiled=False,
                   simplifiedExport=False, imageExportMode="None", exportLevelBg=True, pngFilePattern=None, backupOnSave=False,
                   backupLimit=10, backupRelPath=None, levelNamePattern="Level_%idx", tutorialDesc=None, customCommands=[], flags=[],
                   defs=defs, levels=levels, worlds=[], dummyWorldIid=world_iid)

    problems = []
    validate(project, schema["LdtkJsonRoot"], "root", problems)
    for p in problems: print("schema:", p)
    if problems: sys.exit(1)
    path = out("levels", "legacy.ldtk")
    with open(path + ".tmp", "w") as f:
        # Compact (LDtk reads it as it is, and writes it back its own way when saved)
        json.dump(project, f, separators=(",", ":"))
    os.replace(path + ".tmp", path)
    print(f"Wrote {path}: valid against LDtk's schema")


if __name__ == "__main__":
    make_art()
    make_levels()
