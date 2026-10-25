package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
Field values of any kind (phase 5 of TODO.md's "LDtk level editor"), as LDtk's field form edits
them (ui/FieldInstancesForm.hx, data/inst/FieldInstance.hx): `Field_Value` sets one value of an
entity's or a level's field (`entity` or `level`: its iid; `field`: the definition's uid; `index`:
an array's item), adds an item to an array (LDtk's +: an empty one, the default; at most
`arrayMaxLength`), removes one, moves one (`number`: its new place), or clears an array.

- The value is written as LDtk keeps it, in `realEditorValues` (FieldInstance.toJson): `V_Int`,
  `V_Float`, `V_Bool`, `V_String` (points "cx,cy", tiles "x,y,w,h", enum values, file paths
  relative to the project file, references by iid); then LDtk's tidy works out `__value` (clamped, its default where there's none), `__tile`,
  the smart color, and the table of contents.
- Typed values are read as LDtk's FieldInstance.parseValue reads them: whole numbers and numbers
  clamped to the range, colors, an enum's values, a string trimmed and kept to what its regex
  matches (FieldDef.applyRegex), file types (`acceptFileTypes`).

The older single-value ops (`Entity_Field`, `Level_Field`) stay for what they did; arrays, tiles
and paths go through here.
*/

/*
A field value's item as LDtk keeps it in `realEditorValues` ({ id, params }), from typed text.

Returns:
- The item, or why the text isn't a value of the field
*/
LDtk_FieldRawItem :: proc(doc: ^LDtkDoc, info: LDtkFieldInfo, text: string) -> (LDtkJV, string) {
	wrap :: proc(id: string, param: LDtkJV) -> LDtkJV {
		return jobject(jpair("id", id), jpair("params", jarray(param)))
	}
	main := LDtkDoc_Main(doc)
	t := strings.trim_space(text)
	#partial switch info.type {
	case .Int:
		v, ok := strconv.parse_f64(t)
		if !ok do return nil, fmt.tprintf("%q isn't a whole number", text)
		n := int(math.round(v))
		if lo, has := info.min.?; has do n = max(n, int(math.ceil(lo)))
		if hi, has := info.max.?; has do n = min(n, int(math.floor(hi)))
		return wrap("V_Int", i64(n)), ""
	case .Float:
		v, ok := strconv.parse_f64(t)
		if !ok do return nil, fmt.tprintf("%q isn't a number", text)
		if lo, has := info.min.?; has do v = max(v, lo)
		if hi, has := info.max.?; has do v = min(v, hi)
		return wrap("V_Float", jvNumber(v)), ""
	case .Bool:
		switch strings.to_lower(t, context.temp_allocator) {
		case "true": return wrap("V_Bool", true), ""
		case "false": return wrap("V_Bool", false), ""
		}
		return nil, "true or false"
	case .Color:
		c, ok := LDtk_ParseColor(t)
		if !ok do return nil, fmt.tprintf("%q isn't a color (#RRGGBB)", text)
		return wrap("V_Int", i64(c)), ""
	case .String:
		// FieldInstance.parseValue: trimmed, empty is none, "\r" "\n" become spaces, the regex
		// keeps what matches (FieldDef.applyRegex)
		if t == "" do return LDtkJNull{}, ""
		value, _ := strings.replace_all(t, `\r`, " ", context.temp_allocator)
		value, _ = strings.replace_all(value, `\n`, " ", context.temp_allocator)
		value, _ = strings.replace_all(value, "\n", " ", context.temp_allocator)
		if regex := Json_String(main, Json_Get(main, info.node, "regex")); regex != "" do value = LDtk_ApplyRegex(regex, value)
		return wrap("V_String", value), ""
	case .Text:
		if text == "" do return LDtkJNull{}, ""
		return wrap("V_String", strings.clone(text, context.temp_allocator)), ""
	case .Path:
		if t == "" do return LDtkJNull{}, ""
		if types := Json_Get(main, info.node, "acceptFileTypes"); Json_Count(main, types) > 0 {
			ok := false
			for ext in Json_Items(main, types) {
				e := strings.to_lower(strings.trim_prefix(Json_String(main, ext), "."), context.temp_allocator)
				if strings.has_suffix(strings.to_lower(t, context.temp_allocator), fmt.tprintf(".%s", e)) do ok = true
			}
			if !ok do return nil, fmt.tprintf("%q isn't one of the field's file types", t)
		}
		return wrap("V_String", strings.clone(t, context.temp_allocator)), ""
	case .Enum:
		if !slice.contains(LDtkDoc_EnumValues(doc, info.enumUid), t) do return nil, fmt.tprintf("%q isn't one of the enum's values", text)
		return wrap("V_String", strings.clone(t, context.temp_allocator)), ""
	case .Point:
		xs, _, ys := strings.partition(t, ",")
		x, xok := strconv.parse_int(strings.trim_space(xs))
		y, yok := strconv.parse_int(strings.trim_space(ys))
		if !xok || !yok do return nil, fmt.tprintf("%q isn't a cell (x, y)", text)
		return wrap("V_String", fmt.tprintf("%d,%d", x, y)), ""
	case .EntityRef:
		if t == "" do return LDtkJNull{}, ""
		if _, found := LDtkDoc_FindEntity(doc, t); !found do return nil, "no such entity"
		return wrap("V_String", strings.clone(t, context.temp_allocator)), ""
	case .Tile:
		if t == "" do return LDtkJNull{}, ""
		r, ok := LDtk_ParseRect(t)
		if !ok do return nil, fmt.tprintf("%q isn't a tile rectangle (x,y,w,h)", text)
		return wrap("V_String", fmt.tprintf("%d,%d,%d,%d", r[0], r[1], r[2], r[3])), ""
	}
	return nil, "this field's type isn't known here"
}

