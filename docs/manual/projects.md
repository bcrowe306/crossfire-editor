# Projects: making, opening, saving and copying them

A **project** is your game's folder. Everything the game needs is inside it:

| In the folder | What it is |
|---|---|
| `project.xml` | The game's settings: its name, screen size, start scene, input actions, sound buses |
| `scenes/` | The levels and menus, one `.scene.xml` file each |
| `assets/` | Images, sounds, fonts, levels, everything the scenes use |
| `scripts/` | Your Odin code |
| `export/` | Games you exported (made by File > Export; not part of the project) |
| `build/` | The editor's build output (not part of the project) |

The editor works on one project at a time. Its name is in the window's title, with a `*` after
it while there are changes you haven't saved.

- [Making a new project](#making-a-new-project)
- [Opening a project](#opening-a-project)
- [Recent projects](#recent-projects)
- [Saving](#saving)
- [Save Project As: a copy somewhere else](#save-project-as-a-copy-somewhere-else)
- [Project archives: the project in one file](#project-archives-the-project-in-one-file)
- [Unsaved changes](#unsaved-changes)
- [Questions](#questions)

## Making a new project

1. **File > New Project** (Ctrl+N).
2. **Name**: the game's name. It's also the folder's name.
3. **Location**: the folder to make it in (**Browse...** picks one). The project goes in a new
   folder there, `<Location>/<Name>`.
4. **Create**.

A new project has one scene, **Main**, with a **World** node in it, a 1280 x 720 screen, and the
usual input actions (the arrow keys, Enter, Escape: `ui_left`, `ui_accept`...).

## Opening a project

**File > Open Project** (Ctrl+O), then pick the project's folder (the one with `project.xml` in
it).

You can also start the editor with a project: `crossfire-editor path/to/MyGame`.

## Recent projects

The **File** menu lists the projects you opened lately, the most recent first: click one to open
it again. Each shows its folder's name, then where it is (`~` is your home folder). The project
that's open isn't listed.

- The list keeps the last 10 projects (the menu shows 8).
- A project that has been moved or deleted is reported in the Console when you choose it, and
  taken off the list.
- **Clear Recent Projects** (at the end of the list) empties it.

The list is kept beside the editor's settings, in `recent_projects.txt`.

## Saving

**File > Save** (Ctrl+S) writes everything: `project.xml`, every scene, components, animation and
theme files, data resources, and the scripts open in code tabs.

**Play** (F5) and **Export** save first too, so the game runs what you see.

## Save Project As: a copy somewhere else

**File > Save Project As...** (Ctrl+Shift+S) saves the project, as it is now, into another folder,
and opens that copy. Use it to try something out without touching the original, to start a new
game from an old one, or to keep a version before a big change.

1. **File > Save Project As...**
2. **Name**: the copy's name, and its folder's (it starts as "<project> Copy").
3. **Location**: where to put it (it starts beside the project).
4. **Save Copy**.

What happens:

- The project's files are copied into `<Location>/<Name>`: scenes, assets, scripts, everything
  in the folder **except** exported games (`export/`), build output (`build/`) and the Git
  history (`.git/`). The copy starts with no version history of its own.
- What's open goes into the copy, **unsaved changes too** (scene edits, code you haven't saved).
- The copy opens. The project where it was **stays as it was last saved**: the changes you hadn't
  saved are only in the copy.
- The copy is added to the recent projects, so the original is one click away in the File menu.
- Undo starts fresh in the copy.

Assets that live outside the project folder (a path like `../shared/hero.png`) aren't copied: the
copy uses the same path, which may not lead anywhere from its new place. The Console lists them.
To bring outside assets into a project, use a project archive (below).

## Project archives: the project in one file

**File > Export Project Archive...** writes the project as one `.odinsdl` file (a zip) to send to
someone or keep. Assets outside the project folder are copied in. **...with History** keeps the
Git history too. **File > Open Project Archive...** unpacks one and opens it.

## Unsaved changes

New Project, Open Project, a recent project and Quit ask first when there are unsaved changes:

- **Save**: saves, then goes on.
- **Don't Save**: drops the changes and goes on.
- **Cancel**: stays where you are.

Save Project As doesn't ask: your changes go into the copy.

## Questions

**Save Project As says the folder already exists.** It won't copy over another folder: choose
another name or location.

**My copy is missing images.** They were outside the project folder (see the Console). Copy them
into the copy's `assets/` folder and choose them again, or use a project archive, which brings
them in.

**A recent project won't open.** It was moved or deleted; it's taken off the list. Use File >
Open Project to find it where it is now.
