shader_type canvas_item;

uniform float wave_amplitude = 6.0;
uniform float wave_frequency = 10.0;
uniform float wave_speed = 3.0;
uniform vec4 line_color : source_color = vec4(0.6, 0.2, 1.0, 1.0);

void vertex() {
    // UV.x is stable along the line (0 → 1)
    float wave = sin(UV.x * wave_frequency + TIME * wave_speed);

    // IMPORTANT: move perpendicular to line direction
    VERTEX.y += wave * wave_amplitude;
}

void fragment() {
    COLOR = line_color;
}