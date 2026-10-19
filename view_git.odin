package editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The bottom panel's Git tab (vcs.odin): the project's version control.

- Git missing: how to install it. Not a repository: Initialize Repository.
- A repository: on the left the branch (switch from the list, or type a name and Create) and
  Refresh; the upstream with Pull and Push (or a URL and Add Remote when there's no remote); the
  commit message and Commit; Stage All, Unstage All, and the changed files, each with a
  checkbox: staged or not. On the right the last 50 commits (narrower in a narrow panel, left
  out under 720 px).

Widget keys: `git-init`, `panel-git-refresh`, `git-branch`, `git-new-branch`, `git-create-branch`,
`git-pull`, `git-push`, `git-remote-url`, `git-add-remote`, `git-message`, `git-commit`,
`git-stage-all`, `git-unstage-all`, `git-change-<i>` (the checkbox), `git-changes` and
`git-history` (the scrolls).
*/
GitPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	snapshot := &s.git.snapshot
	switch snapshot.availability {
	case .Unknown:
		return placeholder(ctx, "Reading the project's version control...")
	case .Missing:
		return skald.col(
			skald.text("Git isn't installed, or isn't in PATH.", th.color.fg, th.font.size_sm),
			skald.text("Install it from git-scm.com (or your package manager), then press Refresh.", th.color.fg_muted, th.font.size_sm),
			refreshButton(s, ctx),
			spacing = th.spacing.sm,
			padding = th.spacing.md,
		)
	case .Not_Repo:
		return skald.col(
			skald.text("This project isn't under version control.", th.color.fg, th.font.size_sm),
			skald.text("Initialize makes the project folder a Git repository, with a .gitignore that leaves out exported games and build output.", th.color.fg_muted, th.font.size_sm),
			skald.row(
				skald.button(ctx, fmt.tprintf("%s  Initialize Repository", ICON_CODE_BRANCH), Msg(Git_Op_Requested{op = .Init}),
					id = skald.hash_id("git-init"), font_size = th.font.size_sm, disabled = s.git.busy),
				refreshButton(s, ctx),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.md,
		)
	case .Repo:
	}
	return skald.sized(ctx, s, repoBody)
}

// The changes, and beside them the history: narrower in a narrow panel, left out when too narrow
@(private="file")
repoBody :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	historyWidth := size.x >= 720 ? min(380, size.x * 0.36) : 0
	if historyWidth == 0 do return changesColumn(s, ctx)
	return skald.row(
		skald.flex(1, changesColumn(s, ctx)),
		skald.divider(ctx, vertical = true),
		skald.col(historyColumn(s, ctx), width = historyWidth, cross_align = .Stretch),
		cross_align = .Stretch,
		height = size.y,
	)
}

@(private="file")
refreshButton :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return panelButton(ctx, "git-refresh", ICON_REFRESH, "Refresh", Msg(Git_Refresh_Requested{}))
}

