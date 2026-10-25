package crossfire_editor

import "core:strconv"
import "core:strings"

/*
LDtk's JSON writer, ported (deepnightLibs' `dn.data.JsonPretty`, which LDtk's ProjectSaver uses with
its "Compact" level, or "Minified" when the project says so): the values painting writes into a
document (an IntGrid's `intGridCsv`, a layer's `gridTiles` and `autoLayerTiles`, a new entity) come
out as LDtk would write them, so a file saved after painting differs from LDtk's own save only
where the content does.

The Compact rules (`APPROXIMATE_MAX_LINE_LENGTH` is 85):
- an array of numbers longer than 85 is a grid: 35 numbers per line, one level deeper;
- a value whose estimated length (`ldtkPrettyLength`) is at most 85 is on one line
  (`{ "a": 1, "b": [1,2] }`; arrays of numbers without spaces, of one item without spaces);
- anything else has an item per line, a tab deeper.

Numbers are written as JavaScript writes them (LDtk runs in Electron: a whole float is an Int to
Haxe's `Type.typeof`, so `1.0` is written `1`). Strings are written as JsonPretty writes them: line
breaks and tabs become spaces, quotes are escaped, backslashes aren't (LDtk's quirk), and a string
like `5f` becomes the number `5.0` (another). `ldtkPrettyString` keeps backslashes valid JSON
instead: they're escaped (a value with a backslash would otherwise not parse).
*/

// A JSON value to write (temp allocated trees)
LDtkJV :: union {
	LDtkJNull,
	i64,
	f64,
	bool,
	string,
	LDtkJArray,
	LDtkJObject,
}

// JSON's null
LDtkJNull :: struct {}

// An array's items
LDtkJArray :: distinct []LDtkJV

// An object's members, in order
LDtkJObject :: distinct []LDtkJPair

// An object member
LDtkJPair :: struct {
	key: string,
	value: LDtkJV,
}

@(private="file")
PRETTY_MAX_LINE :: 85

// The writer's settings and output
@(private="file")
Pretty :: struct {
	b: ^strings.Builder,
	minified: bool,
	indent: int,
}

/*
Writes a value as LDtk's JsonPretty does.

Inputs:
- v: The value
- minified: The file is minified (no spaces or line breaks)
- indent: How many tabs deep the value starts (the indentation of the line its key is on)

Returns:
- The JSON text (temp allocated)
*/
LDtk_PrettyJson :: proc(v: LDtkJV, minified: bool, indent := 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	p := Pretty{b = &b, minified = minified, indent = indent}
	prettyValue(&p, "", false, v)
	return strings.to_string(b)
}

// How many tabs the line holding a text position starts with (a patched value's indentation)
LDtk_IndentAt :: proc(text: string, pos: int) -> int {
	start := pos
	for start > 0 && text[start - 1] != '\n' do start -= 1
	n := 0
	for start + n < len(text) && text[start + n] == '\t' do n += 1
	return n
}

/*
A number as JavaScript's `String(n)` writes it: the shortest digits that read back as the same
double, without an exponent between 1e-7 and 1e21.

Returns:
- The text (temp allocated)
*/
LDtk_JsNumber :: proc(v: f64) -> string {
	if v != v do return "NaN"
	if v == 0 do return "0"
	buf: [64]u8
	// "+d.ddde±XX": the shortest round-trip digits and the exponent
	s := string(strconv.write_float(buf[:], v, 'e', -1, 64))
	negative := s[0] == '-'
	body := s[1:]
	mantissa, _, expText := strings.partition(body, "e")
	exp, _ := strconv.parse_int(expText)
	digits := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)mantissa do if c != '.' do strings.write_byte(&digits, c)
	d := strings.to_string(digits)
	// Trailing zeros aren't digits JavaScript writes
	for len(d) > 1 && d[len(d) - 1] == '0' do d = d[:len(d) - 1]
	k := len(d)
	n := exp + 1
	out := strings.builder_make(context.temp_allocator)
	if negative do strings.write_byte(&out, '-')
	switch {
	case k <= n && n <= 21:
		strings.write_string(&out, d)
		for _ in 0 ..< n - k do strings.write_byte(&out, '0')
	case 0 < n && n <= 21:
		strings.write_string(&out, d[:n])
		strings.write_byte(&out, '.')
		strings.write_string(&out, d[n:])
	case -6 < n && n <= 0:
		strings.write_string(&out, "0.")
		for _ in 0 ..< -n do strings.write_byte(&out, '0')
		strings.write_string(&out, d)
	case:
		strings.write_byte(&out, d[0])
		if k > 1 {
			strings.write_byte(&out, '.')
			strings.write_string(&out, d[1:])
		}
		strings.write_byte(&out, 'e')
		strings.write_byte(&out, n - 1 >= 0 ? '+' : '-')
		strings.write_int(&out, abs(n - 1))
	}
	return strings.to_string(out)
}

