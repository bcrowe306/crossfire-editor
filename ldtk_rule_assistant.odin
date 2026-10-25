package crossfire_editor

import "core:fmt"
import "core:strings"

/*
LDtk's Rule Assistant (ui/modal/dialog/RulesWizard.hx, 1.5.3): a group of rules made from one
IntGrid value (the "main" value) and, optionally, the value around it (the "outer" value; none: any
other value), by giving each wall part (`LDtkWallFragment`: a block, its walls, corners, turns,
crosses...) its tiles. Parts without tiles take a mirrored part's tiles when it has them (the rule
then mirrors: flipX / flipY), as the Assistant does. Its group is marked `usesWizard`: the panel
edits its rules only through the Assistant again (or after "Advanced mode").

The edit (`Rule_Group_Assistant`): `def` the layer, `index` the group made before (-1: a new one,
first in the list), `text` the group's name, `ids` the Assistant's choices:
`[main, outer, breakOnMatch (0 / 1), then per part: its index, its tile count, its tiles...]`
(`LDtkAssistant_Encode`).
*/

// The Assistant's wall parts, in LDtk's order (the order its rules are made in)
LDtkWallFragment :: enum u8 {
	Single, Cross,
	Turn_NW, Turn_NE, Turn_SE, Turn_SW,
	Diagonal_SW_NE, Diagonal_NW_SE,
	Corner_NW_to_N, Corner_NW_to_W, Corner_NW_to_NW,
	Corner_NE_to_N, Corner_NE_to_E, Corner_NE_to_NE,
	Corner_SE_to_E, Corner_SE_to_S, Corner_SE_to_SE,
	Corner_SW_to_S, Corner_SW_to_W, Corner_SW_to_SW,
	TCross_N, TCross_E, TCross_S, TCross_W,
	TWall_W, TWall_E, TWall_S, TWall_N,
	Horizontal_W, Horizontal_E, Horizontal_Mid,
	Vertical_N, Vertical_S, Vertical_Mid,
	ExtCorner_NW, ExtCorner_NE, ExtCorner_SE, ExtCorner_SW,
	Wall_N, Wall_E, Wall_S, Wall_W,
	InCorner_NW, InCorner_NE, InCorner_SE, InCorner_SW,
	Full,
}

// Where each part sits in the Assistant's grid (its `@at` metadata: column, row of a 12 x 5 grid)
LDTK_WALL_FRAGMENT_AT := [LDtkWallFragment][2]int{
	.Single = {3, 1}, .Cross = {3, 2},
	.Turn_NW = {2, 3}, .Turn_NE = {3, 3}, .Turn_SE = {3, 4}, .Turn_SW = {2, 4},
	.Diagonal_SW_NE = {10, 2}, .Diagonal_NW_SE = {10, 3},
	.Corner_NW_to_N = {6, 2}, .Corner_NW_to_W = {6, 0}, .Corner_NW_to_NW = {10, 0},
	.Corner_NE_to_N = {7, 2}, .Corner_NE_to_E = {7, 0}, .Corner_NE_to_NE = {11, 0},
	.Corner_SE_to_E = {7, 1}, .Corner_SE_to_S = {7, 3}, .Corner_SE_to_SE = {11, 1},
	.Corner_SW_to_S = {6, 3}, .Corner_SW_to_W = {6, 1}, .Corner_SW_to_SW = {10, 1},
	.TCross_N = {8, 3}, .TCross_E = {8, 2}, .TCross_S = {9, 2}, .TCross_W = {9, 3},
	.TWall_W = {8, 0}, .TWall_E = {9, 0}, .TWall_S = {8, 1}, .TWall_N = {9, 1},
	.Horizontal_W = {3, 0}, .Horizontal_E = {5, 0}, .Horizontal_Mid = {4, 0},
	.Vertical_N = {4, 1}, .Vertical_S = {4, 3}, .Vertical_Mid = {4, 2},
	.ExtCorner_NW = {0, 0}, .ExtCorner_NE = {2, 0}, .ExtCorner_SE = {2, 2}, .ExtCorner_SW = {0, 2},
	.Wall_N = {1, 0}, .Wall_E = {2, 1}, .Wall_S = {1, 2}, .Wall_W = {0, 1},
	.InCorner_NW = {0, 3}, .InCorner_NE = {1, 3}, .InCorner_SE = {1, 4}, .InCorner_SW = {0, 4},
	.Full = {1, 1},
}

