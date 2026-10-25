package crossfire_editor

import "core:strings"

/*
LDtk's auto-layer rules, ported from its source (`ldtk/src/electron.renderer`: AutoLayerRuleDef,
AutoLayerRuleGroupDef, LayerInstance's applyRuleAt / applyAllRulesAt / applyBreakOnMatchesArea /
addRuleTilesAt, LayerDef's rule orders), so painted IntGrid cells make the tiles LDtk would make,
byte for byte in the saved file.

- **When:** LDtk evaluates the rules again in the changed cells' rectangle, widened by the largest
  pattern's radius (`LDTK_MAX_PATTERN_SIZE` / 2), for the painted layer when it's an auto layer
  (an IntGrid layer with a tileset), every AutoLayer whose source it is, and every auto layer a
  painted Tiles layer kills tiles in (`autoTilesKilledByOtherLayerUid`): `LDtkRules_ApplyArea`.
  A layer whose file had no `autoLayerTiles` gets every rule applied first (LDtk's null cache).
- **Order:** rules run in evaluation order (groups first to last, rules first to last: only the
  active rules of the groups applied in this level: optional groups turned on here, biomes); each
  rule's tiles are cleared in the rectangle and the rule tried at every cell, its flipped variants
  when it doesn't break on its match. Then the break-on-match pass: per cell, in evaluation order,
  a rule's tiles under a locked cell go, a rule that breaks on match locks it, and so does a rule
  with an opaque tile (no offsets, full alpha). The file lists them in display order (the
  reverse: `LDtkRules_DisplayOrder`).
- **Randomness** is LDtk's, seeded by the layer's `seed` and the rule's uid: `dn.M.randSeedCoords`
  for chance and random tiles and offsets (`ldtkRandSeedCoords`, with JavaScript's doubles: LDtk
  runs in Electron and its integer maths overflows into doubles there), heaps' `hxd.Perlin` for
  Perlin masks (`ldtkPerlin`, normalized, its repeat 50 as `adjustScale(50, 1)` sets it).
  Constants are multiplied at run time, never folded at compile time (Odin's constant folding is
  exact; JavaScript rounds each step).
- **Verified** against LDtk's own samples (ldtk/app/extraFiles/samples, saved by LDtk 1.5.3): every
  auto layer of every level, its tiles cleared and every rule applied again, writes the file's
  `autoLayerTiles` exactly (`ldtk_rules_match_ldtk_samples`).
*/

// LDtk's "anything" pattern value (Const.AUTO_LAYER_ANYTHING); negative: nothing
LDTK_ANYTHING :: 1000001
// The largest rule pattern (Const.MAX_AUTO_PATTERN_SIZE)
LDTK_MAX_PATTERN_SIZE :: 9

// How a rule places its tiles
LDtkRuleTileMode :: enum u8 {
	// One tile (a random one of the rule's)
	Single,
	// A rectangle of tiles, placed by the rule's pivot
	Stamp,
}

// A rule's checker mode (every other row or column shifted)
LDtkRuleChecker :: enum u8 {
	None,
	Horizontal,
	Vertical,
}

// An auto-layer rule (AutoLayerRuleDef)
LDtkRule :: struct {
	uid: int,
	active: bool,
	size: int,
	// The tile choices: each a list of tile ids (a stamp, or one tile)
	tileRectsIds: [dynamic][dynamic]int,
	chance: f64,
	breakOnMatch: bool,
	// size x size values: 0 anything, v this value, -v not it, groups as (uid + 1) * 1000,
	// LDTK_ANYTHING any value, -LDTK_ANYTHING none
	pattern: [dynamic]int,
	alpha: f64,
	// The value outside the layer (`hasOutOfBounds` false: the rule fails there)
	outOfBounds: int,
	hasOutOfBounds: bool,
	flipX, flipY: bool,
	tileMode: LDtkRuleTileMode,
	pivot: [2]f64,
	xModulo, yModulo, xOffset, yOffset: int,
	tileXOffset, tileYOffset: int,
	tileRandomXMin, tileRandomXMax, tileRandomYMin, tileRandomYMax: int,
	checker: LDtkRuleChecker,
	perlinActive: bool,
	perlinSeed: int,
	perlinScale: f64,
	perlinOctaves: int,
	// The values the pattern needs (AutoLayerRuleDef.explicitlyRequiredValues)
	required: [dynamic]int,
}

// A group of rules (AutoLayerRuleGroupDef)
LDtkRuleGroup :: struct {
	uid: int,
	active, isOptional: bool,
	rules: [dynamic]LDtkRule,
	// Biomes: the level's enum values the group needs (owned), any (0) or all (1) of them
	biomeValues: [dynamic]string,
	biomeMode: int,
}

// Reads a rule group from a layer definition's `autoRuleGroups` (AutoLayerRuleGroupDef.fromJson)
LDtkRuleGroup_Read :: proc(json: ^JsonDoc, node: int) -> LDtkRuleGroup {
	g := LDtkRuleGroup{
		uid = Json_Int(json, Json_Get(json, node, "uid"), -1),
		active = Json_Bool(json, Json_Get(json, node, "active"), true),
		isOptional = Json_Bool(json, Json_Get(json, node, "isOptional"), false),
		biomeMode = Json_Int(json, Json_Get(json, node, "biomeRequirementMode")),
	}
	for v in Json_Items(json, Json_Get(json, node, "requiredBiomeValues")) do append(&g.biomeValues, strings.clone(Json_String(json, v)))
	for r in Json_Items(json, Json_Get(json, node, "rules")) do append(&g.rules, LDtkRule_Read(json, r))
	return g
}

