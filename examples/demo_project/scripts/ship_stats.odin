package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
ShipStats: a DATA TYPE. Each ship the player can fly is a data resource of this type: a file in
data/ (data/scout.data.json, data/hauler.data.json), made in the browser's Data folder
(right-click > New Data Resource) and edited in the inspector when selected there.

Code loads one with e.Data(ShipStats, DATA_SCOUT): the DATA_ constants are generated in
assets.odin, one per data resource. A resource is loaded once and shared by everyone who asks
for it, so treat it as read-only.
*/
ShipStats :: struct {
	// Shown in the Options scene
	name: string `export:"default=Ship"`,
	// Pixels per second
	speed: f32 `export:"default=300 min=50 max=1000"`,
	// The ship's image (an asset picker in the inspector) and its size on screen
	sprite: e.TextureAsset `export:""`,
	scale: f32 `export:"default=1 min=0.05 max=4"`,
	tint: sdl.Color `export:"default=#ffffff"`,
}

@(init)
register_ShipStats :: proc "contextless" () {
	e.Data_Register(ShipStats)
}
