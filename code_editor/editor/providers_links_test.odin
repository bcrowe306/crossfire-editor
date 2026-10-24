package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// What the link providers saw (their user data)
@(private="file")
Links :: struct {
	chosen:  int,
	clicks:  int,
	opened:  int,
	renamed: string,
	reject:  bool,
}

@(private="file")
links_registry :: proc(links: ^Links) -> Provider_Registry {
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Gutter, name = "users", user_data = links,
		gutter = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Gutter_Marker) {
			choices := make([]string, 3, ctx.allocator)
			choices[0], choices[1], choices[2] = "Forest: Hero", "Cave: Hero", "Globals: Hero"
			append(out, Gutter_Marker{line = 0, icon = .Diamond, tooltip = "3 users", choices = choices})
			append(out, Gutter_Marker{line = 1, icon = .Dot, tooltip = "1 user"})
		},
		on_click = proc(doc: Provider_Document, marker: Gutter_Marker, user_data: rawptr) {
			l := (^Links)(user_data)
			l.clicks += 1
			l.chosen = marker.choice
		},
	})
	provider_register(&reg, Provider{kind = .Usages, name = "usages", user_data = links,
		usages = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Usages_Result) -> bool {
			if pos.line != 0 do return false
			out.symbol = "Hero"
			append(&out.items, Provider_Usage{label = "Forest: Hero", preview = "speed = 250", id = 10})
			append(&out.items, Provider_Usage{label = "Cave: Hero", preview = "speed = 175 (default)", id = 11})
			return true
		},
		on_open = proc(doc: Provider_Document, usage: Provider_Usage, user_data: rawptr) {
			(^Links)(user_data).opened = usage.id
		},
	})
	provider_register(&reg, Provider{kind = .Rename, name = "renames", user_data = links,
		prepare_rename = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Rename_Target) -> bool {
			if pos.line != 0 do return false
			out^ = {start = {0, 0}, end = {0, 4}, name = "Hero", title = "Rename script Hero", note = "Also: 2 nodes"}
			return true
		},
		rename = proc(doc: Provider_Document, target: Rename_Target, new_name: string, ctx: Provider_Context, out: ^Rename_Result) -> bool {
			l := (^Links)(ctx.user_data)
			if new_name == "Taken" {
				out.error = "Taken is taken"
				return false
			}
			l.renamed = strings.clone(new_name, context.temp_allocator)
			// Every "Hero" in the document
			for i in 0 ..< buf.buffer_line_count(doc.buffer) {
				line := buf.buffer_line_str(doc.buffer, i)
				at := 0
				for {
					j := strings.index(line[at:], "Hero")
					if j < 0 do break
					append(&out.edits, Text_Edit{start = {i, at + j}, end = {i, at + j + 4}, text = new_name})
					at += j + 4
				}
			}
			out.message = "renamed"
			return true
		},
	})
	return reg
}

// A marker with several choices opens a menu; picking one calls the provider with it. One with
// none calls it at once
@(test)
test_marker_choices_open_a_menu :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		links: Links
		reg := links_registry(&links)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("Hero :: struct {}\nspeed: f32,\nx")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)

		mouse_click(&ed, editor_gutter_width(&ed) - 4, 10)
		testing.expect_value(t, links.clicks, 0)
		testing.expect(t, editor_code_actions_visible(&ed), "the menu")
		testing.expect_value(t, editor_code_action_count(&ed), 3)
		title, _ := editor_code_action_title(&ed, 1)
		testing.expect_value(t, title, "Cave: Hero")
		key_and_update(&ed, sdl.K_DOWN)
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, links.clicks == 1 && links.chosen == 1, "the second choice")
		testing.expect(t, !ed.actions.active, "closed")

		// Without a server the menu stays until chosen or dismissed (it isn't the server's)
		ed.lsp_enabled = false
		mouse_click(&ed, editor_gutter_width(&ed) - 4, 10)
		editor_update(&ed)
		testing.expect(t, editor_code_actions_visible(&ed), "still open")
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.actions.active, "Escape closes it")
		ed.lsp_enabled = true

		// The second line's marker has no choices: called at once
		mouse_click(&ed, editor_gutter_width(&ed) - 4, 30)
		testing.expect(t, links.clicks == 2 && links.chosen == 0, "at once")
	})
}

