package crossfire_editor

import "base:runtime"
import "core:os"
import "core:time"

/*
Runs a program, waits for it, and gives what it printed: `os.process_exec`, without its lost
output.

`os.process_exec` stops reading a pipe when `poll` says the other end hung up and nothing is
waiting (`os.pipe_has_data` returns `.Broken_Pipe`). Linux's pipe poll reads "is there data" and
"are there writers" one after the other without a lock, so a program that writes and exits
between the two looks hung up with nothing written: its output is lost and it seems to have
printed nothing. Under heavy CPU load it happened about once in 2000 runs of `printf`, and the
Git tab read an empty `git status` (no branch: a push then said "invalid refspec";
vcs_test.odin's `git_init_stage_commit_branch_push` failed). Here a hang-up is followed by a
read, which returns what's left and then the end. It also waits a millisecond when neither pipe
had anything, instead of spinning.

Inputs:
- desc: The program, as for os.process_exec (its stdout and stderr must not be set)
- allocator: For stdout and stderr

Returns:
- The process's state, its output and errors (allocated with `allocator`), and whether it could
  run
*/
Process_Exec :: proc(desc: os.Process_Desc, allocator: runtime.Allocator) -> (state: os.Process_State, stdout, stderr: []byte, err: os.Error) {
	assert(desc.stdout == nil && desc.stderr == nil, "Process_Exec captures stdout and stderr")
	stdoutR, stdoutW := os.pipe() or_return
	defer os.close(stdoutR)
	stderrR, stderrW, pipeErr := os.pipe()
	if pipeErr != nil {
		os.close(stdoutW)
		return state, nil, nil, pipeErr
	}
	defer os.close(stderrR)

	process: os.Process
	{
		// Our write ends close whatever happens: the reads see the end once the program's do
		defer os.close(stdoutW)
		defer os.close(stderrW)
		desc := desc
		desc.stdout = stdoutW
		desc.stderr = stderrW
		process = os.process_start(desc) or_return
	}

	out := make([dynamic]byte, allocator)
	errs := make([dynamic]byte, allocator)
	buffer: [4096]u8 = ---
	outDone, errDone := false, false
	// One pipe: true when something was read (or it ended)
	drain :: proc(r: ^os.File, into: ^[dynamic]byte, done: ^bool, buffer: []u8) -> (progressed: bool, err: os.Error) {
		has, pollErr := os.pipe_has_data(r)
		if pollErr != nil && pollErr != .Broken_Pipe do return false, pollErr
		// A hang-up may still have data behind it: read until the read says it's the end
		if !has && pollErr != .Broken_Pipe do return false, nil
		n, readErr := os.read(r, buffer)
		switch readErr {
		case nil:
			append(into, ..buffer[:n])
			return true, nil
		case .EOF, .Broken_Pipe:
			done^ = true
			return true, nil
		}
		return false, readErr
	}
	for err == nil && (!outDone || !errDone) {
		progressed := false
		if !outDone {
			p, e := drain(stdoutR, &out, &outDone, buffer[:])
			progressed ||= p
			err = e
		}
		if err == nil && !errDone {
			p, e := drain(stderrR, &errs, &errDone, buffer[:])
			progressed ||= p
			err = e
		}
		if !progressed && err == nil do time.sleep(time.Millisecond)
	}
	stdout, stderr = out[:], errs[:]
	if err != nil {
		state, _ = os.process_wait(process, timeout = 0)
		if !state.exited {
			_ = os.process_kill(process)
			state, _ = os.process_wait(process)
		}
		return
	}
	state, err = os.process_wait(process)
	return
}
