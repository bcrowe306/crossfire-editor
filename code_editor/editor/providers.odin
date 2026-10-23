// Providers: what a host adds to the editor beyond the language server. A host registers
// procedures in a `Provider_Registry` and points its editors at it (`editor_set_providers`);
// the editor calls them with the document, a position and a context, and merges what they
// return with OLS's answers:
//
//   completion    items merged into the completion list (ranked, duplicates folded)
//   hover         content blocks shown with the server's hover (text, an image, a host widget)
//   diagnostics   problems merged with the server's (squiggles, gutter, Problems panel)
//   gutter        markers in the gutter (an icon, a tooltip, a click callback)
//   inlay hints   notes drawn after a line's text
//   drops         a host's drop on the code: the editor works out where it landed (the
//                 syntactic context, `editor_syntax_context_at`) and the provider says what
//                 to insert
//
// The editor stays independent of any host: providers are plain procedures with a user data
// pointer. They run on the editor's thread, inside `editor_update` / event handling, so they
// must be fast and never block (look things up in data the host already has; do slow work on
// the host's own worker and call `editor_invalidate_providers` when it's done). Completion and
// hover providers run when the user asks (typing, resting the pointer); diagnostics, gutter and
// inlay providers run once per text version, after the text has been still for
// PROVIDER_DEBOUNCE, and again when the host invalidates them. The time each call took is kept
// (`editor_provider_stats`) so a slow provider shows up.
//
// What a provider returns may be allocated with `ctx.allocator` (the frame's temp allocator):
// the editor copies what it keeps.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "base:runtime"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// How long the text must be still before diagnostics, gutter and inlay providers run again
PROVIDER_DEBOUNCE :: 250 * time.Millisecond

// The document a provider is asked about. `buffer` is the editor's: read it, don't change it
Provider_Document :: struct {
	// The file's path ("" for an untitled buffer)
	path:    string,
	buffer:  ^buf.Buffer,
	// The buffer's version (it changes with every edit)
	version: int,
}

// Why a provider is called
Provider_Trigger :: enum {
	// The user asked (Ctrl+Space, resting the pointer, a drop)
	Invoked,
	// A typed character opened it (completion: `ctx.trigger_char`)
	Typed,
	// The text changed, or the host invalidated the provider
	Refresh,
}

// What a provider is told besides the document and position
Provider_Context :: struct {
	trigger:      Provider_Trigger,
	// Completion: the character that opened the list ('.', or 0)
	trigger_char: u8,
	// Completion: the part of the word before the position
	prefix:       string,
	// Where the position is in the code (completion, hover and drops; temp allocated)
	syntax:       Syntax_Context,
	// The pointer the provider was registered with
	user_data:    rawptr,
	// For what the provider returns (the frame's temp allocator: the editor copies what it keeps)
	allocator:    runtime.Allocator,
}

// A completion item a provider offers
Provider_Completion :: struct {
	label:         string,
	// Shown beside the label (a type, what it is)
	detail:        string,
	documentation: string,
	doc_markdown:  bool,
	// Inserted on accept ("" = the label); a snippet when is_snippet ($1, ${1:x}, $0)
	insert_text:   string,
	is_snippet:    bool,
	// Matched against the typed prefix ("" = the label)
	filter_text:   string,
	// The LSP CompletionItemKind (6 variable, 21 constant, 3 function...; 0 none)
	kind:          int,
	// Ranking: among items that match the typed prefix as well, higher comes first (the
	// server's items are 0)
	priority:      int,
}

// Hover content: blocks drawn in order
Hover_Content :: struct {
	blocks: [dynamic]Hover_Block,
}

// One part of a hover
Hover_Block :: union {
	Hover_Text,
	Hover_Image,
	Hover_Widget,
}

// Text, plain or markdown (code fences are highlighted)
Hover_Text :: struct {
	text:     string,
	markdown: bool,
}

// A picture: RGBA8 pixels, `width` x `height`, drawn at most HOVER_IMAGE_MAX pixels on a side
Hover_Image :: struct {
	pixels:        []u8,
	width, height: int,
}

