package crossfire_editor

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
The Auto-layer Rules tab's edits (phase 4 of TODO.md's "LDtk level editor"), as LDtk's rule panel
and rule editor make them (its source in the workspace's `../ldtk`, 1.5.3:
ui/modal/panel/EditAllAutoLayerRules.hx, ui/modal/dialog/RuleEditor.hx, RuleModuloEditor,
RulePerlinSettings, RuleRandomOffsets, RuleGroupRemap, RulesWizard, ui/RulePatternEditor.hx,
data/def/AutoLayerRuleDef.hx, AutoLayerRuleGroupDef.hx, LayerDef.hx's rule functions,
Definitions.sortLayerAutoRules / sortLayerAutoGroup).

**How an edit is made.** The layer definition's rule groups are read (`LDtkRules_ReadGroups`: every
group and rule as LDtk's fromJson reads them), changed, and written back as LDtk's toJson writes
them (`ldtkGroupJV`, `ldtkRuleJV`), every rule tidied first as toJson tidies it (`LDtkRule_Tidy`:
the pattern trimmed, flips of symmetric patterns and checker modes without a modulo turned off, a
lost out-of-bounds value cleared). An untouched group is written byte for byte as it was (a test
reads and writes back every group of LDtk's samples). Then LDtk's tidy (ldtk_tidy.odin) and the
rules applied again in every level (`rerunRules`: LDtk applies an invalidated rule and the ones
after it in the current level, then the others when the panel closes or the project saves; the
result is the same as applying them all again). One document change, one undo step.

**The edits** (`LDtk_Edit`: `def` the layer definition's uid, `index` a group's uid, `field` a
rule's uid):
- groups: `Rule_Group_Added` (`text` its name, "" LDtk's "New group"; `number` its place: LDtk's 0),
  `_Removed`, `_Duplicated` (after it, new uids), `_Moved` (`number` places), `_Set` (`key`: name,
  active, color ("#RRGGBB", "" none), icon ("x,y,w,h" of the tileset `number`, "" none),
  isOptional, requiredBiomeValues (names, comma separated: sorted as LDtk sorts them),
  biomeRequirementMode (0 any, 1 all), usesWizard (false: LDtk's advanced mode),
  outOfBoundsValue (every rule's: "" none, "0" empty cells, a value)), `_Here` (an optional group
  on or off in the level `level`: its layer instance's `optionalRules`), `_Remapped` (LDtk's
  Duplicate and Remap: `text` the copy's name, `ids` old and new IntGrid values in pairs,
  `number` / `number2` the tiles' offset in cells), `_Assistant` (LDtk's Rule Assistant:
  ldtk_rule_assistant.odin);
- rules: `Rule_Added` (`index` the group, `number` its place), `_Removed`, `_Duplicated` (after it),
  `_Moved` (into the group `index` at `number`), `_Set` (`key` a member of `LDTK_RULE_MEMBERS`, its
  value in `number`, `text` or `flag`; a fraction typed as a percentage has `number2` 100),
  `_Pattern` (`ids`: the `number` x `number` pattern, as the
  rule editor's 9 x 9 grid), `_Tiles` (`key` "single": `ids` each a tile; "stamp": `ids` a
  rectangle's tiles at `number` (-1 a new one); "remove": the rectangle `number`);
- `Rule_Pasted` (`key` "rule" or "group", `text` its JSON as copied: LDtk's clipboard, after the
  rule `field` or group `index`, -1 at the end);
- the level's layer instance (`level`): `Rule_Seed` (`number` the new seed, < 0 a random one: LDtk's
  Randomize), `Rule_Tileset_Here` (`number` a tileset of the same size, -1 the layer's own).

Refused as LDtk refuses them: groups on a layer whose settings stop its rules working, rules of a
group the Assistant manages (edited with the Assistant, or after Advanced mode), flips of a
symmetric pattern, a checker mode without its modulo, another level's tileset of another size.
Not LDtk's: a new empty rule stays until it's removed (LDtk's rule editor removes a rule left empty
when it closes); the Assistant reads back every tile of a group it made (LDtk keeps the first of
each part only).
*/

// A rule group as the rule edits change it (AutoLayerRuleGroupDef: what its toJson writes)
LDtkGroupEdit :: struct {
	uid: int,
	name: string,
	// -1: no color
	color: int,
	// Its icon: the tileset's uid, x, y, w, h (`hasIcon` false: none)
	icon: [5]int,
	hasIcon: bool,
	active, isOptional, usesWizard: bool,
	rules: [dynamic]LDtkRule,
	biome: [dynamic]string,
	biomeMode: int,
}

// A rule member the editors set (`Rule_Set`), its kind and LDtk's bounds
LDtkRuleMember :: struct {
	key: string,
	type: LDtkMemberKind,
	lo, hi: f64,
	label: string,
}

// LDtk's rule options (the panel's row, its modulo, offsets and Perlin dialogs, the rule editor)
LDTK_RULE_MEMBERS := [?]LDtkRuleMember{
	{"active", .Bool, 0, 0, "Enable or disable a rule"},
	{"chance", .Float, 0.01, 1, "Change a rule's chance"},
	{"alpha", .Float, 0.01, 1, "Change a rule's opacity"},
	{"breakOnMatch", .Bool, 0, 0, "Change a rule's break on match"},
	{"flipX", .Bool, 0, 0, "Change a rule's X mirror"},
	{"flipY", .Bool, 0, 0, "Change a rule's Y mirror"},
	{"xModulo", .Int, 1, 40, "Change a rule's modulo"},
	{"yModulo", .Int, 1, 40, "Change a rule's modulo"},
	{"xOffset", .Int, -4096, 4096, "Change a rule's modulo offset"},
	{"yOffset", .Int, -4096, 4096, "Change a rule's modulo offset"},
	{"checker", .Choice, 0, 0, "Change a rule's checker mode"},
	{"moduloReset", .Special, 0, 0, "Reset a rule's modulos"},
	{"tileXOffset", .Int, -1024, 1024, "Change a rule's tile offset"},
	{"tileYOffset", .Int, -1024, 1024, "Change a rule's tile offset"},
	{"tileRandomXMin", .Int, -1024, 1024, "Change a rule's random offset"},
	{"tileRandomXMax", .Int, -1024, 1024, "Change a rule's random offset"},
	{"tileRandomYMin", .Int, -1024, 1024, "Change a rule's random offset"},
	{"tileRandomYMax", .Int, -1024, 1024, "Change a rule's random offset"},
	// The random offset's linked pair (min = -max), and the link turned on
	{"tileRandomX", .Int, 0, 1024, "Change a rule's random offset"},
	{"tileRandomY", .Int, 0, 1024, "Change a rule's random offset"},
	{"tileRandomXLink", .Special, 0, 0, "Link a rule's random offsets"},
	{"tileRandomYLink", .Special, 0, 0, "Link a rule's random offsets"},
	{"offsetsReset", .Special, 0, 0, "Reset a rule's offsets"},
	{"tileMode", .Choice, 0, 0, "Change a rule's tile mode"},
	{"pivot", .Special, 0, 1, "Change a rule's stamp pivot"},
	{"outOfBoundsValue", .Special, 0, 0, "Change a rule's out-of-bounds policy"},
	{"perlinActive", .Bool, 0, 0, "Change a rule's Perlin filter"},
	{"perlinSeed", .Int, -2147483648, 2147483647, "Change a rule's Perlin seed"},
	// A new random seed (RulePerlinSettings' Random button)
	{"perlinSeedRandom", .Special, 0, 0, "Change a rule's Perlin seed"},
	{"perlinScale", .Float, 0.01, 0.99, "Change a rule's Perlin scale"},
	{"perlinOctaves", .Int, 1, 4, "Change a rule's Perlin octaves"},
}

// A rule member by key (nil: none)
LDtkRules_Member :: proc(key: string) -> ^LDtkRuleMember {
	for &m in LDTK_RULE_MEMBERS do if m.key == key do return &m
	return nil
}

// LDtk's nice palette (Const.NICE_PALETTE: Endesga 32), the colors rule groups are given
LDTK_NICE_PALETTE :: [?]int{
	0xbe4a2f, 0xd77643, 0xead4aa, 0xe4a672, 0xb86f50, 0x733e39, 0x3e2731, 0xa22633, 0xe43b44, 0xf77622, 0xfeae34,
	0xfee761, 0x63c74d, 0x3e8948, 0x265c42, 0x193c3e, 0x124e89, 0x0099db, 0x2ce8f5, 0xffffff, 0xc0cbdc, 0x8b9bb4,
	0x5a6988, 0x3a4466, 0x262b44, 0x181425, 0xff0044, 0x68386c, 0xb55088, 0xf6757a, 0xe8b796, 0xc28569,
}

// --- Reading and writing ---------------------------------------------------------------------

/*
A layer definition's rule groups as LDtk reads them (AutoLayerRuleGroupDef.fromJson,
AutoLayerRuleDef.fromJson: older files' `tileIds` too). Temp allocated.
*/
LDtkRules_ReadGroups :: proc(json: ^JsonDoc, layer: int) -> [dynamic]LDtkGroupEdit {
	context.allocator = context.temp_allocator
	out := make([dynamic]LDtkGroupEdit)
	for g in Json_Items(json, Json_Get(json, layer, "autoRuleGroups")) do append(&out, ldtkGroupRead(json, g))
	return out
}

@(private)
ldtkGroupRead :: proc(json: ^JsonDoc, g: int) -> LDtkGroupEdit {
	context.allocator = context.temp_allocator
	name := Json_Get(json, g, "name")
	x := LDtkGroupEdit{
		uid = Json_Int(json, Json_Get(json, g, "uid"), -1),
		name = Json_Kind(json, name) == .String ? Json_String(json, name) : "default",
		color = -1,
		active = Json_Bool(json, Json_Get(json, g, "active"), true),
		isOptional = Json_Bool(json, Json_Get(json, g, "isOptional")),
		usesWizard = Json_Bool(json, Json_Get(json, g, "usesWizard")),
		biomeMode = Json_Int(json, Json_Get(json, g, "biomeRequirementMode")),
	}
	if c, ok := LDtk_ParseColor(Json_String(json, Json_Get(json, g, "color"))); ok do x.color = c
	if icon := Json_Get(json, g, "icon"); Json_Kind(json, icon) == .Object {
		x.hasIcon = true
		for key, i in ([]string{"tilesetUid", "x", "y", "w", "h"}) do x.icon[i] = Json_Int(json, Json_Get(json, icon, key))
	}
	for r in Json_Items(json, Json_Get(json, g, "rules")) do append(&x.rules, LDtkRule_Read(json, r))
	for v in Json_Items(json, Json_Get(json, g, "requiredBiomeValues")) do append(&x.biome, Json_String(json, v))
	return x
}

// A rule as LDtk's toJson writes it (its keys in LDtk's order)
ldtkRuleJV :: proc(r: ^LDtkRule) -> LDtkJV {
	rects := make([]LDtkJV, len(r.tileRectsIds), context.temp_allocator)
	for ids, i in r.tileRectsIds {
		a := make([]LDtkJV, len(ids), context.temp_allocator)
		for id, j in ids do a[j] = i64(id)
		rects[i] = LDtkJArray(a)
	}
	pattern := make([]LDtkJV, len(r.pattern), context.temp_allocator)
	for v, i in r.pattern do pattern[i] = i64(v)
	checker := "None"
	switch r.checker {
	case .None:
	case .Horizontal: checker = "Horizontal"
	case .Vertical: checker = "Vertical"
	}
	return jobject(
		jpair("uid", i64(r.uid)), jpair("active", r.active), jpair("size", i64(r.size)), jpair("tileRectsIds", LDtkJArray(rects)),
		jpair("alpha", jvNumber(r.alpha)), jpair("chance", jvNumber(ldtkWriteFloat(r.chance))), jpair("breakOnMatch", r.breakOnMatch),
		jpair("pattern", LDtkJArray(pattern)), jpair("flipX", r.flipX), jpair("flipY", r.flipY),
		jpair("xModulo", i64(r.xModulo)), jpair("yModulo", i64(r.yModulo)), jpair("xOffset", i64(r.xOffset)), jpair("yOffset", i64(r.yOffset)),
		jpair("tileXOffset", i64(r.tileXOffset)), jpair("tileYOffset", i64(r.tileYOffset)),
		jpair("tileRandomXMin", i64(r.tileRandomXMin)), jpair("tileRandomXMax", i64(r.tileRandomXMax)),
		jpair("tileRandomYMin", i64(r.tileRandomYMin)), jpair("tileRandomYMax", i64(r.tileRandomYMax)),
		jpair("checker", checker), jpair("tileMode", r.tileMode == .Stamp ? "Stamp" : "Single"),
		jpair("pivotX", jvNumber(ldtkWriteFloat(r.pivot.x))), jpair("pivotY", jvNumber(ldtkWriteFloat(r.pivot.y))),
		jpair("outOfBoundsValue", r.hasOutOfBounds ? LDtkJV(i64(r.outOfBounds)) : LDtkJNull{}),
		jpair("invalidated", false), jpair("perlinActive", r.perlinActive), jpair("perlinSeed", i64(r.perlinSeed)),
		jpair("perlinScale", jvNumber(ldtkWriteFloat(r.perlinScale))), jpair("perlinOctaves", i64(r.perlinOctaves)),
	)
}

// A rule group as LDtk's toJson writes it
ldtkGroupJV :: proc(g: ^LDtkGroupEdit) -> LDtkJV {
	rules := make([]LDtkJV, len(g.rules), context.temp_allocator)
	for &r, i in g.rules do rules[i] = ldtkRuleJV(&r)
	biome := make([]LDtkJV, len(g.biome), context.temp_allocator)
	for v, i in g.biome do biome[i] = v
	icon: LDtkJV = LDtkJNull{}
	if g.hasIcon do icon = rectJV(g.icon[0], {g.icon[1], g.icon[2], g.icon[3], g.icon[4]})
	return jobject(
		jpair("uid", i64(g.uid)), jpair("name", g.name), jpair("color", g.color >= 0 ? LDtkJV(LDtk_FormatColor(g.color)) : LDtkJNull{}),
		jpair("icon", icon), jpair("active", g.active), jpair("isOptional", g.isOptional), jpair("rules", LDtkJArray(rules)),
		jpair("usesWizard", g.usesWizard), jpair("requiredBiomeValues", LDtkJArray(biome)), jpair("biomeRequirementMode", i64(g.biomeMode)),
	)
}

// --- AutoLayerRuleDef's pattern and tidy ------------------------------------------------------

// A pattern cell (cx, cy) of a rule
LDtkRule_Pattern :: #force_inline proc(r: ^LDtkRule, cx, cy: int) -> int {
	if cx < 0 || cy < 0 || cx >= r.size || cy >= r.size do return 0
	return r.pattern[cx + cy * r.size]
}

// A rule's pattern resized around its center (AutoLayerRuleDef.resize: odd sizes 1 to 9)
LDtkRule_Resize :: proc(r: ^LDtkRule, size: int) {
	if size < 1 || size > LDTK_MAX_PATTERN_SIZE || size % 2 == 0 || size == r.size do return
	old := slice.clone(r.pattern[:], context.temp_allocator)
	oldSize := r.size
	pad := abs(size - oldSize) / 2
	r.size = size
	resize(&r.pattern, size * size)
	for &v in r.pattern do v = 0
	if size < oldSize {
		for cx in 0 ..< size do for cy in 0 ..< size do r.pattern[cx + cy * size] = old[cx + pad + (cy + pad) * oldSize]
	} else {
		for cx in 0 ..< oldSize do for cy in 0 ..< oldSize do r.pattern[cx + pad + (cy + pad) * size] = old[cx + cy * oldSize]
	}
}

// Empty borders removed (AutoLayerRuleDef.trim)
LDtkRule_Trim :: proc(r: ^LDtkRule) {
	for r.size > 1 {
		empty := true
		for cx in 0 ..< r.size do if LDtkRule_Pattern(r, cx, 0) != 0 || LDtkRule_Pattern(r, cx, r.size - 1) != 0 do empty = false
		if empty do for cy in 0 ..< r.size do if LDtkRule_Pattern(r, 0, cy) != 0 || LDtkRule_Pattern(r, r.size - 1, cy) != 0 do empty = false
		if !empty do break
		LDtkRule_Resize(r, r.size - 2)
	}
}

// Whether the pattern reads the same mirrored horizontally (AutoLayerRuleDef.isSymetricX)
LDtkRule_SymmetricX :: proc(r: ^LDtkRule) -> bool {
	for cx in 0 ..< r.size / 2 do for cy in 0 ..< r.size do if LDtkRule_Pattern(r, cx, cy) != LDtkRule_Pattern(r, r.size - 1 - cx, cy) do return false
	return true
}

// Whether the pattern reads the same mirrored vertically (isSymetricY)
LDtkRule_SymmetricY :: proc(r: ^LDtkRule) -> bool {
	for cx in 0 ..< r.size do for cy in 0 ..< r.size / 2 do if LDtkRule_Pattern(r, cx, cy) != LDtkRule_Pattern(r, cx, r.size - 1 - cy) do return false
	return true
}

// The values the pattern needs (updateUsedValues)
@(private)
ruleUpdateUsed :: proc(r: ^LDtkRule) {
	clear(&r.required)
	for v in r.pattern {
		if v <= 0 || v == LDTK_ANYTHING do continue
		if !slice.contains(r.required[:], v) do append(&r.required, v)
	}
}

/*
A rule tidied as LDtk's toJson tidies it (AutoLayerRuleDef.tidy): the pattern trimmed, a mirror of
a symmetric pattern off, a checker mode without its modulo off (or the other axis's), an
out-of-bounds value the source layer lost cleared.

Inputs:
- values: The IntGrid values of the rules' source layer

Returns:
- Whether it changed (beyond the trim)
*/
LDtkRule_Tidy :: proc(r: ^LDtkRule, values: map[int]bool) -> bool {
	LDtkRule_Trim(r)
	fixed := false
	if r.flipX && LDtkRule_SymmetricX(r) do r.flipX, fixed = false, true
	if r.flipY && LDtkRule_SymmetricY(r) do r.flipY, fixed = false, true
	if r.xModulo == 1 && r.yModulo == 1 && r.checker != .None do r.checker, fixed = .None, true
	if r.xModulo == 1 && r.checker == .Horizontal do r.checker, fixed = r.yModulo > 1 ? .Vertical : .None, true
	if r.yModulo == 1 && r.checker == .Vertical do r.checker, fixed = r.xModulo > 1 ? .Horizontal : .None, true
	if r.hasOutOfBounds && r.outOfBounds != 0 && r.outOfBounds not_in values do r.hasOutOfBounds = false
	ruleUpdateUsed(r)
	return fixed
}

// Whether a rule has nothing (no pattern, no tiles: AutoLayerRuleDef.isEmpty)
LDtkRule_IsEmpty :: proc(r: ^LDtkRule) -> bool {
	for v in r.pattern do if v != 0 do return false
	return len(r.tileRectsIds) == 0
}

/*
Whether a rule's pattern names values the source layer doesn't have
(AutoLayerRuleDef.isUsingUnknownIntGridValues: the panel shows "Error" instead of its pattern).
*/
LDtkRule_UsesUnknownValues :: proc(r: ^LDtkRule, values: map[int]bool, groups: map[int]bool) -> bool {
	for raw in r.pattern {
		if raw == 0 do continue
		v := abs(raw)
		if v <= 999 && v not_in values do return true
		if v > 999 && v != LDTK_ANYTHING && (v / 1000 - 1) not_in groups do return true
	}
	return false
}

/*
The IntGrid values and groups a layer's rules read: its own, or an AutoLayer's source layer's
(LayerDef.autoSourceLd; temp).
*/
LDtkRules_SourceValues :: proc(doc: ^LDtkDoc, layer: int) -> (values, groups: map[int]bool, source: int) {
	main := LDtkDoc_Main(doc)
	values = make(map[int]bool, context.temp_allocator)
	groups = make(map[int]bool, context.temp_allocator)
	source = layer
	if Json_String(main, Json_Get(main, layer, "type")) == "AutoLayer" {
		if s := LDtkDoc_DefByUid(doc, "layers", nodeUid(main, Json_Get(main, layer, "autoSourceLayerDefUid"))); s >= 0 do source = s
	}
	for v in Json_Items(main, Json_Get(main, source, "intGridValues")) do values[Json_Int(main, Json_Get(main, v, "value"))] = true
	for g in Json_Items(main, Json_Get(main, source, "intGridValuesGroups")) do groups[Json_Int(main, Json_Get(main, g, "uid"))] = true
	return
}

/*
Whether a layer's rules can work (LayerDef.autoLayerRulesCanBeUsed: an IntGrid layer with a
tileset, an AutoLayer with a tileset and a source layer), and why not.
*/
LDtkRules_CanBeUsed :: proc(main: ^JsonDoc, layer: int) -> (bool, string) {
	type := Json_String(main, Json_Get(main, layer, "type"))
	tileset := Json_Kind(main, Json_Get(main, layer, "tilesetDefUid")) == .Number
	switch type {
	case "IntGrid":
		if !tileset do return false, "an IntGrid layer's rules need a tileset (the Layers tab's Rules' tileset)"
	case "AutoLayer":
		if !tileset do return false, "this auto-layer has no tileset: pick one in the Layers tab"
		if Json_Kind(main, Json_Get(main, layer, "autoSourceLayerDefUid")) != .Number do return false, "this auto-layer has no source IntGrid layer: pick one in the Layers tab"
	case:
		return false, "only IntGrid layers and auto-layers have rules"
	}
	return true, ""
}

// A new rule as LDtk makes one (new AutoLayerRuleDef(uid): 3 x 3, its own Perlin seed)
@(private)
ldtkNewRule :: proc(uid: int, size := 3) -> LDtkRule {
	context.allocator = context.temp_allocator
	r := LDtkRule{uid = uid, active = true, size = size, chance = 1, breakOnMatch = true, alpha = 1, xModulo = 1, yModulo = 1,
		perlinSeed = int(rand.int_max(9999999)), perlinScale = 0.2, perlinOctaves = 2}
	r.pattern = make([dynamic]int, size * size)
	r.tileRectsIds = make([dynamic][dynamic]int)
	r.required = make([dynamic]int)
	return r
}

// A rule copied (its arrays its own, temp)
@(private)
ldtkRuleClone :: proc(r: LDtkRule) -> LDtkRule {
	context.allocator = context.temp_allocator
	c := r
	c.pattern = make([dynamic]int, len(r.pattern))
	copy(c.pattern[:], r.pattern[:])
	c.required = make([dynamic]int, len(r.required))
	copy(c.required[:], r.required[:])
	c.tileRectsIds = make([dynamic][dynamic]int, len(r.tileRectsIds))
	for ids, i in r.tileRectsIds {
		c.tileRectsIds[i] = make([dynamic]int, len(ids))
		copy(c.tileRectsIds[i][:], ids[:])
	}
	return c
}

// A group copied (temp)
@(private)
ldtkGroupClone :: proc(g: LDtkGroupEdit) -> LDtkGroupEdit {
	context.allocator = context.temp_allocator
	c := g
	c.rules = make([dynamic]LDtkRule, len(g.rules))
	for r, i in g.rules do c.rules[i] = ldtkRuleClone(r)
	c.biome = make([dynamic]string, len(g.biome))
	copy(c.biome[:], g.biome[:])
	return c
}

// Where a group is (-1 none)
@(private)
groupIndex :: proc(groups: []LDtkGroupEdit, uid: int) -> int {
	for g, i in groups do if g.uid == uid do return i
	return -1
}

// Where a rule is: its group's index and its own (-1 none)
@(private)
ruleIndex :: proc(groups: []LDtkGroupEdit, uid: int) -> (g, r: int) {
	for group, gi in groups do for rule, ri in group.rules do if rule.uid == uid do return gi, ri
	return -1, -1
}

// Which level an edit names, and its layer instance of the layer definition (`file` -1: none)
@(private)
ruleLayerInstance :: proc(doc: ^LDtkDoc, level: string, layerUid: int) -> (file, node: int) {
	l := LDtkDoc_FindLevel(doc, level)
	if l < 0 do return -1, -1
	f, array := LDtkDoc_LayerInstances(doc, l)
	json := LDtkDoc_Json(doc, f)
	for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == layerUid do return f, li
	return -1, -1
}

// --- The edits -------------------------------------------------------------------------------

// What a rule edit's stages need
@(private)
RuleOp :: struct {
	s: ^Stages,
	edit: LDtk_Edit,
	doc: ^LDtkDoc,
	layer: int,
	groups: [dynamic]LDtkGroupEdit,
	uids: Uids,
	// The rules' tiles don't change (a group's name, color, icon): nothing applied again
	noRerun: bool,
	// Only this level's rules are applied again (-1 every level's)
	level: int,
	// The groups were changed: written back
	changed: bool,
}

/*
Makes an Auto-layer Rules edit (`Rule_*`) in the document in memory: the layer's rule groups
changed and written as LDtk writes them, LDtk's tidy, the rules applied again where their tiles may
change. One undo step.

Returns:
- "" or why nothing changed
*/
LDtkOps_RuleEdit :: proc(doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string) {
	s := stagesMake(doc)
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	main := LDtkDoc_Main(doc)
	layer := LDtkDoc_DefByUid(doc, "layers", edit.def)
	if layer < 0 do return "no such layer"
	op := RuleOp{s = &s, edit = edit, doc = doc, layer = layer, groups = LDtkRules_ReadGroups(main, layer), uids = uidsMake(doc), level = -1}
	p := LDtkPatches{}
	#partial switch edit.op {
	case .Rule_Group_Added, .Rule_Group_Removed, .Rule_Group_Duplicated, .Rule_Group_Moved, .Rule_Group_Set, .Rule_Group_Remapped:
		problem = ruleGroupEdit(&op)
	case .Rule_Group_Assistant:
		problem = ruleAssistant(&op)
	case .Rule_Added, .Rule_Removed, .Rule_Duplicated, .Rule_Moved, .Rule_Set, .Rule_Pattern, .Rule_Tiles:
		problem = ruleEdit(&op)
	case .Rule_Pasted:
		problem = rulePaste(&op)
	case .Rule_Group_Here, .Rule_Seed, .Rule_Tileset_Here:
		problem = ruleLevelEdit(&op, &p)
	case:
		problem = "not a rule edit"
	}
	if problem != "" do return problem
	if op.changed {
		values, _, _ := LDtkRules_SourceValues(doc, layer)
		items := make([]LDtkJV, len(op.groups), context.temp_allocator)
		{
			// The rules' arrays are the frame's (some never had an allocator)
			context.allocator = context.temp_allocator
			for &g, i in op.groups {
				for &r in g.rules do LDtkRule_Tidy(&r, values)
				items[i] = ldtkGroupJV(&g)
			}
		}
		defWrite(&p, doc, layer, "autoRuleGroups", LDtkJArray(items))
		uidsDone(&p, doc, op.uids)
	}
	if problem = stagesApply(&s, &p); problem != "" do return problem
	if len(s.made) == 0 do return ""
	if problem = LDtkTidy_Run(&s); problem != "" do return problem
	if !op.noRerun {
		layers := make(map[int]bool, context.temp_allocator)
		layers[edit.def] = true
		if problem = rerunRules(&s, layers, op.level); problem != "" do return problem
	}
	result := stagesFinish(&s, "")
	s.made = nil
	return result
}

// What a rule edit's undo step says
LDtkRules_SetLabel :: proc(edit: LDtk_Edit) -> string {
	if m := LDtkRules_Member(edit.key); m != nil do return m.label
	return "Change a rule"
}

// Whether a layer's rules can take groups: why not
@(private)
rulesUsable :: proc(op: ^RuleOp) -> string {
	ok, why := LDtkRules_CanBeUsed(LDtkDoc_Main(op.doc), op.layer)
	if !ok do return fmt.tprintf("The layer's settings prevent its rules to work: %s", why)
	return ""
}

@(private)
WIZARD_REFUSAL :: "the rules of a group the Assistant made are edited with the Assistant (or switch the group to Advanced mode)"

// A group's edits
@(private)
ruleGroupEdit :: proc(op: ^RuleOp) -> string {
	context.allocator = context.temp_allocator
	edit := op.edit
	groups := &op.groups
	if edit.op == .Rule_Group_Added {
		if why := rulesUsable(op); why != "" do return why
		name := edit.text != "" ? strings.clone(edit.text, context.temp_allocator) : "New group"
		g := LDtkGroupEdit{uid = uidTake(&op.uids), name = name, color = -1, active = true}
		g.rules = make([dynamic]LDtkRule, context.temp_allocator)
		g.biome = make([dynamic]string, context.temp_allocator)
		inject_at(groups, clamp(int(math.round(edit.number)), 0, len(groups)), g)
		op.changed, op.noRerun = true, true
		return ""
	}
	at := groupIndex(groups[:], edit.index)
	if at < 0 do return "no such rule group"
	g := &groups[at]
	#partial switch edit.op {
	case .Rule_Group_Removed:
		ordered_remove(groups, at)
	case .Rule_Group_Duplicated:
		// LayerDef.duplicateRuleGroup: a copy after it, new uids
		c := ldtkGroupClone(g^)
		c.uid = uidTake(&op.uids)
		for &r in c.rules do r.uid = uidTake(&op.uids)
		inject_at(groups, at + 1, c)
	case .Rule_Group_Moved:
		steps := int(math.round(edit.number))
		to := clamp(at + steps, 0, len(groups) - 1)
		if to == at do return ""
		moved := groups[at]
		ordered_remove(groups, at)
		inject_at(groups, to, moved)
	case .Rule_Group_Remapped:
		return ruleRemap(op, at)
	case .Rule_Group_Set:
		switch edit.key {
		case "name":
			if g.name == edit.text do return ""
			g.name = strings.clone(edit.text, context.temp_allocator)
			op.noRerun = true
		case "active":
			if g.isOptional do return "an optional group is turned on or off per level"
			if g.active == edit.flag do return ""
			g.active = edit.flag
		case "color":
			t := strings.trim_space(edit.text)
			c := -1
			if t != "" {
				v, ok := LDtk_ParseColor(t)
				if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text)
				c = v
			}
			if c == g.color do return ""
			g.color = c
			op.noRerun = true
		case "icon":
			t := strings.trim_space(edit.text)
			if t == "" {
				if !g.hasIcon do return ""
				g.hasIcon = false
			} else {
				r, ok := LDtk_ParseRect(t)
				if !ok do return fmt.tprintf("%q isn't a tile rectangle (x,y,w,h)", edit.text)
				g.icon, g.hasIcon = {int(math.round(edit.number)), r[0], r[1], r[2], r[3]}, true
			}
			op.noRerun = true
		case "isOptional":
			if g.isOptional == edit.flag do return ""
			g.isOptional = edit.flag
			// "Turn into an OPTIONAL group": active again (LDtk's cleanup); the levels' states go
			// with it when it's no longer optional (LDtk's tidy)
			if edit.flag do g.active = true
		case "requiredBiomeValues":
			known, has := LDtkRules_BiomeValues(op.doc, op.layer)
			if !has do return "this layer has no biome field (the Layers tab's Biome field)"
			values := make([dynamic]string, context.temp_allocator)
			for part in strings.split(edit.text, ",", context.temp_allocator) {
				v := strings.trim_space(part)
				if v == "" || slice.contains(values[:], v) do continue
				if !slice.contains(known, v) do return fmt.tprintf("%q isn't a value of the biome enum", v)
				append(&values, v)
			}
			// openBiomePicker's sort: by lower case
			slice.sort_by(values[:], proc(a, b: string) -> bool {
				return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)
			})
			g.biome = values
			if len(values) <= 1 do g.biomeMode = 0
		case "biomeRequirementMode":
			mode := int(math.round(edit.number))
			if mode != 0 && mode != 1 do return "a biome condition is 0 (any of them) or 1 (all of them)"
			if g.biomeMode == mode do return ""
			g.biomeMode = mode
		case "usesWizard":
			// LDtk's "Switch to advanced mode" (it can't be turned back on)
			if edit.flag && !g.usesWizard do return "only the Assistant makes groups it manages"
			if !g.usesWizard do return ""
			g.usesWizard = false
			op.noRerun = true
		case "outOfBoundsValue":
			// "Edit out-of-bounds policy for all rules"
			oob, has, why := ruleOutOfBounds(op, edit.text)
			if why != "" do return why
			for &r in g.rules do r.outOfBounds, r.hasOutOfBounds = oob, has
		case:
			return fmt.tprintf("%q isn't a rule group's setting", edit.key)
		}
	}
	op.changed = true
	return ""
}

