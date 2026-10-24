package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

/*
JSON that keeps its text (the LDtk tab's write-back: ldtk_doc.odin).

`Json_Parse` reads a document into a flat tree of nodes, each knowing where its value (and an
object member's key) is in the text. Nothing is rebuilt from the tree: an edit is a list of
patches, each replacing one span of the original text (`Json_Apply`), so everything an edit doesn't
touch stays byte for byte as it was (unknown keys, their order, numbers as they were written,
LDtk's own formatting). Values an edit writes are formatted like their neighbours: a minified
document gets minified text, an array's new item the separator its items already have.

Nodes are indices into `JsonDoc.nodes` (0 is the root, -1 is "none"); a node's children are a
linked list (`first`, `next`), in the text's order.

Example:
	doc, problem := Json_Parse(`{"a": [1, 2], "b": "x"}`)
	defer Json_Destroy(&doc)
	b := Json_Get(&doc, 0, "b")
	text, ok := Json_Apply(doc.text, {Json_SetPatch(&doc, b, Json_Quote("y"))})
	// text == `{"a": [1, 2], "b": "y"}`
*/

// What a JSON value is
JsonKind :: enum u8 {
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

// A value of a parsed document, and where it is in the text
JsonNode :: struct {
	kind: JsonKind,
	// The value's text is `text[start:end]` (strings with their quotes)
	start, end: i32,
	// An object member's key, with its quotes (-1 for array items and the root)
	keyStart, keyEnd: i32,
	// The enclosing array or object, the first and last children, the next sibling (-1 none)
	parent, first, last, next: i32,
	// How many children it has
	count: i32,
}

// A parsed document: its text (owned) and its nodes (the root is node 0)
JsonDoc :: struct {
	text: string,
	nodes: [dynamic]JsonNode,
}

// One edit of a document's text: `text[start:end]` becomes `text`
JsonPatch :: struct {
	start, end: int,
	text: string,
}

// Deeper nesting than this isn't read (LDtk's files nest about 10 levels)
@(private="file")
JSON_MAX_DEPTH :: 256

@(private="file")
JsonParser :: struct {
	doc: ^JsonDoc,
	pos: int,
	problem: string,
}

/*
Parses a document, keeping where every value is in the text.

Inputs:
- text: The JSON (cloned into the document)

Returns:
- The document (free it with `Json_Destroy`), and "" or what's wrong with the text (then the
  document is empty)
*/
Json_Parse :: proc(text: string, allocator := context.allocator) -> (JsonDoc, string) {
	doc := JsonDoc{text = strings.clone(text, allocator), nodes = make([dynamic]JsonNode, 0, max(len(text) / 12, 16), allocator)}
	p := JsonParser{doc = &doc}
	skipSpace(&p)
	if parseValue(&p, -1, -1, -1, 0) < 0 {
		problem := p.problem
		Json_Destroy(&doc)
		return {}, problem
	}
	skipSpace(&p)
	if p.pos < len(doc.text) {
		problem := fmt.tprintf("unexpected text after the value at %d", p.pos)
		Json_Destroy(&doc)
		return {}, problem
	}
	return doc, ""
}

// Frees a document
Json_Destroy :: proc(doc: ^JsonDoc) {
	delete(doc.text, doc.nodes.allocator)
	delete(doc.nodes)
	doc^ = {}
}

@(private="file")
skipSpace :: proc(p: ^JsonParser) {
	text := p.doc.text
	for p.pos < len(text) {
		switch text[p.pos] {
		case ' ', '\t', '\n', '\r': p.pos += 1
		case: return
		}
	}
}

@(private="file")
fail :: proc(p: ^JsonParser, what: string) -> i32 {
	if p.problem == "" do p.problem = fmt.tprintf("%s at %d", what, p.pos)
	return -1
}

// Parses the value at the position into a new node (its key's span given): the node's index, or -1
@(private="file")
parseValue :: proc(p: ^JsonParser, parent: i32, keyStart, keyEnd: i32, depth: int) -> i32 {
	if depth > JSON_MAX_DEPTH do return fail(p, "nested too deep")
	text := p.doc.text
	if p.pos >= len(text) do return fail(p, "a value expected")
	index := i32(len(p.doc.nodes))
	append(&p.doc.nodes, JsonNode{start = i32(p.pos), keyStart = keyStart, keyEnd = keyEnd, parent = parent, first = -1, last = -1, next = -1})
	if parent >= 0 {
		parentNode := &p.doc.nodes[parent]
		if parentNode.last >= 0 do p.doc.nodes[parentNode.last].next = index
		else do parentNode.first = index
		parentNode.last = index
		parentNode.count += 1
	}
	kind: JsonKind
	switch c := text[p.pos]; c {
	case '{':
		kind = .Object
		p.pos += 1
		skipSpace(p)
		if p.pos < len(text) && text[p.pos] == '}' {
			p.pos += 1
			break
		}
		for {
			skipSpace(p)
			if p.pos >= len(text) || text[p.pos] != '"' do return fail(p, "a key expected")
			ks := p.pos
			if !skipString(p) do return fail(p, "an unterminated key")
			ke := p.pos
			skipSpace(p)
			if p.pos >= len(text) || text[p.pos] != ':' do return fail(p, "':' expected")
			p.pos += 1
			skipSpace(p)
			if parseValue(p, index, i32(ks), i32(ke), depth + 1) < 0 do return -1
			skipSpace(p)
			if p.pos >= len(text) do return fail(p, "'}' expected")
			if text[p.pos] == ',' {
				p.pos += 1
				continue
			}
			if text[p.pos] == '}' {
				p.pos += 1
				break
			}
			return fail(p, "',' or '}' expected")
		}
	case '[':
		kind = .Array
		p.pos += 1
		skipSpace(p)
		if p.pos < len(text) && text[p.pos] == ']' {
			p.pos += 1
			break
		}
		for {
			skipSpace(p)
			if parseValue(p, index, -1, -1, depth + 1) < 0 do return -1
			skipSpace(p)
			if p.pos >= len(text) do return fail(p, "']' expected")
			if text[p.pos] == ',' {
				p.pos += 1
				continue
			}
			if text[p.pos] == ']' {
				p.pos += 1
				break
			}
			return fail(p, "',' or ']' expected")
		}
	case '"':
		kind = .String
		if !skipString(p) do return fail(p, "an unterminated string")
	case 't':
		kind = .True
		if !strings.has_prefix(text[p.pos:], "true") do return fail(p, "a value expected")
		p.pos += 4
	case 'f':
		kind = .False
		if !strings.has_prefix(text[p.pos:], "false") do return fail(p, "a value expected")
		p.pos += 5
	case 'n':
		kind = .Null
		if !strings.has_prefix(text[p.pos:], "null") do return fail(p, "a value expected")
		p.pos += 4
	case '-', '0' ..= '9':
		kind = .Number
		start := p.pos
		numberLoop: for p.pos < len(text) {
			switch text[p.pos] {
			case '-', '+', '.', 'e', 'E', '0' ..= '9': p.pos += 1
			case: break numberLoop
			}
		}
		if _, ok := strconv.parse_f64(text[start:p.pos]); !ok do return fail(p, "a bad number")
	case:
		return fail(p, "a value expected")
	}
	node := &p.doc.nodes[index]
	node.kind = kind
	node.end = i32(p.pos)
	return index
}

// Moves past a string starting at the position (its quote): false when it doesn't end
@(private="file")
skipString :: proc(p: ^JsonParser) -> bool {
	text := p.doc.text
	p.pos += 1
	for p.pos < len(text) {
		switch text[p.pos] {
		case '\\': p.pos += 2
		case '"':
			p.pos += 1
			return true
		case: p.pos += 1
		}
	}
	return false
}

// The root node (-1 for an empty document)
Json_Root :: proc(doc: ^JsonDoc) -> int {
	return len(doc.nodes) > 0 ? 0 : -1
}

// The kind of a node (Null for -1)
Json_Kind :: proc(doc: ^JsonDoc, node: int) -> JsonKind {
	return node >= 0 && node < len(doc.nodes) ? doc.nodes[node].kind : .Null
}

/*
An object's member by key (the first with it), or -1.

Inputs:
- doc: The document
- object: An object node (anything else has no members)
- key: The key, as written between its quotes (LDtk's keys need no escapes)
*/
Json_Get :: proc(doc: ^JsonDoc, object: int, key: string) -> int {
	if object < 0 || object >= len(doc.nodes) || doc.nodes[object].kind != .Object do return -1
	for c := doc.nodes[object].first; c >= 0; c = doc.nodes[c].next {
		n := &doc.nodes[c]
		if int(n.keyEnd - n.keyStart) == len(key) + 2 && doc.text[n.keyStart + 1:n.keyEnd - 1] == key do return int(c)
	}
	return -1
}

// An array's item by index, or -1
Json_At :: proc(doc: ^JsonDoc, array: int, index: int) -> int {
	if array < 0 || array >= len(doc.nodes) || doc.nodes[array].kind != .Array || index < 0 do return -1
	i := 0
	for c := doc.nodes[array].first; c >= 0; c = doc.nodes[c].next {
		if i == index do return int(c)
		i += 1
	}
	return -1
}

/*
The children of an array or object, in order (temp allocated; none for other values).
*/
Json_Items :: proc(doc: ^JsonDoc, node: int) -> []int {
	if node < 0 || node >= len(doc.nodes) do return nil
	out := make([dynamic]int, 0, doc.nodes[node].count, context.temp_allocator)
	for c := doc.nodes[node].first; c >= 0; c = doc.nodes[c].next do append(&out, int(c))
	return out[:]
}

// How many children a node has
Json_Count :: proc(doc: ^JsonDoc, node: int) -> int {
	return node >= 0 && node < len(doc.nodes) ? int(doc.nodes[node].count) : 0
}

// A member's key as written (without its quotes; "" for array items)
Json_Key :: proc(doc: ^JsonDoc, node: int) -> string {
	if node < 0 || node >= len(doc.nodes) || doc.nodes[node].keyStart < 0 do return ""
	n := doc.nodes[node]
	return doc.text[n.keyStart + 1:n.keyEnd - 1]
}

// A value's text as written (a string with its quotes)
Json_Text :: proc(doc: ^JsonDoc, node: int) -> string {
	if node < 0 || node >= len(doc.nodes) do return ""
	n := doc.nodes[node]
	return doc.text[n.start:n.end]
}

/*
A string value, unescaped ("" for anything else).

Returns:
- The text (allocated with `allocator` when it had escapes, else pointing into the document)
*/
Json_String :: proc(doc: ^JsonDoc, node: int, allocator := context.temp_allocator) -> string {
	if Json_Kind(doc, node) != .String do return ""
	raw := Json_Text(doc, node)
	return Json_Unquote(raw, allocator)
}

// A JSON string literal's text (with its quotes), unescaped
Json_Unquote :: proc(raw: string, allocator := context.temp_allocator) -> string {
	if len(raw) < 2 do return ""
	inner := raw[1:len(raw) - 1]
	if !strings.contains_rune(inner, '\\') do return inner
	b := strings.builder_make(0, len(inner), allocator)
	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c != '\\' || i + 1 >= len(inner) {
			strings.write_byte(&b, c)
			continue
		}
		i += 1
		switch inner[i] {
		case 'n': strings.write_byte(&b, '\n')
		case 't': strings.write_byte(&b, '\t')
		case 'r': strings.write_byte(&b, '\r')
		case 'b': strings.write_byte(&b, '\b')
		case 'f': strings.write_byte(&b, '\f')
		case 'u':
			if i + 4 < len(inner) {
				if code, ok := strconv.parse_int(inner[i + 1:i + 5], 16); ok {
					r := rune(code)
					// A surrogate pair
					if r >= 0xD800 && r < 0xDC00 && i + 10 < len(inner) && inner[i + 5] == '\\' && inner[i + 6] == 'u' {
						if low, lowOk := strconv.parse_int(inner[i + 7:i + 11], 16); lowOk && low >= 0xDC00 && low < 0xE000 {
							r = 0x10000 + (r - 0xD800) * 0x400 + (rune(low) - 0xDC00)
							i += 6
						}
					}
					strings.write_rune(&b, r)
					i += 4
					continue
				}
			}
			strings.write_byte(&b, 'u')
		case: strings.write_byte(&b, inner[i])
		}
	}
	return strings.to_string(b)
}

