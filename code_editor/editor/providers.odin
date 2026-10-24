// Providers: what a host adds to the editor beyond the language server. A host registers
// procedures in a `Provider_Registry` and points its editors at it (`editor_set_providers`);
// the editor calls them with the document, a position and a context, and merges what they
// return with OLS's answers:
//
//   completion    items merged into the completion list (ranked, duplicates folded)
//   hover         content blocks shown with the server's hover (text, an image, a host widget
//                 that can take clicks), or instead of it
//   diagnostics   problems merged with the server's (squiggles, gutter, Problems panel), with
//                 quick fixes (Ctrl+.'s menu, before the server's code actions)
//   gutter        markers in the gutter (an icon, a tooltip, a click callback)
//   inlay hints   notes drawn after a line's text, or color swatches (a click calls the host);
//                 a clickable hint takes a click on its label, and one with choices opens a
//                 menu of them first (a running game's nodes, say)
//   scrubbing     Alt+drag on a number the provider says can be scrubbed: the host is told the
//                 new value as it's dragged (the literal isn't edited), and at the release it
//                 may offer choices (where to write it) in a menu
//   menu items    the host's entries in the right-click menu, for the line clicked
//   gutter clicks a click in the marker column of a line without a marker (setting something
//                 on that line: a log point)
//   drops         a host's drop on the code: the editor works out where it landed (the
//                 syntactic context, `editor_syntax_context_at`) and the provider says what
//                 to insert
//   usages        the host's own uses of the symbol at the caret (Find Usages: nodes running a
//                 script, say), listed in the references panel; picking one calls the host
//   renames       renaming the symbol at the caret (F2): the provider says what it would rename
//                 and does it (its edits to this document, and whatever else it owns); without
//                 one, the language server renames
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
	// The column (bytes, on the position's line) where the text it replaces starts; unset: the
	// typed word's start (the editor's anchor). For text that isn't one word (a path, a name with
	// spaces): the list still filters by the typed word, so `filter_text` should be the part of
	// the label from that word on
	replace_start: Maybe(int),
}

