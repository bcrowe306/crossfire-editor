package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"

/*
Dropping a browser asset on a code tab adds a field of its handle type to the script, exported,
defaulting to the asset, with a comment showing how to use it:

	// e.Scene_AddComponent(self.scene, self.coin, position = e.Node_GetWorldPosition(self.node))
	coin: e.ComponentAsset `export:"default=components/coin.component.xml"`,

Images, sounds, music, fonts, components and data resources have handles (the engine's
assets.odin); the inspector then picks another asset of that kind per node.
*/

// The handle type an asset kind's fields have, and a line using one (`self.<name>`); "" for none
AssetField_Type :: proc(kind: AssetKind) -> (type: string, ok: bool) {
	#partial switch kind {
	case .Image:     return "TextureAsset", true
	case .Audio:     return "SoundAsset", true
	case .Music:     return "MusicAsset", true
	case .Font:      return "FontAsset", true
	case .Component: return "ComponentAsset", true
	case .Data:      return "DataAsset", true
	case .Animation: return "AnimationAsset", true
	}
	return "", false
}

// A field name for an asset: its file's name without its extensions ("coin.component.xml" -> coin)
AssetField_BaseName :: proc(path: string) -> string {
	base := filepath.base(path)
	if dot := strings.index_byte(base, '.'); dot > 0 do base = base[:dot]
	return base
}

/*
The lines a drop in a script struct adds for an asset (code_drops.odin): a comment using it, the exported field.

Inputs:
- st: The script struct (its fields, so the name is unique, and the engine's import name)
- project: The project (a data resource's type)
- asset: The asset

Returns:
- The lines, the field's name, and false for assets without a handle type
*/
AssetField_Line :: proc(st: NodeField_Struct, project: ^Project, asset: AssetDef) -> (line, name: string, ok: bool) {
	type, handled := AssetField_Type(asset.kind)
	if !handled do return "", "", false
	name = NodeField_Name(AssetField_BaseName(asset.path), st.fields)
	a := st.engineAlias
	options := fmt.tprintf("default=%s", asset.path)
	use: string
	#partial switch asset.kind {
	// Where the script's node is: with no parent, the position is in the world (0, 0 is the
	// level's corner, likely off screen)
	case .Component: use = fmt.tprintf("%s.Scene_AddComponent(self.scene, self.%s, position = %s.Node_GetWorldPosition(self.node))", a, name, a)
	case .Audio:     use = fmt.tprintf("%s.Game_PlaySound(self.game, self.%s)", a, name)
	case .Image:     use = fmt.tprintf("texture := %s.Asset_Texture(self.game, self.%s)", a, name)
	case .Font:      use = fmt.tprintf("font := %s.Asset_Font(self.game, self.%s, 24)", a, name)
	case .Music:     use = fmt.tprintf("%s.AudioPlayer_SetSound(player, self.%s.path) (a MusicPlayer)", a, name)
	case .Animation: use = fmt.tprintf("%s.AnimatedSprite_UseAnimations(sprite, self.%s) (an AnimatedSprite)", a, name)
	case .Data:
		dataType := "T"
		if i := Project_FindData(project, asset.path); i >= 0 && project.data[i].type != "" {
			dataType = project.data[i].type
			options = fmt.tprintf("%s kind=%s", options, dataType)
		}
		use = fmt.tprintf("values := %s.Data(%s, self.%s)", a, dataType, name)
	}
	return fmt.tprintf("\t// %s\n\t%s: %s.%s `export:\"%s\"`,\n", use, name, a, type, options), name, true
}
