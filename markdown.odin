package crossfire_editor

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import vmem "core:mem/virtual"

/*
A small Markdown parser for the docs window (docs.odin, view_docs.odin): the subset the manual and
the generated API pages use, parsed into blocks of styled spans the view draws with Skald.

	blocks     headings (`#`..`######`, with Starlight's anchors), paragraphs, lists (`-`, `*`,
	           `+`, `1.`; nested by indentation), tables (`| a | b |` over `|---|`), fenced code
	           (``` or ~~~, the info's first word its language), block quotes, rules
	inlines    **bold**, *italic* / _italic_, `code`, [links](target), ![images](src), <autolinks>,
	           backslash escapes, &lt; &gt; &amp; &quot;
	frontmatter `---` lines of `key: value` at the top (title, description, order)

Not supported (the manual's rules leave them out): HTML, setext headings, indented code blocks,
reference links, footnotes. Anchors follow github-slugger (what Starlight uses): the heading's text
lower-cased, everything but letters, digits, spaces, `-` and `_` removed, spaces turned into
dashes; a repeated anchor gets `-1`, `-2`...

Everything a parse makes lives in its `MdDoc`'s arena: `MdDoc_Destroy` frees it at once.
*/

// A run of text with one style
MdSpan :: struct {
	text: string,
	bold, italic, code: bool,
	// A link's target ("" none); an image's source when `image`
	link: string,
	image: bool,
}

MdBlockKind :: enum {
	Paragraph,
	Heading,
	List,
	Code,
	Table,
	Quote,
	Rule,
}

// One item of a list: its text, its depth (0 top level) and its number (ordered lists)
MdListItem :: struct {
	spans: []MdSpan,
	depth: int,
	number: int,
}

// A table cell's alignment (from the separator row's colons)
MdAlign :: enum {
	Left,
	Center,
	Right,
}

MdBlock :: struct {
	kind: MdBlockKind,
	// Paragraphs, headings and quotes
	spans: []MdSpan,
	// Headings: 1-6, the plain text and the anchor
	level: int,
	text: string,
	anchor: string,
	// Lists
	items: []MdListItem,
	ordered: bool,
	// Code: the text (lines joined by "\n") and the language ("odin"; "" none)
	code: string,
	lang: string,
	// Tables: the header row first, then the rows; each cell's spans
	rows: [][][]MdSpan,
	align: []MdAlign,
	// The source line the block starts on (0-based, after the frontmatter)
	line: int,
}

// A parsed document
MdDoc :: struct {
	arena: vmem.Arena,
	allocator: runtime.Allocator,
	// The frontmatter's keys (title, description, order; "" / 0 when missing)
	title, description: string,
	order: int,
	blocks: [dynamic]MdBlock,
}