// Find Usages: the provider's items in the references panel, in its order; picking one calls it
@(test)
test_find_usages_lists_the_providers_items :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		links: Links
		reg := links_registry(&links)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("Hero :: struct {}\nx")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)

		key_and_update(&ed, sdl.K_F12, sdl.KMOD_SHIFT | sdl.KMOD_ALT)
		r := &ed.nav.refs
		testing.expect(t, r.open && r.usages && len(r.items) == 2, "the usages")
		testing.expect_value(t, r.symbol, "Hero")
		testing.expect_value(t, r.items[1].label, "Cave: Hero")
		key_and_update(&ed, sdl.K_F4)
		testing.expect_value(t, links.opened, 11)
		editor_open_reference(&ed, 0)
		testing.expect_value(t, links.opened, 10)

		// Nothing the provider knows: the status says so
		editor_close_references(&ed)
		ed.buf.cursors[0] = {pos = {1, 0}}
		editor_find_usages(&ed)
		testing.expect(t, !r.open, "no panel")
		testing.expect_value(t, editor_status_text(&ed), "No usages to find here")
	})
}

// F2: the provider's box, a taken name keeps it open with the reason, a good one renames as one
// undo step that undoes to one caret
@(test)
test_rename_with_a_provider :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		links: Links
		reg := links_registry(&links)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("Hero :: struct {}\nh: ^Hero\nlist: [dynamic]^Hero")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)

		key_and_update(&ed, sdl.K_F2)
		testing.expect(t, editor_rename_open(&ed), "the box")
		testing.expect_value(t, ed.rename.target.title, "Rename script Hero")
		testing.expect_value(t, editor_rename_text(&ed), "Hero")
		_, ok := editor_rename_layout(&ed)
		testing.expect(t, ok, "laid out")
		// Typing replaces the selected name; keys edit it
		type_and_update(&ed, "Taken")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, editor_rename_open(&ed) && ed.rename.error == "Taken is taken", "the provider's reason")
		key_and_update(&ed, sdl.K_BACKSPACE)
		testing.expect_value(t, editor_rename_text(&ed), "Take")
		key_and_update(&ed, sdl.K_HOME)
		type_and_update(&ed, "9")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, strings.contains(ed.rename.error, "isn't a name"), "not an identifier")
		key_and_update(&ed, sdl.K_A, sdl.KMOD_CTRL)
		type_and_update(&ed, "Player")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !editor_rename_open(&ed), "closed")
		testing.expect_value(t, links.renamed, "Player")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "Player :: struct {}\nh: ^Player\nlist: [dynamic]^Player")
		testing.expect_value(t, editor_status_text(&ed), "renamed")
		testing.expect_value(t, editor_primary_cursor(&ed).pos, buf.Position{0, 0})
		// One undo step, one caret
		testing.expect(t, buf.buffer_undo(&ed.buf), "undone")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "Hero :: struct {}\nh: ^Hero\nlist: [dynamic]^Hero")
		testing.expect_value(t, len(ed.buf.cursors), 1)

		// Escape cancels
		key_and_update(&ed, sdl.K_F2)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !editor_rename_open(&ed), "cancelled")
	})
}

// Without a provider for it: the server's rename, this document's edits applied, other files'
// left for the host
@(test)
test_rename_through_the_server :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("count := 1\nx := count + 1")
		defer editor_destroy(&ed)
		ed.buf.cursors[0] = {pos = {1, 6}}
		editor_start_rename(&ed)
		testing.expect(t, editor_rename_open(&ed) && ed.rename.provider == -1, "the server's")
		testing.expect_value(t, editor_rename_text(&ed), "count")
		editor_rename_text_input(&ed, "total")
		editor_commit_rename(&ed)
		testing.expect(t, ed.rename.waiting, "asked")
		edit :: proc(line, from, to: int) -> string {
			return fmt.tprintf(`{{"range":{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}},"newText":"total"}}`, line, from, line, to)
		}
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"changes":{{"file:///tmp/lsp_ui_test.odin":[%s,%s],"file:///tmp/other.odin":[%s]}}}}}}`,
			ed.lsp.latest_rename_id, edit(0, 0, 5), edit(1, 5, 10), edit(3, 2, 7))
		lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
		editor_update(&ed)
		testing.expect(t, !editor_rename_open(&ed), "done")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "total := 1\nx := total + 1")
		others := editor_take_file_edits(&ed)
		testing.expect(t, len(others) == 1 && others[0].key == "/tmp/other.odin" && others[0].range.start.line == 3, "the other file's edit for the host")
		testing.expect_value(t, len(editor_take_file_edits(&ed)), 0)

		// The server refusing: the box stays with its message
		editor_start_rename(&ed)
		editor_rename_text_input(&ed, "again")
		editor_commit_rename(&ed)
		body = fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"error":{{"code":-32803,"message":"Can't rename a keyword"}}}}`, ed.lsp.latest_rename_id)
		lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
		editor_update(&ed)
		testing.expect(t, editor_rename_open(&ed) && ed.rename.error == "Can't rename a keyword", "the server's error")
		editor_close_rename(&ed)
	})
}
