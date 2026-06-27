shader_type canvas_item;

uniform float speed = 0.1;
uniform float scale = 1.0;
uniform float density = 1.0;
uniform vec4 mist_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Simple value noise
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}

void fragment() {
    vec2 uv = UV * scale;
    uv.x += TIME * speed;

    float n = noise(uv);

    float alpha = n * density;
	
    float edge_fade = smoothstep(0.0, 0.2, UV.x) *
                      smoothstep(1.0, 0.8, UV.x) *
                      smoothstep(0.0, 0.2, UV.y) *
                      smoothstep(1.0, 0.8, UV.y);

    alpha *= edge_fade;

    // FIX: Set the RGB color, and isolate the alpha channel calculation
    COLOR.rgb = mist_color.rgb;
    COLOR.a = mist_color.a * alpha;
}