// Frees a rule group
LDtkRuleGroup_Destroy :: proc(g: ^LDtkRuleGroup) {
	for &r in g.rules {
		for ids in r.tileRectsIds do delete(ids)
		delete(r.tileRectsIds)
		delete(r.pattern)
		delete(r.required)
	}
	delete(g.rules)
	for v in g.biomeValues do delete(v)
	delete(g.biomeValues)
	g^ = {}
}

// Reads a rule (AutoLayerRuleDef.fromJson, older files' `tileIds` too)
LDtkRule_Read :: proc(json: ^JsonDoc, node: int) -> LDtkRule {
	get :: proc(json: ^JsonDoc, node: int, key: string) -> int { return Json_Get(json, node, key) }
	r := LDtkRule{
		uid = Json_Int(json, get(json, node, "uid"), -1),
		active = Json_Bool(json, get(json, node, "active"), true),
		size = max(Json_Int(json, get(json, node, "size"), 3), 1),
		chance = Json_Float(json, get(json, node, "chance"), 1),
		breakOnMatch = Json_Bool(json, get(json, node, "breakOnMatch"), false),
		alpha = Json_Float(json, get(json, node, "alpha"), 1),
		flipX = Json_Bool(json, get(json, node, "flipX")),
		flipY = Json_Bool(json, get(json, node, "flipY")),
		pivot = {Json_Float(json, get(json, node, "pivotX")), Json_Float(json, get(json, node, "pivotY"))},
		xModulo = Json_Int(json, get(json, node, "xModulo"), 1),
		yModulo = Json_Int(json, get(json, node, "yModulo"), 1),
		xOffset = Json_Int(json, get(json, node, "xOffset")),
		yOffset = Json_Int(json, get(json, node, "yOffset")),
		tileXOffset = Json_Int(json, get(json, node, "tileXOffset")),
		tileYOffset = Json_Int(json, get(json, node, "tileYOffset")),
		tileRandomXMin = Json_Int(json, get(json, node, "tileRandomXMin")),
		tileRandomXMax = Json_Int(json, get(json, node, "tileRandomXMax")),
		tileRandomYMin = Json_Int(json, get(json, node, "tileRandomYMin")),
		tileRandomYMax = Json_Int(json, get(json, node, "tileRandomYMax")),
		perlinActive = Json_Bool(json, get(json, node, "perlinActive")),
		perlinSeed = Json_Int(json, get(json, node, "perlinSeed")),
		perlinScale = Json_Float(json, get(json, node, "perlinScale"), 0.2),
		perlinOctaves = Json_Int(json, get(json, node, "perlinOctaves"), 2),
	}
	if oob := get(json, node, "outOfBoundsValue"); Json_Kind(json, oob) == .Number {
		r.outOfBounds, r.hasOutOfBounds = Json_Int(json, oob), true
	}
	switch Json_String(json, get(json, node, "tileMode")) {
	case "Stamp": r.tileMode = .Stamp
	}
	switch Json_String(json, get(json, node, "checker")) {
	case "Horizontal": r.checker = .Horizontal
	case "Vertical":   r.checker = .Vertical
	}
	if rects := get(json, node, "tileRectsIds"); Json_Kind(json, rects) == .Array {
		for ids in Json_Items(json, rects) {
			list := make([dynamic]int)
			for id in Json_Items(json, ids) do append(&list, Json_Int(json, id))
			append(&r.tileRectsIds, list)
		}
	} else if old := get(json, node, "tileIds"); Json_Kind(json, old) == .Array {
		// Before 1.4: one tile each (Single) or one stamp
		if r.tileMode == .Single {
			for id in Json_Items(json, old) {
				list := make([dynamic]int)
				append(&list, Json_Int(json, id))
				append(&r.tileRectsIds, list)
			}
		} else {
			list := make([dynamic]int)
			for id in Json_Items(json, old) do append(&list, Json_Int(json, id))
			append(&r.tileRectsIds, list)
		}
	}
	for v in Json_Items(json, get(json, node, "pattern")) do append(&r.pattern, Json_Int(json, v))
	for len(r.pattern) < r.size * r.size do append(&r.pattern, 0)
	// AutoLayerRuleDef.updateUsedValues
	for v in r.pattern {
		if v <= 0 || v == LDTK_ANYTHING do continue
		seen := false
		for x in r.required do if x == v do seen = true
		if !seen do append(&r.required, v)
	}
	return r
}

// Whether a rule moves its tiles (AutoLayerRuleDef.hasAnyPositionOffset)
LDtkRule_HasOffset :: #force_inline proc(r: ^LDtkRule) -> bool {
	return r.tileRandomXMin != 0 || r.tileRandomXMax != 0 || r.tileRandomYMin != 0 || r.tileRandomYMax != 0 || r.tileXOffset != 0 || r.tileYOffset != 0
}

// Whether a layer definition has rules that can run (LayerDef.isAutoLayer / autoLayerRulesCanBeUsed)
LDtkLayerInfo_IsAuto :: proc(d: ^LDtkLayerInfo) -> bool {
	return (d.kind == .IntGrid && d.tileset >= 0) || d.kind == .AutoLayer
}

