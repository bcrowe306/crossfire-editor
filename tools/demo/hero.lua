-- Makes the demo's hero.aseprite from the Legacy Fantasy pack's character files: every
-- animation on one 96 x 80 canvas, feet on the same line, one tag per animation, a "pivot"
-- slice at her feet (the engine draws the sprite there), frame events in the cels' user data
-- ("step" when a foot lands while running, "slash" on the sword's swings, "land").
--
--   aseprite -b --script-param pack=<Legacy-Fantasy> --script-param out=<file> --script hero.lua
--
-- make_demo.py runs it.
local pack = app.params["pack"]
local out = app.params["out"]
local W, H, FEET = 96, 80, 76
-- name, file, first and last frame (1-based), milliseconds a frame, loops, events by frame
local anims = {
	{"idle", "Character/Idle/Idle.aseprite", 1, 4, 160, true, {}},
	{"run", "Character/Run/Run.aseprite", 1, 8, 75, true, {[3] = "step", [7] = "step"}},
	{"jump", "Character/Jumlp-All/Jump-All.aseprite", 3, 6, 80, false, {}},
	{"fall", "Character/Jumlp-All/Jump-All.aseprite", 7, 12, 90, true, {}},
	{"land", "Character/Jumlp-All/Jump-All.aseprite", 13, 15, 60, false, {}},
	{"attack", "Character/Attack-01/Attack-01.aseprite", 1, 8, 50, false, {[3] = "slash", [7] = "slash"}},
	{"hurt", "Character/Dead/Dead.aseprite", 1, 2, 120, false, {}},
	{"dead", "Character/Dead/Dead.aseprite", 1, 8, 110, false, {}},
}
local dst = Sprite(W, H, ColorMode.RGB)
local layer = dst.layers[1]
layer.name = "Hero"
local frameNo = 0
-- Tags are made once every frame is in: a tag ending on the last frame grows with frames added after it
local ranges = {}
for _, a in ipairs(anims) do
	local src = app.open(pack .. "/" .. a[2])
	-- The lowest opaque row over the whole file goes on FEET, so frames in the air stay up
	local bottom = 0
	local images = {}
	for i = 1, #src.frames do
		local img = Image(src.spec)
		img:drawSprite(src, i)
		images[i] = img
		for y = img.height - 1, 0, -1 do
			local found = false
			for x = 0, img.width - 1 do
				if app.pixelColor.rgbaA(img:getPixel(x, y)) > 0 then found = true break end
			end
			if found then
				if y + 1 > bottom then bottom = y + 1 end
				break
			end
		end
	end
	local dx = math.floor((W - src.width) / 2)
	local dy = FEET - bottom
	local first = frameNo + 1
	for i = a[3], a[4] do
		frameNo = frameNo + 1
		local frame
		if frameNo == 1 then frame = dst.frames[1] else frame = dst:newEmptyFrame(frameNo) end
		frame.duration = a[5] / 1000
		local cel = dst:newCel(layer, frameNo, images[i], Point(dx, dy))
		local event = a[7][i - a[3] + 1]
		if event then cel.data = event end
	end
	src:close()
	app.activeSprite = dst
	ranges[#ranges + 1] = {first, frameNo, a}
end
for _, r in ipairs(ranges) do
	local tag = dst:newTag(r[1], r[2])
	tag.name = r[3][1]
	-- Tags without a repeat count loop; the others play once
	if not r[3][6] then tag.repeats = 1 end
end
local slice = dst:newSlice(Rectangle(W / 2 - 8, FEET - 40, 16, 40))
slice.name = "pivot"
slice.pivot = Point(8, 40)
dst:saveAs(out)
print("hero.aseprite: " .. #dst.frames .. " frames, " .. #dst.tags .. " tags")