// An out-of-bounds policy typed: "" none, "0" empty cells, a value of the source layer
@(private)
ruleOutOfBounds :: proc(op: ^RuleOp, text: string) -> (value: int, has: bool, problem: string) {
	t := strings.trim_space(text)
	if t == "" || t == "null" do return 0, false, ""
	v, ok := strconv.parse_int(t)
	if !ok do return 0, false, fmt.tprintf("%q isn't an IntGrid value", text)
	values, _, _ := LDtkRules_SourceValues(op.doc, op.layer)
	if v != 0 && v not_in values do return 0, false, fmt.tprintf("the source layer has no value %d", v)
	return v, true, ""
}

// A rule's edits
@(private)
ruleEdit :: proc(op: ^RuleOp) -> string {
	context.allocator = context.temp_allocator
	edit := op.edit
	groups := &op.groups
	if edit.op == .Rule_Added {
		gi := groupIndex(groups[:], edit.index)
		if gi < 0 do return "no such rule group"
		if groups[gi].usesWizard do return WIZARD_REFUSAL
		rules := &groups[gi].rules
		inject_at(rules, clamp(int(math.round(edit.number)), 0, len(rules)), ldtkNewRule(uidTake(&op.uids)))
		op.changed = true
		return ""
	}
	gi, ri := ruleIndex(groups[:], edit.field)
	if gi < 0 do return "no such rule"
	if groups[gi].usesWizard do return WIZARD_REFUSAL
	rules := &groups[gi].rules
	r := &rules[ri]
	#partial switch edit.op {
	case .Rule_Removed:
		ordered_remove(rules, ri)
	case .Rule_Duplicated:
		// LayerDef.duplicateRule: after it, a new uid
		c := ldtkRuleClone(r^)
		c.uid = uidTake(&op.uids)
		inject_at(rules, ri + 1, c)
	case .Rule_Moved:
		// Definitions.sortLayerAutoRules: out of its group, into the target at its place
		to := groupIndex(groups[:], edit.index)
		if to < 0 do return "no such rule group"
		if groups[to].usesWizard do return WIZARD_REFUSAL
		at := int(math.round(edit.number))
		if at < 0 || (to == gi && at >= len(rules)) || (to != gi && at > len(groups[to].rules)) do return "no such place in the group"
		if to == gi && at == ri do return ""
		moved := r^
		ordered_remove(rules, ri)
		inject_at(&groups[to].rules, at, moved)
	case .Rule_Pattern:
		size := int(math.round(edit.number))
		if size < 1 || size > LDTK_MAX_PATTERN_SIZE || size % 2 == 0 || len(edit.ids) != size * size do return "a pattern is an odd size from 1 to 9, size x size values"
		r.size = size
		resize(&r.pattern, size * size)
		copy(r.pattern[:], edit.ids)
	case .Rule_Tiles:
		switch edit.key {
		case "single":
			if len(edit.ids) == 0 do return "pick at least one tile"
			clear(&r.tileRectsIds)
			for id in edit.ids {
				one := make([dynamic]int, 1, context.temp_allocator)
				one[0] = id
				append(&r.tileRectsIds, one)
			}
		case "stamp":
			if len(edit.ids) == 0 do return "pick a rectangle of tiles"
			ids := make([dynamic]int, len(edit.ids), context.temp_allocator)
			copy(ids[:], edit.ids)
			at := int(math.round(edit.number))
			if at < 0 || at >= len(r.tileRectsIds) do append(&r.tileRectsIds, ids)
			else do r.tileRectsIds[at] = ids
		case "remove":
			at := int(math.round(edit.number))
			if at < 0 || at >= len(r.tileRectsIds) do return "no such tiles"
			ordered_remove(&r.tileRectsIds, at)
		case:
			return fmt.tprintf("%q isn't a way to pick tiles", edit.key)
		}
	case .Rule_Set:
		if why := ruleSet(op, r); why != "" do return why
	}
	op.changed = true
	return ""
}