@(private="file")
rulesCanBeUsed :: proc(d: ^LDtkLayerInfo) -> bool {
	if !LDtkLayerInfo_IsAuto(d) || d.tileset < 0 do return false
	if d.kind == .AutoLayer && d.autoSource < 0 do return false
	return true
}

// Whether a group's rules apply in a level's layer (LayerInstance.isRuleGroupAppliedHere)
LDtkRules_GroupApplied :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, g: ^LDtkRuleGroup) -> bool {
	d := &m.defs[l.def]
	if g.active && len(g.biomeValues) > 0 {
		if values, found := m.fields[d.biomeField]; found && d.biomeField >= 0 {
			switch g.biomeMode {
			case 0:
				for v in values do for b in g.biomeValues do if v == b do return true
				return false
			case 1:
				matches := 0
				for b in g.biomeValues {
					for v in values do if v == b {
						matches += 1
						break
					}
				}
				return matches >= len(g.biomeValues)
			case:
				return false
			}
		}
	}
	// LayerInstance.isRuleGroupEnabled (as LDtk groups it: an optional group turned on here
	// applies even when it's inactive)
	if g.active && !g.isOptional do return true
	for uid in l.optionalRules do if uid == g.uid do return true
	return false
}

// The active rules applied in a layer, in evaluation order (temp allocated)
LDtkRules_EvalOrder :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> []^LDtkRule {
	out := make([dynamic]^LDtkRule, context.temp_allocator)
	for &g in m.defs[l.def].groups {
		if !LDtkRules_GroupApplied(m, l, &g) do continue
		for &r in g.rules do if r.active do append(&out, &r)
	}
	return out[:]
}

// The active rules applied in a layer, in display order (the file's: last group first, last rule first)
LDtkRules_DisplayOrder :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> []^LDtkRule {
	out := make([dynamic]^LDtkRule, context.temp_allocator)
	groups := m.defs[l.def].groups[:]
	#reverse for &g in groups {
		if !LDtkRules_GroupApplied(m, l, &g) do continue
		#reverse for &r in g.rules do if r.active do append(&out, &r)
	}
	return out[:]
}

// JavaScript's ToInt32 of an integral double (its low 32 bits, signed)
@(private="file")
jsInt32 :: #force_inline proc(v: f64) -> i32 {
	i := i64(v)
	return transmute(i32)u32(u64(i) & 0xFFFFFFFF)
}

/*
deepnightLibs' `M.randSeedCoords` as LDtk runs it in JavaScript: a hash of a seed and a cell,
`0 <= n < max`. Haxe's Int maths on JavaScript are doubles until a bit operator truncates them, so
the products are rounded as doubles (exact up to 2^53) before each `^` / `>>`.
*/
ldtkRandSeedCoords :: proc(seed, x, y, max: int) -> int {
	if max <= 0 do return 0
	k1, k2, k3: f64 = 374761393, 668265263, 1274126177
	h := f64(seed) + f64(x) * k1 + f64(y) * k2
	a := jsInt32(h)
	b := a ~ (a >> 13)
	c := jsInt32(f64(b) * k3)
	d := c ~ (c >> 16)
	return int(d) % max
}