// Space the host draws into: `draw` is called with the editor's renderer and the block's rect
// whenever the hover is drawn. `data` must stay valid while the hover shows
Hover_Widget :: struct {
	width, height: f32,
	draw:          proc(renderer: ^sdl.Renderer, rect: sdl.FRect, data: rawptr),
	data:          rawptr,
}

// The largest side a hover image is drawn at (pixels; larger ones are scaled down)
HOVER_IMAGE_MAX :: 160

// A problem a provider finds (buffer positions; `end` exclusive)
Provider_Diagnostic :: struct {
	start, end: buf.Position,
	severity:   Diagnostic_Severity,
	message:    string,
	// Who says so ("crossfire"); shown in the tooltip and the Problems panel
	source:     string,
}

// The shapes a gutter marker can have
Gutter_Icon :: enum {
	Dot,
	Ring,
	Diamond,
	Triangle,
	Bar,
}

// A mark in the gutter beside a line
Gutter_Marker :: struct {
	line:    int,
	icon:    Gutter_Icon,
	// Zero: the theme's info color
	color:   sdl.Color,
	// Shown when the pointer rests on it
	tooltip: string,
	// The host's own number, given back to the click callback
	id:      int,
}

// What kind of note an inlay hint is (its color)
Inlay_Kind :: enum {
	Note,
	Type,
	Parameter,
	Value,
}

// A note drawn after a line's text (inline placement that moves the text is for later)
Inlay_Hint :: struct {
	pos:   buf.Position,
	label: string,
	kind:  Inlay_Kind,
}

// What a host drops on the code (its own meaning: `kind` and `value` say what it is, `data`
// is anything else the drop provider needs)
Drop_Request :: struct {
	kind:  string,
	value: string,
	data:  rawptr,
}

// An edit a drop provider asks for (buffer positions in the text as it is)
Text_Edit :: struct {
	start, end: buf.Position,
	text:       string,
}

// What a drop provider decides
Drop_Result :: struct {
	edits:   [dynamic]Text_Edit,
	// Where the caret goes after the edits (in the edited text); unset: after the last edit
	caret:   Maybe(buf.Position),
	// A sentence for the host's log ("Added sprite to Hero")
	message: string,
}

Completion_Provider_Proc :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]Provider_Completion)
Hover_Provider_Proc      :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Hover_Content)
Diagnostic_Provider_Proc :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Provider_Diagnostic)
Gutter_Provider_Proc     :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Gutter_Marker)
Gutter_Click_Proc        :: proc(doc: Provider_Document, marker: Gutter_Marker, user_data: rawptr)
Inlay_Provider_Proc      :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Inlay_Hint)
// Returns whether it handled the drop (else the next drop provider is asked)
Drop_Provider_Proc       :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, drop: Drop_Request, out: ^Drop_Result) -> bool

Provider_Kind :: enum {
	Completion,
	Hover,
	Diagnostics,
	Gutter,
	Inlay,
	Drop,
}

// One registered provider
Provider :: struct {
	kind:       Provider_Kind,
	name:       string,
	user_data:  rawptr,
	completion: Completion_Provider_Proc,
	hover:      Hover_Provider_Proc,
	diagnostic: Diagnostic_Provider_Proc,
	gutter:     Gutter_Provider_Proc,
	on_click:   Gutter_Click_Proc,
	inlay:      Inlay_Provider_Proc,
	drop:       Drop_Provider_Proc,
	// Timing: calls, the last and the slowest call
	calls:      int,
	last, worst: time.Duration,
}

/*
The providers a host registers, shared by its editors (`editor_set_providers`). The host owns
it: it must outlive the editors pointing at it.
*/
Provider_Registry :: struct {
	providers: [dynamic]Provider,
	// Bumped by provider_registry_invalidate: editors re-run their cached providers
	generation: int,
}

// Frees a registry's list (the providers' user data is the host's)
provider_registry_destroy :: proc(reg: ^Provider_Registry) {
	for p in reg.providers do delete(p.name)
	delete(reg.providers)
	reg.providers = nil
}

