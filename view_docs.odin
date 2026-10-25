package crossfire_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "gui:skald"
import ce "code_editor/editor"
import syn "code_editor/syntax"

/*
The docs window: a popup over the editor showing a page of the bundled docs (docs.odin) rendered
from its Markdown (markdown.odin) with Skald's widgets.

	header    back, forward, contents (the manual's), the page's title, Open on
	          crossfireengine.io, close
	sidebar   (a wide window) the search box, then the results while there's a query, else the
	          contents: the manual's pages in reading order, the API reference's areas
	page      its title and description, then its blocks: headings, paragraphs (rich text with
	          links), lists, tables (columns sized to their text), code (Odin highlighted with
	          the code editor's tokenizer and colors, in its monospace font), quotes, rules,
	          images (the manual's folder's files)

A narrow window (a tiled one) has no sidebar: the search box sits under the header and its
results take the page's place until one is picked.

**Long pages are built in pieces:** the API's areas run to hundreds of declarations, so each
block's height is measured once per page, width and theme (`docsLayout`: the block's view built
without links and measured with `skald.view_size`), and each frame builds only the blocks in
view between two spacers. The same heights put an anchor's heading at the top
(`docsPageView`, once the scroll has laid out the page), when the address changes or is opened again (`docsScrollAgain`).

Keys: Alt+Left / Alt+Right back and forward, Ctrl+F the search box, Escape closes.
Widget keys: `docs-dialog`, `docs-back`, `docs-forward`, `docs-contents`, `docs-web`,
`docs-close`, `docs-search`, `docs-scroll` (the page), `docs-side-scroll`, `docs-entry-<i>` (the
contents), `docs-hit-<i>` (results), `docs-text-<block>-<n>` (the page's text, links in it).
*/

// The monospace font code blocks use (the code editor's, loaded once)
@(private="file")
docsMono: skald.Font
@(private="file")
docsMonoLoaded: bool

// The page's measured blocks: their tops and heights at a width (heap; one page at a time)
@(private="file")
docsLayout: struct {
	page: string,
	width: f32,
	dark: bool,
	fontSize: f32,
	tops: [dynamic]f32,
	heights: [dynamic]f32,
	total: f32,
}

// The address last scrolled to
@(private="file")
docsScrolled: string

// The widest the window gets, and the width under which it drops the sidebar
DOCS_MAX_WIDTH :: f32(1100)
DOCS_WIDE_WIDTH :: f32(720)
DOCS_SIDEBAR_WIDTH :: f32(230)

docsWindowView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	skald.prof_scope("docsWindowView")
	if !s.docs.open do return closedDialog(ctx, "docs-dialog")
	if !docsMonoLoaded && ctx.renderer != nil {
		docsMono = skald.font_load(ctx.renderer, "docs-mono", CODE_FONT)
		docsMonoLoaded = true
	}

	// Keys
	skald.shortcut(ctx, {.Left, {.Alt}}, Msg(Docs_Back{}))
	skald.shortcut(ctx, {.Right, {.Alt}}, Msg(Docs_Forward{}))
	if .F in ctx.input.keys_pressed && (ctx.input.modifiers == {.Ctrl} || ctx.input.modifiers == {.Super}) {
		skald.widget_focus(ctx, skald.hash_id("docs-search"))
		ctx.input.keys_pressed -= {.F}
	}

	win := [2]f32{1280, 720}
	if ctx.renderer != nil do win = {f32(ctx.renderer.fb_size.x), f32(ctx.renderer.fb_size.y)}
	width := clamp(win.x - 40, 300, DOCS_MAX_WIDTH)
	height := clamp(win.y - 60, 220, 900)
	return skald.dialog(ctx,
		open = s.docs.open,
		on_dismiss = proc() -> Msg { return Docs_Closed{} },
		content = docsWindowContent(s, ctx, width, height),
		id = skald.hash_id("docs-dialog"),
		width = width,
		max_width = width,
	)
}