// heaps' 256 gradients (hxd.Perlin.GRADIENTS), scaled by 2.12 at run time as there
@(private="file")
PERLIN_GRADIENTS := [?]f64{
	-0.763874, -0.596439, -0.246489, 0.396055, 0.904518, -0.158073, -0.499004, -0.8665, -0.0131631, 0.468724, -0.824756, 0.316346,
	0.829598, 0.43195, 0.353816, -0.454473, 0.629497, -0.630228, -0.162349, -0.869962, -0.465628, 0.932805, 0.253451, 0.256198,
	-0.345419, 0.927299, -0.144227, -0.715026, -0.293698, -0.634413, -0.245997, 0.717467, -0.651711, -0.967409, -0.250435, -0.037451,
	0.901729, 0.397108, -0.170852, 0.892657, -0.0720622, -0.444938, 0.0260084, -0.0361701, 0.999007, 0.949107, -0.19486, 0.247439,
	0.471803, -0.807064, -0.355036, 0.879737, 0.141845, 0.453809, 0.570747, 0.696415, 0.435033, -0.141751, -0.988233, -0.0574584,
	-0.58219, -0.0303005, 0.812488, -0.60922, 0.239482, -0.755975, 0.299394, -0.197066, -0.933557, -0.851615, -0.220702, -0.47544,
	0.848886, 0.341829, -0.403169, -0.156129, -0.687241, 0.709453, -0.665651, 0.626724, 0.405124, 0.595914, -0.674582, 0.43569,
	0.171025, -0.509292, 0.843428, 0.78605, 0.536414, -0.307222, 0.18905, -0.791613, 0.581042, -0.294916, 0.844994, 0.446105,
	0.342031, -0.58736, -0.7335, 0.57155, 0.7869, 0.232635, 0.885026, -0.408223, 0.223791, -0.789518, 0.571645, 0.223347,
	0.774571, 0.31566, 0.548087, -0.79695, -0.0433603, -0.602487, -0.142425, -0.473249, -0.869339, -0.0698838, 0.170442, 0.982886,
	0.687815, -0.484748, 0.540306, 0.543703, -0.534446, -0.647112, 0.97186, 0.184391, -0.146588, 0.707084, 0.485713, -0.513921,
	0.942302, 0.331945, 0.043348, 0.499084, 0.599922, 0.625307, -0.289203, 0.211107, 0.9337, 0.412433, -0.71667, -0.56239,
	0.87721, -0.082816, 0.47291, -0.420685, -0.214278, 0.881538, 0.752558, -0.0391579, 0.657361, 0.0765725, -0.996789, 0.0234082,
	-0.544312, -0.309435, -0.779727, -0.455358, -0.415572, 0.787368, -0.874586, 0.483746, 0.0330131, 0.245172, -0.0838623, 0.965846,
	0.382293, -0.432813, 0.81641, -0.287735, -0.905514, 0.311853, -0.667704, 0.704955, -0.239186, 0.717885, -0.464002, -0.518983,
	0.976342, -0.214895, 0.0240053, -0.0733096, -0.921136, 0.382276, -0.986284, 0.151224, -0.0661379, -0.899319, -0.429671, 0.0812908,
	0.652102, -0.724625, 0.222893, 0.203761, 0.458023, -0.865272, -0.030396, 0.698724, -0.714745, -0.460232, 0.839138, 0.289887,
	-0.0898602, 0.837894, 0.538386, -0.731595, 0.0793784, 0.677102, -0.447236, -0.788397, 0.422386, 0.186481, 0.645855, -0.740335,
	-0.259006, 0.935463, 0.240467, 0.445839, 0.819655, -0.359712, 0.349962, 0.755022, -0.554499, -0.997078, -0.0359577, 0.0673977,
	-0.431163, -0.147516, -0.890133, 0.299648, -0.63914, 0.708316, 0.397043, 0.566526, -0.722084, -0.502489, 0.438308, -0.745246,
	0.0687235, 0.354097, 0.93268, -0.0476651, -0.462597, 0.885286, -0.221934, 0.900739, -0.373383, -0.956107, -0.225676, 0.186893,
	-0.187627, 0.391487, -0.900852, -0.224209, -0.315405, 0.92209, -0.730807, -0.537068, 0.421283, -0.0353135, -0.816748, 0.575913,
	-0.941391, 0.176991, -0.287153, -0.154174, 0.390458, 0.90762, -0.283847, 0.533842, 0.796519, -0.482737, -0.850448, 0.209052,
	-0.649175, 0.477748, 0.591886, 0.885373, -0.405387, -0.227543, -0.147261, 0.181623, -0.972279, 0.0959236, -0.115847, -0.988624,
	-0.89724, -0.191348, 0.397928, 0.903553, -0.428461, -0.00350461, 0.849072, -0.295807, -0.437693, 0.65551, 0.741754, -0.141804,
	0.61598, -0.178669, 0.767232, 0.0112967, 0.932256, -0.361623, -0.793031, 0.258012, 0.551845, 0.421933, 0.454311, 0.784585,
	-0.319993, 0.0401618, -0.946568, -0.81571, 0.551307, -0.175151, -0.377644, 0.00322313, 0.925945, 0.129759, -0.666581, -0.734052,
	0.601901, -0.654237, -0.457919, -0.927463, -0.0343576, -0.372334, -0.438663, -0.868301, -0.231578, -0.648845, -0.749138, -0.133387,
	0.507393, -0.588294, 0.629653, 0.726958, 0.623665, 0.287358, 0.411159, 0.367614, -0.834151, 0.806333, 0.585117, -0.0864016,
	0.263935, -0.880876, 0.392932, 0.421546, -0.201336, 0.884174, -0.683198, -0.569557, -0.456996, -0.117116, -0.0406654, -0.992285,
	-0.643679, -0.109196, -0.757465, -0.561559, -0.62989, 0.536554, 0.0628422, 0.104677, -0.992519, 0.480759, -0.2867, -0.828658,
	-0.228559, -0.228965, -0.946222, -0.10194, -0.65706, -0.746914, 0.0689193, -0.678236, 0.731605, 0.401019, -0.754026, 0.52022,
	-0.742141, 0.547083, -0.387203, -0.00210603, -0.796417, -0.604745, 0.296725, -0.409909, -0.862513, -0.260932, -0.798201, 0.542945,
	-0.641628, 0.742379, 0.192838, -0.186009, -0.101514, 0.97729, 0.106711, -0.962067, 0.251079, -0.743499, 0.30988, -0.592607,
	-0.795853, -0.605066, -0.0226607, -0.828661, -0.419471, -0.370628, 0.0847218, -0.489815, -0.8677, -0.381405, 0.788019, -0.483276,
	0.282042, -0.953394, 0.107205, 0.530774, 0.847413, 0.0130696, 0.0515397, 0.922524, 0.382484, -0.631467, -0.709046, 0.313852,
	0.688248, 0.517273, 0.508668, 0.646689, -0.333782, -0.685845, -0.932528, -0.247532, -0.262906, 0.630609, 0.68757, -0.359973,
	0.577805, -0.394189, 0.714673, -0.887833, -0.437301, -0.14325, 0.690982, 0.174003, 0.701617, -0.866701, 0.0118182, 0.498689,
	-0.482876, 0.727143, 0.487949, -0.577567, 0.682593, -0.447752, 0.373768, 0.0982991, 0.922299, 0.170744, 0.964243, -0.202687,
	0.993654, -0.035791, -0.106632, 0.587065, 0.4143, -0.695493, -0.396509, 0.26509, -0.878924, -0.0866853, 0.83553, -0.542563,
	0.923193, 0.133398, -0.360443, 0.00379108, -0.258618, 0.965972, 0.239144, 0.245154, -0.939526, 0.758731, -0.555871, 0.33961,
	0.295355, 0.309513, 0.903862, 0.0531222, -0.91003, -0.411124, 0.270452, 0.0229439, -0.96246, 0.563634, 0.0324352, 0.825387,
	0.156326, 0.147392, 0.976646, -0.0410141, 0.981824, 0.185309, -0.385562, -0.576343, -0.720535, 0.388281, 0.904441, 0.176702,
	0.945561, -0.192859, -0.262146, 0.844504, 0.520193, 0.127325, 0.0330893, 0.999121, -0.0257505, -0.592616, -0.482475, -0.644999,
	0.539471, 0.631024, -0.557476, 0.655851, -0.027319, -0.754396, 0.274465, 0.887659, 0.369772, -0.123419, 0.975177, -0.183842,
	-0.223429, 0.708045, 0.66989, -0.908654, 0.196302, 0.368528, -0.95759, -0.00863708, 0.288005, 0.960535, 0.030592, 0.276472,
	-0.413146, 0.907537, 0.0754161, -0.847992, 0.350849, -0.397259, 0.614736, 0.395841, 0.68221, -0.503504, -0.666128, -0.550234,
	-0.268833, -0.738524, -0.618314, 0.792737, -0.60001, -0.107502, -0.637582, 0.508144, -0.579032, 0.750105, 0.282165, -0.598101,
	-0.351199, -0.392294, -0.850155, 0.250126, -0.960993, -0.118025, -0.732341, 0.680909, -0.0063274, -0.760674, -0.141009, 0.633634,
	0.222823, -0.304012, 0.926243, 0.209178, 0.505671, 0.836984, 0.757914, -0.56629, -0.323857, -0.782926, -0.339196, 0.52151,
	-0.462952, 0.585565, 0.665424, 0.61879, 0.194119, -0.761194, 0.741388, -0.276743, 0.611357, 0.707571, 0.702621, 0.0752872,
	0.156562, 0.819977, 0.550569, -0.793606, 0.440216, 0.42, 0.234547, 0.885309, -0.401517, 0.132598, 0.80115, -0.58359,
	-0.377899, -0.639179, 0.669808, -0.865993, -0.396465, 0.304748, -0.624815, -0.44283, 0.643046, -0.485705, 0.825614, -0.287146,
	-0.971788, 0.175535, 0.157529, -0.456027, 0.392629, 0.798675, -0.0104443, 0.521623, -0.853112, -0.660575, -0.74519, 0.091282,
	-0.0157698, -0.307475, -0.951425, -0.603467, -0.250192, 0.757121, 0.506876, 0.25006, 0.824952, 0.255404, 0.966794, 0.00884498,
	0.466764, -0.874228, -0.133625, 0.475077, -0.0682351, -0.877295, -0.224967, -0.938972, -0.260233, -0.377929, -0.814757, -0.439705,
	-0.305847, 0.542333, -0.782517, 0.26658, -0.902905, -0.337191, 0.0275773, 0.322158, -0.946284, 0.0185422, 0.716349, 0.697496,
	-0.20483, 0.978416, 0.0273371, -0.898276, 0.373969, 0.230752, -0.00909378, 0.546594, 0.837349, 0.6602, -0.751089, 0.000959236,
	0.855301, -0.303056, 0.420259, 0.797138, 0.0623013, -0.600574, 0.48947, -0.866813, 0.0951509, 0.251142, 0.674531, 0.694216,
	-0.578422, -0.737373, -0.348867, -0.254689, -0.514807, 0.818601, 0.374972, 0.761612, 0.528529, 0.640303, -0.734271, -0.225517,
	-0.638076, 0.285527, 0.715075, 0.772956, -0.15984, -0.613995, 0.798217, -0.590628, 0.118356, -0.986276, -0.0578337, -0.154644,
	-0.312988, -0.94549, 0.0899272, -0.497338, 0.178325, 0.849032, -0.101136, -0.981014, 0.165477, -0.521688, 0.0553434, -0.851339,
	-0.786182, -0.583814, 0.202678, -0.565191, 0.821858, -0.0714658, 0.437895, 0.152598, -0.885981, -0.92394, 0.353436, -0.14635,
	0.212189, -0.815162, -0.538969, -0.859262, 0.143405, -0.491024, 0.991353, 0.112814, 0.0670273, 0.0337884, -0.979891, -0.196654,
}