// A rule's member set (`Rule_Set`), as LDtk's inputs bound and fix it
@(private)
ruleSet :: proc(op: ^RuleOp, r: ^LDtkRule) -> string {
	edit := op.edit
	m := LDtkRules_Member(edit.key)
	if m == nil do return fmt.tprintf("%q isn't a rule's setting", edit.key)
	num :: proc(edit: LDtk_Edit, m: ^LDtkRuleMember) -> (f64, string) {
		v, ok := editNumber(edit)
		if !ok do return 0, fmt.tprintf("%q isn't a number", edit.text)
		// A percentage (LDtk's percent inputs: chance, Perlin scale): `number2` 100
		if m.type == .Float && edit.number2 > 0 do v /= edit.number2
		return clamp(v, m.lo, m.hi), ""
	}
	whole :: proc(edit: LDtk_Edit, m: ^LDtkRuleMember) -> (int, string) {
		v, why := num(edit, m)
		return int(math.round(v)), why
	}
	switch edit.key {
	case "active": r.active = edit.flag
	case "breakOnMatch": r.breakOnMatch = edit.flag
	case "perlinActive": r.perlinActive = edit.flag
	case "flipX", "flipY":
		// "This option will have no effect on a symetric rule."
		symmetric := edit.key == "flipX" ? LDtkRule_SymmetricX(r) : LDtkRule_SymmetricY(r)
		if symmetric do return "this option has no effect on a symmetric rule"
		if edit.key == "flipX" do r.flipX = edit.flag
		else do r.flipY = edit.flag
	case "chance":
		v, why := num(edit, m)
		if why != "" do return why
		r.chance = v
	case "alpha":
		// Its input's precision: 2 decimals
		v, why := num(edit, m)
		if why != "" do return why
		r.alpha = ldtkRound(v * 100) / 100
	case "perlinScale":
		v, why := num(edit, m)
		if why != "" do return why
		r.perlinScale = v
	case "xModulo", "yModulo", "xOffset", "yOffset", "tileXOffset", "tileYOffset", "tileRandomXMin", "tileRandomXMax",
	     "tileRandomYMin", "tileRandomYMax", "tileRandomX", "tileRandomY", "perlinSeed", "perlinOctaves":
		v, why := whole(edit, m)
		if why != "" do return why
		switch edit.key {
		case "xModulo": r.xModulo = v
		case "yModulo": r.yModulo = v
		// RuleModuloEditor's fixValue (the X offset only, as LDtk's): within the modulo, Haxe's % keeping the sign
		case "xOffset": r.xOffset = v % max(r.xModulo, 1)
		case "yOffset": r.yOffset = v
		case "tileXOffset": r.tileXOffset = v
		case "tileYOffset": r.tileYOffset = v
		// RuleRandomOffsets' fixValue: min <= max
		case "tileRandomXMin": r.tileRandomXMin = min(v, r.tileRandomXMax)
		case "tileRandomXMax": r.tileRandomXMax = max(v, r.tileRandomXMin)
		case "tileRandomYMin": r.tileRandomYMin = min(v, r.tileRandomYMax)
		case "tileRandomYMax": r.tileRandomYMax = max(v, r.tileRandomYMin)
		// Linked: -max to max
		case "tileRandomX": r.tileRandomXMax, r.tileRandomXMin = v, -v
		case "tileRandomY": r.tileRandomYMax, r.tileRandomYMin = v, -v
		case "perlinSeed": r.perlinSeed = v
		case "perlinOctaves": r.perlinOctaves = v
		}
	case "perlinSeedRandom":
		r.perlinSeed = int(rand.int_max(99999999))
	case "tileRandomXLink":
		r.tileRandomXMax = max(r.tileRandomXMin, r.tileRandomXMax)
		r.tileRandomXMin = -r.tileRandomXMax
	case "tileRandomYLink":
		r.tileRandomYMax = max(r.tileRandomYMin, r.tileRandomYMax)
		r.tileRandomYMin = -r.tileRandomYMax
	case "checker":
		switch strings.trim_space(edit.text) {
		case "None": r.checker = .None
		case "Horizontal":
			if r.xModulo <= 1 do return "a horizontal checker needs an X modulo above 1"
			r.checker = .Horizontal
		case "Vertical":
			if r.yModulo <= 1 do return "a vertical checker needs a Y modulo above 1"
			r.checker = .Vertical
		case: return fmt.tprintf("%q isn't a checker mode (None, Horizontal, Vertical)", edit.text)
		}
	case "moduloReset":
		r.xModulo, r.yModulo, r.xOffset, r.yOffset, r.checker = 1, 1, 0, 0, .None
	case "offsetsReset":
		r.tileXOffset, r.tileYOffset = 0, 0
		r.tileRandomXMin, r.tileRandomXMax, r.tileRandomYMin, r.tileRandomYMax = 0, 0, 0, 0
	case "tileMode":
		mode: LDtkRuleTileMode
		switch strings.trim_space(edit.text) {
		case "Single": mode = .Single
		case "Stamp": mode = .Stamp
		case: return fmt.tprintf("%q isn't a tile mode (Single, Stamp)", edit.text)
		}
		if mode == r.tileMode do return ""
		// RuleEditor: another mode clears the tiles
		r.tileMode = mode
		clear(&r.tileRectsIds)
	case "pivot":
		r.pivot = {clamp(edit.number, 0, 1), clamp(edit.number2, 0, 1)}
	case "outOfBoundsValue":
		oob, has, why := ruleOutOfBounds(op, edit.text)
		if why != "" do return why
		r.outOfBounds, r.hasOutOfBounds = oob, has
	}
	return ""
}

