// Package syntax provides a pluggable tokenizer/highlighter architecture.
// Highlighters work one line at a time and thread a small integer "line
// state" through calls so that multi-line constructs (block comments) can
// be resumed correctly without re-scanning the whole document.
package syntax

import "core:mem"

TokenKind :: enum {
	Default,
	Keyword,
	Identifier,
	Builtin,
	Type,
	String,
	Number,
	Comment,
	Operator,
	Punctuation,
	Function,  // procedure names: declarations, calls, builtin procs
	Constant,  // true/false/nil, SCREAMING_CASE constants
	Property,  // field / member after '.'
	Directive, // #partial, #force_inline, #load ...
	Attribute, // @(private), @require_results ...
}

// Token spans [start, end) byte offsets within the line that was tokenized.
Token :: struct {
	kind:  TokenKind,
	start: int,
	end:   int,
}

// LineTokenizer tokenizes a single line of source, given the state left
// over from the previous line (e.g. "inside a block comment"), and returns
// the tokens plus the state to carry into the next line.
LineTokenizer :: proc(line: string, state_in: int, allocator: mem.Allocator) -> (tokens: []Token, state_out: int)

// Language bundles a display name with its tokenizer so hosts can register
// multiple languages and pick one per buffer/file-extension.
Language :: struct {
	name:         string,
	tokenize:     LineTokenizer,
	line_comment: string, // e.g. "//" (Toggle Line Comment)
}

LINE_STATE_NORMAL :: 0