// The gradients as hxd.Perlin's constructor makes them (x, y, z, 0 per gradient)
@(private="file", thread_local)
perlinGradients: [256 * 4]f64
@(private="file", thread_local)
perlinReady: bool

@(private="file")
perlinInit :: proc() {
	if perlinReady do return
	scale := f64(2.12)
	for i in 0 ..< 256 {
		perlinGradients[i * 4 + 0] = PERLIN_GRADIENTS[i * 3 + 0] * scale
		perlinGradients[i * 4 + 1] = PERLIN_GRADIENTS[i * 3 + 1] * scale
		perlinGradients[i * 4 + 2] = PERLIN_GRADIENTS[i * 3 + 2] * scale
		perlinGradients[i * 4 + 3] = 0
	}
	perlinReady = true
}

// hxd.Perlin's repeat after `adjustScale(50, 1)` (AutoLayerRuleDef's)
@(private="file")
PERLIN_REPEAT :: 50

@(private="file")
perlinGradientAt :: #force_inline proc(x, y: f64, ix, iy, seed: int) -> f64 {
	index := i64(seed) * 1013 + i64(ix % PERLIN_REPEAT) * 1619 + i64(iy % PERLIN_REPEAT) * 31337
	// JavaScript: (index ^ (index >>> 8)) & 0xFF on the double's low 32 bits
	u := u32(u64(index) & 0xFFFFFFFF)
	i := int((u ~ (u >> 8)) & 0xFF) << 2
	return perlinGradients[i] * (x - f64(ix)) + perlinGradients[i + 1] * (y - f64(iy))
}

