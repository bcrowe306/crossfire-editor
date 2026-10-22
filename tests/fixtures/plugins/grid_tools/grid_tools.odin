// A sample Crossfire Editor plugin (the plugins UI test and the manual's example): a command,
// an importer and inspector rows.
package grid_tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import api "plugin_api:."

// The grid cell the inspector's Snap uses (the plugin's own state, kept while it's loaded)
cell: f32 = 32

commands := []api.Command{
	{name = "Arrange Children in a Grid", description = "Lays the selected node's children out in rows of four, 48 px apart", run = arrange},
}

importers := []api.Importer{
	{extensions = {"csv"}, description = "speaker,text lines into a dialogue", run = importCSV},
}

inspectors := []api.Inspector{
	{targets = {"Sprite"}, rows = spriteRows, changed = spriteChanged},
}

@(export)
crossfire_plugin :: proc(host: ^api.Host) -> api.Plugin {
	return {
		name = "Grid Tools",
		description = "Arranges nodes on a grid, snaps sprites, imports CSV conversations",
		version = api.PLUGIN_API_VERSION,
		commands = commands,
		importers = importers,
		inspectors = inspectors,
	}
}

arrange :: proc(host: ^api.Host) {
	parent := host.selected()
	if parent < 0 {
		host.log("Select a node whose children to arrange", warning = true)
		return
	}
	for child, i in host.nodeChildren(parent) {
		host.setProperty(child, "position", fmt.tprintf("%d, %d", (i % 4) * 48, (i / 4) * 48))
	}
	host.log(fmt.tprintf("Arranged %d nodes", len(host.nodeChildren(parent))))
}

// "Guide,Hello there" lines: a dialogue of one node
importCSV :: proc(host: ^api.Host, source: string) -> (asset: string, problem: string) {
	data, err := os.read_entire_file(source, context.temp_allocator)
	if err != nil do return "", fmt.tprintf("couldn't read %s", source)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<dialogue start=\"Start\">\n\t<node name=\"Start\" x=\"20\" y=\"20\">\n")
	for line in strings.split_lines(string(data), context.temp_allocator) {
		speaker, _, text := strings.partition(line, ",")
		if strings.trim_space(text) == "" do continue
		fmt.sbprintf(&b, "\t\t<line speaker=\"%s\" text=\"%s\"/>\n", strings.trim_space(speaker), strings.trim_space(text))
	}
	strings.write_string(&b, "\t</node>\n</dialogue>\n")
	name := strings.trim_suffix(filepath.base(source), filepath.ext(source))
	asset = fmt.tprintf("dialogues/%s.dialogue.xml", name)
	folder := fmt.tprintf("%s/dialogues", host.projectRoot())
	_ = os.make_directory_all(folder)
	if os.write_entire_file(fmt.tprintf("%s/%s", host.projectRoot(), asset), transmute([]byte)strings.to_string(b)) != nil do return "", "couldn't write the dialogue"
	if !host.addAsset(asset) do return "", "couldn't add it to the project"
	return asset, ""
}

spriteRows :: proc(host: ^api.Host, node: int) -> []api.InspectorRow {
	position, _ := host.getProperty(node, "position")
	rows := make([]api.InspectorRow, 3, context.temp_allocator)
	rows[0] = {label = "At", kind = .Note, value = position}
	rows[1] = {id = "cell", label = "Grid cell", kind = .Number, value = fmt.tprintf("%v", cell)}
	rows[2] = {id = "snap", label = "Snap", kind = .Button, value = "Snap to the Grid"}
	return rows
}

spriteChanged :: proc(host: ^api.Host, node: int, id, value: string) {
	switch id {
	case "cell":
		if v, ok := strconv.parse_f32(value); ok && v > 0 do cell = v
	case "snap":
		position, _ := host.getProperty(node, "position")
		x, _, y := strings.partition(position, ",")
		px, _ := strconv.parse_f32(strings.trim_space(x))
		py, _ := strconv.parse_f32(strings.trim_space(y))
		snap :: proc(v, cell: f32) -> f32 { return f32(int(v / cell + (v < 0 ? -0.5 : 0.5))) * cell }
		host.setProperty(node, "position", fmt.tprintf("%v, %v", snap(px, cell), snap(py, cell)))
	}
}