// A number value (false for anything else)
Json_Number :: proc(doc: ^JsonDoc, node: int) -> (f64, bool) {
	if Json_Kind(doc, node) != .Number do return 0, false
	return strconv.parse_f64(Json_Text(doc, node))
}

// A number value as an int (`default` for anything else)
Json_Int :: proc(doc: ^JsonDoc, node: int, default := 0) -> int {
	v, ok := Json_Number(doc, node)
	return ok ? int(math.round(v)) : default
}

// A number value as a float (`default` for anything else)
Json_Float :: proc(doc: ^JsonDoc, node: int, default: f64 = 0) -> f64 {
	v, ok := Json_Number(doc, node)
	return ok ? v : default
}

// A boolean value (`default` for anything else)
Json_Bool :: proc(doc: ^JsonDoc, node: int, default := false) -> bool {
	switch Json_Kind(doc, node) {
	case .True: return true
	case .False: return false
	case .Null, .Number, .String, .Array, .Object: return default
	}
	return default
}

/*
A node by path: segments separated by dots, each a key, an array index, or `key=value` (an array's
first object whose `key` is that string, or number). For tests and the UI driver.

Example:
	Json_Path(&doc, "defs.layers.identifier=Walls.gridSize")
*/
Json_Path :: proc(doc: ^JsonDoc, path: string) -> int {
	node := Json_Root(doc)
	rest := path
	for rest != "" && node >= 0 {
		segment: string
		// A selector's value may hold dots: it runs to the next ".", but "key=a.b" can't be told
		// apart from "key=a" then "b": selectors take one segment
		segment, _, rest = strings.partition(rest, ".")
		if key, _, value := strings.partition(segment, "="); value != "" || strings.has_suffix(segment, "=") {
			found := -1
			for item in Json_Items(doc, node) {
				member := Json_Get(doc, item, key)
				if member < 0 do continue
				if Json_String(doc, member) == value || (Json_Kind(doc, member) == .Number && Json_Text(doc, member) == value) {
					found = item
					break
				}
			}
			node = found
			continue
		}
		if Json_Kind(doc, node) == .Array {
			index, ok := strconv.parse_int(segment)
			node = ok ? Json_At(doc, node, index) : -1
		} else {
			node = Json_Get(doc, node, segment)
		}
	}
	return node
}

