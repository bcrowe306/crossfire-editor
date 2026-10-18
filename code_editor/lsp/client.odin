// Client spawns and drives the Odin Language Server (OLS) subprocess over
// stdio. `client_poll` is non-blocking (uses os.pipe_has_data) so it can be
// called once per editor frame/update without stalling the host's render
// loop. `client_feed_bytes` contains all the message-dispatch logic and is
// exposed separately so it can be unit tested with synthetic byte streams,
// without ever spawning a real `ols` process.
package lsp

import "core:c/libc"
import "core:mem"
import "core:os"
import "core:time"

RequestKind :: enum {
	Initialize,
	Completion,
	SignatureHelp,
	Hover,
	CodeAction,
	Definition,
	References,
	Other,
}

Client :: struct {
	process:    os.Process,
	has_process: bool,
	stdin:      ^os.File,
	stdout:     ^os.File,
	allocator:  mem.Allocator,

	next_id:      int,
	recv_buf:     [dynamic]u8,
	pending_kind: map[int]RequestKind,

	// Keyed by uri_key (decoded, symlink-resolved path).
	diagnostics:     map[string][dynamic]Diagnostic,
	// Bumped on every publishDiagnostics.
	diagnostics_seq: int,
	last_completion: [dynamic]CompletionItem,
	last_signatures: [dynamic]SignatureInformation,
	// Response-level activeSignature/activeParameter of the last
	// signatureHelp reply.
	active_signature: int,
	active_parameter: int,
	initialized:     bool,

	// Bumped every time a completion/signatureHelp response is stored
	// (including empty/null results), so a UI can tell "a new answer
	// arrived" apart from "still waiting" by comparing against the value
	// it last saw.
	completion_seq: int,
	signature_seq:  int,
	// Id of the most recent request of each kind. Responses to older
	// requests are dropped so a slow reply can't overwrite a newer one.
	latest_completion_id: int,
	latest_signature_id:  int,

	// Last textDocument/hover answer (markdown or plain), "" if none.
	last_hover:          string,
	last_hover_markdown: bool,
	hover_seq:           int,
	latest_hover_id:     int,

	// Last textDocument/definition or /references answer.
	last_locations:     [dynamic]Location,
	locations_kind:     RequestKind, // .Definition or .References
	location_seq:       int,
	latest_location_id: int,

	last_code_actions:     [dynamic]Code_Action,
	code_action_seq:       int,
	latest_code_action_id: int,

	// Set once the server process has gone away (crashed, killed, or
	// closed its pipes). The client never takes the host down with it:
	// writes to a dead server fail quietly and the host can inspect
	// `dead`/`exit_code` and restart (see editor's LSP supervisor).
	dead:      bool,
	exit_code: int,

	// textDocumentSync kind from the initialize result: 1 = full text,
	// 2 = incremental ranges (0 = none). Defaults to full until known.
	sync_kind: int,

	// isIncomplete of the last completion list: typing further should
	// re-query rather than only filter locally.
	completion_incomplete: bool,
	// initializationOptions JSON sent with `initialize` (owned; "" = null).
	init_options: string,
}

client_init :: proc(allocator := context.allocator) -> Client {
	return Client{
		allocator        = allocator,
		recv_buf         = make([dynamic]u8, allocator),
		pending_kind     = make(map[int]RequestKind, allocator),
		diagnostics      = make(map[string][dynamic]Diagnostic, allocator),
		last_completion  = make([dynamic]CompletionItem, allocator),
		last_signatures  = make([dynamic]SignatureInformation, allocator),
		last_code_actions = make([dynamic]Code_Action, allocator),
		last_locations   = make([dynamic]Location, allocator),
		sync_kind        = 1,
	}
}

client_destroy :: proc(c: ^Client) {
	if c.has_process {
		client_stop(c)
	}
	delete(c.recv_buf)
	delete(c.init_options, c.allocator)
	delete(c.pending_kind)
	for uri, list in c.diagnostics {
		free_diagnostics(c, list)
		delete(uri, c.allocator)
	}
	delete(c.diagnostics)
	client_clear_completion(c)
	delete(c.last_completion)
	client_clear_signatures(c)
	delete(c.last_signatures)
	client_clear_code_actions(c)
	delete(c.last_code_actions)
	delete(c.last_hover, c.allocator)
	client_clear_locations(c)
	delete(c.last_locations)
}