// A rule or group pasted from LDtk's clipboard (LayerDef.pasteRule, pasteRuleGroup)
@(private)
rulePaste :: proc(op: ^RuleOp) -> string {
	context.allocator = context.temp_allocator
	edit := op.edit
	doc, problem := Json_Parse(edit.text, context.temp_allocator)
	if problem != "" || Json_Kind(&doc, 0) != .Object do return "the clipboard holds no rule"
	switch edit.key {
	case "rule":
		gi := groupIndex(op.groups[:], edit.index)
		if gi < 0 do return "no such rule group"
		if op.groups[gi].usesWizard do return WIZARD_REFUSAL
		r: LDtkRule
		{
			context.allocator = context.temp_allocator
			r = LDtkRule_Read(&doc, 0)
		}
		r.uid = uidTake(&op.uids)
		rules := &op.groups[gi].rules
		at := len(rules)
		for x, i in rules do if x.uid == edit.field do at = i + 1
		inject_at(rules, at, r)
	case "group":
		if why := rulesUsable(op); why != "" do return why
		g := ldtkGroupRead(&doc, 0)
		g.uid = uidTake(&op.uids)
		for &r in g.rules do r.uid = uidTake(&op.uids)
		at := len(op.groups)
		for x, i in op.groups do if x.uid == edit.index do at = i + 1
		inject_at(&op.groups, at, g)
	case:
		return "paste a rule or a group"
	}
	op.changed = true
	return ""
}