// The window's content (inside the dialog): the header, then the sidebar and page or results
docsWindowContent :: proc(s: ^State, ctx: ^skald.Ctx(Msg), width, height: f32) -> skald.View {
	th := ctx.theme
	lib := Docs_Library()
	wide := width >= DOCS_WIDE_WIDTH
	pad := th.spacing.md
	current := Docs_Current(&s.docs)
	page := DocsLibrary_Find(lib, current)
	// Header
	iconButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, label: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		text := label == "" ? icon : fmt.tprintf("%s  %s", icon, label)
		return skald.button(ctx, text, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, th.spacing.xs}, font_size = th.font.size_sm, disabled = disabled)
	}
	title := page != nil ? page.title : "Docs"
	header := skald.row(
		iconButton(ctx, "docs-back", ICON_ARROW_LEFT, "", Msg(Docs_Back{}), disabled = s.docs.at <= 0),
		iconButton(ctx, "docs-forward", ICON_ARROW_RIGHT, "", Msg(Docs_Forward{}), disabled = s.docs.at + 1 >= len(s.docs.history)),
		iconButton(ctx, "docs-contents", ICON_HOUSE, wide ? "Contents" : "", Msg(Docs_Hit_Chosen{address = "/manual/", clear = !wide})),
		skald.flex(1, uiText(th, .Title, title, max_width = width - (wide ? 470 : 230), overflow = .Ellipsis)),
		iconButton(ctx, "docs-web", ICON_EXTERNAL, wide ? "Open on crossfireengine.io" : "Web", Msg(Docs_Open_On_Web{}), disabled = current == ""),
		iconButton(ctx, "docs-close", ICON_XMARK, "", Msg(Docs_Closed{})),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
	search := skald.text_input(ctx, s.docs.search, proc(v: string) -> Msg { return Docs_Search_Changed(v) },
		id = skald.hash_id("docs-search"), placeholder = "Search the docs", clear_button = true,
		width = wide ? DOCS_SIDEBAR_WIDTH - th.spacing.sm * 2 : width - pad * 2)

	bodyHeight := height - 72
	searching := strings.trim_space(s.docs.search) != ""
	body: skald.View
	if wide {
		side := skald.col(
			search,
			skald.scroll(ctx, {DOCS_SIDEBAR_WIDTH, bodyHeight - 44}, docsSidebar(s, ctx, lib, page, searching, DOCS_SIDEBAR_WIDTH - 12, false),
				id = skald.hash_id("docs-side-scroll"), reveal_focus = false),
			spacing = th.spacing.sm,
			width = DOCS_SIDEBAR_WIDTH,
		)
		pageWidth := width - DOCS_SIDEBAR_WIDTH - pad * 2 - 1
		body = skald.row(side, skald.divider(ctx, vertical = true), docsPageView(s, ctx, lib, page, current, pageWidth, bodyHeight),
			spacing = th.spacing.sm, height = bodyHeight)
	} else if searching {
		body = skald.col(search,
			skald.scroll(ctx, {width - pad * 2, bodyHeight - 40}, docsSidebar(s, ctx, lib, page, true, width - pad * 2 - 12, true),
				id = skald.hash_id("docs-side-scroll"), reveal_focus = false),
			spacing = th.spacing.sm)
	} else {
		body = skald.col(search, docsPageView(s, ctx, lib, page, current, width - pad * 2, bodyHeight - 40), spacing = th.spacing.sm)
	}

	return skald.col(header, skald.divider(ctx), body, spacing = th.spacing.sm, padding = pad, cross_align = .Stretch, width = width, height = height)
}

