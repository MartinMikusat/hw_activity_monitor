// Panel animation tests: curve and transform are pure.

package activity_monitor

import "core:testing"

@(test)
test_panel_ease_out_cubic :: proc(t: ^testing.T) {
	testing.expect_value(t, panel_ease_out_cubic(0), f32(0))
	testing.expect_value(t, panel_ease_out_cubic(1), f32(1))
	testing.expect_value(t, panel_ease_out_cubic(-1), f32(0))
	testing.expect_value(t, panel_ease_out_cubic(2), f32(1))
	testing.expect(t, panel_ease_out_cubic(0.25) > 0.25, "ease out front-loads motion")
	testing.expect(t, panel_ease_out_cubic(0.5) > 0.5)
	testing.expect(t, panel_ease_out_cubic(0.75) < 1)
}

@(test)
test_panel_transform_settles_to_identity :: proc(t: ^testing.T) {
	settled := panel_transform(1, 220, 400, 0, PANEL_TRANSLATE_START)
	testing.expect(t, abs(settled.m00 - 1) < 0.0001)
	testing.expect(t, abs(settled.m11 - 1) < 0.0001)
	testing.expect(t, abs(settled.m01) < 0.0001)
	testing.expect(t, abs(settled.m10) < 0.0001)
	testing.expect(t, abs(settled.tx) < 0.0001)
	testing.expect(t, abs(settled.ty) < 0.0001)
}

@(test)
test_panel_transform_starts_scaled_at_anchor :: proc(t: ^testing.T) {
	hidden := panel_transform(0, 220, 400, 0, PANEL_TRANSLATE_START)
	testing.expect(t, abs(hidden.m00 - PANEL_SCALE_START) < 0.0001)
	testing.expect(t, abs(hidden.tx - (220 - PANEL_SCALE_START*220)) < 0.0001, "anchor x stays put")
	testing.expect(t, abs(hidden.ty - (400 - PANEL_SCALE_START*400 + PANEL_TRANSLATE_START)) < 0.0001, "anchor y plus start offset")
}