// The branch bar, the commit message, and the changed files
@(private="file")
changesColumn :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	git := &s.git
	snapshot := &git.snapshot
	small := th.font.size_sm

	branchText := snapshot.branch == "" ? "(no branch)" : snapshot.branch
	branches := make([dynamic]string, context.temp_allocator)
	for b in snapshot.branches do append(&branches, b)
	if len(branches) == 0 && snapshot.branch != "" do append(&branches, snapshot.branch)
	tracking := ""
	if snapshot.upstream != "" {
		tracking = fmt.tprintf("%s  %s%s%s", ICON_LINK, snapshot.upstream,
			snapshot.ahead > 0 ? fmt.tprintf("  %s%d", ICON_ARROW_UP, snapshot.ahead) : "",
			snapshot.behind > 0 ? fmt.tprintf("  %s%d", ICON_ARROW_DOWN, snapshot.behind) : "")
	}

	bar := make([dynamic]skald.View, context.temp_allocator)
	append(&bar, skald.text(ICON_CODE_BRANCH, th.color.fg_muted, small))
	append(&bar, skald.select(ctx, branchText, branches[:],
		proc(name: string) -> Msg { return Git_Op_Requested{op = .Switch_Branch, arg = name} },
		id = skald.hash_id("git-branch"), width = 140, disabled = git.busy || len(branches) < 2))
	append(&bar, skald.text_input(ctx, strings.clone(git.newBranch, context.temp_allocator),
		proc(v: string) -> Msg { return Git_New_Branch_Changed(v) },
		id = skald.hash_id("git-new-branch"), placeholder = "New branch", width = 120))
	append(&bar, skald.button(ctx, "Create", Msg(Git_Op_Requested{op = .Create_Branch, arg = strings.clone(git.newBranch, context.temp_allocator)}),
		id = skald.hash_id("git-create-branch"), bg = th.color.surface, fg = th.color.fg, font_size = small,
		disabled = git.busy || strings.trim_space(git.newBranch) == ""))
	append(&bar, skald.flex(1, skald.spacer(0)))
	append(&bar, refreshButton(s, ctx))

	// The remote: Pull and Push, or adding one
	remote: skald.View
	if len(snapshot.remotes) == 0 {
		remote = skald.row(
			skald.text("No remote:", th.color.fg_muted, small),
			skald.flex(1, skald.text_input(ctx, strings.clone(git.remoteURL, context.temp_allocator),
				proc(v: string) -> Msg { return Git_Remote_URL_Changed(v) },
				id = skald.hash_id("git-remote-url"), placeholder = "Its URL (https://... or git@...)")),
			skald.button(ctx, "Add Remote", Msg(Git_Op_Requested{op = .Add_Remote, arg = strings.clone(git.remoteURL, context.temp_allocator)}),
				id = skald.hash_id("git-add-remote"), bg = th.color.surface, fg = th.color.fg, font_size = small,
				disabled = git.busy || strings.trim_space(git.remoteURL) == ""),
			spacing = th.spacing.sm,
			cross_align = .Center,
		)
	} else {
		remote = skald.row(
			skald.text(tracking == "" ? fmt.tprintf("%s  %s (not pushed yet)", ICON_LINK, snapshot.remotes[0]) : tracking, th.color.fg_muted, small),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, fmt.tprintf("%s  Pull", ICON_DOWNLOAD), Msg(Git_Op_Requested{op = .Pull}),
				id = skald.hash_id("git-pull"), bg = th.color.surface, fg = th.color.fg, font_size = small, disabled = git.busy),
			skald.button(ctx, fmt.tprintf("%s  Push", ICON_UPLOAD), Msg(Git_Op_Requested{op = .Push}),
				id = skald.hash_id("git-push"), bg = th.color.surface, fg = th.color.fg, font_size = small, disabled = git.busy),
			spacing = th.spacing.sm,
			cross_align = .Center,
		)
	}

	message := skald.row(
		skald.flex(1, skald.text_input(ctx, strings.clone(git.message, context.temp_allocator),
			proc(v: string) -> Msg { return Git_Message_Changed(v) },
			id = skald.hash_id("git-message"), placeholder = "Commit message")),
		skald.button(ctx, fmt.tprintf("%s  Commit", ICON_CHECK), Msg(Git_Op_Requested{op = .Commit, arg = strings.clone(git.message, context.temp_allocator)}),
			id = skald.hash_id("git-commit"), font_size = small,
			disabled = git.busy || len(snapshot.changes) == 0 || strings.trim_space(git.message) == ""),
		spacing = th.spacing.sm,
		cross_align = .Center,
	)

	staged := 0
	for change in snapshot.changes do if isStaged(change) do staged += 1
	summary := len(snapshot.changes) == 0 ? "No changes" : fmt.tprintf("%d change%s, %d staged%s", len(snapshot.changes),
		len(snapshot.changes) == 1 ? "" : "s", staged, staged == 0 ? " (Commit takes them all)" : "")
	actions := skald.row(
		skald.text(summary, th.color.fg_muted, small),
		skald.flex(1, skald.spacer(0)),
		skald.button(ctx, "Stage All", Msg(Git_Op_Requested{op = .Stage_All}), id = skald.hash_id("git-stage-all"),
			bg = th.color.surface, fg = th.color.fg, font_size = small, disabled = git.busy || staged == len(snapshot.changes)),
		skald.button(ctx, "Unstage All", Msg(Git_Op_Requested{op = .Unstage_All}), id = skald.hash_id("git-unstage-all"),
			bg = th.color.surface, fg = th.color.fg, font_size = small, disabled = git.busy || staged == 0),
		spacing = th.spacing.sm,
		cross_align = .Center,
	)

	rows := make([dynamic]skald.View, context.temp_allocator)
	for change, i in snapshot.changes {
		letter, color := changeLetter(change, th)
		append(&rows, skald.row(
			skald.checkbox(ctx, isStaged(change), "", strings.clone(change.path, context.temp_allocator),
				proc(path: string, value: bool) -> Msg { return Git_Op_Requested{op = value ? .Stage : .Unstage, arg = path} },
				id = skald.hash_id(fmt.tprintf("git-change-%d", i)), disabled = git.busy),
			skald.col(skald.text(letter, color, small), width = 16),
			skald.text(change.path, th.color.fg, small),
			spacing = th.spacing.sm,
			cross_align = .Center,
		))
	}
	if snapshot.problem != "" do append(&rows, skald.text(snapshot.problem, th.color.danger, small))
	list := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = 2, padding = th.spacing.xs), id = skald.hash_id("git-changes"))

	return skald.col(
		skald.row(..bar[:], spacing = th.spacing.sm, cross_align = .Center),
		remote,
		message,
		actions,
		skald.flex(1, list),
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// The last commits
@(private="file")
historyColumn :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	small := th.font.size_sm
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text("History", th.color.fg, small))
	if len(s.git.snapshot.log) == 0 do append(&rows, skald.text("No commits yet.", th.color.fg_muted, small))
	for commit in s.git.snapshot.log {
		append(&rows, skald.col(
			skald.text(commit.subject, th.color.fg, small),
			skald.text(fmt.tprintf("%s  %s, %s", commit.hash, commit.author, commit.date), th.color.fg_muted, small),
			spacing = 1,
		))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.sm), id = skald.hash_id("git-history"))
}

// Whether a change is in the index (what Commit takes when anything is)
@(private="file")
isStaged :: proc(change: GitChange) -> bool {
	return change.staged != ' ' && change.staged != '?'
}

// A change's letter (the work tree's, else the index's) and its color
@(private="file")
changeLetter :: proc(change: GitChange, th: ^skald.Theme) -> (string, skald.Color) {
	letter := change.unstaged != ' ' ? change.unstaged : change.staged
	switch letter {
	case '?': return "U", th.color.success
	case 'A': return "A", th.color.success
	case 'D': return "D", th.color.danger
	case 'R': return "R", th.color.primary
	case 'U': return "!", th.color.danger
	}
	return "M", th.color.warning
}