@(private="file")
scurve :: #force_inline proc(a: f64) -> f64 {
	a2 := a * a
	six, fifteen, ten := f64(6), f64(15), f64(10)
	return a2 * a * (six * a2 - fifteen * a + ten)
}

@(private="file")
linear :: #force_inline proc(a, b, k: f64) -> f64 {
	return a + k * (b - a)
}

@(private="file")
perlinGradient :: proc(seed: int, x, y: f64) -> f64 {
	ix := int(x)
	xs := scurve(x - f64(ix))
	iy := int(y)
	ys := scurve(y - f64(iy))
	ga := perlinGradientAt(x, y, ix, iy, seed)
	gb := perlinGradientAt(x, y, ix + 1, iy, seed)
	gc := perlinGradientAt(x, y, ix, iy + 1, seed)
	gd := perlinGradientAt(x, y, ix + 1, iy + 1, seed)
	return linear(linear(ga, gb, xs), linear(gc, gd, xs), ys)
}

// heaps' `hxd.Perlin.perlin` (normalized, persistence 0.5, lacunarity 2), as LDtk's rules use it
ldtkPerlin :: proc(seed: int, x, y: f64, octaves: int) -> f64 {
	perlinInit()
	x, y := x, y
	v, k, sum := f64(0), f64(1), f64(0)
	persist, lacunarity := f64(0.5), f64(2)
	for i in 0 ..< octaves {
		v += perlinGradient(seed + i, x, y) * k
		sum += k
		k *= persist
		x *= lacunarity
		y *= lacunarity
	}
	if sum != 0 do v /= sum
	return v
}

// Whether a rule's needed values are around a cell (AutoLayerRuleDef.isRelevantInLayerAt)
@(private="file")
relevantAt :: proc(r: ^LDtkRule, source: ^LDtkLayerData, cx, cy: int) -> bool {
	radius := r.size <= 1 ? 1 : r.size / 2
	for v in r.required {
		if !LDtkLayer_Contains(source, v) do return false
		if r.size == 1 {
			if !LDtkLayer_InArea(source, v, cx, cy) do return false
		} else if !LDtkLayer_InArea(source, v, cx - radius, cy - radius) && !LDtkLayer_InArea(source, v, cx + radius, cy - radius) &&
		   !LDtkLayer_InArea(source, v, cx + radius, cy + radius) && !LDtkLayer_InArea(source, v, cx - radius, cy + radius) {
			return false
		}
	}
	return true
}

/*
Whether a rule matches at a cell (AutoLayerRuleDef.matches): its chance, its Perlin mask, then its
pattern against the source layer's values (`dir` -1 mirrors it).
*/
LDtkRule_Matches :: proc(m: ^LDtkLevelModel, r: ^LDtkRule, li, source: ^LDtkLayerData, cx, cy: int, dirX := 1, dirY := 1) -> bool {
	if len(r.tileRectsIds) == 0 do return false
	if r.chance <= 0 || (r.chance < 1 && f64(ldtkRandSeedCoords(li.seed + r.uid, cx, cy, 100)) >= r.chance * 100) do return false
	if r.perlinActive && ldtkPerlin(li.seed + r.perlinSeed, f64(cx) * r.perlinScale, f64(cy) * r.perlinScale, r.perlinOctaves) < 0 do return false
	radius := r.size / 2
	sourceDef := &m.defs[source.def]
	for px in 0 ..< r.size do for py in 0 ..< r.size {
		p := r.pattern[px + py * r.size]
		if p == 0 do continue
		x, y := cx + dirX * (px - radius), cy + dirY * (py - radius)
		value: int
		if LDtkLayer_Valid(source, x, y) {
			value = LDtkLayer_IntGrid(source, x, y)
		} else {
			if !r.hasOutOfBounds do return false
			value = r.outOfBounds
		}
		switch {
		case abs(p) == LDTK_ANYTHING:
			if p > 0 && value == 0 do return false
			if p < 0 && value != 0 do return false
		case abs(p) > 999:
			info := LDtkLayerInfo_Value(sourceDef, value)
			if p > 0 && (info == nil || info.group != p / 1000 - 1) do return false
			if p < 0 && info != nil && info.group == -p / 1000 - 1 do return false
		case:
			if p > 0 && value != p do return false
			if p < 0 && value == -p do return false
		}
	}
	return true
}