/*
LDtk's Duplicate and Remap (RuleGroupRemap): a copy of the group after it, named `text`, its
IntGrid values remapped (`ids`: old, new pairs; "not" values with them; the out-of-bounds value
too), its tiles moved by (`number`, `number2`) cells of the layer's tileset.
*/
@(private)
ruleRemap :: proc(op: ^RuleOp, at: int) -> string {
	context.allocator = context.temp_allocator
	edit := op.edit
	if strings.trim_space(edit.text) == "" do return "name the new group"
	if len(edit.ids) % 2 != 0 do return "IntGrid values are remapped in pairs"
	main := LDtkDoc_Main(op.doc)
	td := LDtkDoc_DefByUid(op.doc, "tilesets", nodeUid(main, Json_Get(main, op.layer, "tilesetDefUid")))
	if td < 0 do return "the layer has no tileset"
	cWid := max(Json_Int(main, Json_Get(main, td, "__cWid")), 1)
	cHei := max(Json_Int(main, Json_Get(main, td, "__cHei")), 1)
	ox, oy := int(math.round(edit.number)), int(math.round(edit.number2))
	remap := make(map[int]int, context.temp_allocator)
	for i := 0; i < len(edit.ids); i += 2 do remap[edit.ids[i]] = edit.ids[i + 1]
	c := ldtkGroupClone(op.groups[at])
	c.uid = uidTake(&op.uids)
	c.name = strings.clone(edit.text, context.temp_allocator)
	for &r in c.rules {
		r.uid = uidTake(&op.uids)
		for &ids in r.tileRectsIds do for &id in ids {
			cx, cy := id % cWid + ox, id / cWid + oy
			if cx < 0 || cy < 0 || cx >= cWid || cy >= cHei do return "the tiles moved go past the tileset's edge"
			id += ox + oy * cWid
		}
		for &v in r.pattern {
			if to, found := remap[v]; found do v = to
			else if to2, foundNot := remap[-v]; foundNot do v = -to2
		}
		if r.hasOutOfBounds do if to, found := remap[r.outOfBounds]; found do r.outOfBounds = to
		ruleUpdateUsed(&r)
	}
	inject_at(&op.groups, at + 1, c)
	op.changed = true
	return ""
}