/*
Applies patches to a text: each replaces its span of the original text.

Returns:
- The new text (allocated with `allocator`), and false when two patches overlap (nothing applied)
*/
Json_Apply :: proc(text: string, patches: []JsonPatch, allocator := context.allocator) -> (string, bool) {
	sorted := slice.clone(patches, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: JsonPatch) -> bool { return a.start < b.start || (a.start == b.start && a.end < b.end) })
	for p, i in sorted {
		if p.start < 0 || p.end < p.start || p.end > len(text) do return "", false
		if i > 0 && p.start < sorted[i - 1].end do return "", false
		// Two insertions at one place would be applied in an order nobody chose
		if i > 0 && p.start == sorted[i - 1].start && p.start == p.end && sorted[i - 1].start == sorted[i - 1].end do return "", false
	}
	b := strings.builder_make(0, len(text) + 64, allocator)
	at := 0
	for p in sorted {
		strings.write_string(&b, text[at:p.start])
		strings.write_string(&b, p.text)
		at = p.end
	}
	strings.write_string(&b, text[at:])
	return strings.to_string(b), true
}

// A patch replacing a node's value with `text` (JSON, as written)
Json_SetPatch :: proc(doc: ^JsonDoc, node: int, text: string) -> JsonPatch {
	n := doc.nodes[node]
	return {int(n.start), int(n.end), text}
}

