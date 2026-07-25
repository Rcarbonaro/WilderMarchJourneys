// res://shaders/wind_sway.gdshader
//
// WIND SWAY + BREATHING -- for anything that should sway gently, rooted in
// place: map feature sprites (trees, mushrooms, flowers -- see
// map_feature_data.gd / battle_grid.gd) AND character sprites (see
// unit_data.gd / unit_node.gd's _apply_wind_sway()). Fully generic --
// shader_type canvas_item operating on UV.y -- so the exact same file
// works for either without any code changes.
//
// ── WIND SWAY (horizontal) ───────────────────────────────────────────────
// Offsets vertices horizontally with a blend of two sine waves at
// different speeds (reads as gentle organic wind rather than a perfectly
// repeating metronome), weighted by sway_pivot so only the region ABOVE
// the pivot line moves at all, ramping smoothly up to full strength at the
// very top of the frame.
//
// sway_pivot MATTERS A LOT for character sprites specifically: an
// animated character's sprite sheet is almost always padded with
// transparent space around the actual character, so every frame (idle,
// attack, hurt, ...) shares one uniform frame size without the character
// visibly shifting between frames. If sway_pivot is left at 1.0 (anchor at
// the very bottom of the FRAME), that transparent padding below the actual
// feet gets counted as part of the character's height -- so the real,
// visible portion of the sprite ends up sitting in the middle of the
// weighting curve instead of at its "anchored" extreme, and the whole
// visible character shifts together instead of just its top. Lowering
// sway_pivot (see unit_data.gd's sway_pivot) moves the anchor line up to
// roughly where the character's actual feet are within the padded frame,
// so only their upper body actually sways. Map features default to 1.0
// (unchanged from before this was added) since a static, tightly-cropped
// Sprite2D texture doesn't have this padding problem.
//
// ── BREATHING (vertical, off by default) ─────────────────────────────────
// A separate, independent effect: a small vertical bob concentrated around
// a "chest" band (breathing_center/breathing_width), oscillating on its
// OWN clock (breathing_speed/breathing_phase) -- deliberately NOT tied to
// sway's phase_offset/unison system at all, even when sways_in_wind and
// sway_in_unison are both on. Real breathing doesn't sync between people
// the way wind affects everything at once, so every unit that breathes
// always gets its own independently randomized breathing_phase regardless
// of its wind-sway unison setting -- see unit_node.gd's _apply_wind_sway().
//
// UNISON vs INDIVIDUAL (wind sway only): both callers default phase_offset
// to this shader's own default (0.0), which is what makes everything sway
// IN SYNC -- one coherent gust passing through the whole scene, features
// and unison-enabled units together. Setting phase_offset to something
// else (either caller can, per-instance) makes that one sprite sway
// independently instead -- map features never do this (always unison),
// but UnitData.sway_in_unison = false gives an individual unit its own
// randomized phase for exactly this reason.
//
// TUNING: every uniform below is exposed as an @export field on both
// MapFeatureData (per feature type) and UnitData (per unit) -- see those
// files for the exact numbers currently in use.

shader_type canvas_item;

// ── Wind sway ──
uniform bool sways = true;   // map features never set this explicitly, so they keep swaying by default; unit_node.gd sets it from unit_data.sways_in_wind so a unit can breathe without swaying
uniform float sway_speed : hint_range(0.0, 5.0) = 1.0;
uniform float sway_strength : hint_range(0.0, 20.0) = 4.0;   // pixels of horizontal offset at the very top of the sprite
uniform float sway_pivot : hint_range(0.0, 1.0) = 1.0;       // UV.y at/below which sway is ZERO -- see the big comment above
uniform float phase_offset = 0.0;   // 0.0 = sways in unison with everything else also left at the default; set per-instance to make just that one sprite sway independently

// ── Breathing ──
uniform bool breathes = false;
uniform float breathing_speed : hint_range(0.0, 3.0) = 0.5;
uniform float breathing_strength : hint_range(0.0, 10.0) = 1.5;   // pixels of vertical offset at the peak of the breath
uniform float breathing_center : hint_range(0.0, 1.0) = 0.3;      // UV.y of the "chest" -- center of the affected band
uniform float breathing_width : hint_range(0.01, 1.0) = 0.15;     // how tall that band is -- smaller = tighter/more localized
uniform float breathing_phase = 0.0;   // always randomized per-instance in GDScript, independent of phase_offset above -- see the big comment

void vertex() {
	if (sways) {
		// Zero sway at/below sway_pivot, ramping up (eased, not linear) to
		// full strength at the very top of the frame (UV.y = 0).
		float above_pivot = clamp((sway_pivot - UV.y) / max(sway_pivot, 0.001), 0.0, 1.0);
		float root_weight = above_pivot * above_pivot;

		// Two sine waves at different speeds/weights blended together reads
		// as gentle organic wind rather than a perfectly repeating metronome.
		float wave = sin(TIME * sway_speed + phase_offset) * 0.7
				   + sin(TIME * sway_speed * 1.7 + phase_offset * 1.3) * 0.3;

		VERTEX.x += wave * sway_strength * root_weight;
	}

	if (breathes) {
		// A bump centered on breathing_center, fading out both above
		// (shoulders/head) and below (waist/legs) -- entirely independent
		// of sway_pivot/root_weight above, since breathing should still
		// read even on a body that's fully "anchored" against wind sway.
		float dist_from_chest = (UV.y - breathing_center) / breathing_width;
		float breathing_weight = exp(-dist_from_chest * dist_from_chest);
		float breath = sin(TIME * breathing_speed + breathing_phase);
		// CHANGED: was VERTEX.y -= ... -- that moved the chest the wrong
		// direction on inhale, so this is flipped.
		VERTEX.y += breath * breathing_strength * breathing_weight;
	}
}