/*
Registers a provider (one of the procedure fields of `Provider` set, its kind set to match).

Example:
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Completion, name = "project", completion = my_completions})
*/
provider_register :: proc(reg: ^Provider_Registry, p: Provider) {
	p := p
	p.name = strings.clone(p.name)
	p.calls, p.last, p.worst = 0, 0, 0
	append(&reg.providers, p)
	reg.generation += 1
}

// Tells every editor using the registry that its providers' answers may have changed (the
// host's data changed): diagnostics, gutter markers and inlay hints are asked again
provider_registry_invalidate :: proc(reg: ^Provider_Registry) {
	reg.generation += 1
}

// Points an editor at a registry (nil: no providers)
editor_set_providers :: proc(ed: ^Editor, reg: ^Provider_Registry) {
	ed.providers = reg
	ed.provided.generation = -1
}

// Asks this editor's diagnostics, gutter and inlay providers again on its next update
editor_invalidate_providers :: proc(ed: ^Editor) {
	ed.provided.generation = -1
}

// Whether the editor has a provider of that kind
editor_has_provider :: proc(ed: ^Editor, kind: Provider_Kind) -> bool {
	if ed.providers == nil do return false
	for p in ed.providers.providers do if p.kind == kind do return true
	return false
}

// A provider's timing: how often it ran, its last and its slowest call
Provider_Stat :: struct {
	name:        string,
	kind:        Provider_Kind,
	calls:       int,
	last, worst: time.Duration,
}

// The registry's providers and their timings (temp allocated)
editor_provider_stats :: proc(ed: ^Editor) -> []Provider_Stat {
	if ed.providers == nil do return nil
	out := make([]Provider_Stat, len(ed.providers.providers), context.temp_allocator)
	for p, i in ed.providers.providers do out[i] = {p.name, p.kind, p.calls, p.last, p.worst}
	return out
}

// The editor's document, for providers
editor_provider_document :: proc(ed: ^Editor) -> Provider_Document {
	return {path = ed.buf.file_path, buffer = &ed.buf, version = ed.buf.version}
}

// What the editor keeps of its cached providers' answers (owned), moved with every edit
Provided :: struct {
	diagnostics: [dynamic]Provider_Diagnostic,
	markers:     [dynamic]Gutter_Marker,
	inlays:      [dynamic]Inlay_Hint,
	// The buffer version and registry generation they were asked at (-1: never), and when the
	// text last changed (the debounce)
	version:     int,
	generation:  int,
	changed_at:  time.Tick,
	seen_version: int,
	// Bumped whenever the diagnostics change (the overlay rebuilds) or anything changes (renders)
	diag_seq:    int,
	seq:         int,
	// The hover's provided blocks (owned), for the hover in Hover_Info
	hover:       [dynamic]Hover_Block,
}

@(private)
provided_clear_diagnostics :: proc(p: ^Provided) {
	for d in p.diagnostics {
		delete(d.message)
		delete(d.source)
	}
	clear(&p.diagnostics)
}

@(private)
provided_clear_markers :: proc(p: ^Provided) {
	for m in p.markers do delete(m.tooltip)
	clear(&p.markers)
}

@(private)
provided_clear_inlays :: proc(p: ^Provided) {
	for h in p.inlays do delete(h.label)
	clear(&p.inlays)
}

@(private)
provided_clear_hover :: proc(p: ^Provided) {
	hover_blocks_free(&p.hover)
}

@(private)
hover_blocks_free :: proc(blocks: ^[dynamic]Hover_Block) {
	for b in blocks {
		switch v in b {
		case Hover_Text:   delete(v.text)
		case Hover_Image:  delete(v.pixels)
		case Hover_Widget:
		}
	}
	clear(blocks)
}

@(private)
provided_destroy :: proc(p: ^Provided) {
	provided_clear_diagnostics(p)
	provided_clear_markers(p)
	provided_clear_inlays(p)
	provided_clear_hover(p)
	delete(p.diagnostics)
	delete(p.markers)
	delete(p.inlays)
	delete(p.hover)
}

