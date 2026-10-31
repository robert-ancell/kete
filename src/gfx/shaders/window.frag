#version 330 core
// As shaders/window.zig: the window's rounded box's coverage (mode 0), or
// the shadow under it (mode 1).
in vec2 v_px;
in vec4 v_box;
in vec4 v_params;
out vec4 o_color;

float roundedBox(vec2 p, vec2 c, vec2 half_size, float radius) {
    vec2 q = abs(p - c) - half_size;
    vec2 m = max(q, vec2(0.0));
    return sqrt(m.x * m.x + m.y * m.y) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    vec2 c = v_box.xy;
    vec2 half_size = v_box.zw;
    float radius = v_params.x;
    float s = v_params.y;
    float mode = v_params.z;

    float d_win = roundedBox(v_px, c, half_size, radius);
    float cov = clamp(0.5 - d_win, 0.0, 1.0);

    float d_key = roundedBox(v_px, c + vec2(0.0, 4.0 * s), half_size, radius);
    float u_key = clamp(1.0 - max(d_key, 0.0) / (22.0 * s), 0.0, 1.0);
    float t_key = u_key * u_key * u_key;
    float d_amb = roundedBox(v_px, c + vec2(0.0, 1.0 * s), half_size, radius);
    float u_amb = clamp(1.0 - max(d_amb, 0.0) / (7.0 * s), 0.0, 1.0);
    float t_amb = u_amb * u_amb * (3.0 - 2.0 * u_amb);
    float band = clamp(1.0 - abs(d_win - 0.3 * s) / (0.9 * s), 0.0, 1.0) * clamp((d_win + 0.5) * 1e6, 0.0, 1.0);
    float outline = 0.18 * band;
    float shadow = clamp(0.28 * t_key + 0.14 * t_amb + outline, 0.0, 1.0);

    o_color = mode < 0.5 ? vec4(1.0, 1.0, 1.0, cov) : vec4(0.0, 0.0, 0.0, shadow);
}