// Hover content: blocks drawn in order
Hover_Content :: struct {
	blocks: [dynamic]Hover_Block,
	// The blocks say what the server would (an engine procedure's documentation): its answer
	// isn't shown under them, and isn't asked for
	replace_server: bool,
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

// A picture: RGBA8 pixels, `width` x `height`, drawn at most HOVER_IMAGE_MAX pixels tall and twice
// that wide (a strip of animation frames)
Hover_Image :: struct {
	pixels:        []u8,
	width, height: int,
}

/*
Space the host draws into: `draw` is called with the editor's renderer and the block's rect
whenever the hover is drawn. `data` must stay valid while the hover shows.

A left press on it calls `click` (when set) with the point in the block (0, 0 its top left) and
the hover stays open: a play button. The editor draws again on its next render; a host whose
drawing changes for another reason (a sound ended) calls `editor_redraw_hover`.
*/
Hover_Widget :: struct {
	width, height: f32,
	draw:          proc(renderer: ^sdl.Renderer, rect: sdl.FRect, data: rawptr),
	data:          rawptr,
	// Returns whether it used the press (else it goes to the text under the hover, as usual)
	click:         proc(x, y: f32, data: rawptr) -> bool,
}

// The tallest a hover image is drawn (pixels; larger ones are scaled down); it may be twice as wide
HOVER_IMAGE_MAX :: 160

// A problem a provider finds (buffer positions; `end` exclusive)
Provider_Diagnostic :: struct {
	start, end: buf.Position,
	severity:   Diagnostic_Severity,
	message:    string,
	// Who says so ("crossfire"); shown in the tooltip and the Problems panel
	source:     string,
	// Quick fixes, offered by the code actions menu (Ctrl+.) with the caret on the problem
	fixes:      []Provider_Fix,
}

// A quick fix for a provider's diagnostic: its edits (buffer positions in the text as it is when
// the provider runs; the editor moves them with later edits), applied as one undo step
Provider_Fix :: struct {
	title:     string,
	edits:     []Text_Edit,
	// Listed first and selected (like the server's preferred actions)
	preferred: bool,
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
	// Several things it stands for (a node each): a click opens a menu of them (the code
	// actions menu), and the click callback is told which was chosen (`choice`). One or none:
	// a click calls it at once
	choices: []string,
	// Set by the editor when it calls the click callback: the choice picked (0 without choices)
	choice:  int,
}

// What kind of note an inlay hint is (its color)
Inlay_Kind :: enum {
	Note,
	Type,
	Parameter,
	Value,
}

/*
A note drawn after a line's text (inline placement that moves the text is for later). With a
`swatch`, a square of that color is drawn before the label (a color literal's): a left click on
it calls the inlay provider's `on_inlay_click` with the hint. A `clickable` hint takes a click on
its label too (drawn with a frame); with `choices`, a click opens a menu of them first (the code
actions menu) and the callback gets the one picked in `choice`.
*/
Inlay_Hint :: struct {
	pos:    buf.Position,
	label:  string,
	kind:   Inlay_Kind,
	swatch: Maybe(sdl.Color),
	// The host's own number, given back to the click callback
	id:     int,
	// The label takes a left click (on_inlay_click)
	clickable: bool,
	// Things to pick from: a click opens a menu of them, and the callback gets `choice`
	choices: []string,
	// Set by the editor when it calls the click callback: the choice picked (0 without choices)
	choice:  int,
}

// What a host drops on the code (its own meaning: `kind` and `value` say what it is, `data`
// is anything else the drop provider needs)
Drop_Request :: struct {
	kind:  string,
	value: string,
	data:  rawptr,
	// List the provider's alternatives in a menu (with a preview of each) instead of applying
	// the plain drop (a host passes it when Shift is held at the release)
	menu:  bool,
}

// An edit a drop provider asks for (buffer positions in the text as it is)
Text_Edit :: struct {
	start, end: buf.Position,
	text:       string,
}

// What a drop provider decides
Drop_Result :: struct {
	// The plain drop: its edits, applied as one undo step
	edits:   [dynamic]Text_Edit,
	// Where the caret goes after the edits (in the edited text); unset: after the last edit
	caret:   Maybe(buf.Position),
	// A sentence for the host's log ("Added sprite to Hero")
	message: string,
	// The useful alternatives, the plain drop's first (a few: they're a menu). A drop asking for
	// the menu (`Drop_Request.menu`) lists them when there are two or more; else `edits` (or,
	// without any, the first choice) is applied
	choices: [dynamic]Drop_Choice,
}

// One way a drop can go: a menu entry with a preview of the code it writes
Drop_Choice :: struct {
	// The menu's text ("Play it")
	title:   string,
	// The code it writes, shown beside the menu (lines; tabs are fine)
	preview: string,
	edits:   []Text_Edit,
	// Where the caret goes after the edits (in the edited text); unset: after the last edit
	caret:   Maybe(buf.Position),
	// For the host's log
	message: string,
}

// One of a host's uses of a symbol (a node running a script, say): a row of the references panel
Provider_Usage :: struct {
	// Where it is ("Forest: Hero"): the row's location column
	label:   string,
	// What it says there ("speed = 250")
	preview: string,
	// The host's own number, given back to `on_open`
	id:      int,
}

// What a usages provider answers
Usages_Result :: struct {
	// The symbol, for the panel's header ("Hero")
	symbol:        string,
	items:         [dynamic]Provider_Usage,
	// Said in the status line when there are none ("No node runs Hero")
	empty_message: string,
}

// What a rename provider would rename at a position
Rename_Target :: struct {
	// The name's range in the document (the rename box opens under it)
	start, end: buf.Position,
	// The current name
	name:       string,
	// The box's title ("Rename script Hero")
	title:      string,
	// What else it changes ("Also 3 nodes in 2 scenes"), shown under the name
	note:       string,
}

// What a rename did, or why it can't
Rename_Result :: struct {
	// Edits to this document (positions in its text now), applied as one undo step
	edits:   [dynamic]Text_Edit,
	// For the status line ("Renamed Hero to Player: 3 files, 4 nodes")
	message: string,
	// Why the new name won't do ("Player is taken"): the box stays open and shows it
	error:   string,
}

Completion_Provider_Proc :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]Provider_Completion)
Hover_Provider_Proc      :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Hover_Content)
Diagnostic_Provider_Proc :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Provider_Diagnostic)
Gutter_Provider_Proc     :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Gutter_Marker)
Gutter_Click_Proc        :: proc(doc: Provider_Document, marker: Gutter_Marker, user_data: rawptr)
Inlay_Provider_Proc      :: proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Inlay_Hint)
// A click on an inlay hint's swatch, or on a clickable hint (its choice picked, with choices)
Inlay_Click_Proc         :: proc(doc: Provider_Document, hint: Inlay_Hint, user_data: rawptr)
// A click in the marker column of a line without a marker; returns whether it was taken
Gutter_Line_Proc         :: proc(doc: Provider_Document, line: int, user_data: rawptr) -> bool
// Returns whether it handled the drop (else the next drop provider is asked)
Drop_Provider_Proc       :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, drop: Drop_Request, out: ^Drop_Result) -> bool
// Returns whether the position is on a symbol the provider knows (else the next one is asked)
Usages_Provider_Proc     :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Usages_Result) -> bool
// A usage picked in the references panel (click, Enter, F4)
Usage_Open_Proc          :: proc(doc: Provider_Document, usage: Provider_Usage, user_data: rawptr)
// Returns whether the provider renames the symbol at the position (else the next one, then the server)
Rename_Prepare_Proc      :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Rename_Target) -> bool
// Renames what prepare_rename offered to `new_name`; returns false (or sets `out.error`) when it can't
Rename_Proc              :: proc(doc: Provider_Document, target: Rename_Target, new_name: string, ctx: Provider_Context, out: ^Rename_Result) -> bool

