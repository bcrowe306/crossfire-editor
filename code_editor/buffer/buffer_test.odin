package buffer

import "core:mem"
import "core:testing"

// run_leak_free wraps a test body in a tracking allocator, failing the test
// on any leak or bad free — mirrors the convention used by the `engine`
// package's test suite.
run_leak_free :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	body(t)
	context.allocator = old

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "Memory leak: %v bytes at %v", entry.size, entry.location)
	}
	for bf in track.bad_free_array {
		testing.expectf(t, false, "Bad free: %p at %v", bf.memory, bf.location)
	}
}

@(test)
test_set_and_to_string_roundtrip :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)

		buffer_set_text(&b, "hello\nworld\n")
		testing.expect_value(t, buffer_line_count(&b), 3)
		testing.expect_value(t, buffer_line_str(&b, 0), "hello")
		testing.expect_value(t, buffer_line_str(&b, 1), "world")
		testing.expect_value(t, buffer_line_str(&b, 2), "")

		out := buffer_to_string(&b, context.temp_allocator)
		testing.expect_value(t, out, "hello\nworld\n")
	})
}

@(test)
test_insert_single_line :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "helloworld")
		end := buffer_insert_text(&b, Position{0, 5}, " ")
		testing.expect_value(t, buffer_line_str(&b, 0), "hello world")
		testing.expect_value(t, end, Position{0, 6})
	})
}

@(test)
test_insert_multiline_splits :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foobar")
		end := buffer_insert_text(&b, Position{0, 3}, "\nBAZ\n")
		testing.expect_value(t, buffer_line_count(&b), 3)
		testing.expect_value(t, buffer_line_str(&b, 0), "foo")
		testing.expect_value(t, buffer_line_str(&b, 1), "BAZ")
		testing.expect_value(t, buffer_line_str(&b, 2), "bar")
		testing.expect_value(t, end, Position{2, 0})
	})
}

@(test)
test_delete_single_line_range :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello world")
		removed := buffer_delete_range(&b, Position{0, 5}, Position{0, 11})
		testing.expect_value(t, buffer_line_str(&b, 0), "hello")
		testing.expect_value(t, removed, " world")
	})
}

@(test)
test_delete_multiline_merges :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo\nBAZ\nbar")
		buffer_delete_range(&b, Position{0, 3}, Position{2, 0})
		testing.expect_value(t, buffer_line_count(&b), 1)
		testing.expect_value(t, buffer_line_str(&b, 0), "foobar")
	})
}

@(test)
test_undo_redo_insert :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "abc")
		buffer_insert_text(&b, Position{0, 3}, "def")
		testing.expect_value(t, buffer_line_str(&b, 0), "abcdef")

		ok := buffer_undo(&b)
		testing.expect(t, ok, "expected undo to succeed")
		testing.expect_value(t, buffer_line_str(&b, 0), "abc")

		ok = buffer_redo(&b)
		testing.expect(t, ok, "expected redo to succeed")
		testing.expect_value(t, buffer_line_str(&b, 0), "abcdef")
	})
}

@(test)
test_undo_redo_delete :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "abcdef")
		buffer_delete_range(&b, Position{0, 3}, Position{0, 6})
		testing.expect_value(t, buffer_line_str(&b, 0), "abc")

		testing.expect(t, buffer_undo(&b), "undo should succeed")
		testing.expect_value(t, buffer_line_str(&b, 0), "abcdef")

		testing.expect(t, buffer_redo(&b), "redo should succeed")
		testing.expect_value(t, buffer_line_str(&b, 0), "abc")
	})
}

@(test)
test_undo_group_batches_edits :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "")

		buffer_type_text(&b, "a")
		buffer_type_text(&b, "b")
		buffer_type_text(&b, "c")
		testing.expect_value(t, buffer_line_str(&b, 0), "abc")

		// Consecutive keystrokes at the caret coalesce into one undo step.
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "")
	})
}