/*
A `Field_Value` edit (see the file's doc block).

Returns:
- "" or why nothing changed
*/
LDtkOps_FieldValue :: proc(root: string, doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string) {
	_ = root
	s := stagesMake(doc)
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	_, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
	if fieldDef < 0 do return "no such field"
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	// Where the field's instances are: an entity's, or every copy of a level's
	places := make([dynamic]LDtkDocPlace, context.temp_allocator)
	if edit.entity != "" {
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity"
		append(&places, LDtkDocPlace{e.file, e.node})
	} else {
		level := LDtkDoc_FindLevel(doc, edit.level)
		if level < 0 do return "no such level"
		append(&places, ..LDtkDoc_LevelObjects(doc, level))
	}
	main := LDtkDoc_Main(doc)
	maxLength := Json_Kind(main, Json_Get(main, fieldDef, "arrayMaxLength")) == .Number ? Json_Int(main, Json_Get(main, fieldDef, "arrayMaxLength")) : -1
	p := LDtkPatches{}
	found := false
	for place in places {
		json := LDtkDoc_Json(doc, place.file)
		for fi in Json_Items(json, Json_Get(json, place.node, "fieldInstances")) {
			if Json_Int(json, Json_Get(json, fi, "defUid"), -1) != edit.field do continue
			found = true
			rawNode := Json_Get(json, fi, "realEditorValues")
			raws := make([dynamic]LDtkJV, context.temp_allocator)
			for r in Json_Items(json, rawNode) do append(&raws, ldtkJV(json, r))
			i := edit.index
			switch edit.key {
			case "add":
				if !info.isArray do return "not an array"
				if maxLength >= 0 && len(raws) >= maxLength do return fmt.tprintf("the array holds at most %d", maxLength)
				append(&raws, LDtkJNull{})
			case "remove":
				if i < 0 || i >= len(raws) do return "no such item"
				ordered_remove(&raws, i)
			case "move":
				if i < 0 || i >= len(raws) do return "no such item"
				to := clamp(int(math.round(edit.number)), 0, len(raws) - 1)
				if to == i do return ""
				moved := raws[i]
				ordered_remove(&raws, i)
				inject_at(&raws, to, moved)
			case "clear":
				clear(&raws)
			case "", "set":
				item: LDtkJV
				if strings.trim_space(edit.text) == "" && info.type != .Text {
					item = LDtkJNull{}
				} else {
					why: string
					item, why = LDtk_FieldRawItem(doc, info, edit.text)
					if why != "" do return why
				}
				if !info.isArray {
					// A single value: none is the default (LDtk's empty internal values)
					clear(&raws)
					if _, isNull := item.(LDtkJNull); !isNull do append(&raws, item)
				} else {
					if i < 0 || i >= len(raws) do return "no such item"
					raws[i] = item
				}
			case:
				return fmt.tprintf("%q isn't a field edit", edit.key)
			}
			LDtkPatches_Set(&p, doc, place.file, rawNode, writeAt(json, rawNode, LDtkJArray(raws[:]), Json_Minified(json)))
		}
	}
	if !found do return "this field has no value in the file yet: open and save it in LDtk once"
	if problem = stagesApply(&s, &p); problem != "" do return
	if len(s.made) == 0 do return ""
	// __value, __tile, smart colors, the table of contents (LDtk's tidy)
	if problem = LDtkTidy_Run(&s); problem != "" do return
	result := stagesFinish(&s, "")
	s.made = nil
	return result
}

