---
title: The docs window
description: "This manual and the engine's API reference inside the editor, offline: F1, Open Docs and the Manual buttons, links, search, back and forward, the same page on crossfireengine.io."
order: 41
---

# The docs window

The editor carries its documentation with it: this manual, a guide to every node kind and the
engine's whole API reference open in a window inside the editor, without a network. It's the same
text as on [crossfireengine.io](https://crossfireengine.io), and every page has a button that
opens it there.

- [Opening it](#opening-it)
- [Reading a page](#reading-a-page)
- [Searching](#searching)
- [What's in it](#whats-in-it)
- [Keys](#keys)
- [Questions](#questions)

## Opening it

It opens at the page about what you're doing:

| From | It shows |
|---|---|
| **Help > User Manual**, or **F1** | The page of the panel under the pointer: over the inspector or the viewport, the selected node's guide; over a bottom tab (Mixer, Timeline, States...), that tab's page; over the [sprite sheet slicer](sprite_slicer.md)'s tab, its page; over the browser, the selected scene's or asset's page; anywhere else, this manual's contents |
| **F1** in a code tab | The API entry of the engine procedure, type or constant at the caret (`e.Camera2D_Follow`), or the page of the type of the field or variable there; otherwise the code editor's page |
| **Open Docs** in a code tab's right-click menu | The page of the name you clicked: a node type's guide (`e.Sprite`), an API entry, or a field's or variable's type (`self.door` declared `door: ^e.Sprite`: the Sprite's guide). See [The code editor](code_editor.md#hovers-and-previews) |
| **Open Docs** in a right-click menu | A node's guide (in the scene tree or the viewport), a scene's, an asset kind's (images, sounds, fonts, animations, themes, materials, shaders, atlases, dialogues, LDtk projects, translations, data, components), a script's, a tab's, a bottom panel's |
| A panel's **Manual** button | That panel's page (the Timeline, States, Tiles, Dialogue and Plugins tabs, the Mixer's effects) |

The window sits over the editor; **Escape** or its **✕** closes it. Back still knows the pages
you read before, the next time it opens.

## Reading a page

The page is drawn like the website's: headings, tables, lists, code (Odin colored as in the code
editor) and links.

- **Links** to other pages of the manual or the API open them in the window, at the heading they
  point to. Links to other websites open in your browser.
- **Back** and **Forward** (the arrows, or **Alt+Left** and **Alt+Right**) go through the pages
  you opened, like a browser's.
- **Contents** (the house) opens this manual's list of pages.
- **Open on crossfireengine.io** opens the same page, at the same heading, in your browser: to
  share a link, or to read the newest docs.

In a wide window the left column lists every page: the manual in reading order, then the API
reference's areas. A narrow window (a tiled one) leaves it out; Contents has the same list.

## Searching

Type in **Search the docs** (**Ctrl+F** puts the cursor there). Every word you type must be on
the page: in its title, a heading or the text under a heading. The results show pages whose title
matches first, then headings (an API entry named exactly what you typed first of all), then
text, each with the words around the match. Click one to open its page at that heading. In a
narrow window the results take the page's place until you pick one; clear the box (its ✕) to
get the page back.

## What's in it

- **This manual**, every page of it, with the [node guides](nodes.md): a section per node kind
  with what it does, its properties as the inspector names them, how to set it up, how to use it
  from a script, an example and links to the API.
- **The engine's API reference**: every public type, procedure and constant of the Crossfire
  Engine with its documentation, in the same areas and with the same headings as on the
  website, so links between them work both ways. The editor makes it from the engine it builds
  your games with (its source in a release's `engine` folder), so it always describes that
  engine.

The docs ship with the editor (beside it in the Linux and Windows downloads, inside the app on
a Mac), so they work offline.

## Keys

| Key | Does |
|---|---|
| F1 | Opens the window (see [Opening it](#opening-it)) |
| Alt+Left, Alt+Right | Back, Forward |
| Ctrl+F | The search box |
| Escape | Closes the window |

## Questions

**The page on the website says something different.** The website shows the docs of the newest
release; the window shows the ones of your editor. After updating the editor they agree again.

**Open Docs isn't in a code tab's menu.** It's there when the name under the pointer is one the
docs know: an engine name, or a field, variable or parameter whose type the code shows as an
engine type. A node type of your own (`Door :: struct { using sprite: e.Sprite }`) goes to the guide of
the kind it's built on (the Sprite's); a script's struct to the scripts page. Your own
procedures have no page.

**F1 opened the wrong page.** F1 goes by where the pointer is, not by which panel you clicked
last. Point at the panel (or select the node) and press F1 again, or use the node's
**Open Docs**.

**Can I read the docs without the editor?** Yes: on [crossfireengine.io](https://crossfireengine.io),
or as Markdown files in the editor's `docs/manual` folder.
