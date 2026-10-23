// The syntactic context of a position: whether it's inside a struct, a procedure's body, a
// call's argument list, a string or a comment, worked out from the buffer with the language's
// tokenizer (no parse, so it works on half-typed code). Drop and completion providers use it to
// decide what fits where (`Provider_Context.syntax`).
package code_editor

import buf "../buffer"
import syn "../syntax"
import "core:strings"

// What encloses a position
Syntax_Kind :: enum {
	// Outside any declaration's braces (a `when` block's too)
	Top_Level,
	// Between a struct's braces (`syntax.name` is the struct's name)
	Struct_Body,
	// Between an enum's braces
	Enum_Body,
	// Between a union's braces
	Union_Body,
	// Inside a procedure's body (`proc_name`), its blocks and literals included
	Proc_Body,
	// Inside a call's parentheses (`call_name`, `argument`)
	Call_Argument,
	// Inside a comment
	Comment,
}

/*
Where a position is in the code. Names are temp allocated (`editor_syntax_context_at`'s
allocator).
*/
Syntax_Context :: struct {
	kind:        Syntax_Kind,
	pos:         buf.Position,
	// Struct_Body / Enum_Body / Union_Body: the type's name ("" when it isn't declared `Name ::`),
	// and its braces (`close` is the buffer's end when it isn't closed yet)
	name:        string,
	open, close: buf.Position,
	// The innermost procedure around the position ("" outside one; a literal's field or variable
	// name, `ready = proc(...)`, else "")
	proc_name:   string,
	in_proc:     bool,
	// Call_Argument: the called expression as written ("e.Node_FindPath"), the argument's index
	// (0-based) and where that argument starts
	call_name:   string,
	argument:    int,
	arg_start:   buf.Position,
	// The position is inside a string literal (a call's string argument: Call_Argument with this set)
	in_string:   bool,
	// How many structs and procedures the position is nested in
	depth:       int,
}

@(private="file")
Frame_Kind :: enum {
	Struct,
	Enum,
	Union,
	Proc,
	// `if`, `for`, `when`... and other braces
	Block,
	// A compound literal's braces
	Literal,
	Call,
	// A procedure type's parameter list
	Params,
	// Grouping parentheses, `cast(...)`
	Paren,
	Index,
}

@(private="file")
Frame :: struct {
	kind:      Frame_Kind,
	name:      string,
	open:      buf.Position,
	args:      int,
	arg_start: buf.Position,
}

// A recent token, for deciding what an opening bracket opens
@(private="file")
Recent :: struct {
	text: string,
	kind: syn.TokenKind,
}

/*
The syntactic context of a buffer position (see Syntax_Context).

Inputs:
- pos: The position (clamped to the buffer)
- allocator: For the names

Example:
	ctx := editor_syntax_context_at(ed, buf.Position{3, 4}, context.temp_allocator)
	if ctx.kind == .Struct_Body do fmt.println("inside", ctx.name)
*/
editor_syntax_context_at :: proc(ed: ^Editor, pos: buf.Position, allocator := context.temp_allocator) -> Syntax_Context {
	return syntax_context_of(&ed.buf, ed.language, pos, allocator)
}