/*
A text kept to what a field's regex matches (FieldDef.applyRegex, "/pattern/flags"): "" when nothing
matches, else every match in turn, joined. A small regex reader for what fields use (anchors,
classes, ranges, ., *, +, ?, {n,m}, groups with |, escapes \d \w \s); a pattern it can't read
keeps the text.
*/
LDtk_ApplyRegex :: proc(regex, text: string) -> string {
	pattern := regex
	flags := ""
	if strings.has_prefix(pattern, "/") {
		last := strings.last_index_byte(pattern, '/')
		if last > 0 {
			flags = pattern[last + 1:]
			pattern = pattern[1:last]
		}
	}
	m := RegexMatcher{pattern = pattern, insensitive = strings.contains_rune(flags, 'i')}
	node, ok := regexParseAlt(&m)
	if !ok || m.pos != len(m.pattern) do return text
	b := strings.builder_make(context.temp_allocator)
	sub := text
	any := false
	for {
		start, end := -1, -1
		for at in 0 ..= len(sub) {
			if e := regexMatch(&m, node, sub, at); e >= 0 {
				start, end = at, e
				break
			}
		}
		if start < 0 do break
		any = true
		strings.write_string(&b, sub[start:end])
		// Haxe's matchedRight: what follows the match (an empty match moves on one)
		next := end > start ? end : end + 1
		if next >= len(sub) do break
		sub = sub[next:]
	}
	if !any do return ""
	return strings.to_string(b)
}

@(private="file")
RegexMatcher :: struct {
	pattern: string,
	pos: int,
	insensitive: bool,
	nodes: [dynamic]RegexNode,
}

@(private="file")
RegexKind :: enum u8 {
	Char,
	Any,
	Class,
	Start,
	End,
	Group,
	Alt,
}

@(private="file")
RegexNode :: struct {
	kind: RegexKind,
	c: u8,
	negated: bool,
	// A class's ranges (pairs), a group's / alternation's parts (node indexes per branch)
	ranges: [dynamic][2]u8,
	branches: [dynamic][dynamic]int,
	min, max: int,
}

// Alternatives: branch (| branch)*
@(private="file")
regexParseAlt :: proc(m: ^RegexMatcher) -> (int, bool) {
	alt := RegexNode{kind = .Alt, min = 1, max = 1}
	alt.branches = make([dynamic][dynamic]int, context.temp_allocator)
	alt.ranges = make([dynamic][2]u8, context.temp_allocator)
	for {
		branch := make([dynamic]int, context.temp_allocator)
		for m.pos < len(m.pattern) && m.pattern[m.pos] != '|' && m.pattern[m.pos] != ')' {
			n, ok := regexParseAtom(m)
			if !ok do return -1, false
			append(&branch, n)
		}
		append(&alt.branches, branch)
		if m.pos < len(m.pattern) && m.pattern[m.pos] == '|' {
			m.pos += 1
			continue
		}
		break
	}
	if m.nodes == nil do m.nodes = make([dynamic]RegexNode, context.temp_allocator)
	append(&m.nodes, alt)
	return len(m.nodes) - 1, true
}

@(private="file")
regexParseAtom :: proc(m: ^RegexMatcher) -> (int, bool) {
	if m.nodes == nil do m.nodes = make([dynamic]RegexNode, context.temp_allocator)
	n := RegexNode{min = 1, max = 1}
	n.ranges = make([dynamic][2]u8, context.temp_allocator)
	c := m.pattern[m.pos]
	m.pos += 1
	switch c {
	case '^': n.kind = .Start
	case '$': n.kind = .End
	case '.': n.kind = .Any
	case '(':
		if m.pos + 1 < len(m.pattern) && m.pattern[m.pos] == '?' && m.pattern[m.pos + 1] == ':' do m.pos += 2
		inner, ok := regexParseAlt(m)
		if !ok || m.pos >= len(m.pattern) || m.pattern[m.pos] != ')' do return -1, false
		m.pos += 1
		n.kind = .Group
		n.branches = make([dynamic][dynamic]int, context.temp_allocator)
		one := make([dynamic]int, context.temp_allocator)
		append(&one, inner)
		append(&n.branches, one)
	case '[':
		n.kind = .Class
		if m.pos < len(m.pattern) && m.pattern[m.pos] == '^' {
			n.negated = true
			m.pos += 1
		}
		for m.pos < len(m.pattern) && m.pattern[m.pos] != ']' {
			a := m.pattern[m.pos]
			m.pos += 1
			if a == '\\' && m.pos < len(m.pattern) {
				regexEscapeRanges(&n, m.pattern[m.pos])
				m.pos += 1
				continue
			}
			if m.pos + 1 < len(m.pattern) && m.pattern[m.pos] == '-' && m.pattern[m.pos + 1] != ']' {
				append(&n.ranges, [2]u8{a, m.pattern[m.pos + 1]})
				m.pos += 2
			} else {
				append(&n.ranges, [2]u8{a, a})
			}
		}
		if m.pos >= len(m.pattern) do return -1, false
		m.pos += 1
	case '\\':
		if m.pos >= len(m.pattern) do return -1, false
		e := m.pattern[m.pos]
		m.pos += 1
		switch e {
		case 'd', 'w', 's', 'D', 'W', 'S':
			n.kind = .Class
			regexEscapeRanges(&n, e)
		case:
			n.kind = .Char
			n.c = e
		}
	case '*', '+', '?', '{', ')', '|':
		return -1, false
	case:
		n.kind = .Char
		n.c = c
	}
	// Quantifiers
	if m.pos < len(m.pattern) {
		switch m.pattern[m.pos] {
		case '*': n.min, n.max = 0, max(int); m.pos += 1
		case '+': n.min, n.max = 1, max(int); m.pos += 1
		case '?': n.min, n.max = 0, 1; m.pos += 1
		case '{':
			end := strings.index_byte(m.pattern[m.pos:], '}')
			if end < 0 do return -1, false
			body := m.pattern[m.pos + 1:m.pos + end]
			lo, _, hi := strings.partition(body, ",")
			a, okA := strconv.parse_int(lo)
			if !okA do return -1, false
			n.min, n.max = a, a
			if strings.contains_rune(body, ',') {
				n.max = max(int)
				if hi != "" {
					b, okB := strconv.parse_int(hi)
					if !okB do return -1, false
					n.max = b
				}
			}
			m.pos += end + 1
		}
		if m.pos < len(m.pattern) && m.pattern[m.pos] == '?' do m.pos += 1
	}
	append(&m.nodes, n)
	return len(m.nodes) - 1, true
}