// The Assistant's grid's size (columns, rows)
LDTK_ASSISTANT_GRID :: [2]int{12, 5}

/*
A part's 3 x 3 pattern (RulesWizard.getRuleMatrixFromFragment): `o` the main value, `x` the outer
one, `-` anything; mirrored on request.
*/
LDtkWallFragment_Matrix :: proc(f: LDtkWallFragment, flipX := false, flipY := false) -> [3]string {
	m: [3]string
	switch f {
	case .Full:           m = {"---", "-o-", "---"}
	case .Single:         m = {"-x-", "xox", "-x-"}
	case .Cross:          m = {"xox", "ooo", "xox"}
	case .Diagonal_NW_SE: m = {"oox", "ooo", "xoo"}
	case .Diagonal_SW_NE: m = {"xoo", "ooo", "oox"}
	case .TWall_N:        m = {"xox", "ooo", "ooo"}
	case .TWall_S:        m = LDtkWallFragment_Matrix(.TWall_N, false, true)
	case .TWall_W:        m = {"xoo", "ooo", "xoo"}
	case .TWall_E:        m = LDtkWallFragment_Matrix(.TWall_W, true, false)
	case .TCross_N:       m = {"xox", "ooo", "-x-"}
	case .TCross_S:       m = LDtkWallFragment_Matrix(.TCross_N, false, true)
	case .TCross_W:       m = {"xo-", "oox", "xo-"}
	case .TCross_E:       m = LDtkWallFragment_Matrix(.TCross_W, true, false)
	case .Vertical_N:     m = {"-x-", "xox", "---"}
	case .Vertical_Mid:   m = {"---", "xox", "---"}
	case .Vertical_S:     m = LDtkWallFragment_Matrix(.Vertical_N, false, true)
	case .Horizontal_W:   m = {"-x-", "xo-", "-x-"}
	case .Horizontal_Mid: m = {"-x-", "-o-", "-x-"}
	case .Horizontal_E:   m = LDtkWallFragment_Matrix(.Horizontal_W, true, false)
	case .Turn_NW:        m = {"-x-", "xoo", "-ox"}
	case .Turn_NE:        m = LDtkWallFragment_Matrix(.Turn_NW, true, false)
	case .Turn_SE:        m = LDtkWallFragment_Matrix(.Turn_NW, true, true)
	case .Turn_SW:        m = LDtkWallFragment_Matrix(.Turn_NW, false, true)
	case .Wall_N:         m = {"-x-", "-o-", "---"}
	case .Wall_S:         m = LDtkWallFragment_Matrix(.Wall_N, false, true)
	case .Wall_W:         m = {"---", "xo-", "---"}
	case .Wall_E:         m = LDtkWallFragment_Matrix(.Wall_W, true, false)
	case .ExtCorner_NW:   m = {"-x-", "xo-", "---"}
	case .ExtCorner_NE:   m = LDtkWallFragment_Matrix(.ExtCorner_NW, true, false)
	case .ExtCorner_SE:   m = LDtkWallFragment_Matrix(.ExtCorner_NW, true, true)
	case .ExtCorner_SW:   m = LDtkWallFragment_Matrix(.ExtCorner_NW, false, true)
	case .InCorner_NW:    m = {"xo-", "oo-", "---"}
	case .InCorner_NE:    m = LDtkWallFragment_Matrix(.InCorner_NW, true, false)
	case .InCorner_SE:    m = LDtkWallFragment_Matrix(.InCorner_NW, true, true)
	case .InCorner_SW:    m = LDtkWallFragment_Matrix(.InCorner_NW, false, true)
	case .Corner_NW_to_N: m = {"-ox", "xoo", "-oo"}
	case .Corner_NE_to_N: m = LDtkWallFragment_Matrix(.Corner_NW_to_N, true, false)
	case .Corner_SE_to_S: m = LDtkWallFragment_Matrix(.Corner_NW_to_N, true, true)
	case .Corner_SW_to_S: m = LDtkWallFragment_Matrix(.Corner_NW_to_N, false, true)
	case .Corner_NW_to_W: m = {"-x-", "ooo", "xoo"}
	case .Corner_NE_to_E: m = LDtkWallFragment_Matrix(.Corner_NW_to_W, true, false)
	case .Corner_SE_to_E: m = LDtkWallFragment_Matrix(.Corner_NW_to_W, true, true)
	case .Corner_SW_to_W: m = LDtkWallFragment_Matrix(.Corner_NW_to_W, false, true)
	case .Corner_NW_to_NW: m = {"xox", "ooo", "xoo"}
	case .Corner_NE_to_NE: m = LDtkWallFragment_Matrix(.Corner_NW_to_NW, true, false)
	case .Corner_SW_to_SW: m = LDtkWallFragment_Matrix(.Corner_NW_to_NW, false, true)
	case .Corner_SE_to_SE: m = LDtkWallFragment_Matrix(.Corner_NW_to_NW, true, true)
	}
	if flipX {
		for &line in m {
			b := make([]u8, len(line), context.temp_allocator)
			for i in 0 ..< len(line) do b[i] = line[len(line) - 1 - i]
			line = string(b)
		}
	}
	if flipY do m[0], m[2] = m[2], m[0]
	return m
}