// Moves what providers said with an edit (from editor_consume_buffer_changes)
@(private)
provided_shift :: proc(p: ^Provided, ch: buf.Change) {
	for &d in p.diagnostics {
		d.start = buf.position_after_change(d.start, ch)
		d.end = buf.position_after_change(d.end, ch)
	}
	for &m in p.markers do m.line = buf.position_after_change({m.line, 0}, ch).line
	for &h in p.inlays do h.pos = buf.position_after_change(h.pos, ch)
}

// Runs a provider call and records its time
@(private)
provider_timed :: proc(p: ^Provider, start: time.Tick) {
	d := time.tick_since(start)
	p.calls += 1
	p.last = d
	p.worst = max(p.worst, d)
}

@(private)
provider_context :: proc(p: ^Provider, trigger: Provider_Trigger) -> Provider_Context {
	return {trigger = trigger, user_data = p.user_data, allocator = context.temp_allocator}
}

/*
Runs the diagnostics, gutter and inlay providers when the text changed and has been still for
PROVIDER_DEBOUNCE, or the registry or editor was invalidated. Called from editor_update.
*/
editor_update_providers :: proc(ed: ^Editor) {
	if ed.providers == nil do return
	p := &ed.provided
	if ed.buf.version != p.seen_version {
		p.seen_version = ed.buf.version
		p.changed_at = time.tick_now()
	}
	generation_changed := p.generation != ed.providers.generation
	if !generation_changed && p.version == ed.buf.version do return
	if !generation_changed && time.tick_since(p.changed_at) < PROVIDER_DEBOUNCE do return
	editor_run_cached_providers(ed)
}

/*
Runs the diagnostics, gutter and inlay providers now (editor_update_providers does it after the
debounce; tests and hosts that just changed their data can call this).
*/
editor_run_cached_providers :: proc(ed: ^Editor) {
	if ed.providers == nil do return
	editor_consume_buffer_changes(ed)
	p := &ed.provided
	p.version = ed.buf.version
	p.generation = ed.providers.generation
	doc := editor_provider_document(ed)

	diags := make([dynamic]Provider_Diagnostic, context.temp_allocator)
	markers := make([dynamic]Gutter_Marker, context.temp_allocator)
	inlays := make([dynamic]Inlay_Hint, context.temp_allocator)
	for &prov in ed.providers.providers {
		start := time.tick_now()
		ctx := provider_context(&prov, .Refresh)
		switch prov.kind {
		case .Diagnostics: if prov.diagnostic != nil { prov.diagnostic(doc, ctx, &diags); provider_timed(&prov, start) }
		case .Gutter:      if prov.gutter != nil { prov.gutter(doc, ctx, &markers); provider_timed(&prov, start) }
		case .Inlay:       if prov.inlay != nil { prov.inlay(doc, ctx, &inlays); provider_timed(&prov, start) }
		case .Completion, .Hover, .Drop:
		}
	}
	count := buf.buffer_line_count(&ed.buf)
	clamp_pos :: proc(b: ^buf.Buffer, pos: buf.Position) -> buf.Position { return buf.buffer_clamp_position(b, pos) }

	// Diagnostics: only a change rebuilds the overlay (it keeps the server's shifted positions)
	same := len(diags) == len(p.diagnostics)
	for i in 0 ..< len(diags) {
		if !same do break
		d, old := diags[i], p.diagnostics[i]
		same = d.start == old.start && d.end == old.end && d.severity == old.severity && d.message == old.message && d.source == old.source
	}
	if !same {
		provided_clear_diagnostics(p)
		for d in diags {
			if d.start.line < 0 || d.start.line >= count do continue
			start, end := clamp_pos(&ed.buf, d.start), clamp_pos(&ed.buf, d.end)
			if buf.position_less(end, start) do start, end = end, start
			sev := d.severity == {} ? Diagnostic_Severity.Warning : d.severity
			append(&p.diagnostics, Provider_Diagnostic{start, end, sev, strings.clone(d.message), strings.clone(d.source)})
		}
		p.diag_seq += 1
	}
	provided_clear_markers(p)
	for m in markers {
		if m.line < 0 || m.line >= count do continue
		mm := m
		mm.tooltip = strings.clone(m.tooltip)
		append(&p.markers, mm)
	}
	slice.stable_sort_by(p.markers[:], proc(a, b: Gutter_Marker) -> bool { return a.line < b.line })
	provided_clear_inlays(p)
	for h in inlays {
		if h.pos.line < 0 || h.pos.line >= count || len(h.label) == 0 do continue
		hh := h
		hh.label = strings.clone(h.label)
		append(&p.inlays, hh)
	}
	slice.stable_sort_by(p.inlays[:], proc(a, b: Inlay_Hint) -> bool { return buf.position_less(a.pos, b.pos) })
	p.seq += 1
}

