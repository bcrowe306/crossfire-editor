package crossfire_editor

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Runs an operation as the Git tab would (synchronously), then reads the snapshot again
@(private="file")
gitDo :: proc(t: ^testing.T, folder: string, snapshot: ^GitSnapshot, op: GitOp, arg := "") -> bool {
	output, ok := Git_RunCommands(folder, op, Git_Commands(op, arg, snapshot), context.temp_allocator, Git_DiscardDeletes(op, arg, snapshot))
	testing.expectf(t, ok, "%v failed: %s", op, output)
	GitSnapshot_Destroy(snapshot)
	snapshot^ = Git_ReadSnapshot(folder)
	return ok
}

@(private="file")
findChange :: proc(snapshot: ^GitSnapshot, path: string) -> (GitChange, bool) {
	for change in snapshot.changes do if change.path == path do return change, true
	return {}, false
}

@(test)
git_init_stage_commit_branch_push :: proc(t: ^testing.T) {
	if _, ok := Script_FindEditorProgram("git"); !ok {
		log.info("git isn't installed: skipped")
		return
	}
	// Commits need a name and email; CI machines have none
	os.set_env("GIT_AUTHOR_NAME", "Test")
	os.set_env("GIT_AUTHOR_EMAIL", "test@example.com")
	os.set_env("GIT_COMMITTER_NAME", "Test")
	os.set_env("GIT_COMMITTER_EMAIL", "test@example.com")

	os.make_directory("build")
	dir := "build/test_git"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := absolutePath(joinPath(dir, "Game", allocator = context.temp_allocator))
	project := Project_CreateEmpty(root, "Game")
	defer Project_Destroy(&project)
	testing.expect_value(t, Project_Save(&project), "")

	// Inside the editor's repository, whose build/ is ignored: not under version control
	snapshot := Git_ReadSnapshot(root)
	defer GitSnapshot_Destroy(&snapshot)
	testing.expect_value(t, snapshot.availability, GitAvailability.Not_Repo)

	// Initialize: a repository on main, with a .gitignore; everything untracked
	if !gitDo(t, root, &snapshot, .Init) do return
	testing.expect_value(t, snapshot.availability, GitAvailability.Repo)
	testing.expect_value(t, snapshot.branch, "main")
	testing.expect(t, !snapshot.hasCommits)
	testing.expect(t, os.exists(joinPath(root, ".gitignore", allocator = context.temp_allocator)))
	testing.expect(t, os.exists(joinPath(root, ".gitattributes", allocator = context.temp_allocator)))
	change, found := findChange(&snapshot, "project.xml")
	testing.expect(t, found, "project.xml is a change")
	testing.expect_value(t, change.staged, '?')

	// Staging one file, and unstaging it before the first commit
	gitDo(t, root, &snapshot, .Stage, "project.xml")
	change, _ = findChange(&snapshot, "project.xml")
	testing.expect_value(t, change.staged, 'A')
	gitDo(t, root, &snapshot, .Unstage, "project.xml")
	change, _ = findChange(&snapshot, "project.xml")
	testing.expect_value(t, change.staged, '?')

	// Commit with nothing staged takes every change
	testing.expect(t, Git_OpProblem(.Commit, "", &snapshot) != "", "a commit needs a message")
	gitDo(t, root, &snapshot, .Commit, "First")
	testing.expect_value(t, len(snapshot.changes), 0)
	testing.expect(t, snapshot.hasCommits)
	testing.expect_value(t, len(snapshot.log), 1)
	if len(snapshot.log) > 0 do testing.expect_value(t, snapshot.log[0].subject, "First")
	testing.expect(t, Git_OpProblem(.Commit, "Again", &snapshot) != "", "nothing to commit")

	// A change, on a new branch; switching back brings main's file back
	xml := joinPath(root, "project.xml", allocator = context.temp_allocator)
	first, _ := os.read_entire_file(xml, context.temp_allocator)
	_ = os.write_entire_file(xml, transmute([]byte)strings.concatenate({string(first), "<!-- changed -->\n"}, context.temp_allocator))
	GitSnapshot_Destroy(&snapshot)
	snapshot = Git_ReadSnapshot(root)
	change, _ = findChange(&snapshot, "project.xml")
	testing.expect_value(t, change.unstaged, 'M')
	testing.expect(t, Git_OpProblem(.Create_Branch, "bad name", &snapshot) != "")
	gitDo(t, root, &snapshot, .Create_Branch, "feature")
	testing.expect_value(t, snapshot.branch, "feature")
	gitDo(t, root, &snapshot, .Commit, "Second")
	testing.expect_value(t, len(snapshot.branches), 2)
	gitDo(t, root, &snapshot, .Switch_Branch, "main")
	testing.expect_value(t, snapshot.branch, "main")
	now, _ := os.read_entire_file(xml, context.temp_allocator)
	testing.expect(t, string(now) == string(first), "main's project.xml is back")
	testing.expect(t, Git_ChangesFiles(.Switch_Branch))

	// A remote (a bare repository here): push sets the upstream; a commit puts main ahead of it
	testing.expect(t, Git_OpProblem(.Push, "", &snapshot) != "", "no remote yet")
	remote := joinPath(absolutePath(dir), "remote.git", allocator = context.temp_allocator)
	_, bareOk := Git_RunCommands(dir, .Init, {{"git", "init", "-q", "--bare", remote}}, context.temp_allocator)
	testing.expect(t, bareOk)
	gitDo(t, root, &snapshot, .Add_Remote, remote)
	testing.expect_value(t, len(snapshot.remotes), 1)
	gitDo(t, root, &snapshot, .Push)
	testing.expect_value(t, snapshot.upstream, "origin/main")
	testing.expect_value(t, snapshot.ahead, 0)
	_ = os.write_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), transmute([]byte)string("notes"))
	GitSnapshot_Destroy(&snapshot)
	snapshot = Git_ReadSnapshot(root)
	gitDo(t, root, &snapshot, .Commit, "Third")
	testing.expect_value(t, snapshot.ahead, 1)
	gitDo(t, root, &snapshot, .Push)
	testing.expect_value(t, snapshot.ahead, 0)

	// Diffs: a changed file against the last commit, a new file as added lines
	_ = os.write_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), transmute([]byte)string("notes\nmore"))
	_ = os.write_entire_file(joinPath(root, "scratch.txt", allocator = context.temp_allocator), transmute([]byte)string("draft"))
	GitSnapshot_Destroy(&snapshot)
	snapshot = Git_ReadSnapshot(root)
	diff := Git_ReadDiff(root, "notes.txt", false, true, context.temp_allocator)
	testing.expectf(t, strings.contains(diff, "+more") && strings.contains(diff, "@@"), "the change's diff: %s", diff)
	newDiff := Git_ReadDiff(root, "scratch.txt", true, true, context.temp_allocator)
	testing.expectf(t, strings.contains(newDiff, "+draft"), "a new file's diff: %s", newDiff)

	// Discard: a changed file goes back to the last commit, a new one is deleted
	gitDo(t, root, &snapshot, .Discard, "notes.txt")
	notes, _ := os.read_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(notes), "notes")
	testing.expect(t, Git_ChangesFiles(.Discard))
	gitDo(t, root, &snapshot, .Discard, "scratch.txt")
	testing.expect(t, !os.exists(joinPath(root, "scratch.txt", allocator = context.temp_allocator)), "the new file is gone")
	testing.expect_value(t, len(snapshot.changes), 0)
	testing.expect(t, Git_OpProblem(.Discard, "notes.txt", &snapshot) != "", "nothing to discard")

	// A merge with a conflict (both branches changed notes.txt): it stops, merging; keeping
	// this branch's version and committing ends it; then once more taking the other side
	testing.expect(t, Git_OpProblem(.Merge, "main", &snapshot) != "", "can't merge a branch into itself")
	conflict :: proc(t: ^testing.T, root: string, snapshot: ^GitSnapshot, round: string) {
		notesPath := joinPath(root, "notes.txt", allocator = context.temp_allocator)
		gitDo(t, root, snapshot, .Switch_Branch, "feature")
		_ = os.write_entire_file(notesPath, transmute([]byte)strings.concatenate({"theirs ", round}, context.temp_allocator))
		GitSnapshot_Destroy(snapshot)
		snapshot^ = Git_ReadSnapshot(root)
		gitDo(t, root, snapshot, .Commit, strings.concatenate({"Feature ", round}, context.temp_allocator))
		gitDo(t, root, snapshot, .Switch_Branch, "main")
		_ = os.write_entire_file(notesPath, transmute([]byte)strings.concatenate({"mine ", round}, context.temp_allocator))
		GitSnapshot_Destroy(snapshot)
		snapshot^ = Git_ReadSnapshot(root)
		gitDo(t, root, snapshot, .Commit, strings.concatenate({"Main ", round}, context.temp_allocator))
		// The merge itself fails (git stops on the conflict)
		output, ok := Git_RunCommands(root, .Merge, Git_Commands(.Merge, "feature", snapshot), context.temp_allocator)
		testing.expectf(t, !ok && strings.contains(output, "CONFLICT"), "the merge conflicts: %s", output)
		GitSnapshot_Destroy(snapshot)
		snapshot^ = Git_ReadSnapshot(root)
		testing.expect(t, snapshot.merging, "merging")
		// Both changed it (UU), or both added it (AA: the first round, notes.txt is new on both)
		change, _ := findChange(snapshot, "notes.txt")
		testing.expectf(t, change.staged == 'U' || (change.staged == 'A' && change.unstaged == 'A'), "conflicted: %c%c", change.staged, change.unstaged)
	}
	// Without the user's rerere (it would replay earlier resolutions)
	_, _ = Git_RunCommands(root, .Init, {{"git", "config", "rerere.enabled", "false"}}, context.temp_allocator)
	conflict(t, root, &snapshot, "1")
	gitDo(t, root, &snapshot, .Resolve_Mine, "notes.txt")
	gitDo(t, root, &snapshot, .Commit, "Merged, mine")
	testing.expect(t, !snapshot.merging, "the merge is done")
	mine, _ := os.read_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(mine), "mine 1")
	conflict(t, root, &snapshot, "2")
	gitDo(t, root, &snapshot, .Resolve_Theirs, "notes.txt")
	gitDo(t, root, &snapshot, .Commit, "Merged, theirs")
	theirs, _ := os.read_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(theirs), "theirs 2")
	// And an abort puts things back as they were
	conflict(t, root, &snapshot, "3")
	gitDo(t, root, &snapshot, .Merge_Abort)
	testing.expect(t, !snapshot.merging, "aborted")
	aborted, _ := os.read_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(aborted), "mine 3")
	// LFS: refused without git-lfs (or set up with it)
	if !snapshot.lfsAvailable do testing.expect(t, Git_OpProblem(.LFS_Setup, "", &snapshot) != "", "no git-lfs: refused")
	free_all(context.temp_allocator)
}