@(test)
test_cursor_movement_basic :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello\nworld")
		c := Cursor{pos = Position{0, 0}}

		cursor_move_right(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 1})

		cursor_move_line_end(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 5})

		cursor_move_right(&b, &c, false)
		testing.expect_value(t, c.pos, Position{1, 0})

		// At the last line, Down (VSCode-style) jumps to end of that line.
		cursor_move_down(&b, &c, false)
		testing.expect_value(t, c.pos, Position{1, 5})

		cursor_move_left(&b, &c, false)
		testing.expect_value(t, c.pos, Position{1, 4})
	})
}

@(test)
test_cursor_word_movement :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo bar_baz  qux")
		c := Cursor{pos = Position{0, 0}}

		cursor_move_word_right(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 3})
		cursor_move_word_right(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 11})
		cursor_move_word_right(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 16})

		cursor_move_word_left(&b, &c, false)
		testing.expect_value(t, c.pos, Position{0, 13})
	})
}

@(test)
test_selection_extend_and_clear :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello world")
		c := Cursor{pos = Position{0, 0}}

		cursor_move_right(&b, &c, true)
		cursor_move_right(&b, &c, true)
		cursor_move_right(&b, &c, true)
		start, end, ok := selection_range(c)
		testing.expect(t, ok, "expected active selection")
		testing.expect_value(t, start, Position{0, 0})
		testing.expect_value(t, end, Position{0, 3})

		cursor_move_right(&b, &c, false)
		_, _, ok2 := selection_range(c)
		testing.expect(t, !ok2, "selection should clear on non-extend move")
	})
}

@(test)
test_select_all :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo\nbar\nbaz")
		c := Cursor{pos = Position{1, 1}}
		cursor_select_all(&b, &c)
		start, end, ok := selection_range(c)
		testing.expect(t, ok, "expected selection")
		testing.expect_value(t, start, Position{0, 0})
		testing.expect_value(t, end, Position{2, 3})
	})
}

@(test)
test_select_word :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo bar_baz qux")
		c := Cursor{pos = Position{0, 6}}
		cursor_select_word(&b, &c)
		start, end, ok := selection_range(c)
		testing.expect(t, ok, "expected selection")
		testing.expect_value(t, start, Position{0, 4})
		testing.expect_value(t, end, Position{0, 11})
	})
}

@(test)
test_type_text_with_selection_replaces :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello world")
		b.cursors[0] = Cursor{pos = Position{0, 11}, sel = Selection{anchor = Position{0, 6}, active = true}}
		buffer_type_text(&b, "there")
		testing.expect_value(t, buffer_line_str(&b, 0), "hello there")
	})
}

@(test)
test_backspace_and_delete_forward :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello")
		b.cursors[0] = Cursor{pos = Position{0, 5}}
		buffer_backspace(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "hell")

		b.cursors[0] = Cursor{pos = Position{0, 0}}
		buffer_delete_forward(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "ell")
	})
}

@(test)
test_backspace_merges_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo\nbar")
		b.cursors[0] = Cursor{pos = Position{1, 0}}
		buffer_backspace(&b)
		testing.expect_value(t, buffer_line_count(&b), 1)
		testing.expect_value(t, buffer_line_str(&b, 0), "foobar")
	})
}

@(test)
test_newline_auto_indent :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "    foo")
		b.cursors[0] = Cursor{pos = Position{0, 7}}
		buffer_newline(&b)
		testing.expect_value(t, buffer_line_count(&b), 2)
		testing.expect_value(t, buffer_line_str(&b, 1), "    ")
		testing.expect_value(t, b.cursors[0].pos, Position{1, 4})
	})
}

// Regression test for a use-after-free in buffer_raw_insert's multi-line
// path: `after` (the text following the cursor on the original line) was
// read from the old line builder's backing array *after* that builder had
// already been destroyed, corrupting bytes like `)` into garbage/`\x00`
// when splitting a line via newline (e.g. pressing Enter between matching
// brackets: "(|)" -> "(" / ")").
@(test)
test_newline_between_characters_preserves_trailing_text :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "()")
		b.cursors[0] = Cursor{pos = Position{0, 1}}
		buffer_newline(&b)
		testing.expect_value(t, buffer_line_count(&b), 2)
		testing.expect_value(t, buffer_line_str(&b, 0), "(")
		testing.expect_value(t, buffer_line_str(&b, 1), ")")
	})
}