// The gutter markers on a line (a slice of the editor's list)
editor_gutter_markers_on :: proc(ed: ^Editor, line: int) -> []Gutter_Marker {
	list := ed.provided.markers[:]
	first := -1
	for m, i in list {
		if m.line == line && first < 0 do first = i
		if m.line > line do return first < 0 ? nil : list[first:i]
	}
	return first < 0 ? nil : list[first:]
}

// The inlay hints on a line (a slice of the editor's list)
editor_inlays_on :: proc(ed: ^Editor, line: int) -> []Inlay_Hint {
	list := ed.provided.inlays[:]
	first := -1
	for h, i in list {
		if h.pos.line == line && first < 0 do first = i
		if h.pos.line > line do return first < 0 ? nil : list[first:i]
	}
	return first < 0 ? nil : list[first:]
}

// Calls the click callback of the first marker on `line` that has one (a gutter click)
@(private)
editor_click_gutter_marker :: proc(ed: ^Editor, line: int) -> bool {
	if ed.providers == nil do return false
	for m in editor_gutter_markers_on(ed, line) {
		for &prov in ed.providers.providers {
			if prov.kind != .Gutter || prov.on_click == nil do continue
			start := time.tick_now()
			prov.on_click(editor_provider_document(ed), m, prov.user_data)
			provider_timed(&prov, start)
			return true
		}
	}
	return false
}

// --- completion ----------------------------------------------------------------

// One row of the merged completion list
Completion_Entry :: struct {
	// Server items share the client's strings; provider items own theirs
	item:     lspc.CompletionItem,
	// It came from a provider (owned), or a provider folded into the server's item
	provided: bool,
	owned:    bool,
	// A server item whose documentation a provider extended (that string is owned)
	owned_doc: bool,
	priority: int,
}

// Asks the completion providers at the caret (their items are kept until the next request)
@(private)
editor_query_completion_providers :: proc(ed: ^Editor, pos: buf.Position, prefix: string, trigger: Provider_Trigger, trigger_char: u8) {
	cs := &ed.completion
	provided_completions_free(&cs.provided)
	if ed.providers == nil do return
	doc := editor_provider_document(ed)
	syntax := editor_syntax_context_at(ed, pos, context.temp_allocator)
	out := make([dynamic]Provider_Completion, context.temp_allocator)
	for &prov in ed.providers.providers {
		if prov.kind != .Completion || prov.completion == nil do continue
		ctx := provider_context(&prov, trigger)
		ctx.trigger_char = trigger_char
		ctx.prefix = prefix
		ctx.syntax = syntax
		start := time.tick_now()
		prov.completion(doc, pos, ctx, &out)
		provider_timed(&prov, start)
	}
	for c in out {
		if len(c.label) == 0 do continue
		append(&cs.provided, Provider_Completion{
			label = strings.clone(c.label), detail = strings.clone(c.detail),
			documentation = strings.clone(c.documentation), doc_markdown = c.doc_markdown,
			insert_text = strings.clone(c.insert_text), is_snippet = c.is_snippet,
			filter_text = strings.clone(c.filter_text), kind = c.kind, priority = c.priority,
		})
	}
}

@(private)
provided_completions_free :: proc(list: ^[dynamic]Provider_Completion) {
	for c in list {
		delete(c.label)
		delete(c.detail)
		delete(c.documentation)
		delete(c.insert_text)
		delete(c.filter_text)
	}
	clear(list)
}