// The contents (the manual's pages, the API's areas), or the search's results
@(private="file")
docsSidebar :: proc(s: ^State, ctx: ^skald.Ctx(Msg), lib: ^DocsLibrary, page: ^DocsPage, searching: bool, width: f32, clear: bool) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	entry :: proc(ctx: ^skald.Ctx(Msg), key, text, detail: string, address: string, current, clear: bool, width: f32) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		id := skald.hash_id(key)
		bg := current ? th.color.primary : skald.widget_hovered(ctx, id) ? th.color.surface : skald.Color{}
		fg := current ? th.color.on_primary : th.color.fg
		parts := make([dynamic]skald.View, context.temp_allocator)
		append(&parts, skald.text(text, fg, th.font.size_sm, max_width = width - tk.s))
		if detail != "" do append(&parts, skald.text(detail, current ? th.color.on_primary : th.color.fg_muted, th.font.size_xs, max_width = width - tk.s))
		return skald.clickable(ctx, skald.col(..parts[:], padding = tk.xs, spacing = tk.hair, width = width, bg = bg, radius = th.radius.sm),
			Msg(Docs_Hit_Chosen{address = strings.clone(address, context.temp_allocator), clear = clear}), id = id, focusable = false)
	}
	if searching {
		hits := Docs_Search(lib, s.docs.search)
		if len(hits) == 0 do append(&rows, uiText(th, .Label, fmt.tprintf("Nothing matches '%s'.", s.docs.search), max_width = width))
		for hit, i in hits {
			p := &lib.pages[hit.page]
			address := hit.anchor != "" ? fmt.tprintf("%s#%s", p.address, hit.anchor) : p.address
			label := hit.heading != "" ? fmt.tprintf("%s  ›  %s", p.title, hit.heading) : p.title
			snippet := hit.snippet
			if len(snippet) > 160 do snippet = fmt.tprintf("%s...", snippet[:md_runeStart(snippet, 157)])
			append(&rows, entry(ctx, fmt.tprintf("docs-hit-%d", i), label, snippet, address, false, clear, width))
		}
		return skald.col(..rows[:], spacing = tk.xxs)
	}
	header :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		tk := uiTokens(ctx)
		return skald.col(uiText(ctx.theme, .Muted, text), padding = tk.xs)
	}
	append(&rows, header(ctx, "MANUAL"))
	apiStarted := false
	for &p, i in lib.pages {
		if p.api && !apiStarted {
			append(&rows, header(ctx, "ENGINE API"))
			apiStarted = true
		}
		append(&rows, entry(ctx, fmt.tprintf("docs-entry-%d", i), p.title, "", p.address, page == &p, clear, width))
	}
	if len(lib.pages) == 0 do append(&rows, uiText(th, .Label, "No docs were found beside the editor.", max_width = width))
	return skald.col(..rows[:], spacing = tk.hair)
}

