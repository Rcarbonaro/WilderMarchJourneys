// transition_parchment_burn.gdshader
//
// A value-noise dissolve with a warm "ember" glow riding the burning edge —
// meant to suggest parchment paper burning across the screen. Used by
// scene_transitions.gd for the "parchment_burn" transition style.
//
// Same 'progress' convention as transition_page_turn.gdshader: sweeps from
// -PROGRESS_PAD to (1.0 + PROGRESS_PAD); <=0 is fully revealed, >=1 is
// fully covered.
//
// HOW TO ADJUST:
//   - Speed: see scene_transitions.gd's cover_duration / reveal_duration.
//   - Burn origin (which edge it starts from): see the BURN_ORIGIN comment
//     in fragment() below — currently starts from the bottom edge.
//   - Colors: burn_color (the "ash"/backdrop colour once burned through) and
//     ember_color (the glowing edge colour) below.
//   - How jagged/organic the edge looks: noise_scale (higher = more, finer
//     jitter) and edge_width (wider = softer, slower-burning edge) below.
shader_type canvas_item;

uniform float progress : hint_range(-0.4, 1.4) = 0.0;
uniform vec4 burn_color : source_color = vec4(0.05, 0.03, 0.02, 1.0);
uniform vec4 ember_color : source_color = vec4(1.0, 0.45, 0.12, 1.0);
uniform float edge_width : hint_range(0.02, 0.35) = 0.10;
uniform float noise_scale : hint_range(1.0, 40.0) = 14.0;
uniform float noise_strength : hint_range(0.0, 0.6) = 0.32;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	vec2 uv = UV;
	float n = value_noise(uv * noise_scale);

	// BURN_ORIGIN: "1.0 - uv.y" makes the burn start at the BOTTOM edge and
	// spread upward. Swap in "uv.y" to start from the top, "uv.x" for the
	// left edge, "1.0 - uv.x" for the right edge, or
	// "length(uv - vec2(0.5))" for an outward-expanding circle from center.
	float base = 1.0 - uv.y;
	float t = clamp(base + (n - 0.5) * noise_strength, 0.0, 1.0);

	// Same "covered" convention as transition_page_turn.gdshader — progress
	// is the moving quantity, t is the per-pixel threshold.
	float covered = smoothstep(t - edge_width, t + edge_width, progress);
	float ember = 1.0 - clamp(abs(progress - t) / edge_width, 0.0, 1.0);

	vec4 col = burn_color;
	col.rgb = mix(col.rgb, ember_color.rgb, clamp(ember * 1.4, 0.0, 1.0));

	COLOR = vec4(col.rgb, col.a * covered);
}