Provider_Kind :: enum {
	Completion,
	Hover,
	Diagnostics,
	Gutter,
	Inlay,
	Drop,
	Usages,
	Rename,
	// Alt+drag on a number (providers_scrub.odin)
	Scrub,
	// Entries in the right-click menu (providers_scrub.odin)
	Menu,
}

// One registered provider
Provider :: struct {
	kind:       Provider_Kind,
	name:       string,
	user_data:  rawptr,
	// Completion: characters that open the list when typed (as '.' does), asking only the
	// providers ('"', '/' for names in strings). The provider decides whether it has anything there
	trigger_chars: string,
	completion: Completion_Provider_Proc,
	hover:      Hover_Provider_Proc,
	diagnostic: Diagnostic_Provider_Proc,
	gutter:     Gutter_Provider_Proc,
	on_click:   Gutter_Click_Proc,
	inlay:      Inlay_Provider_Proc,
	on_inlay_click: Inlay_Click_Proc,
	drop:       Drop_Provider_Proc,
	usages:     Usages_Provider_Proc,
	on_open:    Usage_Open_Proc,
	prepare_rename: Rename_Prepare_Proc,
	rename:     Rename_Proc,
	// Gutter providers: a click in the marker column of a line without a marker
	on_gutter_line: Gutter_Line_Proc,
	// Scrubbing (providers_scrub.odin): what can be scrubbed at a position, the drag's values and
	// its end (choices to offer), the choice picked
	scrub_target:    Scrub_Target_Proc,
	on_scrub:        Scrub_Proc,
	on_scrub_choice: Scrub_Choice_Proc,
	// The right-click menu's entries for a position, and one picked
	menu_items:   Menu_Items_Proc,
	on_menu_item: Menu_Item_Proc,
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
	for p in reg.providers {
		delete(p.name)
		delete(p.trigger_chars)
	}
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
	p.trigger_chars = strings.clone(p.trigger_chars)
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
	// The hover's provided blocks (owned), for the hover in Hover_Info, and whether they replace
	// the server's answer
	hover:       [dynamic]Hover_Block,
	hover_replaces_server: bool,
	// Each inlay hint's provider (an index of the registry's providers, parallel to `inlays`)
	inlay_providers: [dynamic]int,
	// Each marker's provider (parallel to `markers`): its click goes there
	marker_providers: [dynamic]int,
}

@(private)
provided_clear_diagnostics :: proc(p: ^Provided) {
	for d in p.diagnostics {
		delete(d.message)
		delete(d.source)
		provider_fixes_free(d.fixes)
	}
	clear(&p.diagnostics)
}