@(test)
test_indent_and_outdent_selection :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo\nbar")
		b.cursors[0] = Cursor{pos = Position{1, 3}, sel = Selection{anchor = Position{0, 0}, active = true}}
		buffer_indent(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "    foo")
		testing.expect_value(t, buffer_line_str(&b, 1), "    bar")

		b.cursors[0] = Cursor{pos = Position{1, 7}, sel = Selection{anchor = Position{0, 0}, active = true}}
		buffer_outdent(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "foo")
		testing.expect_value(t, buffer_line_str(&b, 1), "bar")
	})
}

@(test)
test_multi_cursor_type_text :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "foo\nfoo\nfoo")
		clear(&b.cursors)
		append(&b.cursors, Cursor{pos = Position{0, 3}})
		append(&b.cursors, Cursor{pos = Position{1, 3}})
		append(&b.cursors, Cursor{pos = Position{2, 3}})

		buffer_type_text(&b, "!")

		testing.expect_value(t, buffer_line_str(&b, 0), "foo!")
		testing.expect_value(t, buffer_line_str(&b, 1), "foo!")
		testing.expect_value(t, buffer_line_str(&b, 2), "foo!")
	})
}

@(test)
test_file_save_and_load_roundtrip :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "line one\nline two\n")

		path := "/tmp/odin_editor_buffer_test.txt"
		ok := buffer_save_file(&b, path)
		testing.expect(t, ok, "expected save to succeed")

		b2 := buffer_init()
		defer buffer_destroy(&b2)
		ok2 := buffer_load_file(&b2, path)
		testing.expect(t, ok2, "expected load to succeed")
		testing.expect_value(t, buffer_to_string(&b2, context.temp_allocator), "line one\nline two\n")
	})
}

@(test)
test_version_bumps_on_every_content_change :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)

		v0 := b.version
		buffer_set_text(&b, "abc")
		testing.expect(t, b.version > v0, "set_text bumps version")

		v1 := b.version
		cursor_move_right(&b, &b.cursors[0], false)
		testing.expect_value(t, b.version, v1) // movement is not a content change

		buffer_type_text(&b, "X")
		testing.expect(t, b.version > v1, "insert bumps version")

		v2 := b.version
		buffer_backspace(&b)
		testing.expect(t, b.version > v2, "delete bumps version")

		v3 := b.version
		buffer_undo(&b)
		testing.expect(t, b.version > v3, "undo bumps version")

		v4 := b.version
		buffer_insert_text(&b, {0, 0}, "")
		testing.expect_value(t, b.version, v4) // empty insert is a no-op
	})
}

@(test)
test_undo_redo_restore_cursors_to_edit_sites :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "aaa\nbbb\nccc")
		b.cursors[0].pos = {0, 1}
		append(&b.cursors, Cursor{pos = {2, 1}})

		buffer_type_text(&b, "//")
		testing.expect_value(t, buffer_line_str(&b, 0), "a//aa")
		// Wander off with a single cursor before undoing.
		resize(&b.cursors, 1)
		b.cursors[0].pos = {1, 3}

		buffer_undo(&b)
		testing.expect_value(t, len(b.cursors), 2)
		testing.expect_value(t, b.cursors[0].pos, Position{0, 1})
		testing.expect_value(t, b.cursors[1].pos, Position{2, 1})

		buffer_redo(&b)
		testing.expect_value(t, len(b.cursors), 2)
		testing.expect_value(t, b.cursors[0].pos, Position{0, 3})
		testing.expect_value(t, b.cursors[1].pos, Position{2, 3})
	})
}

@(test)
test_undo_backspace_puts_cursor_after_restored_text :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "hello")
		b.cursors[0].pos = {0, 5}
		buffer_backspace(&b)
		b.cursors[0].pos = {0, 0}
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "hello")
		testing.expect_value(t, b.cursors[0].pos, Position{0, 5})
	})
}