// \d \w \s (and their negations) as ranges
@(private="file")
regexEscapeRanges :: proc(n: ^RegexNode, e: u8) {
	switch e {
	case 'd', 'D': append(&n.ranges, [2]u8{'0', '9'})
	case 'w', 'W': append(&n.ranges, [2]u8{'a', 'z'}, [2]u8{'A', 'Z'}, [2]u8{'0', '9'}, [2]u8{'_', '_'})
	case 's', 'S': append(&n.ranges, [2]u8{' ', ' '}, [2]u8{'\t', '\t'}, [2]u8{'\n', '\n'}, [2]u8{'\r', '\r'})
	case: append(&n.ranges, [2]u8{e, e})
	}
	if e == 'D' || e == 'W' || e == 'S' do n.negated = true
}

// One character against a node (Char, Any, Class)
@(private="file")
regexChar :: proc(m: ^RegexMatcher, n: ^RegexNode, c: u8) -> bool {
	lower :: proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }
	switch n.kind {
	case .Any: return c != '\n'
	case .Char: return m.insensitive ? lower(c) == lower(n.c) : c == n.c
	case .Class:
		in_ := false
		for r in n.ranges {
			if c >= r[0] && c <= r[1] do in_ = true
			if m.insensitive && lower(c) >= lower(r[0]) && lower(c) <= lower(r[1]) do in_ = true
		}
		return in_ != n.negated
	case .Start, .End, .Group, .Alt:
	}
	return false
}

// Matches a node at a position (backtracking); the end, -1 when it doesn't
@(private="file")
regexMatch :: proc(m: ^RegexMatcher, node: int, text: string, at: int) -> int {
	n := &m.nodes[node]
	if n.kind != .Alt do return -1
	for branch in n.branches {
		if end := regexSeq(m, branch[:], 0, text, at); end >= 0 do return end
	}
	return -1
}

// A sequence of atoms from its `i`-th, with each atom's repeats tried greedily
@(private="file")
regexSeq :: proc(m: ^RegexMatcher, seq: []int, i: int, text: string, at: int) -> int {
	if i >= len(seq) do return at
	n := &m.nodes[seq[i]]
	switch n.kind {
	case .Start:
		if at != 0 do return -1
		return regexSeq(m, seq, i + 1, text, at)
	case .End:
		if at != len(text) do return -1
		return regexSeq(m, seq, i + 1, text, at)
	case .Alt:
		return -1
	case .Char, .Any, .Class, .Group:
	}
	// Positions after 0, 1, 2... repeats
	ends := make([dynamic]int, context.temp_allocator)
	append(&ends, at)
	pos := at
	for count := 0; count < n.max; count += 1 {
		next := -1
		if n.kind == .Group {
			next = regexMatch(m, n.branches[0][0], text, pos)
		} else if pos < len(text) && regexChar(m, n, text[pos]) {
			next = pos + 1
		}
		if next < 0 || next == pos do break
		pos = next
		append(&ends, pos)
	}
	#reverse for end, count in ends {
		if count < n.min do break
		if r := regexSeq(m, seq, i + 1, text, end); r >= 0 do return r
	}
	return -1
}