/*
The level's layer instance: an optional group turned on or off here (LayerInstance's
optionalRules: written in uid order, as LDtk's map keys come), its seed, its tileset.
*/
@(private)
ruleLevelEdit :: proc(op: ^RuleOp, p: ^LDtkPatches) -> string {
	edit := op.edit
	doc := op.doc
	file, li := ruleLayerInstance(doc, edit.level, edit.def)
	if li < 0 do return "the level has no such layer"
	json := LDtkDoc_Json(doc, file)
	minified := Json_Minified(json)
	main := LDtkDoc_Main(doc)
	l := LDtkDoc_FindLevel(doc, edit.level)
	op.level = l
	#partial switch edit.op {
	case .Rule_Group_Here:
		gi := groupIndex(op.groups[:], edit.index)
		if gi < 0 do return "no such rule group"
		if !op.groups[gi].isOptional do return "only an optional group is turned on or off per level"
		node := Json_Get(json, li, "optionalRules")
		uids := make([dynamic]int, context.temp_allocator)
		for u in Json_Items(json, node) do if Json_Int(json, u) != edit.index do append(&uids, Json_Int(json, u))
		if edit.flag do append(&uids, edit.index)
		slice.sort(uids[:])
		items := make([]LDtkJV, len(uids), context.temp_allocator)
		for u, i in uids do items[i] = i64(u)
		if node < 0 do return "the layer instance has no optional rules list"
		if jvSame(json, node, LDtkJArray(items)) do return ""
		LDtkPatches_Set(p, doc, file, node, writeAt(json, node, LDtkJArray(items), minified))
	case .Rule_Seed:
		seed := int(math.round(edit.number))
		if edit.number < 0 do seed = int(rand.int_max(9999999))
		LDtkPatches_Set(p, doc, file, Json_Get(json, li, "seed"), fmt.tprint(seed))
	case .Rule_Tileset_Here:
		want := int(math.round(edit.number))
		current := nodeUid(json, Json_Get(json, li, "overrideTilesetUid"))
		if current < 0 do current = nodeUid(main, Json_Get(main, op.layer, "tilesetDefUid"))
		if want >= 0 {
			// Only a tileset of the same size (EditAllAutoLayerRules' _tilesetCompatible)
			a, b := LDtkDoc_DefByUid(doc, "tilesets", want), LDtkDoc_DefByUid(doc, "tilesets", current)
			if a < 0 do return "no such tileset"
			if b < 0 do return "the layer has no tileset"
			for key in ([]string{"__cWid", "__cHei", "tileGridSize"}) {
				if Json_Int(main, Json_Get(main, a, key)) != Json_Int(main, Json_Get(main, b, key)) do return "that tileset isn't the same size as the layer's (its grid and tiles across and down)"
			}
		}
		node := Json_Get(json, li, "overrideTilesetUid")
		value: LDtkJV = want >= 0 ? LDtkJV(i64(want)) : LDtkJNull{}
		if node >= 0 {
			if jvSame(json, node, value) do return ""
			LDtkPatches_Set(p, doc, file, node, writeAt(json, node, value, minified))
		} else {
			defWriteIn(p, doc, file, li, "overrideTilesetUid", value)
		}
	}
	return ""
}