// The page: its title, then its blocks (only those in view built)
@(private="file")
docsPageView :: proc(s: ^State, ctx: ^skald.Ctx(Msg), lib: ^DocsLibrary, page: ^DocsPage, current: string, width, height: f32) -> skald.View {
	th := ctx.theme
	scrollId := skald.hash_id("docs-scroll")
	contentWidth := width - 14
	if page == nil {
		missing := current == "" ? "Nothing to show." : fmt.tprintf("There's no page at %s in the docs bundled with this editor.", current)
		return skald.col(
			skald.text(missing, th.color.fg_muted, th.font.size_md, max_width = contentWidth),
			skald.button(ctx, "Manual contents", Msg(Docs_Hit_Chosen{address = "/manual/"}), id = skald.hash_id("docs-missing-contents")),
			spacing = th.spacing.md, width = width, height = height)
	}
	dark := docsDark(th.color.bg)
	pageAddress, anchor := Docs_SplitAddress(current)
	if docsLayout.page != page.address || docsLayout.width != contentWidth || docsLayout.dark != dark || docsLayout.fontSize != th.font.size_md {
		docsMeasure(ctx, lib, page, contentWidth, dark)
	}
	// Scroll to the anchor when the address changed (or was opened again)
	if current != docsScrolled || docsScrollAgain {
		if scroll, drawn := &ctx.widgets.states[scrollId]; drawn {
			top: f32 = 0
			if anchor != "" {
				for b, i in page.doc.blocks do if b.kind == .Heading && b.anchor == anchor && i + 1 < len(docsLayout.tops) {
					top = docsLayout.tops[i + 1]
					break
				}
			}
			scroll.scroll_y = max(top - 4, 0)
			// Skald clamps the offset to the content laid out last frame: until this page's was,
			// keep at it
			if abs(scroll.content_h - docsLayout.total) < 1 {
				delete(docsScrolled)
				docsScrolled = strings.clone(current)
				docsScrollAgain = false
			}
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}
	_ = pageAddress
	// The blocks in view (block 0 of the layout is the title; block i+1 the doc's block i)
	offset: f32 = 0
	if st, ok := ctx.widgets.states[scrollId]; ok do offset = st.scroll_y
	first, last := -1, -1
	MARGIN :: f32(200)
	for i in 0 ..< len(docsLayout.tops) {
		top, h := docsLayout.tops[i], docsLayout.heights[i]
		if top + h < offset - MARGIN || top > offset + height + MARGIN do continue
		if first < 0 do first = i
		last = i
	}
	parts := make([dynamic]skald.View, context.temp_allocator)
	if first >= 0 {
		append(&parts, skald.spacer(docsLayout.tops[first]))
		for i in first ..= last do append(&parts, docsBlockAt(ctx, lib, page, i, contentWidth, dark, false))
		append(&parts, skald.spacer(max(docsLayout.total - (docsLayout.tops[last] + docsLayout.heights[last]), 0)))
	}
	return skald.scroll(ctx, {width, height}, skald.col(..parts[:], width = contentWidth), id = scrollId, reveal_focus = false)
}

// Whether a background is dark (the code blocks take the code editor's dark or light colors)
@(private="file")
docsDark :: proc(c: skald.Color) -> bool {
	return c[0] * 0.3 + c[1] * 0.59 + c[2] * 0.11 < 0.5
}

// Measures every block of a page at a width (`docsLayout`)
@(private="file")
docsMeasure :: proc(ctx: ^skald.Ctx(Msg), lib: ^DocsLibrary, page: ^DocsPage, width: f32, dark: bool) {
	delete(docsLayout.page)
	docsLayout.page = strings.clone(page.address)
	docsLayout.width, docsLayout.dark, docsLayout.fontSize = width, dark, ctx.theme.font.size_md
	clear(&docsLayout.tops)
	clear(&docsLayout.heights)
	y: f32 = 0
	for i in 0 ..= len(page.doc.blocks) {
		h: f32 = 40
		if ctx.renderer != nil do h = skald.view_size(ctx.renderer, docsBlockAt(ctx, lib, page, i, width, dark, true)).y
		append(&docsLayout.tops, y)
		append(&docsLayout.heights, h)
		y += h
	}
	docsLayout.total = y
}

// A layout block: 0 the page's title, i the doc's block i-1, with its spacing below it
@(private="file")
docsBlockAt :: proc(ctx: ^skald.Ctx(Msg), lib: ^DocsLibrary, page: ^DocsPage, i: int, width: f32, dark, measure: bool) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	if i == 0 {
		where_ := page.api ? "Engine API reference" : "Manual"
		parts := make([dynamic]skald.View, context.temp_allocator)
		append(&parts, uiText(th, .Muted, where_))
		append(&parts, skald.rich_text(ctx, {skald.span_bold(page.title)}, th.color.fg, th.font.size_xl + 4, max_width = width))
		if page.description != "" do append(&parts, uiText(th, .Label, page.description, max_width = width))
		append(&parts, skald.spacer(th.spacing.md))
		return skald.col(..parts[:], spacing = tk.xs, width = width)
	}
	b := &page.doc.blocks[i - 1]
	// The manual's first heading repeats the title (the website drops it too)
	if b.kind == .Heading && b.level == 1 && strings.to_lower(b.text, context.temp_allocator) == strings.to_lower(page.title, context.temp_allocator) {
		return skald.spacer(0)
	}
	gap := th.spacing.md
	key := proc(i, n: int) -> skald.Widget_ID { return skald.hash_id(fmt.tprintf("docs-text-%d-%d", i, n)) }
	text :: proc(ctx: ^skald.Ctx(Msg), spans: []MdSpan, size, width: f32, measure: bool, id: skald.Widget_ID, base: skald.Color = {}, bold := false) -> skald.View {
		th := ctx.theme
		color := base[3] > 0 ? base : th.color.fg
		ts := docsSpans(ctx, spans, size, bold)
		if measure do return skald.rich_text(ctx, ts, color, size, max_width = width)
		return skald.rich_text_links(ctx, ts, color, proc(link: string) -> Msg { return Docs_Link_Clicked(link) }, size, max_width = width, id = id)
	}
	switch b.kind {
	case .Heading:
		size := th.font.size_md + 1
		switch b.level {
		case 1: size = th.font.size_xl + 2
		case 2: size = th.font.size_lg + 3
		case 3: size = th.font.size_md + 2
		}
		top := b.level <= 2 ? th.spacing.lg : th.spacing.md
		parts := make([dynamic]skald.View, context.temp_allocator)
		append(&parts, skald.spacer(top))
		append(&parts, text(ctx, b.spans, size, width, measure, key(i, 0), bold = true))
		if b.level == 2 do append(&parts, skald.divider(ctx))
		append(&parts, skald.spacer(th.spacing.sm))
		return skald.col(..parts[:], spacing = tk.xs, width = width, cross_align = .Stretch)
	case .Paragraph:
		if len(b.spans) == 1 && b.spans[0].image do return docsImage(ctx, lib, page, b.spans[0], width, gap)
		return skald.col(text(ctx, b.spans, th.font.size_md, width, measure, key(i, 0)), skald.spacer(gap))
	case .Quote:
		return skald.col(
			skald.row(skald.rect({3, 0}, th.color.primary), text(ctx, b.spans, th.font.size_md, width - 16, measure, key(i, 0), th.color.fg_muted), spacing = tk.m),
			skald.spacer(gap))
	case .Rule:
		return skald.col(skald.spacer(gap), skald.divider(ctx), skald.spacer(gap), width = width, cross_align = .Stretch)
	case .List:
		rows := make([dynamic]skald.View, context.temp_allocator)
		for item, n in b.items {
			indent := f32(item.depth) * 18
			marker := b.ordered ? fmt.tprintf("%d.", item.number) : item.depth > 0 ? "◦" : "•"
			markerWidth: f32 = b.ordered ? 24 : 16
			append(&rows, skald.row(
				skald.spacer(indent),
				skald.col(skald.text(marker, th.color.fg_muted, th.font.size_md), width = markerWidth),
				text(ctx, item.spans, th.font.size_md, width - indent - markerWidth, measure, key(i, n)),
			))
		}
		return skald.col(skald.col(..rows[:], spacing = tk.xs), skald.spacer(gap))
	case .Code:
		return skald.col(docsCode(ctx, b, width, dark, measure), skald.spacer(gap))
	case .Table:
		return skald.col(docsTable(ctx, b, i, width, measure), skald.spacer(gap))
	}
	return skald.spacer(0)
}