// A rule's tiles at a cell (AutoLayerRuleDef.getRandomTileRectIdsForCoord)
@(private="file")
tilesAt :: proc(r: ^LDtkRule, seed, cx, cy, flips: int) -> []int {
	if len(r.tileRectsIds) == 0 do return nil
	return r.tileRectsIds[ldtkRandSeedCoords(r.uid + seed + flips, cx, cy, len(r.tileRectsIds))][:]
}

// AutoLayerRuleDef.getXOffsetForCoord / getYOffsetForCoord
@(private="file")
offsetAt :: proc(r: ^LDtkRule, seed, cx, cy, flips: int) -> [2]int {
	x := r.tileXOffset
	if r.tileRandomXMin != 0 || r.tileRandomXMax != 0 do x += ldtkRandSeedCoords(r.uid + seed + flips, cx, cy, r.tileRandomXMax - r.tileRandomXMin + 1) + r.tileRandomXMin
	y := r.tileYOffset
	if r.tileRandomYMin != 0 || r.tileRandomYMax != 0 do y += ldtkRandSeedCoords(r.uid + seed + 1, cx, cy, r.tileRandomYMax - r.tileRandomYMin + 1) + r.tileRandomYMin
	return {(flips & 1 != 0 ? -1 : 1) * x, (flips & 2 != 0 ? -1 : 1) * y}
}

// Adds a rule's tiles at a cell (LayerInstance.addRuleTilesAt)
@(private="file")
addRuleTiles :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, r: ^LDtkRule, cx, cy, flips: int) {
	d := &m.defs[l.def]
	// LayerInstance.isAutoTileCellAllowed
	if d.killedBy >= 0 {
		if other := LDtkLevel_LayerByDef(m, d.killedBy); other != nil && LDtkLayer_HasTile(other, cx, cy) do return
	}
	td := LDtkLevel_LayerTileset(m, l)
	if td == nil do return
	ids := tilesAt(r, l.seed, cx, cy, flips)
	// The stamp's bounds in the tileset (LayerInstance.getRuleStampRenderInfos)
	top, left, right, bottom := 99999, 99999, 0, 0
	if r.tileMode == .Stamp {
		for id in ids {
			c := LDtkTileset_TileCell(td, id)
			top, bottom = min(top, c.y), max(bottom, c.y)
			left, right = min(left, c.x), max(right, c.x)
		}
	}
	off := offsetAt(r, l.seed, cx, cy, flips)
	grid := d.gridSize
	cell := &l.auto[cx + cy * l.cWid]
	for id in ids {
		stamp := [2]int{}
		if r.tileMode == .Stamp {
			c := LDtkTileset_TileCell(td, id)
			fg := f64(grid)
			sx := int((f64(c.x - left) - r.pivot.x * f64(right - left) + d.tilePivot.x) * fg)
			sy := int((f64(c.y - top) - r.pivot.y * f64(bottom - top) + d.tilePivot.y) * fg)
			stamp = {sx * (flips & 1 != 0 ? -1 : 1), sy * (flips & 2 != 0 ? -1 : 1)}
		}
		src := LDtkTileset_Source(td, id)
		append(cell, LDtkAutoTile{
			rule = i32(r.uid),
			x = i32(cx * grid + stamp.x + off.x), y = i32(cy * grid + stamp.y + off.y),
			srcX = i32(src.x), srcY = i32(src.y),
			tile = i32(id), flips = u8(flips), alpha = r.alpha,
		})
	}
}

// Tries a rule at a cell (LayerInstance.applyRuleAt)
@(private="file")
applyRuleAt :: proc(m: ^LDtkLevelModel, l, source: ^LDtkLayerData, r: ^LDtkRule, cx, cy: int) {
	if !relevantAt(r, source, cx, cy) do return
	if r.xModulo <= 0 || r.yModulo <= 0 do return
	if r.checker != .Vertical && (cy - r.yOffset) % r.yModulo != 0 do return
	if r.checker == .Vertical && (cy + (cx / r.xModulo) % 2) % r.yModulo != 0 do return
	if r.checker != .Horizontal && (cx - r.xOffset) % r.xModulo != 0 do return
	if r.checker == .Horizontal && (cx + (cy / r.yModulo) % 2) % r.xModulo != 0 do return
	matched := false
	if LDtkRule_Matches(m, r, l, source, cx, cy) {
		addRuleTiles(m, l, r, cx, cy, 0)
		matched = true
	}
	if (!matched || !r.breakOnMatch) && r.flipX && LDtkRule_Matches(m, r, l, source, cx, cy, -1) {
		addRuleTiles(m, l, r, cx, cy, 1)
		matched = true
	}
	if (!matched || !r.breakOnMatch) && r.flipY && LDtkRule_Matches(m, r, l, source, cx, cy, 1, -1) {
		addRuleTiles(m, l, r, cx, cy, 2)
		matched = true
	}
	if (!matched || !r.breakOnMatch) && r.flipX && r.flipY && LDtkRule_Matches(m, r, l, source, cx, cy, -1, -1) {
		addRuleTiles(m, l, r, cx, cy, 3)
		matched = true
	}
}

