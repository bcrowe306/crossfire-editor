package code_editor

import buf "../buffer"
import "core:os"
import "core:testing"
import "core:time"

@(private)
pump_for :: proc(ed: ^Editor, d: time.Duration, until: proc(ed: ^Editor) -> bool = nil) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		editor_update(ed)
		if until != nil && until(ed) {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
}

@(test)
test_lsp_crash_loop_gives_up_and_editor_keeps_working :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)

		// A "server" that crashes immediately, every time.
		ok := editor_attach_lsp(&ed, []string{"/bin/sh", "-c", "exit 1"}, "/tmp")
		testing.expect(t, ok, "attach spawns the server")

		pump_for(&ed, 5 * time.Second, proc(ed: ^Editor) -> bool {return editor_lsp_status(ed) == .Failed})
		testing.expect_value(t, editor_lsp_status(&ed), Lsp_Status.Failed)
		testing.expect_value(t, ed.lsp_supervisor.total_crashes, LSP_MAX_RESTARTS + 1)
		testing.expect(t, !ed.lsp_enabled, "LSP paths disabled after giving up")

		// The editor itself is unaffected.
		editor_inject_text(&ed, "still alive")
		editor_update(&ed)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "still alive")
		editor_request_completion(&ed) // no-op, must not crash
	})
}

@(test)
test_lsp_killed_server_is_restarted :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)

		ok := editor_attach_lsp(&ed, []string{"/bin/sh", "-c", "sleep 30"}, "/tmp")
		testing.expect(t, ok, "attach spawns the server")
		first_pid := ed.lsp.process.pid
		editor_update(&ed)
		testing.expect_value(t, editor_lsp_status(&ed), Lsp_Status.Starting)

		// Simulate a crash from outside.
		_ = os.process_kill(ed.lsp.process)
		pump_for(&ed, 2 * time.Second, proc(ed: ^Editor) -> bool {return editor_lsp_status(ed) == .Restarting})
		testing.expect_value(t, editor_lsp_status(&ed), Lsp_Status.Restarting)

		pump_for(&ed, 2 * time.Second, proc(ed: ^Editor) -> bool {return ed.lsp.has_process})
		testing.expect_value(t, editor_lsp_status(&ed), Lsp_Status.Starting)
		testing.expect(t, ed.lsp.process.pid != first_pid, "a new server process was spawned")
		testing.expect_value(t, ed.lsp_supervisor.restarts, 1)
		editor_detach_lsp(&ed)
	})
}