// A member written in an object of any of the document's files (added when missing)
@(private)
defWriteIn :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, node: int, key: string, v: LDtkJV) {
	json := LDtkDoc_Json(doc, file)
	minified := Json_Minified(json)
	member := Json_Get(json, node, key)
	if member >= 0 {
		if jvSame(json, member, v) do return
		LDtkPatches_Add(p, file, Json_SetPatch(json, member, writeAt(json, member, v, minified)))
		return
	}
	indent := LDtk_IndentAt(json.text, int(json.nodes[node].start)) + 1
	LDtkPatches_Add(p, file, Json_AddMemberPatch(json, node, key, LDtk_PrettyJson(v, minified, indent)))
}

// --- What the tab reads ----------------------------------------------------------------------

/*
The values of a layer's biome enum (its level field's enum: LayerDef.getBiomeEnumDef), in order;
false when the layer has no biome field. Temp allocated.
*/
LDtkRules_BiomeValues :: proc(doc: ^LDtkDoc, layer: int) -> (values: []string, ok: bool) {
	main := LDtkDoc_Main(doc)
	field := nodeUid(main, Json_Get(main, layer, "biomeFieldUid"))
	if field < 0 do return nil, false
	_, fd := LDtkDoc_FieldDef(doc, field)
	if fd < 0 do return nil, false
	info := LDtkDoc_FieldInfo(doc, fd)
	if info.type != .Enum do return nil, false
	ed := LDtkDefs_Node(doc, .Enum, info.enumUid)
	out := make([dynamic]string, context.temp_allocator)
	for v in Json_Items(main, Json_Get(main, ed, "values")) do append(&out, Json_String(main, Json_Get(main, v, "id")))
	return out[:], true
}