// The part a part becomes mirrored (RulesWizard.flip)
LDtkWallFragment_Flip :: proc(f: LDtkWallFragment, flipX, flipY: bool) -> LDtkWallFragment {
	pick :: proc(flipX, flipY: bool, f, x, y, xy: LDtkWallFragment) -> LDtkWallFragment {
		if flipX && flipY do return xy
		if flipX do return x
		if flipY do return y
		return f
	}
	switch f {
	case .Full, .Single, .Cross, .Vertical_Mid, .Horizontal_Mid: return f
	case .Wall_N: return flipY ? .Wall_S : f
	case .Wall_E: return flipX ? .Wall_W : f
	case .Wall_S: return flipY ? .Wall_N : f
	case .Wall_W: return flipX ? .Wall_E : f
	case .Diagonal_NW_SE: return flipX || flipY ? .Diagonal_SW_NE : f
	case .Diagonal_SW_NE: return flipX || flipY ? .Diagonal_NW_SE : f
	case .TCross_N: return flipY ? .TCross_S : f
	case .TCross_S: return flipY ? .TCross_N : f
	case .TCross_W: return flipX ? .TCross_E : f
	case .TCross_E: return flipX ? .TCross_W : f
	case .TWall_N: return flipY ? .TWall_S : f
	case .TWall_S: return flipY ? .TWall_N : f
	case .TWall_W: return flipX ? .TWall_E : f
	case .TWall_E: return flipX ? .TWall_W : f
	case .Vertical_N: return flipY ? .Vertical_S : f
	case .Vertical_S: return flipY ? .Vertical_N : f
	case .Horizontal_W: return flipX ? .Horizontal_E : f
	case .Horizontal_E: return flipX ? .Horizontal_W : f
	case .ExtCorner_NW: return pick(flipX, flipY, f, .ExtCorner_NE, .ExtCorner_SW, .ExtCorner_SE)
	case .ExtCorner_NE: return pick(flipX, flipY, f, .ExtCorner_NW, .ExtCorner_SE, .ExtCorner_SW)
	case .ExtCorner_SE: return pick(flipX, flipY, f, .ExtCorner_SW, .ExtCorner_NE, .ExtCorner_NW)
	case .ExtCorner_SW: return pick(flipX, flipY, f, .ExtCorner_SE, .ExtCorner_NW, .ExtCorner_NE)
	case .InCorner_NW: return pick(flipX, flipY, f, .InCorner_NE, .InCorner_SW, .InCorner_SE)
	case .InCorner_NE: return pick(flipX, flipY, f, .InCorner_NW, .InCorner_SE, .InCorner_SW)
	case .InCorner_SE: return pick(flipX, flipY, f, .InCorner_SW, .InCorner_NE, .InCorner_NW)
	case .InCorner_SW: return pick(flipX, flipY, f, .InCorner_SE, .InCorner_NW, .InCorner_NE)
	case .Turn_NW: return pick(flipX, flipY, f, .Turn_NE, .Turn_SW, .Turn_SE)
	case .Turn_NE: return pick(flipX, flipY, f, .Turn_NW, .Turn_SE, .Turn_SW)
	case .Turn_SE: return pick(flipX, flipY, f, .Turn_SW, .Turn_NE, .Turn_NW)
	case .Turn_SW: return pick(flipX, flipY, f, .Turn_SE, .Turn_NW, .Turn_NE)
	case .Corner_NW_to_N: return pick(flipX, flipY, f, .Corner_NE_to_N, .Corner_SW_to_S, .Corner_SE_to_S)
	case .Corner_NW_to_W: return pick(flipX, flipY, f, .Corner_NE_to_E, .Corner_SW_to_W, .Corner_SE_to_E)
	case .Corner_NE_to_N: return pick(flipX, flipY, f, .Corner_NW_to_N, .Corner_SE_to_S, .Corner_SW_to_S)
	case .Corner_NE_to_E: return pick(flipX, flipY, f, .Corner_NW_to_W, .Corner_SE_to_E, .Corner_SW_to_W)
	case .Corner_SW_to_S: return pick(flipX, flipY, f, .Corner_SE_to_S, .Corner_NW_to_N, .Corner_NE_to_N)
	case .Corner_SW_to_W: return pick(flipX, flipY, f, .Corner_SE_to_E, .Corner_NW_to_W, .Corner_NE_to_E)
	case .Corner_SE_to_E: return pick(flipX, flipY, f, .Corner_SW_to_W, .Corner_NE_to_E, .Corner_NW_to_W)
	case .Corner_SE_to_S: return pick(flipX, flipY, f, .Corner_SW_to_S, .Corner_NE_to_N, .Corner_NW_to_N)
	case .Corner_NW_to_NW: return pick(flipX, flipY, f, .Corner_NE_to_NE, .Corner_SW_to_SW, .Corner_SE_to_SE)
	case .Corner_NE_to_NE: return pick(flipX, flipY, f, .Corner_NW_to_NW, .Corner_SE_to_SE, .Corner_SW_to_SW)
	case .Corner_SW_to_SW: return pick(flipX, flipY, f, .Corner_SE_to_SE, .Corner_NW_to_NW, .Corner_NE_to_NE)
	case .Corner_SE_to_SE: return pick(flipX, flipY, f, .Corner_SW_to_SW, .Corner_NE_to_NE, .Corner_NW_to_NW)
	}
	return f
}