// Whether a document is minified (written without line breaks): new values are written so too
Json_Minified :: proc(doc: ^JsonDoc) -> bool {
	return !strings.contains_rune(doc.text[:min(len(doc.text), 4096)], '\n')
}

/*
A patch adding an item at the end of an array, separated from the others as they are from each
other (a line of its own at their indentation, or inline).

Inputs:
- array: The array node
- item: The item's JSON text
*/
Json_AppendPatch :: proc(doc: ^JsonDoc, array: int, item: string) -> JsonPatch {
	n := doc.nodes[array]
	if n.count == 0 {
		// "[]" (or "[ ]"): the item inside
		return {int(n.start) + 1, int(n.end) - 1, item}
	}
	last := doc.nodes[n.last]
	return {int(last.end), int(last.end), fmt.tprintf("%s%s", itemSeparator(doc, array), item)}
}

/*
A patch inserting an item into an array before the item at `index` (at the end when `index` is
past the last).
*/
Json_InsertPatch :: proc(doc: ^JsonDoc, array: int, index: int, item: string) -> JsonPatch {
	at := Json_At(doc, array, index)
	if at < 0 do return Json_AppendPatch(doc, array, item)
	start := int(doc.nodes[at].start)
	return {start, start, fmt.tprintf("%s%s", item, itemSeparator(doc, array))}
}