@(private)
completion_entries_free :: proc(entries: ^[dynamic]Completion_Entry) {
	for en in entries {
		if en.owned_doc do delete(en.item.documentation)
		if !en.owned do continue
		delete(en.item.label)
		delete(en.item.detail)
		delete(en.item.documentation)
		delete(en.item.insert_text)
		delete(en.item.filter_text)
	}
	clear(entries)
}

/*
Builds the completion list from the server's last items and the providers': the server's in
its order, then the providers' that aren't already there. A provider item with the label of a
server item folds into it (the server's insert text and detail stay; the provider's documentation is
added and its priority taken), and the first provider to offer a label wins over later ones.
*/
@(private)
editor_merge_completions :: proc(ed: ^Editor) {
	cs := &ed.completion
	completion_entries_free(&cs.items)
	cs.items_seq += 1
	// Labels already listed (the first item with each)
	listed := make(map[string]int, allocator = context.temp_allocator)
	if ed.lsp_enabled {
		for item in ed.lsp.last_completion {
			if item.label not_in listed do listed[item.label] = len(cs.items)
			append(&cs.items, Completion_Entry{item = item})
		}
	}
	for c in cs.provided {
		folded := false
		if at, ok := listed[c.label]; ok {
			en := &cs.items[at]
			folded = true
			if en.owned do continue // an earlier provider had it
			en.provided = true
			en.priority = max(en.priority, c.priority)
			if len(c.documentation) > 0 {
				doc := len(en.item.documentation) > 0 ? strings.concatenate({en.item.documentation, "\n\n", c.documentation}) : strings.clone(c.documentation)
				// Owned now: freed with the list (the label and the rest stay the server's)
				if en.owned_doc do delete(en.item.documentation)
				en.item.documentation = doc
				en.owned_doc = true
				en.item.doc_markdown ||= c.doc_markdown
			}
		}
		if folded do continue
		listed[c.label] = len(cs.items)
		append(&cs.items, Completion_Entry{
			item = lspc.CompletionItem{
				label = strings.clone(c.label), kind = c.kind, detail = strings.clone(c.detail),
				insert_text = strings.clone(c.insert_text), filter_text = strings.clone(c.filter_text),
				is_snippet = c.is_snippet, documentation = strings.clone(c.documentation), doc_markdown = c.doc_markdown,
			},
			provided = true,
			owned = true,
			priority = c.priority,
		})
	}
}

// The merged list's item at an index of `ed.completion.items` (what `filtered` holds)
editor_completion_item :: proc(ed: ^Editor, index: int) -> lspc.CompletionItem {
	return ed.completion.items[index].item
}

// Whether the completion list's item came from (or was added to by) a provider
editor_completion_item_provided :: proc(ed: ^Editor, index: int) -> bool {
	return ed.completion.items[index].provided
}

// Whether completion can open: a language server is ready, or a provider offers items
editor_completion_available :: proc(ed: ^Editor) -> bool {
	return editor_lsp_ready(ed) || editor_has_provider(ed, .Completion)
}

// --- hover ------------------------------------------------------------------

// Asks the hover providers about a position (their blocks go in ed.provided.hover)
@(private)
editor_query_hover_providers :: proc(ed: ^Editor, pos: buf.Position, line_only: bool) {
	p := &ed.provided
	provided_clear_hover(p)
	if ed.providers == nil do return
	// A gutter marker's tooltip is the hover for its line
	if line_only {
		for m in editor_gutter_markers_on(ed, pos.line) {
			if len(m.tooltip) > 0 do append(&p.hover, Hover_Block(Hover_Text{text = strings.clone(m.tooltip)}))
		}
		return
	}
	doc := editor_provider_document(ed)
	syntax := editor_syntax_context_at(ed, pos, context.temp_allocator)
	for &prov in ed.providers.providers {
		if prov.kind != .Hover || prov.hover == nil do continue
		content := Hover_Content{blocks = make([dynamic]Hover_Block, context.temp_allocator)}
		ctx := provider_context(&prov, .Invoked)
		ctx.syntax = syntax
		start := time.tick_now()
		prov.hover(doc, pos, ctx, &content)
		provider_timed(&prov, start)
		for b in content.blocks {
			switch v in b {
			case Hover_Text:
				if len(strings.trim_space(v.text)) > 0 do append(&p.hover, Hover_Block(Hover_Text{strings.clone(v.text), v.markdown}))
			case Hover_Image:
				if v.width > 0 && v.height > 0 && len(v.pixels) >= v.width * v.height * 4 {
					append(&p.hover, Hover_Block(Hover_Image{slice.clone(v.pixels[:v.width * v.height * 4]), v.width, v.height}))
				}
			case Hover_Widget:
				if v.draw != nil && v.width > 0 && v.height > 0 do append(&p.hover, Hover_Block(v))
			}
		}
	}
}