// Removes a rule's tiles from a cell
@(private="file")
removeRuleTiles :: proc(cell: ^[dynamic]LDtkAutoTile, rule: i32) {
	n := 0
	for t in cell do if t.rule != rule {
		cell[n] = t
		n += 1
	}
	resize(cell, n)
}

// LayerInstance.applyBreakOnMatchesArea
@(private="file")
breakOnMatches :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, rules: []^LDtkRule, cx, cy, wid, hei: int) {
	left, top := max(0, cx), max(0, cy)
	right, bottom := min(l.cWid - 1, left + wid - 1), min(l.cHei - 1, top + hei - 1)
	td := LDtkLevel_LayerTileset(m, l)
	for y in top ..= bottom do for x in left ..= right {
		cell := &l.auto[x + y * l.cWid]
		if len(cell) == 0 do continue
		locked := false
		for r in rules {
			has := false
			for t in cell do if t.rule == i32(r.uid) {
				has = true
				break
			}
			if !has do continue
			switch {
			case locked:
				// Tiles below a lock are discarded
				removeRuleTiles(cell, i32(r.uid))
			case r.breakOnMatch:
				locked = true
			case !LDtkRule_HasOffset(r) && r.alpha >= 1:
				for t in cell do if t.rule == i32(r.uid) && LDtkTileset_Opaque(td, int(t.tile)) {
					locked = true
					break
				}
			}
		}
	}
}

/*
Applies a layer's rules again around a rectangle of cells (LayerInstance.applyAllRulesAt: the
rectangle widened by the largest pattern's radius), or everywhere when the layer had no tiles from
the file (`autoKnown` false). Only for auto layers (`LDtkLayerInfo_IsAuto`).

Inputs:
- l: The auto layer
- cx, cy, wid, hei: The changed cells (of its source layer)

Returns:
- Whether its tiles may have changed
*/
LDtkRules_ApplyArea :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy, wid, hei: int) -> bool {
	d := &m.defs[l.def]
	if !LDtkLayerInfo_IsAuto(d) || len(l.auto) == 0 do return false
	source: ^LDtkLayerData
	if d.kind == .IntGrid do source = l
	else if d.autoSource >= 0 do source = LDtkLevel_LayerByDef(m, d.autoSource)
	if !rulesCanBeUsed(d) || source == nil || len(source.intGrid) == 0 {
		// LayerInstance.clearAllAutoTilesCache
		had := false
		for &cell in l.auto do if len(cell) > 0 {
			clear(&cell)
			had = true
		}
		if had do l.changed += {.Auto}
		l.autoKnown = true
		return had
	}
	if !l.autoKnown {
		// LayerInstance.applyAllRules: a cache from nothing
		l.autoKnown = true
		for &cell in l.auto do clear(&cell)
		return LDtkRules_ApplyArea(m, l, 0, 0, l.cWid, l.cHei)
	}
	radius := LDTK_MAX_PATTERN_SIZE / 2
	left, right := max(0, cx - radius), min(l.cWid - 1, cx + wid - 1 + radius)
	top, bottom := max(0, cy - radius), min(l.cHei - 1, cy + hei - 1 + radius)
	if left > right || top > bottom do return false
	rules := LDtkRules_EvalOrder(m, l)
	for r in rules {
		for y in top ..= bottom do for x in left ..= right do removeRuleTiles(&l.auto[x + y * l.cWid], i32(r.uid))
		for x in left ..= right do for y in top ..= bottom do applyRuleAt(m, l, source, r, x, y)
	}
	breakOnMatches(m, l, rules, left, top, right - left + 1, bottom - top + 1)
	l.changed += {.Auto}
	// The tiles drawn from these cells reach as far as the rules move them: the canvas redraws
	// the whole widened rectangle and what the tiles cover (level_layers_render.odin)
	LDtkLayer_MarkDirty(l, left, top, right, bottom)
	return true
}

/*
Applies the rules every auto layer depends on after cells of a layer changed: the layer itself
(an IntGrid layer with rules), the AutoLayers using it as their source, the auto layers whose
tiles it removes (a Tiles layer: `autoTilesKilledByOtherLayerUid`), as LDtk's LevelRender
invalidates them.

Inputs:
- changed: The painted layer
- left, top, right, bottom: The changed cells
*/
LDtkRules_AfterChange :: proc(m: ^LDtkLevelModel, changed: ^LDtkLayerData, left, top, right, bottom: int) {
	d := &m.defs[changed.def]
	wid, hei := right - left + 1, bottom - top + 1
	if d.kind == .IntGrid {
		if LDtkLayerInfo_IsAuto(d) do LDtkRules_ApplyArea(m, changed, left, top, wid, hei)
		for &other in m.layers {
			od := &m.defs[other.def]
			if od.kind == .AutoLayer && od.autoSource == d.uid do LDtkRules_ApplyArea(m, &other, left, top, wid, hei)
		}
	}
	if d.kind == .Tiles {
		for &other in m.layers {
			od := &m.defs[other.def]
			if LDtkLayerInfo_IsAuto(od) && od.killedBy == d.uid do LDtkRules_ApplyArea(m, &other, left, top, wid, hei)
		}
	}
}

// Every rule of an auto layer applied from nothing (LayerInstance.applyAllRules)
LDtkRules_ApplyAll :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) {
	l.autoKnown = false
	LDtkRules_ApplyArea(m, l, 0, 0, l.cWid, l.cHei)
}

