---
title: Version control with Git
description: Keep every version of your project with Git from the bottom panel's Git tab, with commits, branches, pushing to and pulling from a remote, diffs, merges and Git LFS for big assets.
order: 40
---

# Version control with Git

**Version control** keeps a history of your project: every time you **commit**, Git remembers
exactly what every file looked like. You can see what changed since, throw a change away, try
something on a **branch** without touching the main version, and send the project to a
**remote** (GitHub, GitLab, a server) to back it up or share it with others.

The editor does this through **Git**, in the bottom panel's **Git** tab. You don't need to know
Git's commands: the tab has buttons for the everyday things.

- [Before you start](#before-you-start)
- [Making the project a repository](#making-the-project-a-repository)
- [Changes](#changes)
- [Committing](#committing)
- [Looking at a change, and throwing it away](#looking-at-a-change-and-throwing-it-away)
- [The history](#the-history)
- [Branches](#branches)
- [Remotes: push and pull](#remotes-push-and-pull)
- [Merging branches, and conflicts](#merging-branches-and-conflicts)
- [Git LFS: big images and sounds](#git-lfs-big-images-and-sounds)
- [The branch in the status bar](#the-branch-in-the-status-bar)
- [Questions](#questions)

## Before you start

- **Install Git** (git-scm.com, or your system's package manager). Without it, the tab says
  "Git isn't installed, or isn't in PATH"; install it, then press the tab's **Refresh** button.
  **Edit > Settings > Toolchain** has a Git row showing whether it was found.
- **Tell Git who you are**, once per computer. Every commit records a name and an email. In a
  terminal:

  ```sh
  git config --global user.name "Your Name"
  git config --global user.email "you@example.com"
  ```

  Without them, the first commit fails and the Console shows Git's message saying so.

Open the tab: the bottom panel's **Git** tab (Ctrl+J shows the panel; scroll its tab strip
sideways when it's narrow).

## Making the project a repository

A project that isn't under version control yet shows "This project isn't under version control"
and an **Initialize Repository** button. It makes the project folder a Git **repository** (on a
branch called `main`) and writes two files:

| File | What it does |
|---|---|
| `.gitignore` | Leaves out what shouldn't be kept: exported games (`export/`), build output (`build/`), the editor's own per-user state (`.editor/`: viewport guides), project archives (`*.odinsdl`) and system clutter (`.DS_Store`, `Thumbs.db`) |
| `.gitattributes` | Keeps text files' line endings the same on every computer, so a project moved between Windows, macOS and Linux doesn't show every file as changed |

(An existing `.gitignore` or `.gitattributes` is kept.)

A project inside a folder that's already a repository counts as part of it: the tab shows only
the project folder's changes.

## Changes

The tab lists every file in the project that's different from the last commit. The letter before
each says how:

| Letter | Meaning |
|---|---|
| **M** (yellow) | Modified |
| **U** (green) | New: Git hasn't seen it before |
| **A** (green) | Added: new, and staged |
| **D** (red) | Deleted |
| **R** (blue) | Renamed |
| **!** (red) | A conflict from a merge (see [below](#merging-branches-and-conflicts)) |

The list updates by itself when you save, after every Git action, and when you press
**Refresh**. The editor saves the project before every Git action too, because Git works with
the files on disk.

## Committing

A commit records the changes, with a message saying what you did.

1. Type a message in **Commit message**: short and plain, like "Add the second level" or "Make
   the jump higher".
2. Press **Commit**.

Which changes go in:

- **None staged** (the line over the list says "(Commit takes them all)"): every change goes
  in. This is the simple way, and fine most of the time.
- **Some staged:** only those. **Staging** chooses what goes into the next commit, so one commit
  can hold one idea. Tick a file's checkbox to stage it, untick it to unstage it. **Stage All**
  and **Unstage All** do every file.

Commit is greyed out until there's a message and something to commit.

## Looking at a change, and throwing it away

**Click a file's name** to see what changed in it (its **diff**): added lines in green with a `+`,
removed lines in red with a `-`. It shows on the right instead of the history (in a narrow panel,
instead of the list). Click the name again, or **Close**, to go back.

**Discard** (the ↶ button before a file's name) throws away a file's changes: it goes back to how
it was at the last commit. A new file is deleted. The editor asks first, since **this can't be
undone**. After a discard, the editor reads the project again from disk.

## The history

On the right, **History** lists the last 50 commits: the message, a short id, who made it, and
when. When the panel is narrow (under about 720 pixels), the history is left out to keep room for
the changes; make the window or panel wider to see it.

## Branches

A **branch** is a line of work. Every repository starts with `main`. Make a branch to try
something (a new enemy, a big change to a level) without changing `main`; if it works out, merge
it back; if not, switch back to `main` and it's as you left it.

- **Make one:** type a name in **New branch** (no spaces), then **Create**. You're switched to
  it, with your changes.
- **Switch:** choose a branch from the list beside the branch icon. The editor saves, Git
  changes the files to that branch's, and the editor opens the project again from disk (scenes,
  scripts, everything as that branch has them).

Commit (or discard) your changes before switching: Git refuses to switch when they'd be lost, and
the Console shows why.

## Remotes: push and pull

A **remote** is a copy of the repository somewhere else: a GitHub or GitLab repository, a server.

**Adding one:** with no remote, the tab shows "No remote:" and a field. Make an empty repository
on GitHub (or another site), copy its URL (`https://...` or `git@...`), paste it in the field,
then **Add Remote**. It's added under the name `origin`.

Then the line shows the remote, and:

- **Push** sends your commits to it. The first push of a branch also sets it up to follow the
  remote's ("not pushed yet" until then).
- **Pull** brings commits from it into your branch, then the editor opens the project again from
  disk.

Beside the remote's name, **↑ 2** means you have 2 commits the remote doesn't have yet (push
them); **↓ 3** means it has 3 you don't (pull them).

**Passwords:** the editor can't type a password for Git, so a push or pull that needs one fails
with Git's message instead of waiting. Set up a way that needs no typing: an SSH key added to
your GitHub account (with a `git@github.com:...` URL), or a credential helper (GitHub's `gh auth
login`, or Git Credential Manager), then try again.

**Pull** only moves your branch forward to the remote's. If both you and the remote have new
commits, it stops with "Not possible to fast-forward". See the [Questions](#questions).

## Merging branches, and conflicts

**Merge...** (beside New branch, when there are other branches) brings another branch's commits
into the one you're on. Switch to `main`, then choose your branch from Merge... to bring its work
into `main`.

Usually that's all. But when both branches changed the same part of the same file, Git can't
choose: that's a **conflict**. The tab then says "Merging: resolve each conflicted file (!), then
Commit." and each conflicted file gets two buttons:

| Button | What it keeps |
|---|---|
| **Keep mine** | The file as it is on your branch (the one you're on) |
| **Take theirs** | The file as it is on the branch you're merging in |

Choose for every conflicted file, then **Commit** (a message is needed) to finish the merge. The
editor opens the project again from disk.

**Abort Merge** gives up and puts everything back as it was before the merge.

While a merge is half done, the project isn't reopened (other files still have Git's conflict
marks), and the branch in the status bar says "(merging)".

## Git LFS: big images and sounds

Git keeps every version of every file, so a project with many big images and sounds makes a big
repository. **Git LFS** (Large File Storage) keeps those files on the remote and only the version
you need on your computer.

With Git LFS installed (git-lfs.com) and not used in the repository yet, the tab shows **Use Git
LFS**. It turns LFS on for this repository and tracks the project's images (`.png`, `.jpg`,
`.jpeg`, `.bmp`, `.gif`, `.tga`, `.webp`, `.qoi`), sounds (`.wav`, `.ogg`, `.mp3`, `.flac`) and
fonts (`.ttf`, `.otf`), written in `.gitattributes`. That file is staged for you, so the next
commit takes only it unless you stage more (**Stage All** to commit everything with it). Files
committed from then on are stored with LFS; earlier commits stay as they were. Your remote must support LFS (GitHub and
GitLab do).

## The branch in the status bar

While the project is in a repository, the status bar at the bottom of the window shows the
branch, with ↑ and ↓ counts when it's ahead of or behind its remote, and "(merging)" during a
merge. Click it to open the Git tab.

## Questions

**Commit fails and the Console mentions user.name or user.email.** Git doesn't know who you are:
see [Before you start](#before-you-start).

**Push fails with "Authentication failed" or "Permission denied".** The editor can't type a
password. Use an SSH key or a credential helper (see [Remotes](#remotes-push-and-pull)); a push
from a terminal (`git push`) once is a good test.

**Pull says "Not possible to fast-forward".** You and the remote both have new commits. In a
terminal, in the project folder, run `git pull --no-rebase`. If it reports conflicts, come back
to the Git tab: the conflicted files have Keep mine and Take theirs, and Commit finishes it.

**Switching branches did nothing.** Git refused because of uncommitted changes (the Console has
its message). Commit or discard them first.

**I deleted a file by mistake.** If it was committed, it's in the list with a **D**: Discard
brings it back.

**The project is inside another repository, but I want it on its own.** Add the project's
folder to that repository's `.gitignore`: the tab then offers Initialize Repository for the
project alone.

**What's left out of the repository?** What `.gitignore` lists: exported games and build output,
which the editor can make again. Everything else in the project folder is kept.