// Copies quick fixes (owned: free with provider_fixes_free)
@(private)
provider_fixes_clone :: proc(fixes: []Provider_Fix) -> []Provider_Fix {
	if len(fixes) == 0 do return nil
	out := make([]Provider_Fix, len(fixes))
	for f, i in fixes {
		edits := make([]Text_Edit, len(f.edits))
		for e, j in f.edits do edits[j] = {e.start, e.end, strings.clone(e.text)}
		out[i] = {strings.clone(f.title), edits, f.preferred}
	}
	return out
}

@(private)
provider_fixes_free :: proc(fixes: []Provider_Fix) {
	for f in fixes {
		delete(f.title)
		for e in f.edits do delete(e.text)
		delete(f.edits)
	}
	delete(fixes)
}

@(private)
provided_clear_markers :: proc(p: ^Provided) {
	for m in p.markers {
		delete(m.tooltip)
		marker_choices_free(m.choices)
	}
	clear(&p.markers)
	clear(&p.marker_providers)
}

@(private)
marker_choices_free :: proc(choices: []string) {
	for c in choices do delete(c)
	delete(choices)
}

@(private)
provided_clear_inlays :: proc(p: ^Provided) {
	for h in p.inlays {
		delete(h.label)
		marker_choices_free(h.choices)
	}
	clear(&p.inlays)
	clear(&p.inlay_providers)
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
	delete(p.inlay_providers)
	delete(p.marker_providers)
	delete(p.hover)
}

