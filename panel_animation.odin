// Panel open/close animation: pure math over a progress value in [0, 1].
//
// 0 is fully hidden, 1 is settled. The window code drives progress from the
// display link and applies the result to the draw list: opacity through
// draw.push_opacity, scale and translation through draw.push_transform.

package activity_monitor

import draw "ui_framework:draw"

PANEL_OPEN_SECONDS :: f32(0.20)
PANEL_CLOSE_SECONDS :: f32(0.16)
PANEL_SCALE_START :: f32(0.75)
PANEL_TRANSLATE_START :: f32(8)

// panel_ease_out_cubic is the single curve for both fade and movement; it
// keeps the motion quiet and settles without a bounce.
panel_ease_out_cubic :: proc(progress: f32) -> f32 {
	eased := clamp(progress, 0, 1)
	inverse := 1 - eased
	return 1 - inverse * inverse * inverse
}

panel_opacity :: proc(progress: f32) -> f32 {
	return panel_ease_out_cubic(progress)
}

// panel_transform scales the panel around its anchor (the icon-side corner, in
// draw list coordinates) and slides it in from the icon. At progress 1 the
// transform is the identity.
panel_transform :: proc(progress: f32, anchor_x, anchor_y, from_x, from_y: f32) -> draw.Transform_2D {
	eased := panel_ease_out_cubic(progress)
	scale := PANEL_SCALE_START + (1-PANEL_SCALE_START)*eased
	offset_x := from_x * (1 - eased)
	offset_y := from_y * (1 - eased)
	return {
		m00 = scale,
		m01 = 0,
		m10 = 0,
		m11 = scale,
		tx = anchor_x - scale*anchor_x + offset_x,
		ty = anchor_y - scale*anchor_y + offset_y,
	}
}