/*
Parses a Markdown document.

Inputs:
- source: The text (its frontmatter, if any, first)

Returns:
- The document (free it with MdDoc_Destroy)
*/
Markdown_Parse :: proc(source: string) -> ^MdDoc {
	doc := new(MdDoc)
	if vmem.arena_init_growing(&doc.arena) != nil {
		free(doc)
		return nil
	}
	doc.allocator = vmem.arena_allocator(&doc.arena)
	context.allocator = doc.allocator
	doc.blocks = make([dynamic]MdBlock)

	// The document's own copy (in its arena): blocks keep slices of it (a code block's language,
	// the frontmatter's values); replace_all returns its input when there's nothing to replace
	text := strings.clone(source)
	if strings.contains(text, "\r\n") do text, _ = strings.replace_all(text, "\r\n", "\n")
	lines := strings.split_lines(text)
	at := 0
	// Frontmatter
	if len(lines) > 0 && strings.trim_right_space(lines[0]) == "---" {
		for i in 1 ..< len(lines) {
			if strings.trim_right_space(lines[i]) == "---" {
				for l in lines[1:i] do mdFrontmatterLine(doc, l)
				at = i + 1
				break
			}
		}
	}
	lines = lines[at:]
	anchors := make(map[string]int)
	i := 0
	for i < len(lines) {
		line := lines[i]
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			i += 1
			continue
		}
		start := i
		switch {
		case mdFence(trimmed) != "":
			fence := mdFence(trimmed)
			lang := strings.trim_space(trimmed[len(fence):])
			if sp := strings.index_any(lang, " \t{"); sp >= 0 do lang = lang[:sp]
			indent := len(line) - len(strings.trim_left_space(line))
			body := make([dynamic]string)
			i += 1
			for i < len(lines) {
				t := strings.trim_space(lines[i])
				if strings.has_prefix(t, fence) && strings.trim_left(t, fence[:1]) == "" do break
				l := lines[i]
				// The fence's own indentation (a fence inside a list item)
				n := 0
				for n < indent && n < len(l) && (l[n] == ' ' || l[n] == '\t') do n += 1
				append(&body, l[n:])
				i += 1
			}
			i += 1
			append(&doc.blocks, MdBlock{kind = .Code, code = strings.join(body[:], "\n"), lang = lang, line = start})
		case mdHeadingLevel(trimmed) > 0:
			level := mdHeadingLevel(trimmed)
			content := strings.trim_space(trimmed[level:])
			// Closing #s
			content = strings.trim_right_space(strings.trim_right(content, "#"))
			spans := Markdown_Inline(content)
			plain := MdSpans_Plain(spans)
			anchor := Markdown_Slug(plain)
			if n, seen := anchors[anchor]; seen {
				anchors[anchor] = n + 1
				anchor = strings.concatenate({anchor, "-", mdItoa(n + 1)})
			} else {
				anchors[anchor] = 0
			}
			append(&doc.blocks, MdBlock{kind = .Heading, level = level, spans = spans, text = plain, anchor = anchor, line = start})
			i += 1
		case mdIsRule(trimmed):
			append(&doc.blocks, MdBlock{kind = .Rule, line = start})
			i += 1
		case strings.has_prefix(trimmed, "|") && i + 1 < len(lines) && mdIsTableSeparator(strings.trim_space(lines[i + 1])):
			header := mdCells(trimmed)
			seps := mdCells(strings.trim_space(lines[i + 1]))
			align := make([]MdAlign, len(header))
			for s, c in seps {
				if c >= len(align) do break
				s := strings.trim_space(s)
				left, right := strings.has_prefix(s, ":"), strings.has_suffix(s, ":")
				align[c] = left && right ? .Center : right ? .Right : .Left
			}
			rows := make([dynamic][][]MdSpan)
			append(&rows, mdRowSpans(header[:]))
			i += 2
			for i < len(lines) && strings.has_prefix(strings.trim_space(lines[i]), "|") {
				cells := mdCells(strings.trim_space(lines[i]))
				// As many cells as the header
				for len(cells) < len(header) do append(&cells, "")
				append(&rows, mdRowSpans(cells[:len(header)]))
				i += 1
			}
			append(&doc.blocks, MdBlock{kind = .Table, rows = rows[:], align = align, line = start})
		case strings.has_prefix(trimmed, ">"):
			parts := make([dynamic]string)
			for i < len(lines) && strings.has_prefix(strings.trim_space(lines[i]), ">") {
				append(&parts, strings.trim_space(strings.trim_prefix(strings.trim_space(lines[i]), ">")))
				i += 1
			}
			append(&doc.blocks, MdBlock{kind = .Quote, spans = Markdown_Inline(strings.join(parts[:], " ")), line = start})
		case mdListMarker(line) >= 0:
			items := make([dynamic]MdListItem)
			_, ordered, _ := mdListItem(line)
			// The indentation of each depth seen so far
			indents := make([dynamic]int)
			for i < len(lines) {
				l := lines[i]
				if strings.trim_space(l) == "" {
					// A blank line ends the list unless an item follows
					j := i + 1
					for j < len(lines) && strings.trim_space(lines[j]) == "" do j += 1
					if j < len(lines) && mdListMarker(lines[j]) >= 0 {
						i = j
						continue
					}
					break
				}
				if content, itemOrdered, number := mdListItem(l); mdListMarker(l) >= 0 {
					indent := mdIndent(l)
					// A top-level item of the other kind starts another list
					if len(items) > 0 && itemOrdered != ordered && (len(indents) == 0 || indent <= indents[0]) do break
					for len(indents) > 0 && indents[len(indents) - 1] > indent do pop(&indents)
					if len(indents) == 0 || indents[len(indents) - 1] < indent do append(&indents, indent)
					parts := make([dynamic]string)
					append(&parts, content)
					i += 1
					// Continuation lines: indented, not an item, not another block
					for i < len(lines) {
						next := lines[i]
						t := strings.trim_space(next)
						if t == "" || mdListMarker(next) >= 0 || mdIndent(next) == 0 || mdFence(t) != "" do break
						append(&parts, t)
						i += 1
					}
					append(&items, MdListItem{spans = Markdown_Inline(strings.join(parts[:], " ")), depth = len(indents) - 1, number = number})
					continue
				}
				// A fenced block inside an item: its own block after the list
				break
			}
			append(&doc.blocks, MdBlock{kind = .List, items = items[:], ordered = ordered, line = start})
		case:
			parts := make([dynamic]string)
			for i < len(lines) {
				t := strings.trim_space(lines[i])
				if t == "" || (len(parts) > 0 && mdStartsBlock(lines[i], t, i + 1 < len(lines) ? lines[i + 1] : "")) do break
				append(&parts, t)
				i += 1
			}
			append(&doc.blocks, MdBlock{kind = .Paragraph, spans = Markdown_Inline(strings.join(parts[:], " ")), line = start})
		}
	}
	return doc
}