// What the Assistant was given: the values, the option, each part's tiles
LDtkAssistant :: struct {
	main, other: int,
	breakOnMatch: bool,
	tiles: [LDtkWallFragment][dynamic]int,
}

// A part's mirrored stand-in: the part whose tiles it takes and how (getSymetricalAlternative)
LDtkAssistant_Alternative :: proc(a: ^LDtkAssistant, f: LDtkWallFragment) -> (alt: LDtkWallFragment, flipX, flipY, ok: bool) {
	if s := LDtkWallFragment_Flip(f, true, false); s != f && len(a.tiles[s]) > 0 do return s, true, false, true
	if s := LDtkWallFragment_Flip(f, false, true); s != f && len(a.tiles[s]) > 0 do return s, false, true, true
	if s := LDtkWallFragment_Flip(f, true, true); s != f && len(a.tiles[s]) > 0 do return s, true, true, true
	return f, false, false, false
}

// The Assistant's choices as an edit's `ids` (temp)
LDtkAssistant_Encode :: proc(a: ^LDtkAssistant) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	append(&out, a.main, a.other, a.breakOnMatch ? 1 : 0)
	for f in LDtkWallFragment {
		if len(a.tiles[f]) == 0 do continue
		append(&out, int(f), len(a.tiles[f]))
		append(&out, ..a.tiles[f][:])
	}
	return out[:]
}

// An edit's `ids` read back (temp)
LDtkAssistant_Decode :: proc(ids: []int) -> (a: LDtkAssistant, ok: bool) {
	if len(ids) < 3 do return {}, false
	a.main, a.other, a.breakOnMatch = ids[0], ids[1], ids[2] != 0
	i := 3
	for i < len(ids) {
		if i + 1 >= len(ids) do return {}, false
		f, n := ids[i], ids[i + 1]
		if f < 0 || f > int(max(LDtkWallFragment)) || n < 0 || i + 2 + n > len(ids) do return {}, false
		list := make([dynamic]int, n, context.temp_allocator)
		copy(list[:], ids[i + 2:i + 2 + n])
		a.tiles[LDtkWallFragment(f)] = list
		i += 2 + n
	}
	return a, true
}

// The outer value as patterns hold it: the outer value, else "not the main value"
@(private="file")
assistantOther :: proc(a: ^LDtkAssistant) -> int {
	return a.other == 0 ? -a.main : a.other
}