@(test)
test_change_log_records_edits_when_tracking :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "abc\ndef")
		buffer_insert_text(&b, {0, 1}, "XY") // not tracked yet
		ch, reset := buffer_take_changes(&b)
		testing.expect(t, len(ch) == 0 && !reset, "nothing recorded while tracking is off")

		b.track_changes = true
		buffer_insert_text(&b, {0, 0}, "1\n2")
		buffer_delete_range(&b, {1, 1}, {1, 3})
		ch, reset = buffer_take_changes(&b)
		testing.expect(t, !reset, "no reset")
		testing.expect_value(t, len(ch), 2)
		testing.expect(t, ch[0].start == {0, 0} && ch[0].old_end == {0, 0} && ch[0].new_end == {1, 1}, "insert change")
		testing.expect_value(t, ch[0].text, "1\n2")
		testing.expect(t, ch[1].start == {1, 1} && ch[1].old_end == {1, 3} && ch[1].new_end == {1, 1}, "delete change")
		testing.expect_value(t, ch[1].text, "")

		buffer_set_text(&b, "fresh")
		_, reset = buffer_take_changes(&b)
		testing.expect(t, reset, "set_text reports a reset")
	})
}

@(test)
test_position_after_change :: proc(t: ^testing.T) {
	ins := Change{start = {2, 4}, old_end = {2, 4}, new_end = {3, 1}} // inserted "..\n."
	testing.expect_value(t, position_after_change({2, 3}, ins), Position{2, 3}) // before
	testing.expect_value(t, position_after_change({2, 4}, ins), Position{3, 1}) // at insert point: pushed
	testing.expect_value(t, position_after_change({2, 9}, ins), Position{3, 6}) // same line after
	testing.expect_value(t, position_after_change({5, 2}, ins), Position{6, 2}) // later line

	del := Change{start = {1, 2}, old_end = {3, 5}, new_end = {1, 2}}
	testing.expect_value(t, position_after_change({2, 0}, del), Position{1, 2}) // inside -> collapses
	testing.expect_value(t, position_after_change({3, 8}, del), Position{1, 5}) // after on end line
	testing.expect_value(t, position_after_change({7, 1}, del), Position{5, 1})
}

@(private)
type_chars :: proc(b: ^Buffer, s: string) {
	for ch in s {
		buf: [4]u8
		buf[0] = u8(ch)
		buffer_type_text(b, string(buf[:1]))
	}
}

@(test)
test_typing_coalesces_into_word_sized_undo_steps :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		type_chars(&b, "hello world")
		testing.expect_value(t, buffer_line_str(&b, 0), "hello world")

		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "hello ")
		testing.expect_value(t, len(b.cursors), 1)
		testing.expect_value(t, b.cursors[0].pos, Position{0, 6})
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "")
		testing.expect_value(t, b.cursors[0].pos, Position{0, 0})

		buffer_redo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "hello ")
		testing.expect_value(t, b.cursors[0].pos, Position{0, 6})
	})
}

@(test)
test_typing_run_breaks_on_caret_move_and_other_edits :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		type_chars(&b, "ab")
		cursor_move_left(&b, &b.cursors[0], false)
		type_chars(&b, "X") // caret moved: new step
		buffer_backspace(&b)
		type_chars(&b, "Y") // after a backspace: new step
		testing.expect_value(t, buffer_line_str(&b, 0), "aYb")
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "ab")
		buffer_undo(&b) // the backspace
		testing.expect_value(t, buffer_line_str(&b, 0), "aXb")
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "ab")
		buffer_undo(&b)
		testing.expect_value(t, buffer_line_str(&b, 0), "")
	})
}

@(test)
test_multi_cursor_typing_coalesces_per_caret :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "x\ny")
		append(&b.cursors, Cursor{pos = {1, 0}})
		type_chars(&b, "ab")
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "abx\naby")
		buffer_undo(&b)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "x\ny")
		testing.expect_value(t, len(b.cursors), 2)
		testing.expect_value(t, b.cursors[0].pos, Position{0, 0})
		testing.expect_value(t, b.cursors[1].pos, Position{1, 0})
	})
}

