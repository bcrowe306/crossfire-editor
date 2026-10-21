# Aseprite test sprites

From Aseprite's own test suite (`tests/sprites/` in github.com/aseprite/aseprite), released under
the MIT license (`LICENSE.txt` here, its `tests/LICENSE.txt`). Only that folder of Aseprite is
MIT. The editor's tests import them.

`tilemap.aseprite` is ours, not Aseprite's: written by `make_tilemap.py` (a tilemap layer whose
tiles have collision properties, and a hidden second one).

`features.aseprite`, `tilemap_animated.aseprite` and `terrain.aseprite` (16 grass tiles with terrain and mask properties, a dirt tile) were written by Aseprite itself (the engine's
testdata/aseprite/conformance/make.lua): slices (a hitbox, a pivot, a 9-patch), frame events on a
hidden layer, Body and Sword layers; an animated tilemap with a tag.