// Frees a document and everything in it
MdDoc_Destroy :: proc(doc: ^MdDoc) {
	if doc == nil do return
	vmem.arena_destroy(&doc.arena)
	free(doc)
}

// Whether a line starts a block other than a paragraph (so it ends the paragraph before it)
@(private="file")
mdStartsBlock :: proc(line, trimmed, next: string) -> bool {
	return mdFence(trimmed) != "" || mdHeadingLevel(trimmed) > 0 || mdIsRule(trimmed) || strings.has_prefix(trimmed, ">") ||
		mdListMarker(line) >= 0 || strings.has_prefix(trimmed, "|") && mdIsTableSeparator(strings.trim_space(next))
}

@(private="file")
mdFrontmatterLine :: proc(doc: ^MdDoc, line: string) {
	colon := strings.index_byte(line, ':')
	if colon <= 0 do return
	key := strings.trim_space(line[:colon])
	value := strings.trim_space(line[colon + 1:])
	if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
		value, _ = strings.replace_all(value[1:len(value) - 1], "\\\"", "\"")
	} else if len(value) >= 2 && value[0] == '\'' && value[len(value) - 1] == '\'' {
		value, _ = strings.replace_all(value[1:len(value) - 1], "''", "'")
	}
	switch key {
	case "title":       doc.title = value
	case "description": doc.description = value
	case "order":       doc.order, _ = strconv.parse_int(value)
	}
}

// A code fence's opening (``` or ~~~, as long as written), or ""
@(private="file")
mdFence :: proc(trimmed: string) -> string {
	for c in ([]u8{'`', '~'}) {
		n := 0
		for n < len(trimmed) && trimmed[n] == c do n += 1
		if n >= 3 {
			// A backtick fence's info has no backticks
			if c == '`' && strings.index_byte(trimmed[n:], '`') >= 0 do return ""
			return trimmed[:n]
		}
	}
	return ""
}

@(private="file")
mdHeadingLevel :: proc(trimmed: string) -> int {
	n := 0
	for n < len(trimmed) && trimmed[n] == '#' do n += 1
	if n == 0 || n > 6 do return 0
	if n < len(trimmed) && trimmed[n] != ' ' && trimmed[n] != '\t' do return 0
	return n
}

@(private="file")
mdIsRule :: proc(trimmed: string) -> bool {
	if len(trimmed) < 3 do return false
	c := trimmed[0]
	if c != '-' && c != '*' && c != '_' do return false
	count := 0
	for ch in transmute([]u8)trimmed {
		if ch == c do count += 1
		else if ch != ' ' do return false
	}
	return count >= 3
}

@(private="file")
mdIsTableSeparator :: proc(trimmed: string) -> bool {
	if !strings.contains(trimmed, "-") || !strings.contains(trimmed, "|") && !strings.has_prefix(trimmed, "-") do return false
	for ch in transmute([]u8)trimmed do if ch != '|' && ch != '-' && ch != ':' && ch != ' ' do return false
	return true
}

// A table row's cells: split on `|` outside code spans (`\|` is a literal bar)
@(private="file")
mdCells :: proc(row: string) -> [dynamic]string {
	r := strings.trim_space(row)
	r = strings.trim_prefix(r, "|")
	if strings.has_suffix(r, "|") && !strings.has_suffix(r, "\\|") do r = r[:len(r) - 1]
	cells := make([dynamic]string)
	start := 0
	inCode := false
	for i := 0; i < len(r); i += 1 {
		switch r[i] {
		case '\\':
			i += 1
		case '`':
			inCode = !inCode
		case '|':
			if inCode do continue
			append(&cells, strings.trim_space(r[start:i]))
			start = i + 1
		}
	}
	append(&cells, strings.trim_space(r[start:]))
	for &c in cells do c, _ = strings.replace_all(c, "\\|", "|")
	return cells
}