// Moves what providers said with an edit (from editor_consume_buffer_changes)
@(private)
provided_shift :: proc(p: ^Provided, ch: buf.Change) {
	for &d in p.diagnostics {
		d.start = buf.position_after_change(d.start, ch)
		d.end = buf.position_after_change(d.end, ch)
		for f in d.fixes do for &e in f.edits {
			e.start = buf.position_after_change(e.start, ch)
			e.end = buf.position_after_change(e.end, ch)
		}
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
	// Which provider gave each inlay hint and marker (their click callbacks)
	inlay_from := make([dynamic]int, context.temp_allocator)
	marker_from := make([dynamic]int, context.temp_allocator)
	for &prov, pi in ed.providers.providers {
		start := time.tick_now()
		ctx := provider_context(&prov, .Refresh)
		switch prov.kind {
		case .Diagnostics: if prov.diagnostic != nil { prov.diagnostic(doc, ctx, &diags); provider_timed(&prov, start) }
		case .Gutter:
			if prov.gutter != nil {
				prov.gutter(doc, ctx, &markers)
				provider_timed(&prov, start)
				for len(marker_from) < len(markers) do append(&marker_from, pi)
			}
		case .Inlay:
			if prov.inlay != nil {
				prov.inlay(doc, ctx, &inlays)
				provider_timed(&prov, start)
				for len(inlay_from) < len(inlays) do append(&inlay_from, pi)
			}
		case .Completion, .Hover, .Drop, .Usages, .Rename, .Scrub, .Menu:
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
			append(&p.diagnostics, Provider_Diagnostic{start, end, sev, strings.clone(d.message), strings.clone(d.source), provider_fixes_clone(d.fixes)})
		}
		p.diag_seq += 1
	}
	provided_clear_markers(p)
	Sorted_Marker :: struct { marker: Gutter_Marker, provider: int }
	sorted_markers := make([dynamic]Sorted_Marker, context.temp_allocator)
	for m, i in markers do append(&sorted_markers, Sorted_Marker{m, marker_from[i]})
	slice.stable_sort_by(sorted_markers[:], proc(a, b: Sorted_Marker) -> bool { return a.marker.line < b.marker.line })
	for sm in sorted_markers {
		m := sm.marker
		if m.line < 0 || m.line >= count do continue
		mm := m
		mm.tooltip = strings.clone(m.tooltip)
		mm.choices = nil
		if len(m.choices) > 0 {
			mm.choices = make([]string, len(m.choices))
			for c, i in m.choices do mm.choices[i] = strings.clone(c)
		}
		mm.choice = 0
		append(&p.markers, mm)
		append(&p.marker_providers, sm.provider)
	}
	provided_clear_inlays(p)
	Sorted_Inlay :: struct { hint: Inlay_Hint, provider: int }
	sorted := make([dynamic]Sorted_Inlay, context.temp_allocator)
	for h, i in inlays {
		_, has_swatch := h.swatch.?
		if h.pos.line < 0 || h.pos.line >= count || (len(h.label) == 0 && !has_swatch) do continue
		append(&sorted, Sorted_Inlay{h, inlay_from[i]})
	}
	slice.stable_sort_by(sorted[:], proc(a, b: Sorted_Inlay) -> bool { return buf.position_less(a.hint.pos, b.hint.pos) })
	for s in sorted {
		hh := s.hint
		hh.label = strings.clone(s.hint.label)
		hh.choice = 0
		hh.choices = nil
		if len(s.hint.choices) > 0 {
			hh.choices = make([]string, len(s.hint.choices))
			for c, i in s.hint.choices do hh.choices[i] = strings.clone(c)
		}
		append(&p.inlays, hh)
		append(&p.inlay_providers, s.provider)
	}
	p.seq += 1
}

/*
The quick fixes of the providers' diagnostics at a position: those whose range holds it (its
end included), else those on its line (the editor's; valid until the providers run again).
*/
editor_provider_fixes_at :: proc(ed: ^Editor, pos: buf.Position, allocator := context.temp_allocator) -> []Provider_Fix {
	out := make([dynamic]Provider_Fix, allocator)
	for d in ed.provided.diagnostics {
		if !buf.position_less(pos, d.start) && !buf.position_less(d.end, pos) do for f in d.fixes do append(&out, f)
	}
	if len(out) == 0 {
		for d in ed.provided.diagnostics do if d.start.line <= pos.line && pos.line <= d.end.line do for f in d.fixes do append(&out, f)
	}
	return out[:]
}

// Whether a typed character opens completion for a provider (its `trigger_chars`)
editor_provider_trigger_char :: proc(ed: ^Editor, ch: u8) -> bool {
	if ed.providers == nil do return false
	for p in ed.providers.providers do if p.kind == .Completion && strings.index_byte(p.trigger_chars, ch) >= 0 do return true
	return false
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

/*
A gutter click on a line: the first marker there with a click callback. A marker with several
choices opens a menu of them (the code actions menu, at the line's start); else the callback is
called at once.
*/
@(private)
editor_click_gutter_marker :: proc(ed: ^Editor, line: int) -> bool {
	if ed.providers == nil do return false
	for m, i in ed.provided.markers {
		if m.line != line do continue
		pi := i < len(ed.provided.marker_providers) ? ed.provided.marker_providers[i] : -1
		if pi < 0 || pi >= len(ed.providers.providers) do continue
		prov := &ed.providers.providers[pi]
		if prov.kind != .Gutter || prov.on_click == nil do continue
		if len(m.choices) > 1 {
			editor_open_marker_menu(ed, pi, m)
			return true
		}
		start := time.tick_now()
		mm := m
		mm.choice = 0
		prov.on_click(editor_provider_document(ed), mm, prov.user_data)
		provider_timed(prov, start)
		return true
	}
	return false
}

// Calls a gutter provider's click callback for a marker's choice (the marker menu's)
@(private)
editor_choose_marker :: proc(ed: ^Editor, provider: int, marker: Gutter_Marker, choice: int) {
	if ed.providers == nil || provider < 0 || provider >= len(ed.providers.providers) do return
	prov := &ed.providers.providers[provider]
	if prov.on_click == nil do return
	m := marker
	m.choice = choice
	start := time.tick_now()
	prov.on_click(editor_provider_document(ed), m, prov.user_data)
	provider_timed(prov, start)
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
			replace_start = c.replace_start,
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
	if ed.lsp_enabled && !cs.providers_only {
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
		item := lspc.CompletionItem{
			label = strings.clone(c.label), kind = c.kind, detail = strings.clone(c.detail),
			insert_text = strings.clone(c.insert_text), filter_text = strings.clone(c.filter_text),
			is_snippet = c.is_snippet, documentation = strings.clone(c.documentation), doc_markdown = c.doc_markdown,
		}
		// Replacing from another column than the word's start: an edit range on the anchor's line
		if col, set := c.replace_start.?; set && cs.anchor.line < buf.buffer_line_count(&ed.buf) {
			line := buf.buffer_line_str(&ed.buf, cs.anchor.line)
			item.has_text_edit = true
			item.text_edit_range.start = {cs.anchor.line, lspc.byte_col_to_utf16(line, clamp(col, 0, len(line)))}
			item.text_edit_range.end = item.text_edit_range.start
		}
		append(&cs.items, Completion_Entry{
			item = item,
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
	p.hover_replaces_server = false
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
		if content.replace_server && len(content.blocks) > 0 do p.hover_replaces_server = true
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

// Draws the hover again on the next render (a host widget's look changed: a sound stopped)
editor_redraw_hover :: proc(ed: ^Editor) {
	if ed.hover.visible do ed.hover.shown_seq += 1
}

/*
A left press on the hover: a host widget's `click` under it is called (the point in the widget's
block). Returns whether a widget used it: the hover then stays open.
*/
@(private)
editor_click_hover_widget :: proc(ed: ^Editor, x, y: f32) -> bool {
	rect, lines, ok := editor_hover_layout(ed)
	if !ok || !in_rect(rect, x, y) do return false
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(popup_scroll_get(&ed.hover.scroll, editor_hover_scroll_key(ed)), len(lines), rows)
	for l, i in lines[scroll:min(scroll + rows, len(lines))] {
		if l.block <= 0 || l.block > len(ed.provided.hover) do continue
		widget, is_widget := ed.provided.hover[l.block - 1].(Hover_Widget)
		if !is_widget || widget.click == nil do continue
		box_x := rect.x + POPUP_PAD
		box_y := rect.y + POPUP_PAD + f32(i) * ed.char_h - f32(l.block_row) * ed.char_h
		if x < box_x || y < box_y || x >= box_x + widget.width || y >= box_y + widget.height do continue
		if widget.click(x - box_x, y - box_y, widget.data) {
			ed.hover.shown_seq += 1
			return true
		}
		return false
	}
	return false
}

// --- inlay swatches ---------------------------------------------------------------

// A swatch's width in cells (it's a cell tall, less its padding)
INLAY_SWATCH_COLS :: 2

// Where a line's inlay hints are drawn: each hint's left edge, the swatch's and the label's
// width (pixels, in the editor's coordinates; temp allocated)
@(private)
Inlay_Place :: struct {
	x, swatch_w, label_w: f32,
}

@(private)
editor_inlay_places :: proc(ed: ^Editor, line: int, x: f32) -> []Inlay_Place {
	hints := editor_inlays_on(ed, line)
	out := make([]Inlay_Place, len(hints), context.temp_allocator)
	text := buf.buffer_line_str(&ed.buf, line)
	vcol := visual_col_of(text, len(text), ed.tab_width) + 2
	for h, i in hints {
		_, swatch := h.swatch.?
		cols := text_cols(h.label)
		swatch_cols := swatch ? INLAY_SWATCH_COLS + (cols > 0 ? 1 : 0) : 0
		out[i] = {x + f32(vcol - ed.scroll_col) * ed.char_w, f32(swatch ? INLAY_SWATCH_COLS : 0) * ed.char_w, f32(cols) * ed.char_w}
		vcol += swatch_cols + cols + 2
	}
	return out
}

/*
A left click at a point of the text area: the swatch of an inlay hint under it, or a clickable
hint's label, calls its provider's `on_inlay_click` (a hint with choices opens their menu first).
Returns whether one did.
*/
@(private)
editor_click_inlay_swatch :: proc(ed: ^Editor, x, y: f32) -> bool {
	if ed.providers == nil || y < ed.origin_y do return false
	line := ed.scroll_line + int((y - ed.origin_y) / max(ed.char_h, 1))
	if line < 0 || line >= buf.buffer_line_count(&ed.buf) do return false
	hints := editor_inlays_on(ed, line)
	if len(hints) == 0 do return false
	first := 0
	for h, i in ed.provided.inlays do if h.pos.line == line { first = i; break }
	places := editor_inlay_places(ed, line, ed.origin_x + editor_gutter_width(ed))
	for h, i in hints {
		pl := places[i]
		_, swatch := h.swatch.?
		on_swatch := swatch && x >= pl.x - 2 && x < pl.x + pl.swatch_w + 2
		label_x := pl.x + (pl.swatch_w > 0 ? pl.swatch_w + ed.char_w : 0)
		on_label := h.clickable && x >= label_x - 2 && x < label_x + pl.label_w + 2
		if !on_swatch && !on_label do continue
		at := first + i
		if at >= len(ed.provided.inlay_providers) do return false
		pi := ed.provided.inlay_providers[at]
		if pi < 0 || pi >= len(ed.providers.providers) do return false
		prov := &ed.providers.providers[pi]
		if prov.on_inlay_click == nil do return false
		if on_label && len(h.choices) > 1 {
			editor_open_inlay_menu(ed, pi, h)
			return true
		}
		start := time.tick_now()
		hh := h
		hh.choice = 0
		prov.on_inlay_click(editor_provider_document(ed), hh, prov.user_data)
		provider_timed(prov, start)
		return true
	}
	return false
}

// Calls an inlay provider's click callback for a hint's choice (the inlay menu's)
@(private)
editor_choose_inlay :: proc(ed: ^Editor, provider: int, hint: Inlay_Hint, choice: int) {
	if ed.providers == nil || provider < 0 || provider >= len(ed.providers.providers) do return
	prov := &ed.providers.providers[provider]
	if prov.on_inlay_click == nil do return
	h := hint
	h.choice = choice
	start := time.tick_now()
	prov.on_inlay_click(editor_provider_document(ed), h, prov.user_data)
	provider_timed(prov, start)
}

/*
The window point (the editor's pixels) of the middle of a line's n-th clickable hint's label
(0-based, among its clickable hints), for hosts' tests that click it. Returns false when there's
no such hint or the line isn't in view.
*/
editor_inlay_label_point :: proc(ed: ^Editor, line, n: int) -> (x, y: f32, ok: bool) {
	if line < ed.scroll_line || line >= ed.scroll_line + editor_text_rows(ed) do return
	places := editor_inlay_places(ed, line, ed.origin_x + editor_gutter_width(ed))
	seen := 0
	for h, i in editor_inlays_on(ed, line) {
		if !h.clickable do continue
		if seen == n {
			pl := places[i]
			label_x := pl.x + (pl.swatch_w > 0 ? pl.swatch_w + ed.char_w : 0)
			return label_x + min(pl.label_w * 0.5, ed.char_w * 2), ed.origin_y + (f32(line - ed.scroll_line) + 0.5) * ed.char_h, true
		}
		seen += 1
	}
	return
}

/*
The window point (the editor's pixels) of the middle of a line's n-th swatch (0-based, among its
inlay hints with one), for hosts' tests that click it. Returns false when there's no such swatch
or the line isn't in view.
*/
editor_inlay_swatch_point :: proc(ed: ^Editor, line, n: int) -> (x, y: f32, ok: bool) {
	if line < ed.scroll_line || line >= ed.scroll_line + editor_text_rows(ed) do return
	places := editor_inlay_places(ed, line, ed.origin_x + editor_gutter_width(ed))
	seen := 0
	for h, i in editor_inlays_on(ed, line) {
		if _, swatch := h.swatch.?; !swatch do continue
		if seen == n {
			return places[i].x + places[i].swatch_w * 0.5, ed.origin_y + (f32(line - ed.scroll_line) + 0.5) * ed.char_h, true
		}
		seen += 1
	}
	return
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
		result.choices = make([dynamic]Drop_Choice, context.temp_allocator)
		took := prov.drop(doc, pos, ctx, drop, &result)
		provider_timed(&prov, start)
		if !took do continue
		if drop.menu && len(result.choices) > 1 {
			editor_open_drop_menu(ed, pos, result.choices[:])
			return "", true
		}
		if len(result.edits) == 0 && len(result.choices) > 0 {
			c := result.choices[0]
			editor_apply_edits(ed, c.edits, c.caret)
			return c.message != "" ? c.message : result.message, true
		}
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
	// Undone and redone to one caret, not one per edit site
	buf.buffer_group_single_caret(b, group)
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