@(test)
test_change_log_records_utf16_columns_before_the_edit :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "é😀x")
		b.track_changes = true
		buffer_take_changes(&b) // drop the reset
		buffer_insert_text(&b, {0, 6}, "Y") // after the emoji: byte 6, UTF-16 3
		buffer_delete_range(&b, {0, 2}, {0, 6}) // remove the emoji
		ch, _ := buffer_take_changes(&b)
		testing.expect_value(t, len(ch), 2)
		testing.expect(t, ch[0].start_u16 == 3 && ch[0].old_end_u16 == 3 && ch[0].text == "Y", "insert columns")
		testing.expect(t, ch[1].start_u16 == 1 && ch[1].old_end_u16 == 3, "delete measured before deletion")
		// Taking again frees the previous batch and returns nothing new.
		again, _ := buffer_take_changes(&b)
		testing.expect_value(t, len(again), 0)
	})
}

@(test)
test_duplicate_and_move_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "a\nb\nc")
		b.cursors[0].pos = {1, 1}
		buffer_duplicate_lines(&b, down = false)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nb\nb\nc")
		testing.expect_value(t, b.cursors[0].pos, Position{1, 1}) // up: stays on the upper copy
		buffer_duplicate_lines(&b, down = true)
		testing.expect_value(t, b.cursors[0].pos, Position{2, 1}) // down: moves to the copy
		buffer_undo(&b)
		buffer_undo(&b)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nb\nc")

		b.cursors[0] = {pos = {1, 0}}
		testing.expect(t, buffer_move_lines(&b, -1), "moved up")
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "b\na\nc")
		testing.expect_value(t, b.cursors[0].pos.line, 0)
		testing.expect(t, !buffer_move_lines(&b, -1), "already at the top")
		buffer_move_lines(&b, 1)
		buffer_move_lines(&b, 1)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nc\nb")
		testing.expect(t, !buffer_move_lines(&b, 1), "already at the bottom")
		buffer_move_lines(&b, -1) // last line moving up
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nb\nc")
		buffer_undo(&b)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nc\nb") // one step per move

		// A two-line selection moves as a block.
		buffer_set_text(&b, "1\n2\n3\n4")
		b.cursors[0] = {pos = {2, 1}, sel = {anchor = {1, 0}, active = true}}
		buffer_move_lines(&b, 1)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "1\n4\n2\n3")
		s, e, _ := selection_range(b.cursors[0])
		testing.expect(t, s == {2, 0} && e == {3, 1}, "selection moved with the block")
	})
}

@(test)
test_toggle_comment_delete_and_insert_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buffer_init()
		defer buffer_destroy(&b)
		buffer_set_text(&b, "\tx := 1\n\n\t\ty := 2")
		b.cursors[0] = {pos = {2, 3}, sel = {anchor = {0, 1}, active = true}}
		buffer_toggle_line_comment(&b, "//")
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "\t// x := 1\n\n\t// \ty := 2")
		testing.expect_value(t, b.cursors[0].sel.anchor, Position{0, 1}) // anchor before the insert point stays
		buffer_toggle_line_comment(&b, "//")
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "\tx := 1\n\n\t\ty := 2")

		buffer_set_text(&b, "a\nb\nc\nd")
		b.cursors[0].pos = {1, 0}
		append(&b.cursors, Cursor{pos = {2, 0}})
		buffer_delete_lines(&b)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "a\nd")
		testing.expect_value(t, len(b.cursors), 1)
		testing.expect_value(t, b.cursors[0].pos, Position{1, 0})

		buffer_set_text(&b, "\tfoo()")
		b.cursors[0].pos = {0, 2}
		buffer_insert_line(&b, false)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "\tfoo()\n\t")
		testing.expect_value(t, b.cursors[0].pos, Position{1, 1})
		buffer_insert_line(&b, true)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "\tfoo()\n\t\n\t")
		testing.expect_value(t, b.cursors[0].pos, Position{1, 1})
	})
}