// A block's spans as Skald's: bold, italic, code (the monospace font on a chip), links
@(private="file")
docsSpans :: proc(ctx: ^skald.Ctx(Msg), spans: []MdSpan, size: f32, bold: bool) -> []skald.Text_Span {
	th := ctx.theme
	out := make([]skald.Text_Span, len(spans), context.temp_allocator)
	for s, i in spans {
		t := skald.Text_Span{str = s.text, size = size}
		if s.bold || bold do t.weight = .Bold
		t.italic = s.italic
		if s.code {
			t.font = docsMono
			t.size = size * 0.93
			t.bg = th.color.surface
		}
		if s.image {
			t.str = s.text != "" ? s.text : "image"
			t.italic = true
		}
		if s.link != "" {
			t.link = s.link
			t.underline = true
			t.color = th.color.primary
		}
		out[i] = t
	}
	return out
}

// A code block: Odin highlighted with the code editor's tokenizer and colors, line by line
@(private="file")
docsCode :: proc(ctx: ^skald.Ctx(Msg), b: ^MdBlock, width: f32, dark, measure: bool) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	theme := ce.preset_theme(dark ? .Ayu_Dark : .Ayu_Light)
	color :: proc(c: [4]u8) -> skald.Color { return {f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255, f32(c[3]) / 255} }
	size := th.font.size_sm
	lines := strings.split_lines(b.code, context.temp_allocator)
	rows := make([dynamic]skald.View, context.temp_allocator)
	odin := b.lang == "odin" || b.lang == ""
	state := syn.LINE_STATE_NORMAL
	fg := color(transmute([4]u8)theme.text_default)
	for line in lines {
		l, _ := strings.replace_all(line, "\t", "    ", context.temp_allocator)
		spans := make([dynamic]skald.Text_Span, context.temp_allocator)
		if odin {
			tokens: []syn.Token
			tokens, state = syn.tokenize_odin_line(l, state, context.temp_allocator)
			at := 0
			for tok in tokens {
				if tok.start > at do append(&spans, skald.Text_Span{str = l[at:tok.start], font = docsMono, size = size, color = fg})
				append(&spans, skald.Text_Span{str = l[tok.start:tok.end], font = docsMono, size = size, color = color(docsTokenColor(theme, tok.kind))})
				at = tok.end
			}
			if at < len(l) do append(&spans, skald.Text_Span{str = l[at:], font = docsMono, size = size, color = fg})
		} else {
			append(&spans, skald.Text_Span{str = l, font = docsMono, size = size, color = fg})
		}
		if len(spans) == 0 || l == "" do append(&spans, skald.Text_Span{str = " ", font = docsMono, size = size, color = fg})
		append(&rows, skald.rich_text(ctx, spans[:], fg, size, docsMono, max_width = width - tk.xl))
	}
	return skald.col(..rows[:], padding = tk.m, width = width, bg = color(transmute([4]u8)theme.background), radius = th.radius.sm)
}