/*
A group the Assistant made, read back into its choices (RulesWizard.importRuleGroup): the main
value (the first rule's center), the outer one (the first other value), the stacking option (the
first rule's), each rule matched to its part. Every tile of each rule is kept (LDtk keeps the
first only). False when no main value is found (LDtk starts the Assistant empty then).
*/
LDtkAssistant_Import :: proc(g: ^LDtkGroupEdit) -> (a: LDtkAssistant, ok: bool) {
	for &r in g.rules {
		c := r.size / 2
		if v := LDtkRule_Pattern(&r, c, c); v > 0 {
			a.main = abs(v)
			break
		}
	}
	if a.main == 0 do return {}, false
	found: for &r in g.rules do for cy in 0 ..< r.size do for cx in 0 ..< r.size {
		v := abs(LDtkRule_Pattern(&r, cx, cy))
		if v != 0 && v != a.main && v < LDTK_ANYTHING {
			a.other = v
			break found
		}
	}
	if len(g.rules) > 0 do a.breakOnMatch = g.rules[0].breakOnMatch
	for &r in g.rules {
		for f in LDtkWallFragment {
			if !assistantMatches(&a, &r, f) do continue
			list := make([dynamic]int, context.temp_allocator)
			for ids in r.tileRectsIds do if len(ids) > 0 do append(&list, ids[0])
			a.tiles[f] = list
			break
		}
	}
	return a, true
}

// Whether a rule is a part's (matchRuleToFragment)
@(private="file")
assistantMatches :: proc(a: ^LDtkAssistant, r: ^LDtkRule, f: LDtkWallFragment) -> bool {
	if r.size > 3 do return false
	m := LDtkWallFragment_Matrix(f)
	value :: proc(a: ^LDtkAssistant, c: u8) -> int {
		switch c {
		case 'x': return assistantOther(a)
		case 'o': return a.main
		}
		return 0
	}
	if r.size == 1 {
		for idx in 0 ..< 9 {
			v := value(a, m[idx / 3][idx % 3])
			if idx != 4 && v != 0 do return false
			if idx == 4 && v != LDtkRule_Pattern(r, 0, 0) do return false
		}
		return true
	}
	for cy in 0 ..< r.size do for cx in 0 ..< r.size do if value(a, m[cy][cx]) != LDtkRule_Pattern(r, cx, cy) do return false
	return true
}

// The Assistant's edit: its group made (or made again) from the choices (RulesWizard.createRules)
@(private)
ruleAssistant :: proc(op: ^RuleOp) -> string {
	edit := op.edit
	if why := rulesUsable(op); why != "" do return why
	a, ok := LDtkAssistant_Decode(edit.ids)
	if !ok do return "the Assistant's choices can't be read"
	if a.main <= 0 do return "pick an IntGrid value"
	name := strings.trim_space(edit.text)
	if name == "" do return "name this group of rules"
	values, _, _ := LDtkRules_SourceValues(op.doc, op.layer)
	if a.main not_in values do return fmt.tprintf("the source layer has no value %d", a.main)
	if a.other != 0 && a.other not_in values do return fmt.tprintf("the source layer has no value %d", a.other)
	at := -1
	if edit.index >= 0 {
		at = groupIndex(op.groups[:], edit.index)
		if at < 0 do return "no such rule group"
	} else {
		g := LDtkGroupEdit{uid = uidTake(&op.uids), color = -1, active = true}
		g.rules = make([dynamic]LDtkRule, context.temp_allocator)
		g.biome = make([dynamic]string, context.temp_allocator)
		inject_at(&op.groups, 0, g)
		at = 0
	}
	g := &op.groups[at]
	g.name = strings.clone(edit.text, context.temp_allocator)
	g.usesWizard = true
	clear(&g.rules)
	for f in LDtkWallFragment {
		if len(a.tiles[f]) == 0 do continue
		m := LDtkWallFragment_Matrix(f)
		r := ldtkNewRule(uidTake(&op.uids), 3)
		for cy in 0 ..< 3 do for cx in 0 ..< 3 {
			v := 0
			switch m[cy][cx] {
			case 'x': v = assistantOther(&a)
			case 'o': v = a.main
			}
			r.pattern[cx + cy * 3] = v
		}
		for id in a.tiles[f] {
			one := make([dynamic]int, 1, context.temp_allocator)
			one[0] = id
			append(&r.tileRectsIds, one)
		}
		r.outOfBounds, r.hasOutOfBounds = a.main, true
		r.breakOnMatch = a.breakOnMatch
		// Parts without tiles mirror this one: its rule mirrors too
		for e in LDtkWallFragment {
			if len(a.tiles[e]) > 0 do continue
			alt, fx, fy, has := LDtkAssistant_Alternative(&a, e)
			if !has || alt != f do continue
			if fx do r.flipX = true
			if fy do r.flipY = true
		}
		LDtkRule_Tidy(&r, values)
		append(&g.rules, r)
	}
	op.changed = true
	return ""
}