// A JSON string literal as JsonPretty writes one (with a backslash escaped: see the doc block)
ldtkPrettyString :: proc(s: string) -> string {
	b := strings.builder_make(0, len(s) + 2, context.temp_allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\n', '\t': strings.write_byte(&b, ' ')
		case '\r':
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case:      strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Whether a number is an Int to Haxe on JavaScript (`Type.typeof`: whole and within 32 bits)
@(private="file")
isJsInt :: proc(v: f64) -> bool {
	return v == f64(i64(v)) && v >= -2147483648 && v < 2147483648
}

@(private="file")
isNumber :: proc(v: LDtkJV) -> bool {
	#partial switch _ in v {
	case i64, f64: return true
	}
	return false
}

// JsonPretty's floatReg: `^([-0-9.]+)f$`
@(private="file")
floatHinted :: proc(s: string) -> (f64, bool) {
	if len(s) < 2 || s[len(s) - 1] != 'f' do return 0, false
	for c in transmute([]u8)s[:len(s) - 1] do if !(c == '-' || c == '.' || (c >= '0' && c <= '9')) do return 0, false
	return strconv.parse_f64(s[:len(s) - 1])
}

@(private="file")
writeIndent :: proc(p: ^Pretty) {
	if p.minified do return
	for _ in 0 ..< p.indent do strings.write_byte(p.b, '\t')
}

@(private="file")
writeName :: proc(p: ^Pretty, name: string) {
	if name == "" do return
	strings.write_byte(p.b, '"')
	strings.write_string(p.b, name)
	strings.write_string(p.b, p.minified ? `":` : `": `)
}

// JsonPretty.addValue
@(private="file")
prettyValue :: proc(p: ^Pretty, name: string, force: bool, v: LDtkJV) {
	switch x in v {
	case LDtkJNull:
		writeName(p, name)
		strings.write_string(p.b, "null")
	case i64:
		writeName(p, name)
		strings.write_i64(p.b, x)
	case f64:
		writeName(p, name)
		if isJsInt(x) do strings.write_i64(p.b, i64(x))
		else do strings.write_string(p.b, LDtk_JsNumber(x))
	case bool:
		writeName(p, name)
		strings.write_string(p.b, x ? "true" : "false")
	case string:
		writeName(p, name)
		if f, hinted := floatHinted(x); hinted {
			// "0f" -> 0.0: a float-hinted value (JsonPretty writes the whole ones with ".0")
			if f == f64(i64(f)) {
				strings.write_string(p.b, LDtk_JsNumber(f))
				strings.write_string(p.b, ".0")
			} else {
				strings.write_string(p.b, LDtk_JsNumber(f))
			}
		} else {
			strings.write_string(p.b, ldtkPrettyString(x))
		}
	case LDtkJArray:
		prettyArray(p, name, ([]LDtkJV)(x), force)
	case LDtkJObject:
		prettyObject(p, name, ([]LDtkJPair)(x), force)
	}
}

// JsonPretty.addObject
@(private="file")
prettyObject :: proc(p: ^Pretty, name: string, o: []LDtkJPair, force: bool) {
	if len(o) == 0 {
		// JsonPretty's own spacing for an empty named object
		if name == "" {
			strings.write_string(p.b, "{}")
		} else {
			strings.write_byte(p.b, '"')
			strings.write_string(p.b, name)
			strings.write_string(p.b, `" : {}`)
		}
		return
	}
	length := p.minified ? 0 : ldtkPrettyLength(LDtkJObject(o), 0)
	writeName(p, name)
	if p.minified || (length <= PRETTY_MAX_LINE && !force) {
		strings.write_string(p.b, p.minified ? "{" : "{ ")
		for pair, i in o {
			prettyValue(p, pair.key, false, pair.value)
			if i < len(o) - 1 do strings.write_string(p.b, p.minified ? "," : ", ")
		}
		strings.write_string(p.b, p.minified ? "}" : " }")
		return
	}
	strings.write_string(p.b, "{\n")
	p.indent += 1
	for pair, i in o {
		writeIndent(p)
		prettyValue(p, pair.key, false, pair.value)
		if i < len(o) - 1 do strings.write_string(p.b, ",\n")
	}
	p.indent -= 1
	strings.write_byte(p.b, '\n')
	writeIndent(p)
	strings.write_byte(p.b, '}')
}

// JsonPretty.addArray
@(private="file")
prettyArray :: proc(p: ^Pretty, name: string, a: []LDtkJV, force: bool) {
	if len(a) == 0 {
		writeName(p, name)
		strings.write_string(p.b, "[]")
		return
	}
	length := p.minified ? 0 : ldtkPrettyLength(LDtkJArray(a), 0)
	writeName(p, name)
	numbers := isNumber(a[0])
	if !p.minified && numbers && !force && len(a) > PRETTY_MAX_LINE {
		// A number grid: 35 per line
		strings.write_string(p.b, "[\n")
		p.indent += 1
		writeIndent(p)
		line := 0
		for item, i in a {
			prettyValue(p, "", false, item)
			if i < len(a) - 1 do strings.write_byte(p.b, ',')
			line += 1
			if line >= 35 {
				strings.write_byte(p.b, '\n')
				writeIndent(p)
				line = 0
			}
		}
		p.indent -= 1
		strings.write_byte(p.b, '\n')
		writeIndent(p)
		strings.write_byte(p.b, ']')
		return
	}
	if p.minified || (length <= PRETTY_MAX_LINE && !force) {
		space := ""
		if !p.minified {
			_, isBool := a[0].(bool)
			switch {
			case numbers: space = ""
			case isBool:  space = len(a) > 5 ? "" : " "
			case:         space = len(a) == 1 ? "" : " "
			}
		}
		strings.write_byte(p.b, '[')
		strings.write_string(p.b, space)
		for item, i in a {
			prettyValue(p, "", false, item)
			if i < len(a) - 1 {
				strings.write_byte(p.b, ',')
				strings.write_string(p.b, space)
			}
		}
		strings.write_string(p.b, space)
		strings.write_byte(p.b, ']')
		return
	}
	strings.write_string(p.b, "[\n")
	p.indent += 1
	for item, i in a {
		writeIndent(p)
		prettyValue(p, "", false, item)
		if i < len(a) - 1 do strings.write_string(p.b, ",\n")
	}
	p.indent -= 1
	strings.write_byte(p.b, '\n')
	writeIndent(p)
	strings.write_byte(p.b, ']')
}

// JsonPretty.evaluateLength: the estimate deciding between one line and several
ldtkPrettyLength :: proc(v: LDtkJV, depth: int) -> int {
	switch x in v {
	case LDtkJNull: return 4
	case i64:       return 4
	case f64:       return isJsInt(x) ? 4 : 5
	case bool:      return x ? 4 : 5
	case string:    return len(x) + 2
	case LDtkJObject:
		if depth <= 0 && len(x) <= 5 {
			n := 0
			for pair in x do n += ldtkPrettyLength(pair.value, depth + 1)
			return n
		}
		return len(x) * 10
	case LDtkJArray:
		if len(x) == 0 do return 2
		if len(x) < 50 && isNumber(x[0]) do return len(x)
		if len(x) > 5 || depth > 0 do return 99
		n := 0
		for item in x do n += ldtkPrettyLength(item, depth + 1)
		return n
	}
	return 1
}