// The providers' hover blocks being shown (the editor's)
editor_hover_blocks :: proc(ed: ^Editor) -> []Hover_Block {
	return ed.provided.hover[:]
}

// --- drops --------------------------------------------------------------------

/*
A host's drop at a point of the editor (window pixels, as mouse events): the position under it
and its syntactic context go to the drop providers, the first that takes it says what to insert,
and the edits are applied as one undo step.

Returns:
- The provider's message ("" when none), and whether one took the drop
*/
editor_drop :: proc(ed: ^Editor, x, y: f32, drop: Drop_Request) -> (message: string, handled: bool) {
	return editor_drop_at(ed, editor_screen_to_position(ed, x, y), drop)
}

// A drop at a buffer position (editor_drop's work; tests call it directly)
editor_drop_at :: proc(ed: ^Editor, pos: buf.Position, drop: Drop_Request) -> (message: string, handled: bool) {
	if ed.providers == nil do return "", false
	editor_consume_buffer_changes(ed)
	pos := buf.buffer_clamp_position(&ed.buf, pos)
	doc := editor_provider_document(ed)
	syntax := editor_syntax_context_at(ed, pos, context.temp_allocator)
	for &prov in ed.providers.providers {
		if prov.kind != .Drop || prov.drop == nil do continue
		result := Drop_Result{edits = make([dynamic]Text_Edit, context.temp_allocator)}
		ctx := provider_context(&prov, .Invoked)
		ctx.syntax = syntax
		start := time.tick_now()
		took := prov.drop(doc, pos, ctx, drop, &result)
		provider_timed(&prov, start)
		if !took do continue
		editor_apply_edits(ed, result.edits[:], result.caret)
		return result.message, true
	}
	return "", false
}

/*
Applies edits (positions in the text as it is now; they mustn't overlap) as one undo step, last
first so earlier positions stay right, and tells the language server.

Inputs:
- caret: Where the caret goes, in the edited text (unset: after the last edit)
*/
editor_apply_edits :: proc(ed: ^Editor, edits: []Text_Edit, caret: Maybe(buf.Position) = nil) {
	if len(edits) == 0 do return
	sorted := slice.clone(edits, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Text_Edit) -> bool { return buf.position_less(b.start, a.start) })
	b := &ed.buf
	group := buf.buffer_next_group(b)
	end_of_last: buf.Position
	for e, i in sorted {
		start := buf.buffer_clamp_position(b, e.start)
		end := buf.buffer_clamp_position(b, e.end)
		if buf.position_less(end, start) do start, end = end, start
		if buf.position_less(start, end) do buf.buffer_delete_range(b, start, end, group)
		new_end := start
		if len(e.text) > 0 do new_end = buf.buffer_insert_text(b, start, e.text, group)
		// The first in the document is applied last; edits after it moved by what it changed
		if i == 0 do end_of_last = new_end
		else do end_of_last = buf.position_after_change(end_of_last, {start = start, old_end = end, new_end = new_end})
	}
	resize(&b.cursors, 1)
	at, set := caret.?
	b.cursors[0] = {pos = buf.buffer_clamp_position(b, set ? at : end_of_last)}
	editor_ensure_cursor_visible(ed)
	editor_notify_lsp_changed(ed)
}
