package crossfire_editor

@(require) import "core:fmt"
@(require) import "core:reflect"
@(require) import e "engine:."
import "gui:skald"

// Profiling with Spall (`-define:SPALL=true`, `task profile`): one trace of the editor, Skald and
// the engine. Skald owns it (its prof.odin): the editor starts it before `skald.run` and hands it
// to the engine (`e.Trace_Share`), so the engine's scopes (the viewport's scene drawing) nest in
// the same per-thread buffers. Scopes here: each message `update` handles (by its type) and the
// panels' view procedures (`browserView`, `inspectorView`, `viewportView`, `Preview_Render`...).
// Without SPALL all of it compiles to nothing.

/*
Starts the trace (the `SPALL_TRACE` environment variable names the file; see Skald's prof.odin)
and shares it with the engine. Does nothing without SPALL.
*/
Profiling_Start :: proc() {
	when skald.SPALL {
		if skald.prof_start() {
			e.Trace_Share(skald.prof_context(), proc "contextless" () -> rawptr {
				return skald.prof_thread_buffer()
			})
		}
	}
}

/*
Stops the trace: the engine stops recording into it, then every buffer is written. Call it after
`skald.run` returns and before the process exits (`os.exit` runs no defers).
*/
Profiling_Stop :: proc() {
	when skald.SPALL {
		e.Trace_Share(nil, nil)
		skald.prof_stop()
	}
}

// The name of `update`'s span for a message: its type (temp allocated); "" without SPALL
@(private="file")
messageTraceName :: proc(m: Msg) -> string {
	when skald.SPALL {
		id := reflect.union_variant_typeid(m)
		if id == Action do return fmt.tprintf("Action.%v", m.(Action))
		return fmt.tprint(id)
	} else {
		return ""
	}
}

// A span for `update`'s handling of a message, named by its type
@(deferred_none = skald.prof_end)
Profiling_Message :: proc(m: Msg) {
	when skald.SPALL do skald.prof_begin(messageTraceName(m))
}
