package crossfire_editor

import "core:testing"

// The inspector's layout at a sidebar width (view_inspector.odin's `Inspector_Layout`)

@(test)
narrow_inspectors_stack_their_rows :: proc(t: ^testing.T) {
	settings := Settings_Default()
	theme := Settings_Theme(&settings)
	th := &theme
	needed := NumberField_MinWidth(th) + LINK_BUTTON_WIDTH + th.spacing.xs
	// Wide: side by side, a linked number row fits beside the label
	width, stacked := Inspector_Layout(th, 300)
	testing.expect(t, !stacked, "side by side at 300 px")
	testing.expect(t, width >= needed, "a linked number fits")
	// The narrowest sidebar: the label goes over the control, which has the row's width (and
	// still more than a linked number needs), clear of the scrollbar
	width, stacked = Inspector_Layout(th, MIN_SIDEBAR_WIDTH)
	testing.expect(t, stacked, "stacked at the minimum")
	testing.expect(t, width >= needed, "a linked number fits stacked")
	testing.expect(t, width + th.spacing.md * 2 + INSPECTOR_SCROLLBAR_WIDTH <= MIN_SIDEBAR_WIDTH, "clear of the scrollbar")
	// Exactly where it switches: the widest stacked width is narrower than side by side's need
	edge := needed + INSPECTOR_LABEL_WIDTH + th.spacing.sm + th.spacing.md * 2 + INSPECTOR_SCROLLBAR_WIDTH
	_, stacked = Inspector_Layout(th, edge)
	testing.expect(t, !stacked, "side by side from the edge")
	_, stacked = Inspector_Layout(th, edge - 1)
	testing.expect(t, stacked, "stacked under it")
	// A row's whole width follows
	inspectorStacked = false
	testing.expect_value(t, inspectorRowWidth(100), 100 + INSPECTOR_LABEL_WIDTH)
}
