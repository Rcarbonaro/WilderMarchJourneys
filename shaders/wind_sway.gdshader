// res://shaders/wind_sway.gdshader
//
// WIND SWAY -- for map feature sprites (trees, mushrooms, flowers, etc).
// Offsets vertices horizontally with a blend of two sine waves at
// different speeds (so the motion reads as gentle organic wind rather
// than a perfectly repeating metronome), strongest at the TOP of the
// sprite and fading to zero at the bottom -- so the feature looks rooted
// in the ground while its top sways in the breeze.
//
// Every feature sways IN UNISON -- battle_grid.gd's _spawn_feature_visual()
// leaves phase_offset at this shader's default (0.0) for every sprite, on
// purpose, so the whole map reads as one coherent gust passing through
// rather than each feature swaying independently. Each sprite still gets
// its own ShaderMaterial instance (not a single shared one), since
// sway_strength/sway_speed are still set per feature TYPE from
// MapFeatureData -- e.g. a big tree can sway slower and less than a small
// flower, they just both start (and continue) their motion in sync.
//
// TUNING: sway_strength/sway_speed are exposed as @export fields on
// MapFeatureData per feature type -- see that file for the exact numbers
// currently in use. If you ever want a "wind sweeping across the map"
// ripple instead of perfectly instantaneous unison, set phase_offset from
// world position in battle_grid.gd instead of leaving it at 0 -- see the
// comment there.

shader_type canvas_item;

uniform float sway_speed : hint_range(0.0, 5.0) = 1.0;
uniform float sway_strength : hint_range(0.0, 20.0) = 4.0;   // pixels of horizontal offset at the very top of the sprite
uniform float phase_offset = 0.0;   // set per-instance from GDScript so sprites don't all sway in lockstep

void vertex() {
	// UV.y is 0 at the top of the sprite and 1 at the bottom (Sprite2D's
	// default mapping) -- (1.0 - UV.y) is 1 at the top and 0 at the base,
	// so multiplying by it makes the sway strongest at the top and fade to
	// nothing at the base, like a real plant swaying while rooted in place.
	float root_weight = 1.0 - UV.y;

	// Two sine waves at different speeds/weights blended together reads as
	// gentle organic wind rather than a perfectly repeating metronome tick.
	float wave = sin(TIME * sway_speed + phase_offset) * 0.7
			   + sin(TIME * sway_speed * 1.7 + phase_offset * 1.3) * 0.3;

	VERTEX.x += wave * sway_strength * root_weight;
}
