#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_px;
layout(location = 2) in vec4 a_box;
layout(location = 3) in vec4 a_params;
out vec2 v_px;
out vec4 v_box;
out vec4 v_params;
void main() {
    gl_Position = vec4(a_pos, 0.0, 1.0);
    v_px = a_px;
    v_box = a_box;
    v_params = a_params;
}