@(private="file")
mdRowSpans :: proc(cells: []string) -> [][]MdSpan {
	out := make([][]MdSpan, len(cells))
	for c, i in cells do out[i] = Markdown_Inline(c)
	return out
}

// The width of a line's leading whitespace (a tab counts 4)
@(private="file")
mdIndent :: proc(line: string) -> int {
	n := 0
	for ch in transmute([]u8)line {
		if ch == ' ' do n += 1
		else if ch == '\t' do n += 4
		else do break
	}
	return n
}

// Where a list item's marker starts (-1: the line isn't an item)
@(private="file")
mdListMarker :: proc(line: string) -> int {
	t := strings.trim_left_space(line)
	at := len(line) - len(t)
	if len(t) >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' ' {
		// `---`, `***` are rules, `**bold**` isn't an item
		if mdIsRule(strings.trim_space(t)) do return -1
		return at
	}
	n := 0
	for n < len(t) && t[n] >= '0' && t[n] <= '9' do n += 1
	if n > 0 && n <= 9 && n + 1 < len(t) && (t[n] == '.' || t[n] == ')') && t[n + 1] == ' ' do return at
	return -1
}

// A list item's text after its marker, whether it's numbered and its number
@(private="file")
mdListItem :: proc(line: string) -> (content: string, ordered: bool, number: int) {
	t := strings.trim_left_space(line)
	if len(t) >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') do return strings.trim_space(t[2:]), false, 0
	n := 0
	for n < len(t) && t[n] >= '0' && t[n] <= '9' do n += 1
	number, _ = strconv.parse_int(t[:n])
	if n + 1 <= len(t) do return strings.trim_space(t[n + 1:]), true, number
	return "", true, number
}

@(private="file")
mdItoa :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10))
}

/*
Parses a line of inline Markdown into spans (in the current allocator).

Returns:
- The spans, in order; adjacent text of one style is one span
*/
Markdown_Inline :: proc(text: string) -> []MdSpan {
	out := make([dynamic]MdSpan)
	mdInline(text, &out, false, false, "")
	return out[:]
}

@(private="file")
mdInline :: proc(text: string, out: ^[dynamic]MdSpan, boldIn, italicIn: bool, link: string) {
	bold, italic := boldIn, italicIn
	b := strings.builder_make()
	flush :: proc(b: ^strings.Builder, out: ^[dynamic]MdSpan, bold, italic: bool, link: string) {
		if strings.builder_len(b^) == 0 do return
		append(out, MdSpan{text = strings.clone(strings.to_string(b^)), bold = bold, italic = italic, link = link})
		strings.builder_reset(b)
	}
	isWord :: proc(c: u8) -> bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c >= 0x80 }
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == '\\' && i + 1 < len(text) && strings.index_byte("\\`*_{}[]()#+-.!|<>~\"'", text[i + 1]) >= 0:
			strings.write_byte(&b, text[i + 1])
			i += 2
			continue
		case c == '`':
			n := 0
			for i + n < len(text) && text[i + n] == '`' do n += 1
			ticks := text[i:i + n]
			if end := strings.index(text[i + n:], ticks); end >= 0 {
				code := text[i + n:i + n + end]
				if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' && strings.trim_space(code) != "" do code = code[1:len(code) - 1]
				flush(&b, out, bold, italic, link)
				append(out, MdSpan{text = strings.clone(code), code = true, bold = bold, italic = italic, link = link})
				i += n + end + n
				continue
			}
			strings.write_string(&b, ticks)
			i += n
			continue
		case c == '!' && i + 1 < len(text) && text[i + 1] == '[':
			if label, target, next, ok := mdLinkAt(text, i + 1); ok {
				flush(&b, out, bold, italic, link)
				append(out, MdSpan{text = strings.clone(label), link = strings.clone(target), image = true})
				i = next
				continue
			}
		case c == '[' && link == "":
			if label, target, next, ok := mdLinkAt(text, i); ok {
				flush(&b, out, bold, italic, link)
				mdInline(label, out, bold, italic, strings.clone(target))
				i = next
				continue
			}
		case c == '<' && link == "":
			if end := strings.index_byte(text[i:], '>'); end > 0 {
				inner := text[i + 1:i + end]
				if (strings.has_prefix(inner, "http://") || strings.has_prefix(inner, "https://")) && strings.index_byte(inner, ' ') < 0 {
					flush(&b, out, bold, italic, link)
					append(out, MdSpan{text = strings.clone(inner), link = strings.clone(inner), bold = bold, italic = italic})
					i += end + 1
					continue
				}
			}
		case c == '&':
			entities := [?][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&amp;", "&"}, {"&quot;", "\""}, {"&nbsp;", " "}, {"&#39;", "'"}}
			found := false
			for en in entities do if strings.has_prefix(text[i:], en[0]) {
				strings.write_string(&b, en[1])
				i += len(en[0])
				found = true
				break
			}
			if found do continue
		case c == '*' || c == '_':
			n := 1
			if i + 1 < len(text) && text[i + 1] == c do n = 2
			if n == 2 && i + 2 < len(text) && text[i + 2] == c do n = 2
			prev: u8 = i > 0 ? text[i - 1] : ' '
			next: u8 = i + n < len(text) ? text[i + n] : ' '
			// `_` inside a word (snake_case) is a letter
			if c == '_' && isWord(prev) && isWord(next) do break
			closing := n == 2 ? bold : italic
			if closing {
				if prev != ' ' {
					flush(&b, out, bold, italic, link)
					if n == 2 do bold = false
					else do italic = false
					i += n
					continue
				}
			} else if next != ' ' && next != '\t' && strings.index(text[i + n:], text[i:i + n]) > 0 {
				flush(&b, out, bold, italic, link)
				if n == 2 do bold = true
				else do italic = true
				i += n
				continue
			}
		}
		strings.write_byte(&b, c)
		i += 1
	}
	flush(&b, out, bold, italic, link)
}