// client_start launches `command` (e.g. `{"ols"}`) as a child process and
// wires up its stdin/stdout as pipes. Returns false if the process could
// not be spawned (e.g. `ols` is not installed/built yet).
client_start :: proc(c: ^Client, command: []string, working_dir := "") -> bool {
	// Writing to the stdin pipe of a server that has died raises SIGPIPE,
	// whose default action kills *this* process. Ignore it so a crashed
	// server surfaces as a write error instead. (Process-wide, but
	// SIGPIPE-on-write is never what an interactive app wants.)
	when ODIN_OS != .Windows {
		libc.signal(13 /* SIGPIPE */, auto_cast libc.SIG_IGN)
	}

	in_r, in_w, err1 := os.pipe()
	if err1 != nil {
		return false
	}
	out_r, out_w, err2 := os.pipe()
	if err2 != nil {
		os.close(in_r)
		os.close(in_w)
		return false
	}

	desc := os.Process_Desc{
		command     = command,
		working_dir = working_dir,
		stdin       = in_r,
		stdout      = out_w,
	}
	process, perr := os.process_start(desc)
	// The child end of each pipe is only needed by the child; close our
	// copies once the process has (or hasn't) started.
	os.close(in_r)
	os.close(out_w)
	if perr != nil {
		os.close(in_w)
		os.close(out_r)
		return false
	}

	c.process = process
	c.has_process = true
	c.stdin = in_w
	c.stdout = out_r
	c.dead = false
	return true
}

// client_mark_dead tears down the pipes of a server that has exited (or
// stopped responding to writes), reaps the process, and drops all
// in-flight requests. Safe to call more than once.
client_mark_dead :: proc(c: ^Client) {
	if c.dead {
		return
	}
	c.dead = true
	c.initialized = false
	clear(&c.pending_kind)
	if c.stdin != nil {
		os.close(c.stdin)
		c.stdin = nil
	}
	if c.stdout != nil {
		os.close(c.stdout)
		c.stdout = nil
	}
	if c.has_process {
		// Still unreaped: make sure it's gone, then collect its status so
		// it doesn't linger as a zombie.
		_ = os.process_kill(c.process)
		state, err := os.process_wait(c.process, 500 * time.Millisecond)
		if err == nil && state.exited {
			c.exit_code = state.exit_code
		}
		c.has_process = false
	}
}

client_stop :: proc(c: ^Client) {
	if !c.has_process {
		return
	}
	if c.stdin != nil {
		os.close(c.stdin)
		c.stdin = nil
	}
	_ = os.process_kill(c.process)
	_, _ = os.process_wait(c.process)
	if c.stdout != nil {
		os.close(c.stdout)
		c.stdout = nil
	}
	c.has_process = false
}

client_next_id :: proc(c: ^Client) -> int {
	c.next_id += 1
	return c.next_id
}

client_send_raw :: proc(c: ^Client, framed: string) -> bool {
	if !c.has_process || c.stdin == nil {
		return false
	}
	_, err := os.write(c.stdin, transmute([]u8)framed)
	if err != nil {
		client_mark_dead(c)
		return false
	}
	return true
}

// client_poll drains any currently-available bytes from the subprocess's
// stdout (non-blocking) and dispatches any complete messages found. Safe to
// call every frame even if the process has no output ready.
client_poll :: proc(c: ^Client) {
	if !c.has_process || c.stdout == nil {
		return
	}
	for {
		has_data, err := os.pipe_has_data(c.stdout)
		if err != nil {
			// Broken_Pipe: the server closed stdout (exited/crashed).
			client_mark_dead(c)
			return
		}
		if !has_data {
			break
		}
		chunk: [4096]u8
		n, rerr := os.read(c.stdout, chunk[:])
		if n <= 0 {
			// Readable but zero bytes = EOF.
			client_mark_dead(c)
			return
		}
		client_feed_bytes(c, chunk[:n])
		if rerr != nil {
			client_mark_dead(c)
			return
		}
	}
	// Also catch a server that exited without closing its pipes yet
	// (e.g. a grandchild still holds them). Non-blocking; reaps the zombie.
	state, err := os.process_wait(c.process, 0)
	if err == nil && state.exited {
		// Already reaped: never signal this pid again (it may be reused).
		c.has_process = false
		c.exit_code = state.exit_code
		client_mark_dead(c)
	}
}
