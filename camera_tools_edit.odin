package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Camera tools in the editor (the engine's camera_tools.odin): ParallaxLayer, CameraZone and
CameraView nodes.

- **Data:** `NodeDef.cameraTools` (the engine's `e.CameraToolSettings`, plain) and
  `NodeDef.viewCamera` (a CameraView's camera, a path from it; owned). A layer's image is its
  `texture`; a zone's and a view's size are `shapeSize` (the shape fields' messages).
- **Messages:** `Camera_Tool_Changed{field, value, flag, text}`, a node step (sliders and numbers
  merge while they move).
- **Viewport:** zones and views are outlined; the engine draws layers and views as the game will
  (with the camera where the scene starts it).
*/

// A camera tool setting (`Camera_Tool_Changed`)
CameraToolField :: enum {
	Factor_X,
	Factor_Y,
	Repeat_X,
	Repeat_Y,
	Transition,
	Zoom,
	Border,
	Camera,
}

// A change to the selected camera tool node
Camera_Tool_Changed :: struct {
	field: CameraToolField,
	value: f32,
	flag: bool,
	text: string,
}

// The camera tools' number fields' target (number_field.odin)
CameraToolNumber :: distinct CameraToolField

/*
Applies a camera tool setting to the selected node.

Returns:
- Whether the message was this file's
*/
CameraTools_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Camera_Tool_Changed)
	if !ok do return false
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return true
	node := &scene.nodes[s.selectedNode]
	c := &node.cameraTools
	switch v.field {
	case .Factor_X: c.factor.x = clamp(v.value, -2, 2)
	case .Factor_Y: c.factor.y = clamp(v.value, -2, 2)
	case .Repeat_X: c.repeatX = v.flag
	case .Repeat_Y: c.repeatY = v.flag
	case .Transition: c.transition = max(v.value, 0)
	case .Zoom: c.zoom = max(v.value, 0.01)
	case .Border: c.border = max(v.value, 0)
	case .Camera:
		delete(node.viewCamera)
		node.viewCamera = strings.clone(v.text == CAMERA_NONE ? "" : v.text)
	}
	return true
}

// The camera choice for none
CAMERA_NONE :: "(choose a Camera)"

/*
The inspector's rows for a ParallaxLayer, a CameraZone or a CameraView.
*/
cameraToolInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	c := node.cameraTools
	d := e.DEFAULT_CAMERA_TOOL_SETTINGS
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	Payload :: struct { field: CameraToolField }
	slide :: proc(p: Payload, v: f32) -> Msg { return Camera_Tool_Changed{field = p.field, value = v} }
	check :: proc(ctx: ^skald.Ctx(Msg), key: int, field: CameraToolField, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", Payload{field}, proc(p: Payload, v: bool) -> Msg { return Camera_Tool_Changed{field = p.field, flag = v} },
			id = skald.hash_id(fmt.tprintf("inspector-cam-%v-%d", field, key)))
	}
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: CameraToolField, value: f32, step: f32, decimals: int, width: f32, lo: f64 = 0, hi: f64 = 100000) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-cam-%v-%d", field, key), CameraToolNumber(field), f64(value), f64(step), decimals, width, lo, hi)
	}
	size :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, width: f32) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-%v-%d", field, key), field, f64(value), 16, 0, width, 1, 100000)
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	#partial switch node.kind {
	case .ParallaxLayer:
		images := make([dynamic]string, context.temp_allocator)
		append(&images, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
		append(&rows, inspectorRow(ctx, "Image", skald.select(ctx, node.texture == "" ? TEXTURE_NONE : node.texture, images[:], NodeTextField.Texture, onText,
			id = skald.hash_id(fmt.tprintf("inspector-texture-%d", key)), width = controlWidth, placeholder = "Choose an image")))
		append(&rows, inspectorRow(ctx, "Follows camera X", valueSlider(ctx, fmt.tprintf("inspector-cam-Factor_X-%d", key), c.factor.x, Payload{.Factor_X}, slide, 0, 1, step = 0.01, decimals = 2, defaultValue = d.factor.x, width = controlWidth)))
		append(&rows, inspectorRow(ctx, "Follows camera Y", valueSlider(ctx, fmt.tprintf("inspector-cam-Factor_Y-%d", key), c.factor.y, Payload{.Factor_Y}, slide, 0, 1, step = 0.01, decimals = 2, defaultValue = d.factor.y, width = controlWidth)))
		append(&rows, note(ctx, "1: moves with the world; 0.5: half as fast (far away); 0: stays on the screen (a sky). Its children move with it.", width))
		append(&rows, inspectorRow(ctx, "Repeat across", check(ctx, key, .Repeat_X, c.repeatX)))
		append(&rows, inspectorRow(ctx, "Repeat down", check(ctx, key, .Repeat_Y, c.repeatY)))
	case .CameraZone:
		append(&rows, inspectorRow(ctx, "Room width", size(ctx, s, key, .Shape_Width, node.shapeSize.x, numberWidth)))
		append(&rows, inspectorRow(ctx, "Room height", size(ctx, s, key, .Shape_Height, node.shapeSize.y, numberWidth)))
		append(&rows, inspectorRow(ctx, "Slide time", number(ctx, s, key, .Transition, c.transition, 0.1, 2, numberWidth, 0, 10)))
		append(&rows, note(ctx, "While the scene's camera is in it, the camera can't show past it; entering another zone slides the view over in the slide time.", width))
	case .CameraView:
		append(&rows, inspectorRow(ctx, "View width", size(ctx, s, key, .Shape_Width, node.shapeSize.x, numberWidth)))
		append(&rows, inspectorRow(ctx, "View height", size(ctx, s, key, .Shape_Height, node.shapeSize.y, numberWidth)))
		scene := &s.project.scenes[s.currentScene]
		cameras := make([dynamic]string, context.temp_allocator)
		append(&cameras, CAMERA_NONE)
		for n, i in scene.nodes do if n.kind == .Camera do append(&cameras, Scene_NodePath(scene, key, i, context.temp_allocator))
		CameraPayload :: struct {}
		append(&rows, inspectorRow(ctx, "Shows camera", skald.select(ctx, node.viewCamera == "" ? CAMERA_NONE : node.viewCamera, cameras[:], CameraPayload{},
			proc(_: CameraPayload, v: string) -> Msg { return Camera_Tool_Changed{field = .Camera, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-cam-Camera-%d", key)), width = controlWidth)))
		append(&rows, inspectorRow(ctx, "View zoom", number(ctx, s, key, .Zoom, c.zoom, 0.1, 2, numberWidth, 0.01, 100)))
		append(&rows, inspectorRow(ctx, "Border", number(ctx, s, key, .Border, c.border, 1, 0, numberWidth, 0, 32)))
		append(&rows, note(ctx, "Draws what that camera sees (times the zoom) into this rectangle. Put it on a screen layer (the scene's settings) so the main camera doesn't move it.", width))
	}
	_ = th
	return rows[:]
}
