---
title: Asset import settings, atlases and fonts
description: Choose smooth or pixel-art filtering for images, pack images into texture atlases, use bitmap fonts and fonts that stay sharp at any size, and convert sounds to Ogg Vorbis.
order: 32
---

# Asset import settings, atlases and fonts

When you import a file, the editor copies it into the project's `assets/` folder and the game
uses it as it is. This page is about the settings that change **how** an asset is used:

- [Image filtering](#image-filtering-smooth-or-pixels): smooth, or hard square pixels for pixel art.
- [Texture atlases](#texture-atlases): many small images packed into one picture.
- [Bitmap fonts](#bitmap-fonts): fonts made of pictures of letters (pixel-art lettering).
- [Fonts that stay sharp at any size](#fonts-that-stay-sharp-at-any-size-msdf): big titles, zoomed
  cameras, turned text.
- [Converting sounds](#converting-sounds-to-ogg-vorbis): smaller sound files, and formats the game
  can't play turned into ones it can.

Select an asset in the **browser** (the panel on the left): its preview under the list shows its
settings. Changing them is saved with the project (Ctrl+S). They are asset changes, like
importing, so Undo doesn't take them back.

## Image filtering: smooth or pixels

When an image is drawn bigger or smaller than it is, or turned, the graphics card has to make up
the pixels in between. It can do that two ways:

| Filtering | Looks like | Use it for |
|---|---|---|
| **Smooth** | Soft edges, colors blended between pixels | Painted art, photos, high-resolution sprites |
| **Pixels** | Hard square pixels, no blending | Pixel art: it stays crisp at 2x, 3x, 4x |

**For one image:** select it in the browser; its preview has **Filtering**: *The project's
setting*, *Smooth* or *Pixels*. The viewport changes at once.

**For the whole project:** Project Settings (File > Project Settings) > General > **Image
filtering**. Every image that doesn't choose its own uses it. Its default is Smooth, except
Aseprite files, which are pixel art and use Pixels.

From a script, images are filtered the way the project says; to change one while the game runs:

```odin
e.ResourceManager_SetTextureFilter(&game.resourceManager, e.JoinPath(game.projectDir, TEXTURE_SHIP.path), .Pixel)
```

## Texture atlases

A game with hundreds of small images (items, icons, tiles of a UI) loads each as its own
texture. An **atlas** packs them into one picture, so the game loads one file and the graphics
card switches pictures less. The editor does the packing for you.

### Making one

1. In the browser, right-click and choose **New Atlas**. An `atlases/atlas.atlas.xml` file is
   made and shown in the inspector (the panel on the right).
2. **Add image**: pick one of the project's images. It's packed at once; add as many as you like.
   Each becomes a **region** named after its file (`coin.png` is the region `coin`).
3. **Image gap**: empty pixels between images (2 by default), so neighbours don't bleed into each
   other when drawn scaled. **Filtering**: as for images, for the packed picture.
4. The × beside a region takes it out (the image stays in the project). **Pack Again** packs the
   images again after you changed them in a paint program.

The packed picture is `atlases/<name>.png`, beside the atlas file. Both are written as soon as
you change the atlas, and exports take them.

### Drawing from one

1. Select a **Sprite**. In its **Texture**, choose the atlas (atlases are listed with the images).
2. **Region** picks which of its images the Sprite draws. The Sprite is that image's size, and
   everything else (position, scale, tint, shaders) works as with an ordinary image.

From a script, the editor writes a constant for each atlas (`ATLAS_ITEMS` in
`scripts/assets.odin`):

```odin
// Given: coin: ^e.Sprite
// Show another of the atlas's images
e.Sprite_SetRegion(coin, ATLAS_ITEMS, "gem")

// Draw a region yourself, in a node's draw hook
texture, src, found := e.Game_AtlasRegion(game, ATLAS_ITEMS, "heart")
if found do e.DrawTexture(renderer, texture, {-8, -8, 16, 16}, src = src)
```

## Bitmap fonts

A **bitmap font** is a picture of every letter plus a file saying where each one is. Pixel-art
games use them: the letters are drawn exactly as the artist made them. The engine reads the
**BMFont** format (`.fnt`, text or XML), which BMFont, Hiero, Littera, Snow's Bitmap Font
Generator and many others write.

1. Put the `.fnt` file and its page images (`font_0.png`...) in the same folder, inside the
   project or not.
2. Import the `.fnt` (Ctrl+I). If it was outside the project, copy its page images next to it in
   `assets/` too: the preview says when one is missing.
3. Choose it wherever a font is chosen: a UI theme's font, a DialogueBox's Box font, or a script
   field of type `e.FontAsset`.

The preview tells its size and how many letters it has. Drawn at its own size, or 2x, 3x..., the
letters are pixel-exact; letters the font doesn't have are left out. Kerning pairs in the file are
used.

## Fonts that stay sharp at any size (MSDF)

A TrueType font is turned into pictures of its letters at the size text uses. Text that's scaled
afterwards (a zoomed camera, a title that grows, a node scaled up) gets blurry or blocky. An
**MSDF font** fixes that: the editor turns the font into a *multi-channel signed distance field*
atlas, a picture that records how far each pixel is from the letter's edge, and the engine draws
text from it with a shader that rebuilds sharp edges at any size and angle.

1. Select a `.ttf` or `.otf` font in the browser.
2. Tick **Sharp at any size (MSDF)**. The editor makes its atlas (`<font>.msdf.bmp` and
   `<font>.msdf.json` beside it) with **msdf-atlas-gen**, and makes it again when the font file
   changes (on save, before Play and before exports). **Make Atlas** makes it now.
3. Nothing else changes: text using the font (UI themes, DialogueBoxes, scripts) draws from the
   atlas.

Good to know:

- It needs the **GPU renderer** (Project Settings > General > Renderer: Auto or GPU, which
  projects with shaders get). On other renderers, and on the web, the font draws as an ordinary
  TrueType font: the same letters, without the extra sharpness.
- The atlas holds the printable ASCII and Latin-1 letters (English and most Western European
  languages). Letters outside it aren't drawn: leave the setting off for fonts that need other
  scripts.
- MSDF text also turns with its node (ordinary text stays upright).
- msdf-atlas-gen is one of the editor's shader tools (Settings > Toolchain > Font tool).

## Converting sounds to Ogg Vorbis

The game plays WAV, Ogg Vorbis, MP3 and FLAC. **Ogg Vorbis** is the usual choice: much smaller
than WAV, and it streams well for music. The editor converts with **ffmpeg** when it's installed
(Settings > Toolchain shows it; install it from ffmpeg.org or your package manager).

- **A sound in the project:** select it; its preview has **Convert to Ogg Vorbis**. The editor
  writes `<name>.ogg` beside it and the project uses it from then on: every sound node, music
  layer and script field naming the old file now names the new one. The old file stays in the
  folder (delete it yourself once you're happy).
- **Files the game can't play** (m4a, aac, opus, wma, webm, mp4...): import them as usual; they're
  converted to Ogg Vorbis on the way in.

Conversion uses quality 5 (about 160 kb/s for stereo): smaller than the original WAV by about ten
times, and hard to tell apart.

## In the project files

These settings are written into `project.xml` (and the scene files for Sprites):

```xml
<project ... textureFilter="Pixel">
	<asset path="assets/painting.png" kind="Image" filter="Smooth"/>
	<asset path="assets/fonts/Title.ttf" kind="Font" msdf="true"/>
	<asset path="assets/fonts/pixel.fnt" kind="Font"/>
	<asset path="atlases/items.atlas.xml" kind="Atlas"/>
</project>

<node kind="Sprite" name="Coin" texture="atlases/items.atlas.xml" region="coin"/>
```

## Questions

**My pixel art looks blurry when scaled.** Set its Filtering to Pixels, or the project's Image
filtering to Pixels.

**The atlas's images bleed into each other at the edges.** Raise the Image gap, then they're
packed again.

**My MSDF font looks like the normal one.** It's drawn sharp only on the GPU renderer: check
Project Settings > General > Renderer. Check the preview says its atlas is made.

**Convert to Ogg Vorbis is greyed out.** ffmpeg isn't installed (Settings > Toolchain).