/*
A rule's or group's JSON as LDtk's clipboard holds it (its toJson, tidied; "" when it isn't
there). Temp allocated.
*/
LDtkRules_CopyText :: proc(doc: ^LDtkDoc, layerUid, group, rule: int) -> string {
	main := LDtkDoc_Main(doc)
	layer := LDtkDoc_DefByUid(doc, "layers", layerUid)
	if layer < 0 do return ""
	groups := LDtkRules_ReadGroups(main, layer)
	values, _, _ := LDtkRules_SourceValues(doc, layer)
	if rule >= 0 {
		gi, ri := ruleIndex(groups[:], rule)
		if gi < 0 do return ""
		r := &groups[gi].rules[ri]
		LDtkRule_Tidy(r, values)
		return LDtk_PrettyJson(ldtkRuleJV(r), true)
	}
	gi := groupIndex(groups[:], group)
	if gi < 0 do return ""
	for &r in groups[gi].rules do LDtkRule_Tidy(&r, values)
	return LDtk_PrettyJson(ldtkGroupJV(&groups[gi]), true)
}

/*
Which rules put tiles in a cell of a level's layer (the panel highlights them as the pointer moves
over the level: EditAllAutoLayerRules.onEditorMouseMove). Temp allocated.
*/
LDtkRules_At :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	if l == nil || cx < 0 || cy < 0 || cx >= l.cWid || cy >= l.cHei || len(l.auto) == 0 do return out[:]
	for t in l.auto[cx + cy * l.cWid] do if !slice.contains(out[:], int(t.rule)) do append(&out, int(t.rule))
	return out[:]
}
