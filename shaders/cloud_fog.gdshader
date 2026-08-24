shader_type canvas_item;

// ── PROCEDURAL CLOUD-LIKE FOG SHADER ─────────────────────────────────────
// Generates soft, irregular cloud blobs entirely from math -- no texture
// or art asset required. Apply this to a plain ColorRect (any size/color;
// the shader below ignores it and decides the final color itself).
//
// HOW IT WORKS (for beginners):
//   1. hash() turns a 2D coordinate into a pseudo-random number. On its
//      own this just looks like static (like an untuned TV).
//   2. noise() smoothly blends between hash() values at nearby points, so
//      close-together pixels get similar numbers instead of static --
//      this alone already looks like soft, blobby gray blotches.
//   3. fbm() ("fractal brownian motion") stacks several octaves of that
//      noise on top of each other, each one smaller and fainter than the
//      last. This is the standard trick that turns "soft blotches" into
//      something that actually reads as clouds/smoke, by mixing big soft
//      shapes with smaller wispy detail.
//   4. smoothstep() turns the raw noise number into a MASK: fully see-
//      through below a threshold, fully opaque above it, with a soft
//      feathered transition in between -- that feathered transition is
//      what makes the edges look like puffy cloud edges instead of a
//      hard-edged rubber stamp.
//   5. TIME slowly shifts the noise sideways every frame, so the cloud
//      shape itself gently churns/billows on its own -- separate from
//      (and underneath) any left-right sway you apply to the whole node
//      from GDScript.

uniform float cloud_scale : hint_range(1.0, 30.0) = 8.0;
// How big each cloud blob is. Bigger number = smaller, more numerous
// blobs. Smaller number = fewer, larger, puffier blobs.

uniform float density : hint_range(0.0, 1.0) = 0.55;
// How much of the band ends up covered in visible cloud vs. empty gaps.
// Higher = thicker, more solid-looking fog. Lower = wispier, patchier fog.

uniform float softness : hint_range(0.01, 1.0) = 0.35;
// How feathered each blob's edge is. Higher = softer, more diffuse edges.
// Lower = more defined, puffier edges.

uniform float drift_speed : hint_range(0.0, 2.0) = 0.05;
// How fast the cloud SHAPE itself slowly billows/shifts over time. This is
// separate from any left-right sway of the whole band done in the .gd
// script -- keep this low, a little goes a long way.

uniform float vertical_squash : hint_range(0.1, 4.0) = 1.0;
// Controls how "flattened" the cloud blobs look vertically compared to
// horizontally. LOWER than 1.0 = wider, flatter puffs (good for a short
// band, like fog hugging the ground). 1.0 = natural, unsquashed blobs --
// the right choice once the band covers a large vertical area (like the
// whole screen), since a flattening factor tuned for a short band will
// stretch into tall vertical streaks on a tall one.

uniform vec4 cloud_color : source_color = vec4(0.85, 0.87, 0.9, 1.0);
// Base tint of the fog. Default is a pale, slightly cool white-gray.

uniform float opacity : hint_range(0.0, 1.0) = 0.35;
// Overall maximum opacity for this band. Layers meant to look further
// away should use a LOWER value here.

uniform float top_fade : hint_range(0.0, 1.0) = 0.6;
// How much of the band's TOP portion fades to fully transparent, so the
// fog blends softly into the scene above it instead of ending in a hard
// horizontal line. 0 = no fade (solid all the way to the top edge).

float hash(vec2 p) {
	// Turns a 2D coordinate into a pseudo-random number between 0 and 1.
	// The specific formula has no special meaning -- it's just a cheap,
	// well-known way to get noisy-but-repeatable output from a coordinate.
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	// Smoothly interpolates between hash() values at the 4 corners of the
	// grid cell containing 'p', so nearby points return similar numbers.
	// This turns random static into smooth, blobby noise.
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);   // eases the blend so it's curved, not linear
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(vec2 p) {
	// Layers several "octaves" of noise() at increasing frequency and
	// decreasing strength -- the standard technique for making noise look
	// organic (clouds, smoke, terrain) instead of one smooth, featureless
	// blur.
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 uv = UV;

	// Stretch the noise horizontally so blobs read as wide, flat puffs
	// (like real low-lying fog) rather than round dots, then slowly drift
	// the sampling coordinate sideways over time for a gentle, ever-
	// shifting billow.
	vec2 noise_uv = vec2(uv.x * cloud_scale, uv.y * cloud_scale * vertical_squash);
	noise_uv.x += TIME * drift_speed;

	float n = fbm(noise_uv);

	// The soft-edged mask: fully transparent below the threshold, fully
	// "on" above it, with a smooth feathered transition of width
	// "softness" in between.
	float threshold = 1.0 - density;
	float cloud_mask = smoothstep(threshold - softness, threshold + softness, n);

	// Fades the very top of the band down to transparent so it blends
	// into the scene above instead of ending in a hard line.
	float vertical_fade = mix(1.0, smoothstep(0.0, 1.0, uv.y), top_fade);

	float final_alpha = cloud_mask * vertical_fade * opacity;

	COLOR = vec4(cloud_color.rgb, cloud_color.a * final_alpha);
}
