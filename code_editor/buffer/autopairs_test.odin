package buffer

import "core:testing"

// Auto-closing pairs (autopairs.odin)

// Types each character of `keys` at the caret(s), paired; returns the text
@(private="file")
type_keys :: proc(b: ^Buffer, keys: string, rules: Pair_Rules = {}) -> string {
	for i in 0 ..< len(keys) {
		if !buffer_type_paired(b, keys[i], rules) do buffer_type_text(b, keys[i:i + 1])
	}
	return buffer_to_string(b, context.temp_allocator)
}

@(private="file")
fresh :: proc(text: string, caret: Position) -> Buffer {
	b := buffer_init()
	buffer_set_text(&b, text)
	b.cursors[0] = {pos = caret}
	return b
}

@(test)
test_brackets_and_quotes_close_and_step_over :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := fresh("", {0, 0})
		defer buffer_destroy(&b)
		// Each opener closes; the caret sits inside; typing the closer steps over it
		testing.expect_value(t, type_keys(&b, "f("), "f()")
		testing.expect_value(t, b.cursors[0].pos, Position{0, 2})
		testing.expect_value(t, type_keys(&b, "a[1"), "f(a[1])")
		testing.expect_value(t, type_keys(&b, "]"), "f(a[1])")
		testing.expect_value(t, type_keys(&b, ")"), "f(a[1])")
		testing.expect_value(t, b.cursors[0].pos, Position{0, 7})
		testing.expect_value(t, type_keys(&b, " {"), "f(a[1]) {}")
		testing.expect_value(t, type_keys(&b, `"hi`), `f(a[1]) {"hi"}`)
		testing.expect_value(t, type_keys(&b, `"`), `f(a[1]) {"hi"}`) // stepped over
		testing.expect_value(t, type_keys(&b, " 'x"), `f(a[1]) {"hi" 'x'}`)
		testing.expect_value(t, type_keys(&b, "' `y`"), "f(a[1]) {\"hi\" 'x' `y`}")
	})
}

@(test)
test_pairs_dont_close_where_they_shouldnt :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		// Before a word: no closer
		b := fresh("word", {0, 0})
		defer buffer_destroy(&b)
		testing.expect_value(t, type_keys(&b, "("), "(word")
		// A quote in a word (an apostrophe) or after a backslash: no closer
		c := fresh("", {0, 0})
		defer buffer_destroy(&c)
		testing.expect_value(t, type_keys(&c, "don't"), "don't")
		d := fresh("", {0, 0})
		defer buffer_destroy(&d)
		testing.expect_value(t, type_keys(&d, `"a\"`), `"a\""`)
		// `<` is "less than" in code: no closer after a space; after a word it's generic-like
		e := fresh("", {0, 0})
		defer buffer_destroy(&e)
		testing.expect_value(t, type_keys(&e, "a < b"), "a < b")
		f := fresh("", {0, 0})
		defer buffer_destroy(&f)
		testing.expect_value(t, type_keys(&f, "Map<int"), "Map<int>")
		// In markup it closes anywhere
		g := fresh("", {0, 0})
		defer buffer_destroy(&g)
		testing.expect_value(t, type_keys(&g, "<node", {markup = true}), "<node>")
	})
}

@(test)
test_backspace_removes_an_empty_pair :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := fresh("", {0, 0})
		defer buffer_destroy(&b)
		type_keys(&b, "x(")
		testing.expect(t, buffer_backspace_pair(&b), "removed the pair")
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "x")
		// Not inside an empty pair: an ordinary Backspace's job
		testing.expect(t, !buffer_backspace_pair(&b), "nothing to remove")
		// One undo step brings the pair back
		buffer_undo(&b)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "x()")
	})
}

@(test)
test_typing_an_opener_wraps_the_selection :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := fresh("say hello now", {0, 9})
		defer buffer_destroy(&b)
		b.cursors[0].sel = {anchor = {0, 4}, active = true}
		testing.expect_value(t, type_keys(&b, `"`), `say "hello" now`)
		start, end, ok := selection_range(b.cursors[0])
		testing.expect(t, ok && start == Position{0, 5} && end == Position{0, 10}, "the text inside stays selected")
		testing.expect_value(t, type_keys(&b, "("), `say "(hello)" now`)
	})
}

@(test)
test_enter_between_brackets_opens_an_indented_line :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := fresh("\tmain :: proc() {}", {0, 17})
		defer buffer_destroy(&b)
		buffer_newline_paired(&b, use_tabs = true)
		testing.expect_value(t, buffer_to_string(&b, context.temp_allocator), "\tmain :: proc() {\n\t\t\n\t}")
		testing.expect_value(t, b.cursors[0].pos, Position{1, 2})
		// After an opener alone, one more indent; elsewhere the line's own
		c := fresh("if x {", {0, 6})
		defer buffer_destroy(&c)
		buffer_newline_paired(&c, use_tabs = false)
		testing.expect_value(t, buffer_to_string(&c, context.temp_allocator), "if x {\n    ")
		d := fresh("  a := 1", {0, 8})
		defer buffer_destroy(&d)
		buffer_newline_paired(&d)
		testing.expect_value(t, buffer_to_string(&d, context.temp_allocator), "  a := 1\n  ")
	})
}

@(test)
test_pairs_at_every_caret :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := fresh("a\nb", {0, 1})
		defer buffer_destroy(&b)
		append(&b.cursors, Cursor{pos = {1, 1}})
		testing.expect_value(t, type_keys(&b, "("), "a()\nb()")
		testing.expect(t, b.cursors[0].pos.col == 2 && b.cursors[1].pos.col == 2, "both inside")
	})
}
