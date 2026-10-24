package crossfire_editor

import e "engine:."

/*
Runs a program, waits for it, and gives what it printed: the engine's `e.Process_Exec`
(its process_exec.odin), which is `os.process_exec` without its lost output.

`os.process_exec` took a program that wrote and exited between Linux pipe poll's two looks for
one that printed nothing: under heavy CPU load the Git tab read an empty `git status` (no branch:
a push then said "invalid refspec"). The engine's helper reads after a hang-up until the end.
Every program the editor runs and reads goes through this name; it was the editor's own copy
until the engine had it (2026-10-23).

Inputs:
- desc: The program, as for os.process_exec (its stdout and stderr must not be set)
- allocator: For stdout and stderr

Returns:
- The process's state, its output and errors (allocated with `allocator`), and whether it could
  run
*/
Process_Exec :: e.Process_Exec
