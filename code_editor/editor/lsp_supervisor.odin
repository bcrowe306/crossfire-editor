// LSP supervisor: keeps the editor alive and useful when the language
// server crashes. The server runs as a separate process precisely so that
// a crash in it (OLS asserts/panics on some inputs) can't take the editor
// down; this file adds the recovery half — detect the dead server, close
// popups that depended on it, restart it with exponential backoff, and
// re-open the current document. After too many crashes in a short window
// it gives up (status .Failed) instead of looping forever, and the editor
// keeps working as a plain text editor.
package code_editor

import lspc "../lsp"
import "core:strings"
import "core:time"

LSP_MAX_RESTARTS :: 3                  // ... within LSP_RESTART_WINDOW
LSP_RESTART_WINDOW :: 60 * time.Second
LSP_RESTART_BASE_DELAY :: 250 * time.Millisecond

Lsp_Status :: enum {
	Off,        // no server attached
	Starting,   // spawned, waiting for the initialize response
	Running,    // initialized
	Restarting, // crashed; a restart is scheduled
	Failed,     // crashed too often (or can't be spawned); given up
}

Lsp_Supervisor :: struct {
	command:       []string, // owned copy, for restarts
	root:          string,
	init_options:  string,
	restarts:      int,       // restarts within the current window
	window_start:  time.Tick,
	restart_at:    time.Tick,
	restart_due:   bool,
	total_crashes: int,
	failed:        bool,
}

@(private)
lsp_supervisor_begin :: proc(s: ^Lsp_Supervisor, command: []string, root: string, init_options := "") {
	lsp_supervisor_end(s)
	s.command = make([]string, len(command))
	for arg, i in command {
		s.command[i] = strings.clone(arg)
	}
	s.root = strings.clone(root)
	s.init_options = strings.clone(init_options)
	s.window_start = time.tick_now()
}

@(private)
lsp_supervisor_end :: proc(s: ^Lsp_Supervisor) {
	for arg in s.command {
		delete(arg)
	}
	delete(s.command)
	delete(s.root)
	delete(s.init_options)
	s^ = {}
}

// editor_lsp_status reports the language server's health.
editor_lsp_status :: proc(ed: ^Editor) -> Lsp_Status {
	s := &ed.lsp_supervisor
	switch {
	case s.failed: return .Failed
	case s.restart_due: return .Restarting
	case !ed.lsp_enabled: return .Off
	case ed.lsp.initialized: return .Running
	}
	return .Starting
}

// editor_supervise_lsp runs once per update: notices a dead server and
// performs scheduled restarts.
editor_supervise_lsp :: proc(ed: ^Editor) {
	s := &ed.lsp_supervisor
	if !ed.lsp.dead || len(s.command) == 0 {
		return
	}

	if !s.restart_due {
		// Just died. Anything that was waiting on it is stale.
		s.total_crashes += 1
		editor_close_completion(ed)
		editor_close_signature_help(ed)
		ed.lsp_doc_open = false

		if time.tick_since(s.window_start) > LSP_RESTART_WINDOW {
			s.window_start = time.tick_now()
			s.restarts = 0
		}
		if s.restarts >= LSP_MAX_RESTARTS {
			editor_lsp_give_up(ed)
			return
		}
		delay := LSP_RESTART_BASE_DELAY * time.Duration(1 << uint(s.restarts))
		s.restart_at = time.tick_add(time.tick_now(), delay)
		s.restart_due = true
		return
	}

	if time.tick_diff(s.restart_at, time.tick_now()) < 0 {
		return
	}
	s.restart_due = false
	s.restarts += 1

	// Fresh client; the old one only holds closed pipes now. If it can't
	// even spawn, that counts as another crash next update.
	editor_lsp_respawn(ed)
}

@(private)
editor_lsp_give_up :: proc(ed: ^Editor) {
	ed.lsp_supervisor.failed = true
	lspc.client_destroy(&ed.lsp)
	ed.lsp = {}
	// lsp_enabled = false turns every LSP path into a no-op; the editor
	// carries on as a plain text editor.
	ed.lsp_enabled = false
}