// What separates an array's or object's children: the text between its first two, else a
// comma and the space its first one has after the bracket
@(private="file")
itemSeparator :: proc(doc: ^JsonDoc, parent: int) -> string {
	n := doc.nodes[parent]
	minified := Json_Minified(doc)
	if n.count >= 2 {
		first := doc.nodes[n.first]
		second := doc.nodes[first.next]
		secondStart := second.keyStart >= 0 ? second.keyStart : second.start
		return doc.text[first.end:secondStart]
	}
	if n.count == 1 {
		first := doc.nodes[n.first]
		firstStart := first.keyStart >= 0 ? first.keyStart : first.start
		lead := doc.text[n.start + 1:firstStart]
		if strings.contains_rune(lead, '\n') do return fmt.tprintf(",%s", lead[strings.last_index_byte(lead, '\n'):])
		return minified || lead == "" ? (minified ? "," : ", ") : fmt.tprintf(",%s", lead)
	}
	return minified ? "," : ", "
}

/*
A patch adding a member at the end of an object (the key isn't checked: don't add one it has),
written like its other members.
*/
Json_AddMemberPatch :: proc(doc: ^JsonDoc, object: int, key, value: string) -> JsonPatch {
	n := doc.nodes[object]
	minified := Json_Minified(doc)
	if n.count == 0 do return {int(n.start) + 1, int(n.end) - 1, fmt.tprintf(minified ? "%s:%s" : " %s: %s ", Json_Quote(key), value)}
	first := doc.nodes[n.first]
	colon := doc.text[first.keyEnd:first.start]
	last := doc.nodes[n.last]
	return {int(last.end), int(last.end), fmt.tprintf("%s%s%s%s", itemSeparator(doc, object), Json_Quote(key), colon, value)}
}

/*
A patch removing an item from an array (or a member from an object), with the separator before it
(after it, for the first).
*/
Json_RemovePatch :: proc(doc: ^JsonDoc, item: int) -> JsonPatch {
	n := doc.nodes[item]
	parent := doc.nodes[n.parent]
	start := n.keyStart >= 0 ? int(n.keyStart) : int(n.start)
	if parent.count == 1 do return {int(parent.start) + 1, int(parent.end) - 1, ""}
	if parent.first == i32(item) {
		next := doc.nodes[n.next]
		return {start, next.keyStart >= 0 ? int(next.keyStart) : int(next.start), ""}
	}
	// The previous sibling's end
	prev := parent.first
	for doc.nodes[prev].next != i32(item) do prev = doc.nodes[prev].next
	return {int(doc.nodes[prev].end), int(n.end), ""}
}

// A string as a JSON literal (with its quotes; "/" isn't escaped)
Json_Quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s) + 2, allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case utf8.RUNE_ERROR: strings.write_string(&b, `�`)
		case:
			if r < 0x20 do fmt.sbprintf(&b, `\u%04x`, int(r))
			else do strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

/*
A number as LDtk writes it: whole numbers without a fraction, others with at most `decimals`
decimals and no trailing zeros ("0.5", "175", "-0.125").
*/
Json_FormatNumber :: proc(v: f64, decimals := 3) -> string {
	if math.is_nan(v) || math.is_inf(v) do return "0"
	scale := math.pow(10, f64(decimals))
	rounded := math.round(v * scale) / scale
	if rounded == math.trunc(rounded) && abs(rounded) < 1e15 do return fmt.tprintf("%d", i64(rounded))
	text := fmt.tprintf("%.*f", decimals, rounded)
	text = strings.trim_right(text, "0")
	text = strings.trim_suffix(text, ".")
	if text == "-0" do return "0"
	return text
}

/*
An object's JSON text from key and value pairs (values already JSON), written as LDtk writes small
objects: `{ "id": "V_Int", "params": [5] }` (minified: no spaces).
*/
Json_Object :: proc(minified: bool, pairs: ..[2]string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, minified ? "{" : "{ ")
	for pair, i in pairs {
		if i > 0 do strings.write_string(&b, minified ? "," : ", ")
		fmt.sbprintf(&b, minified ? "%s:%s" : "%s: %s", Json_Quote(pair[0]), pair[1])
	}
	strings.write_string(&b, minified ? "}" : " }")
	return strings.to_string(b)
}

// An array's JSON text from items (already JSON): `[1,2]`, `["a","b"]`
Json_Array :: proc(items: ..string) -> string {
	return fmt.tprintf("[%s]", strings.join(items, ",", context.temp_allocator))
}
