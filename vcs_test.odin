package editor

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Runs an operation as the Git tab would (synchronously), then reads the snapshot again
@(private="file")
gitDo :: proc(t: ^testing.T, folder: string, snapshot: ^GitSnapshot, op: GitOp, arg := "") -> bool {
	output, ok := Git_RunCommands(folder, op, Git_Commands(op, arg, snapshot), context.temp_allocator)
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
	free_all(context.temp_allocator)
}
