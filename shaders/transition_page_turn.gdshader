// transition_page_turn.gdshader
//
// A diagonal wipe with a thin bright "highlight" line riding along the wipe
// boundary — meant to suggest a page turning across the screen. Used by
// scene_transitions.gd for the "page_turn" transition style.
//
// HOW THIS WORKS:
//   'progress' sweeps from -PROGRESS_PAD to (1.0 + PROGRESS_PAD) (see the
//   PROGRESS_PAD constant in scene_transitions.gd). At progress <= 0 the
//   whole screen is uncovered; at progress >= 1 the whole screen is
//   covered. In between, a diagonal line (angled by 'angle_deg') sweeps
//   across, with a soft edge ('edge_softness') and a bright highlight
//   ('highlight_color') riding just ahead of the covering edge.
//
// HOW TO ADJUST:
//   - Speed: NOT set here — see scene_transitions.gd's cover_duration /
//     reveal_duration exported vars, which control how fast 'progress'
//     animates from one end to the other.
//   - Angle: angle_deg below (0 = perfectly vertical wipe, 90 = perfectly
//     horizontal). 20-25 looks like a page-corner turn; try 45 for a
//     classic diagonal wipe.
//   - Wipe color: wipe_color below (this is the "page" colour covering the
//     screen — defaults to a dark near-black, but try a parchment tan for
//     a lighter feel).
//   - Highlight brightness/width: highlight_color / edge_softness below.
shader_type canvas_item;

uniform float progress : hint_range(-0.4, 1.4) = 0.0;
uniform float angle_deg : hint_range(0.0, 90.0) = 22.0;
uniform vec4 wipe_color : source_color = vec4(0.04, 0.03, 0.03, 1.0);
uniform vec4 highlight_color : source_color = vec4(1.0, 0.93, 0.78, 1.0);
uniform float edge_softness : hint_range(0.001, 0.3) = 0.05;

void fragment() {
	vec2 uv = UV;

	float rad = radians(angle_deg);
	float diag = uv.x * cos(rad) + uv.y * sin(rad);

	// Normalize 'diag' into roughly a 0..1 range regardless of angle, so
	// 'progress' means the same thing (0 = nothing covered, 1 = fully
	// covered) at any angle_deg value.
	float diag_min = min(0.0, sin(rad));
	float diag_max = cos(rad) + max(0.0, sin(rad));
	float t = (diag - diag_min) / max(0.0001, diag_max - diag_min);

	// covered == 0 while the wipe hasn't reached this pixel yet (t is still
	// "ahead of" progress), and == 1 once it has swept past. NOTE: 'progress'
	// is the moving quantity here (the argument being tested), and t is the
	// per-pixel threshold — smoothstep(edge0, edge1, x) must have x be the
	// thing that moves for this to sweep correctly across the screen.
	float covered = smoothstep(t - edge_softness, t + edge_softness, progress);

	// Simple triangular peak, maximal exactly where progress == t (the
	// current wipe boundary), fading to 0 by 'edge_softness' away from it.
	float highlight = 1.0 - clamp(abs(progress - t) / edge_softness, 0.0, 1.0);

	vec4 col = wipe_color;
	col.rgb = mix(col.rgb, highlight_color.rgb, clamp(highlight, 0.0, 1.0));

	COLOR = vec4(col.rgb, col.a * covered);
}
