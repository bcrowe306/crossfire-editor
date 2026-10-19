package editor

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
Version control: the project under Git, through the `git` program (the bottom panel's Git tab,
view_git.odin).

- **What the tab shows** is a `GitSnapshot`: whether git is installed, whether the project is in
  a repository, its branch (and how far ahead of or behind its upstream), the changed files in
  the project folder (staged or not), the last commits, the branches and remotes. It's read on
  a worker thread (`Git_ReadSnapshot`) when the tab is shown, after a save, after every git
  command, on Refresh, and when another project opens.
- **A project inside another repository** counts as in it (its folder's changes only, paths
  relative to the project), unless that repository ignores the folder: then it isn't under
  version control, and Initialize makes it its own repository.
- **Commands** (`GitOp`) run on a worker thread, one at a time (`GitState.busy`), with git's
  prompts off (`GIT_TERMINAL_PROMPT=0`, ssh in batch mode): a push needing a password fails
  with git's message instead of waiting for input nobody can type. Their output goes to the
  Console. The project is saved first; after a pull or a branch switch, which change files, it's
  opened again from disk.
- **Initialize** runs `git init -b main` and writes a `.gitignore` (when there's none) leaving
  out exported games, build output, project archives and OS clutter (`GITIGNORE_DEFAULT`).
- **Commit** commits what's staged; with nothing staged, every change in the project folder
  (like VS Code's smart commit). Git needs a name and email for commits (`git config --global
  user.name "..."`, `user.email`): its error says so.

Later: diffs of a change, discarding changes, merge conflicts, Git LFS for large assets.
*/

// The .gitignore Initialize writes
GITIGNORE_DEFAULT :: `# Made by odin_sdl_editor: what a project's repository leaves out
# Exported games (Project Settings > Export)
export/
# Build output
build/
# Project archives (File > Export Project Archive)
*.odinsdl
*.partial
# OS clutter
.DS_Store
Thumbs.db
desktop.ini
`

// What the project's version control is
GitAvailability :: enum {
	// Not read yet
	Unknown,
	// No git program
	Missing,
	// The project isn't in a repository (or the one it's in ignores it)
	Not_Repo,
	Repo,
}

// A changed file: git's two status letters (porcelain v1), for the index and the work tree
GitChange :: struct {
	// Relative to the project folder, "/"-separated
	path: string,
	// ' ' unchanged, 'M' modified, 'A' added, 'D' deleted, 'R' renamed, '?' untracked...
	staged, unstaged: u8,
}

// A commit in the history
GitCommit :: struct {
	hash, subject, author, date: string,
}

/*
The project's version control as last read. Its strings live in its own arena: replacing a
snapshot frees it all (GitSnapshot_Destroy).
*/
GitSnapshot :: struct {
	arena: ^virtual.Arena,
	// The project folder it was read for (absolute)
	folder: string,
	availability: GitAvailability,
	// The repository's top folder, and the project's folder in it ("" at the top; ends in "/")
	repoRoot, prefix: string,
	// "" when detached
	branch: string,
	// "origin/main", or "" without one
	upstream: string,
	ahead, behind: int,
	hasCommits: bool,
	changes: []GitChange,
	log: []GitCommit,
	branches: []string,
	remotes: []string,
	// A command that failed while reading it ("" normally)
	problem: string,
}

// Git commands the tab runs
GitOp :: enum {
	Init,
	// A file's change into or out of the next commit (GitOpRequest.arg: its path)
	Stage,
	Unstage,
	Stage_All,
	Unstage_All,
	// arg: the message
	Commit,
	// arg: the branch
	Switch_Branch,
	Create_Branch,
	Pull,
	Push,
	// arg: the URL (as "origin")
	Add_Remote,
}

// The Git tab's state: the snapshot shown, and what's being typed
GitState :: struct {
	snapshot: GitSnapshot,
	// A command is running / a snapshot is being read (and another was asked for meanwhile)
	busy: bool,
	refreshing, refreshAgain: bool,
	// Read it again (set by saves and by opening a project; the view asks: Git_View_Tick)
	stale: bool,
	// Owned
	message: string,
	newBranch: string,
	remoteURL: string,
}

// Read a new snapshot (Git_Refresh)
Git_Refresh_Requested :: struct {}
// A snapshot was read (heap: the handler keeps it, or destroys it)
Git_Snapshot_Read :: struct {
	snapshot: GitSnapshot,
}
// Run a command (from the tab's buttons)
Git_Op_Requested :: struct {
	op: GitOp,
	// The path, message, branch or URL (copied)
	arg: string,
}
// A command finished (output heap allocated: the handler frees it)
Git_Op_Finished :: struct {
	op: GitOp,
	ok: bool,
	output: string,
}
Git_Message_Changed :: distinct string
Git_New_Branch_Changed :: distinct string
Git_Remote_URL_Changed :: distinct string

// Frees a snapshot
GitSnapshot_Destroy :: proc(snapshot: ^GitSnapshot) {
	if snapshot.arena != nil {
		virtual.arena_destroy(snapshot.arena)
		free(snapshot.arena)
	}
	snapshot^ = {}
}

// Frees the Git tab's state
GitState_Destroy :: proc(git: ^GitState) {
	GitSnapshot_Destroy(&git.snapshot)
	delete(git.message)
	delete(git.newBranch)
	delete(git.remoteURL)
	git^ = {}
}

/*
Reads a project folder's version control: runs git status, log, branch and remote there.

Inputs:
- folder: The project folder

Returns:
- The snapshot (its own arena; GitSnapshot_Destroy frees it)
*/
Git_ReadSnapshot :: proc(folder: string) -> GitSnapshot {
	snapshot := GitSnapshot{arena = new(virtual.Arena)}
	if err := virtual.arena_init_growing(snapshot.arena); err != nil {
		free(snapshot.arena)
		return {availability = .Missing, problem = "out of memory"}
	}
	context.allocator = virtual.arena_allocator(snapshot.arena)
	snapshot.folder = strings.clone(folder)
	if _, ok := Script_FindEditorProgram("git"); !ok {
		snapshot.availability = .Missing
		return snapshot
	}
	top, topOk := gitRun(folder, {"git", "rev-parse", "--show-toplevel", "--show-prefix"})
	if !topOk {
		snapshot.availability = .Not_Repo
		return snapshot
	}
	lines := strings.split_lines(strings.trim_right(top, "\r\n"))
	snapshot.repoRoot = len(lines) > 0 ? strings.trim_space(lines[0]) : ""
	snapshot.prefix = len(lines) > 1 ? strings.trim_space(lines[1]) : ""
	// In a repository that ignores this folder (a project in another project's build/): not
	// under version control, as far as the project goes
	if snapshot.prefix != "" {
		if _, ignored := gitRun(snapshot.repoRoot, {"git", "check-ignore", "-q", "--", strings.trim_right(snapshot.prefix, "/")}); ignored {
			snapshot.availability = .Not_Repo
			return snapshot
		}
	}
	snapshot.availability = .Repo
	_, snapshot.hasCommits = gitRun(folder, {"git", "rev-parse", "-q", "--verify", "HEAD"})

	status, statusOk := gitRun(folder, {"git", "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--", "."})
	if !statusOk {
		snapshot.problem = strings.clone(strings.trim_space(status))
		return snapshot
	}
	parseGitStatus(&snapshot, status)

	if snapshot.hasCommits {
		log, _ := gitRun(folder, {"git", "log", "-n", "50", "--pretty=format:%h%x1f%s%x1f%an%x1f%ar%x1e", "--", "."})
		commits := make([dynamic]GitCommit)
		for record in strings.split(log, "\x1e") {
			fields := strings.split(strings.trim_left(record, "\r\n"), "\x1f")
			if len(fields) < 4 do continue
			append(&commits, GitCommit{fields[0], fields[1], fields[2], fields[3]})
		}
		snapshot.log = commits[:]
	}
	branches, _ := gitRun(folder, {"git", "branch", "--format=%(refname:short)"})
	snapshot.branches = nonEmptyLines(branches)
	remotes, _ := gitRun(folder, {"git", "remote"})
	snapshot.remotes = nonEmptyLines(remotes)
	return snapshot
}

/*
The git commands an operation runs, in order (each stops the rest when it fails).

Inputs:
- op: The operation
- arg: Its path, message, branch or URL
- snapshot: The repository as last read (whether it has commits, the branch, remotes, what's staged)

Returns:
- The commands (temp allocated)
*/
Git_Commands :: proc(op: GitOp, arg: string, snapshot: ^GitSnapshot) -> [][]string {
	commands := make([dynamic][]string, context.temp_allocator)
	add :: proc(commands: ^[dynamic][]string, args: ..string) {
		append(commands, slice_clone(args))
	}
	switch op {
	case .Init:
		add(&commands, "git", "init", "-q", "-b", "main")
	case .Stage:
		add(&commands, "git", "add", "-A", "--", arg)
	case .Unstage:
		if snapshot.hasCommits do add(&commands, "git", "reset", "-q", "HEAD", "--", arg)
		else do add(&commands, "git", "rm", "-q", "-r", "--cached", "--", arg)
	case .Stage_All:
		add(&commands, "git", "add", "-A", "--", ".")
	case .Unstage_All:
		if snapshot.hasCommits do add(&commands, "git", "reset", "-q", "HEAD", "--", ".")
		else do add(&commands, "git", "rm", "-q", "-r", "--cached", "--", ".")
	case .Commit:
		staged := false
		for change in snapshot.changes do if change.staged != ' ' && change.staged != '?' do staged = true
		if !staged do add(&commands, "git", "add", "-A", "--", ".")
		add(&commands, "git", "commit", "-q", "-m", arg)
	case .Switch_Branch:
		add(&commands, "git", "switch", "-q", arg)
	case .Create_Branch:
		add(&commands, "git", "switch", "-q", "-c", arg)
	case .Pull:
		add(&commands, "git", "pull", "--ff-only")
	case .Push:
		if snapshot.upstream != "" {
			add(&commands, "git", "push")
		} else {
			remote := len(snapshot.remotes) > 0 ? snapshot.remotes[0] : "origin"
			add(&commands, "git", "push", "-u", remote, snapshot.branch)
		}
	case .Add_Remote:
		add(&commands, "git", "remote", "add", "origin", arg)
	}
	return commands[:]
}

// Whether an operation changes the project's files (the project is opened again after it)
Git_ChangesFiles :: proc(op: GitOp) -> bool {
	return op == .Pull || op == .Switch_Branch
}

// Why an operation can't run now, or ""
Git_OpProblem :: proc(op: GitOp, arg: string, snapshot: ^GitSnapshot) -> string {
	#partial switch op {
	case .Commit:
		if strings.trim_space(arg) == "" do return "write a commit message first"
		if len(snapshot.changes) == 0 do return "there's nothing to commit"
	case .Switch_Branch, .Create_Branch:
		name := strings.trim_space(arg)
		if name == "" do return "give the branch a name"
		if strings.contains_any(name, " ~^:?*[\\") || strings.has_prefix(name, "-") do return fmt.tprintf("'%s' isn't a valid branch name", name)
	case .Push, .Pull:
		if len(snapshot.remotes) == 0 do return "the repository has no remote: add one first"
		if op == .Push && snapshot.branch == "" do return "not on a branch"
	case .Add_Remote:
		if strings.trim_space(arg) == "" do return "type the remote's URL"
	}
	return ""
}

/*
Asks for a snapshot when the tab's is unknown or stale (called by the view every frame, like the
scripts' background build: saves and project switches can't return commands).
*/
Git_View_Tick :: proc(state: ^State, ctx: ^skald.Ctx(Msg)) {
	git := &state.git
	if (git.snapshot.availability == .Unknown || git.stale) && !git.refreshing {
		skald.send(ctx, Msg(Git_Refresh_Requested{}))
	}
}

// Reads a new snapshot on a worker thread (once at a time: asked again meanwhile, it reads again after)
Git_Refresh :: proc(state: ^State) -> skald.Command(Msg) {
	git := &state.git
	if git.refreshing {
		git.refreshAgain = true
		return {}
	}
	git.refreshing = true
	git.stale = false
	return skald.cmd_thread(Msg, strings.clone(absolutePath(state.project.rootPath)), proc(folder: string) -> Msg {
		defer delete(folder)
		return Git_Snapshot_Read{Git_ReadSnapshot(folder)}
	})
}

/*
Handles the Git tab's messages.

Returns:
- A command to run, and whether `m` was one
*/
Git_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	git := &state.git
	#partial switch v in m {
	case Git_Refresh_Requested:
		return Git_Refresh(state), true
	case Git_Snapshot_Read:
		git.refreshing = false
		snapshot := v.snapshot
		// Read for a project that's been replaced since: dropped, and read again
		if snapshot.folder != absolutePath(state.project.rootPath) {
			GitSnapshot_Destroy(&snapshot)
			return Git_Refresh(state), true
		}
		GitSnapshot_Destroy(&git.snapshot)
		git.snapshot = snapshot
		if git.refreshAgain {
			git.refreshAgain = false
			return Git_Refresh(state), true
		}
	case Git_Message_Changed:
		delete(git.message)
		git.message = strings.clone(string(v))
	case Git_New_Branch_Changed:
		delete(git.newBranch)
		git.newBranch = strings.clone(string(v))
	case Git_Remote_URL_Changed:
		delete(git.remoteURL)
		git.remoteURL = strings.clone(string(v))
	case Git_Op_Requested:
		if git.busy {
			logLine(state, .Warning, strings.clone("Git: a command is still running"))
			return {}, true
		}
		arg := strings.trim_space(v.arg)
		if problem := Git_OpProblem(v.op, arg, &git.snapshot); problem != "" {
			logLine(state, .Warning, fmt.aprintf("Git: %s", problem))
			return {}, true
		}
		// Git works on what's on disk: save first
		if v.op != .Add_Remote && Project_IsModified(state) && !Session_Save(state) do return {}, true
		git.busy = true
		return gitStart(state, v.op, arg), true
	case Git_Op_Finished:
		git.busy = false
		defer delete(v.output)
		label := gitOpLabel(v.op)
		output := strings.trim_space(v.output)
		if !v.ok {
			logLine(state, .Error, fmt.aprintf("Git: %s failed: %s", label, output))
			if strings.contains(output, "Please tell me who you are") || strings.contains(output, "Author identity unknown") {
				logLine(state, .Info, strings.clone("Git needs your name and email for commits: run git config --global user.name \"Your Name\" and git config --global user.email you@example.com"))
			}
		} else {
			logLine(state, .Info, output == "" ? fmt.aprintf("Git: %s", label) : fmt.aprintf("Git: %s: %s", label, output))
			if v.op == .Commit {
				delete(git.message)
				git.message = strings.clone("")
			}
			if v.op == .Create_Branch {
				delete(git.newBranch)
				git.newBranch = strings.clone("")
			}
			if v.op == .Add_Remote {
				delete(git.remoteURL)
				git.remoteURL = strings.clone("")
			}
			if Git_ChangesFiles(v.op) do Session_OpenProject(state, strings.clone(state.project.rootPath, context.temp_allocator))
		}
		return Git_Refresh(state), true
	case:
		return {}, false
	}
	return {}, true
}

// A command's job for the worker: the folder, its commands (owned), whether to write .gitignore
@(private="file")
GitJob :: struct {
	op: GitOp,
	folder: string,
	commands: [][]string,
}

@(private="file")
gitStart :: proc(state: ^State, op: GitOp, arg: string) -> skald.Command(Msg) {
	commands := Git_Commands(op, arg, &state.git.snapshot)
	owned := make([][]string, len(commands))
	for command, i in commands {
		owned[i] = make([]string, len(command))
		for part, j in command do owned[i][j] = strings.clone(part)
	}
	logLine(state, .Info, fmt.aprintf("Git: %s...", gitOpLabel(op)))
	job := GitJob{op = op, folder = strings.clone(absolutePath(state.project.rootPath)), commands = owned}
	return skald.cmd_thread(Msg, job, proc(job: GitJob) -> Msg {
		defer {
			for command in job.commands {
				for part in command do delete(part)
				delete(command)
			}
			delete(job.commands)
			delete(job.folder)
		}
		output, ok := Git_RunCommands(job.folder, job.op, job.commands)
		return Git_Op_Finished{op = job.op, ok = ok, output = output}
	})
}

/*
Runs an operation's commands (Git_Commands) in a folder, stopping at the first that fails; after
Init, writes the .gitignore when there's none. Blocks: the tab runs it on a worker thread.

Returns:
- What git printed (allocated with `allocator`), and whether every command worked
*/
Git_RunCommands :: proc(folder: string, op: GitOp, commands: [][]string, allocator := context.allocator) -> (string, bool) {
	output := strings.builder_make(allocator)
	for command in commands {
		text, ok := gitRun(folder, command, context.temp_allocator)
		if strings.builder_len(output) > 0 && strings.trim_space(text) != "" do strings.write_string(&output, "\n")
		strings.write_string(&output, strings.trim_space(text))
		if !ok do return strings.to_string(output), false
	}
	if op == .Init {
		ignore := strings.concatenate({folder, "/.gitignore"}, context.temp_allocator)
		if !os.exists(ignore) do _ = os.write_entire_file(ignore, transmute([]byte)string(GITIGNORE_DEFAULT))
	}
	return strings.to_string(output), true
}

// What an operation is called in the Console
@(private="file")
gitOpLabel :: proc(op: GitOp) -> string {
	switch op {
	case .Init:          return "initialize the repository"
	case .Stage:         return "stage"
	case .Unstage:       return "unstage"
	case .Stage_All:     return "stage all"
	case .Unstage_All:   return "unstage all"
	case .Commit:        return "commit"
	case .Switch_Branch: return "switch branch"
	case .Create_Branch: return "create branch"
	case .Pull:          return "pull"
	case .Push:          return "push"
	case .Add_Remote:    return "add remote"
	}
	return ""
}

/*
Runs git in a folder, prompts off, and gives what it printed (stdout, then stderr) and whether it
worked. Allocates with context.allocator.
*/
@(private="file")
gitRun :: proc(folder: string, command: []string, allocator := context.allocator) -> (string, bool) {
	env, _ := os.environ(context.temp_allocator)
	full := make([dynamic]string, 0, len(env) + 3, context.temp_allocator)
	sshSet := false
	for entry in env {
		if strings.has_prefix(entry, "GIT_SSH_COMMAND=") do sshSet = true
		append(&full, entry)
	}
	append(&full, "GIT_TERMINAL_PROMPT=0", "GIT_MERGE_AUTOEDIT=no")
	if !sshSet do append(&full, "GIT_SSH_COMMAND=ssh -o BatchMode=yes")
	state, stdout, stderr, err := os.process_exec({working_dir = folder, command = command, env = full[:]}, context.temp_allocator)
	if err != nil do return fmt.aprintf("couldn't run git: %v", err, allocator = allocator), false
	if !state.success {
		text := strings.trim_space(string(stderr))
		if text == "" do text = strings.trim_space(string(stdout))
		return strings.clone(text, allocator), false
	}
	return strings.clone(string(stdout), allocator), true
}

// git status --porcelain=v1 -z --branch: the branch line, then "XY path" records ("R" and "C"
// are followed by the old path)
@(private="file")
parseGitStatus :: proc(snapshot: ^GitSnapshot, status: string) {
	records := strings.split(status, "\x00")
	changes := make([dynamic]GitChange)
	for i := 0; i < len(records); i += 1 {
		record := records[i]
		if strings.has_prefix(record, "## ") {
			parseGitBranch(snapshot, record[3:])
			continue
		}
		if len(record) < 4 do continue
		path := record[3:]
		if record[0] == 'R' || record[0] == 'C' do i += 1
		// Relative to the project folder (porcelain paths are relative to the repository)
		if snapshot.prefix != "" && strings.has_prefix(path, snapshot.prefix) do path = path[len(snapshot.prefix):]
		append(&changes, GitChange{path = path, staged = record[0], unstaged = record[1]})
	}
	snapshot.changes = changes[:]
}

// "main...origin/main [ahead 1, behind 2]", "No commits yet on main", "HEAD (no branch)"
@(private="file")
parseGitBranch :: proc(snapshot: ^GitSnapshot, text: string) {
	line := text
	if strings.has_prefix(line, "No commits yet on ") {
		snapshot.branch = line[len("No commits yet on "):]
		return
	}
	if strings.has_prefix(line, "HEAD (no branch)") do return
	counts := ""
	if open := strings.index(line, " ["); open >= 0 {
		counts = strings.trim_suffix(line[open + 2:], "]")
		line = line[:open]
	}
	if dots := strings.index(line, "..."); dots >= 0 {
		snapshot.branch = line[:dots]
		snapshot.upstream = line[dots + 3:]
	} else {
		snapshot.branch = line
	}
	for part in strings.split(counts, ", ", context.temp_allocator) {
		if strings.has_prefix(part, "ahead ") do snapshot.ahead, _ = strconv.parse_int(part[len("ahead "):])
		if strings.has_prefix(part, "behind ") do snapshot.behind, _ = strconv.parse_int(part[len("behind "):])
	}
}

@(private="file")
nonEmptyLines :: proc(text: string) -> []string {
	lines := make([dynamic]string)
	for line in strings.split_lines(text) {
		trimmed := strings.trim_space(line)
		if trimmed != "" do append(&lines, trimmed)
	}
	return lines[:]
}

@(private="file")
slice_clone :: proc(args: []string) -> []string {
	result := make([]string, len(args), context.temp_allocator)
	copy(result, args)
	return result
}