// A `[label](target)` at `at` (its `[`): the label, the target (a title after it dropped) and
// where the text goes on
@(private="file")
mdLinkAt :: proc(text: string, at: int) -> (label, target: string, next: int, ok: bool) {
	depth := 0
	close := -1
	inCode := false
	loop: for i := at; i < len(text); i += 1 {
		switch text[i] {
		case '\\': i += 1
		case '`': inCode = !inCode
		case '[': if !inCode do depth += 1
		case ']':
			if inCode do continue
			depth -= 1
			if depth == 0 {
				close = i
				break loop
			}
		}
	}
	if close < 0 || close + 1 >= len(text) || text[close + 1] != '(' do return
	end := strings.index_byte(text[close + 2:], ')')
	if end < 0 do return
	inside := strings.trim_space(text[close + 2:close + 2 + end])
	if strings.has_prefix(inside, "<") {
		if gt := strings.index_byte(inside, '>'); gt > 0 do inside = inside[1:gt]
	} else if sp := strings.index_any(inside, " \t"); sp >= 0 {
		inside = inside[:sp]
	}
	return text[at + 1:close], inside, close + 2 + end + 1, true
}

// The spans' text joined (temp allocated)
MdSpans_Plain :: proc(spans: []MdSpan, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for s in spans do strings.write_string(&b, s.text)
	return strings.to_string(b)
}

/*
A heading's anchor as Starlight makes it (github-slugger): lower-cased, every character but
letters, digits, spaces, `-` and `_` dropped, spaces turned into dashes ("Layers: who collides"
is "layers-who-collides").

Returns:
- The anchor (in the current allocator)
*/
Markdown_Slug :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in strings.trim_space(text) {
		switch {
		case r == ' ':
			strings.write_byte(&b, '-')
		case r == '-' || r == '_' || unicode.is_letter(r) || unicode.is_digit(r):
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	return strings.to_string(b)
}

// The document's text without markup, for search: its blocks' text, one block per line (temp)
MdDoc_PlainText :: proc(doc: ^MdDoc, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for blk in doc.blocks {
		switch blk.kind {
		case .Paragraph, .Heading, .Quote:
			for s in blk.spans do strings.write_string(&b, s.text)
		case .List:
			for item in blk.items {
				for s in item.spans do strings.write_string(&b, s.text)
				strings.write_byte(&b, ' ')
			}
		case .Table:
			for row in blk.rows do for cell in row {
				for s in cell do strings.write_string(&b, s.text)
				strings.write_byte(&b, ' ')
			}
		case .Code:
			strings.write_string(&b, blk.code)
		case .Rule:
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Whether a byte offset of a string sits on a character's start (search snippets cut there)
@(private)
md_runeStart :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	for j > 0 && j < len(s) && !utf8.rune_start(s[j]) do j -= 1
	return j
}