// The work of editor_syntax_context_at, on any buffer and language
syntax_context_of :: proc(b: ^buf.Buffer, language: syn.Language, pos: buf.Position, allocator := context.temp_allocator) -> Syntax_Context {
	pos := buf.buffer_clamp_position(b, pos)
	out := Syntax_Context{pos = pos}
	if language.tokenize == nil do return out

	frames := make([dynamic]Frame, context.temp_allocator)
	recent := make([dynamic]Recent, context.temp_allocator)
	// A `struct` / `enum` / `union` / `proc` keyword waiting for its `{`, its name, and the frame
	// depth it was seen at
	pending: Maybe(Frame_Kind)
	pending_name := ""
	pending_depth := 0
	// An `if` / `for` / `switch` / `when` / `else` / `defer` whose `{` opens a block (not a
	// literal: `if ok {`), and its frame depth
	control := false
	control_depth := 0

	push_recent :: proc(recent: ^[dynamic]Recent, r: Recent) {
		if len(recent) >= 16 do ordered_remove(recent, 0)
		append(recent, r)
	}
	// The name declared before `::` (or assigned with `=` / `:=`): `Hero :: struct`, `ready = proc`
	declared_name :: proc(recent: []Recent) -> string {
		// recent ends with the keyword
		i := len(recent) - 2
		if i < 1 do return ""
		op := recent[i].text
		if op != "::" && op != "=" && op != ":=" && op != ":" do return ""
		name := recent[i - 1]
		if name.kind == .Operator || name.kind == .Punctuation do return ""
		return name.text
	}
	// The called expression before `(`: `name`, `pkg.name`, `a.b.c`
	call_name :: proc(recent: []Recent) -> (string, bool) {
		n := len(recent)
		if n == 0 do return "", false
		last := recent[n - 1]
		#partial switch last.kind {
		case .Identifier, .Function, .Builtin, .Type, .Property, .Constant:
		case: return "", false
		}
		start := n - 1
		for start >= 2 && recent[start - 1].text == "." {
			prev := recent[start - 2]
			#partial switch prev.kind {
			case .Identifier, .Function, .Type, .Property, .Constant:
				start -= 2
				continue
			}
			break
		}
		total := 0
		for r in recent[start:] do total += len(r.text)
		b := strings.builder_make(0, total, context.temp_allocator)
		for r in recent[start:] do strings.write_string(&b, r.text)
		return strings.to_string(b), true
	}

	state := syn.LINE_STATE_NORMAL
	done := false
	for ln := 0; ln <= pos.line && !done; ln += 1 {
		line := buf.buffer_line_str(b, ln)
		tokens, next := language.tokenize(line, state, context.temp_allocator)
		state = next
		for tok in tokens {
			at_line := ln == pos.line
			// The position inside (or right at the end of an unclosed) string or comment
			// (At the end of a line comment is still in it; after a block comment's `*/` isn't)
			line_comment_end := at_line && tok.end == pos.col && tok.kind == .Comment && tok.start < pos.col && strings.has_prefix(line[tok.start:], "//")
			if at_line && tok.start < pos.col && pos.col < tok.end || line_comment_end {
				if tok.kind == .Comment {
					out.kind = .Comment
					done = true
					break
				}
				if tok.kind == .String {
					out.in_string = true
					done = true
					break
				}
			}
			if at_line && tok.start >= pos.col {
				done = true
				break
			}
			text := line[tok.start:tok.end]
			#partial switch tok.kind {
			case .Comment:
				continue
			case .String:
				push_recent(&recent, {text, tok.kind})
				continue
			case .Punctuation, .Operator:
				// One character at a time: tokenizers may group `({` or `::`
				i := 0
				for i < len(text) {
					ch := text[i]
					here := buf.Position{ln, tok.start + i}
					after := buf.Position{ln, tok.start + i + 1}
					if at_line && here.col >= pos.col do break
					switch ch {
					case '{':
						kind := Frame_Kind.Block
						name := ""
						if k, ok := pending.?; ok && pending_depth == len(frames) {
							kind, name = k, pending_name
							pending = nil
						} else if control && control_depth == len(frames) {
							kind = .Block
							control = false
						} else if len(recent) > 0 {
							last := recent[len(recent) - 1]
							#partial switch last.kind {
							case .Identifier, .Type, .Property, .Constant, .Builtin:
								kind = .Literal
							case .Keyword:
								kind = last.text == "return" ? .Literal : .Block
							case:
								switch last.text {
								case ",", "=", ":=", "(", "{", "[", "::", ":", "return", "]":
									kind = .Literal
								}
							}
						}
						append(&frames, Frame{kind = kind, name = name, open = here})
					case '(':
						kind := Frame_Kind.Paren
						name := ""
						n := len(recent)
						if n > 0 && recent[n - 1].text == "proc" || n > 1 && recent[n - 1].kind == .String && recent[n - 2].text == "proc" {
							// `proc(`, `proc "contextless" (`
							kind = .Params
						} else if n, ok := call_name(recent[:]); ok {
							kind, name = .Call, n
						} else if len(recent) > 0 && (recent[len(recent) - 1].text == ")" || recent[len(recent) - 1].text == "]") {
							kind = .Call
						}
						append(&frames, Frame{kind = kind, name = name, open = here, arg_start = after})
					case '[':
						append(&frames, Frame{kind = .Index, open = here})
					case '}', ')', ']':
						want: bit_set[Frame_Kind] = ch == '}' ? {.Struct, .Enum, .Union, .Proc, .Block, .Literal} : ch == ')' ? {.Call, .Params, .Paren} : {.Index}
						for len(frames) > 0 {
							f := pop(&frames)
							if f.kind in want do break
						}
						if ch == '}' && len(frames) < pending_depth do pending = nil
						if ch == '}' && len(frames) <= control_depth do control = false
					case ',':
						if len(frames) > 0 && frames[len(frames) - 1].kind == .Call {
							frames[len(frames) - 1].args += 1
							frames[len(frames) - 1].arg_start = after
						}
						if len(frames) == pending_depth do pending = nil
					case ';':
						if len(frames) == pending_depth do pending = nil
						if len(frames) == control_depth do control = false
					}
					// `::`, `:=`, `->` stay whole in `recent`
					if i + 1 < len(text) && (text[i:i + 2] == "::" || text[i:i + 2] == ":=" || text[i:i + 2] == "->") {
						push_recent(&recent, {text[i:i + 2], tok.kind})
						i += 2
						continue
					}
					push_recent(&recent, {text[i:i + 1], tok.kind})
					i += 1
				}
				continue
			case .Keyword:
				switch text {
				case "struct":
					push_recent(&recent, {text, tok.kind})
					pending, pending_name, pending_depth = .Struct, declared_name(recent[:]), len(frames)
					continue
				case "enum":
					push_recent(&recent, {text, tok.kind})
					pending, pending_name, pending_depth = .Enum, declared_name(recent[:]), len(frames)
					continue
				case "union":
					push_recent(&recent, {text, tok.kind})
					pending, pending_name, pending_depth = .Union, declared_name(recent[:]), len(frames)
					continue
				case "proc":
					push_recent(&recent, {text, tok.kind})
					pending, pending_name, pending_depth = .Proc, declared_name(recent[:]), len(frames)
					continue
				case "if", "for", "switch", "when", "else", "defer":
					control, control_depth = true, len(frames)
				}
			}
			push_recent(&recent, {text, tok.kind})
		}
	}

	// The innermost frame that decides the kind
	if out.kind != .Comment {
		out.kind = .Top_Level
		decided := false
		for i := len(frames) - 1; i >= 0; i -= 1 {
			f := frames[i]
			switch f.kind {
			case .Struct, .Enum, .Union:
				if !decided {
					out.kind = f.kind == .Struct ? .Struct_Body : f.kind == .Enum ? .Enum_Body : .Union_Body
					out.name = strings.clone(f.name, allocator)
					out.open = f.open
					out.close = matching_close(b, language, f.open)
					decided = true
				}
				out.depth += 1
			case .Proc:
				if !out.in_proc {
					out.in_proc = true
					out.proc_name = strings.clone(f.name, allocator)
				}
				if !decided {
					out.kind = .Proc_Body
					out.open = f.open
					decided = true
				}
				out.depth += 1
			case .Call:
				if !decided {
					out.kind = .Call_Argument
					out.call_name = strings.clone(f.name, allocator)
					out.argument = f.args
					out.arg_start = f.arg_start
					out.open = f.open
					decided = true
				}
			case .Block, .Literal, .Paren, .Index, .Params:
			}
		}
	} else {
		for i := len(frames) - 1; i >= 0; i -= 1 {
			if frames[i].kind == .Proc {
				out.in_proc = true
				out.proc_name = strings.clone(frames[i].name, allocator)
				break
			}
		}
	}
	return out
}

// The `}` matching the `{` at `open` (the buffer's end when it isn't closed)
@(private="file")
matching_close :: proc(b: ^buf.Buffer, language: syn.Language, open: buf.Position) -> buf.Position {
	depth := 0
	state := syn.LINE_STATE_NORMAL
	// The tokenizer's state at the opening line: re-derived from the start (block comments)
	for ln in 0 ..< open.line {
		tokens, next := language.tokenize(buf.buffer_line_str(b, ln), state, context.temp_allocator)
		delete(tokens, context.temp_allocator)
		state = next
	}
	count := buf.buffer_line_count(b)
	for ln in open.line ..< count {
		line := buf.buffer_line_str(b, ln)
		tokens, next := language.tokenize(line, state, context.temp_allocator)
		state = next
		for tok in tokens {
			if tok.kind == .String || tok.kind == .Comment do continue
			for i in tok.start ..< tok.end {
				if ln == open.line && i < open.col do continue
				switch line[i] {
				case '{': depth += 1
				case '}':
					depth -= 1
					if depth == 0 do return {ln, i}
				}
			}
		}
	}
	return buf.buffer_end_position(b)
}