// A token's color in a code editor theme (the code editor's own mapping, which it keeps private)
@(private="file")
docsTokenColor :: proc(theme: ce.Theme, kind: syn.TokenKind) -> [4]u8 {
	c := theme.text_default
	#partial switch kind {
	case .Keyword:     c = theme.text_keyword
	case .String:      c = theme.text_string
	case .Number:      c = theme.text_number
	case .Comment:     c = theme.text_comment
	case .Type:        c = theme.text_type
	case .Builtin:     c = theme.text_builtin
	case .Function:    c = theme.text_function
	case .Constant:    c = theme.text_constant
	case .Property:    c = theme.text_property
	case .Operator:    c = theme.text_operator
	case .Punctuation: c = theme.text_punct
	case .Directive:   c = theme.text_directive
	case .Attribute:   c = theme.text_attribute
	}
	return transmute([4]u8)c
}

// A table: columns sized to their text (shrunk to fit), the header row bold on the surface color
@(private="file")
docsTable :: proc(ctx: ^skald.Ctx(Msg), b: ^MdBlock, block: int, width: f32, measure: bool) -> skald.View {
	th := ctx.theme
	if len(b.rows) == 0 do return skald.spacer(0)
	cols := len(b.rows[0])
	CELL_PAD :: f32(6)
	natural := make([]f32, cols, context.temp_allocator)
	for row in b.rows do for cell, c in row {
		if c >= cols do break
		w: f32 = 60
		plain := MdSpans_Plain(cell, context.temp_allocator)
		if ctx.renderer != nil do w, _ = skald.measure_text(ctx.renderer, plain, th.font.size_md)
		natural[c] = max(natural[c], w + CELL_PAD * 2 + 2)
	}
	widths := make([]f32, cols, context.temp_allocator)
	total: f32 = 0
	for n in natural do total += n
	if total <= width {
		copy(widths, natural)
		widths[cols - 1] += width - total
	} else {
		// Each column its share; what narrow columns leave goes to the wide ones
		share := width / f32(cols)
		left := width
		wideTotal: f32 = 0
		for n, c in natural {
			if n <= share {
				widths[c] = n
				left -= n
			} else {
				wideTotal += n
			}
		}
		for n, c in natural do if n > share do widths[c] = max(left * n / wideTotal, 40)
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	for row, r in b.rows {
		cells := make([dynamic]skald.View, context.temp_allocator)
		for c in 0 ..< cols {
			spans := c < len(row) ? row[c] : []MdSpan{}
			ts := docsSpans(ctx, spans, th.font.size_md, r == 0)
			inner := widths[c] - CELL_PAD * 2
			v: skald.View
			if measure {
				v = skald.rich_text(ctx, ts, th.color.fg, th.font.size_md, max_width = inner)
			} else {
				v = skald.rich_text_links(ctx, ts, th.color.fg, proc(link: string) -> Msg { return Docs_Link_Clicked(link) },
					th.font.size_md, max_width = inner, id = skald.hash_id(fmt.tprintf("docs-text-%d-%d", block, r * 100 + c)))
			}
			append(&cells, skald.col(v, width = widths[c], padding = CELL_PAD))
		}
		bg := r == 0 ? th.color.surface : skald.Color{}
		append(&rows, skald.row(..cells[:], bg = bg))
		append(&rows, skald.divider(ctx))
	}
	return skald.col(..rows[:], width = width, cross_align = .Stretch)
}

// An image of the manual (its folder's file), as wide as fits; its text when there's no file
@(private="file")
docsImage :: proc(ctx: ^skald.Ctx(Msg), lib: ^DocsLibrary, page: ^DocsPage, span: MdSpan, width, gap: f32) -> skald.View {
	th := ctx.theme
	path := ""
	if !strings.contains(span.link, "://") && lib.manualDir != "" do path = joinPath(lib.manualDir, span.link, allocator = context.temp_allocator)
	if path != "" && os.exists(path) {
		if size, ok := Image_Size(path); ok && size.x > 0 {
			w := min(f32(size.x), width)
			h := w * f32(size.y) / f32(size.x)
			return skald.col(skald.image(ctx, path, width = w, height = h, fit = .Contain), skald.spacer(gap))
		}
	}
	return skald.col(uiText(th, .Label, fmt.tprintf("[%s]", span.text)), skald.spacer(gap))
}

/*
The anchor of the heading the docs page is scrolled to: the last one at or above the view's top
("" the page's start). The UI tests' `docs_at`.
*/
Docs_VisibleAnchor :: proc(ctx: ^skald.Ctx(Msg)) -> string {
	st, ok := ctx.widgets.states[skald.hash_id("docs-scroll")]
	if !ok do return ""
	page := DocsLibrary_Find(Docs_Library(), docsLayout.page)
	if page == nil do return ""
	anchor := ""
	for b, i in page.doc.blocks {
		if b.kind != .Heading || i + 1 >= len(docsLayout.tops) do continue
		if docsLayout.tops[i + 1] <= st.scroll_y + 8 do anchor = b.anchor
		else do break
	}
	return anchor
}

/*
Where a link of the docs page whose target contains `target` is drawn (last frame), inside the
page's view. The UI tests' `docs_click_link`.
*/
Docs_LinkRect :: proc(ctx: ^skald.Ctx(Msg), target: string) -> (skald.Rect, bool) {
	area, ok := ctx.widgets.states[skald.hash_id("docs-scroll")]
	if !ok do return {}, false
	view := area.last_rect
	best: skald.Rect
	found := false
	for _, st in ctx.widgets.states {
		if st.link_rects == nil || !skald.widget_drawn_last_frame(ctx.widgets, st) do continue
		for lr in st.link_rects^ {
			r := lr.rect
			if !strings.contains(lr.link, target) || r.w <= 0 do continue
			cy := r.y + r.h * 0.5
			if cy < view.y || cy > view.y + view.h || r.x < view.x || r.x > view.x + view.w do continue
			if !found || r.y < best.y {
				best = r
				found = true
			}
		}
	}
	return best, found
}
