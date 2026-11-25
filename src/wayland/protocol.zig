//! Wayland protocol interfaces: names, versions and opcodes, from
//! wayland.xml, xdg-shell.xml and linux-dmabuf-v1.xml. Requests are sent by
//! clients, events by the server; each list starts at opcode 0.

pub const wl_display = struct {
    pub const name = "wl_display";
    pub const id: u32 = 1;
    pub const request = struct {
        pub const sync = 0;
        pub const get_registry = 1;
    };
    pub const event = struct {
        pub const @"error" = 0;
        pub const delete_id = 1;
    };
    pub const err = struct {
        pub const invalid_object = 0;
        pub const invalid_method = 1;
        pub const no_memory = 2;
        pub const implementation = 3;
    };
};

pub const wl_registry = struct {
    pub const name = "wl_registry";
    pub const request = struct {
        pub const bind = 0;
    };
    pub const event = struct {
        pub const global = 0;
        pub const global_remove = 1;
    };
};

pub const wl_callback = struct {
    pub const name = "wl_callback";
    pub const event = struct {
        pub const done = 0;
    };
};

pub const wl_compositor = struct {
    pub const name = "wl_compositor";
    pub const version = 6;
    pub const request = struct {
        pub const create_surface = 0;
        pub const create_region = 1;
    };
};

pub const wl_surface = struct {
    pub const name = "wl_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const attach = 1;
        pub const damage = 2;
        pub const frame = 3;
        pub const set_opaque_region = 4;
        pub const set_input_region = 5;
        pub const commit = 6;
        pub const set_buffer_transform = 7;
        pub const set_buffer_scale = 8;
        pub const damage_buffer = 9;
    };
    pub const event = struct {
        /// It is shown on an output (or no longer is).
        pub const enter = 0;
        pub const leave = 1;
        pub const preferred_buffer_scale = 2;
        pub const preferred_buffer_transform = 3;
    };
    pub const err = struct {
        pub const invalid_scale = 0;
        pub const invalid_transform = 1;
        pub const invalid_size = 2;
    };
};

pub const wl_region = struct {
    pub const name = "wl_region";
    pub const request = struct {
        pub const destroy = 0;
        pub const add = 1;
        pub const subtract = 2;
    };
};

pub const wl_buffer = struct {
    pub const name = "wl_buffer";
    pub const request = struct {
        pub const destroy = 0;
    };
    pub const event = struct {
        pub const release = 0;
    };
};

pub const wl_shm = struct {
    pub const name = "wl_shm";
    pub const version = 1;
    pub const request = struct {
        pub const create_pool = 0;
    };
    pub const event = struct {
        pub const format = 0;
    };
    pub const format = struct {
        pub const argb8888 = 0;
        pub const xrgb8888 = 1;
        /// Other formats are their DRM fourcc codes.
        pub const rgb565 = fourcc.rgb565;
        pub const bgr565 = fourcc.bgr565;
    };
    pub const err = struct {
        pub const invalid_format = 0;
        pub const invalid_stride = 1;
        pub const invalid_fd = 2;
    };
};

pub const wl_shm_pool = struct {
    pub const name = "wl_shm_pool";
    pub const request = struct {
        pub const create_buffer = 0;
        pub const destroy = 1;
        pub const resize = 2;
    };
};

/// Surfaces in other surfaces (a video in a window, say), placed relative
/// to their parent.
pub const wl_subcompositor = struct {
    pub const name = "wl_subcompositor";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_subsurface = 1;
    };
    pub const err = struct {
        pub const bad_surface = 0;
        pub const bad_parent = 1;
    };
};

pub const wl_subsurface = struct {
    pub const name = "wl_subsurface";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_position = 1;
        pub const place_above = 2;
        pub const place_below = 3;
        pub const set_sync = 4;
        pub const set_desync = 5;
    };
    pub const err = struct {
        pub const bad_surface = 0;
    };
};

/// A screen.
pub const wl_output = struct {
    pub const name = "wl_output";
    pub const version = 4;
    pub const request = struct {
        /// Since version 3.
        pub const release = 0;
    };
    pub const event = struct {
        pub const geometry = 0;
        pub const mode = 1;
        /// Since version 2: the end of a batch of these events.
        pub const done = 2;
        pub const scale = 3;
        /// Since version 4.
        pub const name = 4;
        pub const description = 5;
    };
    pub const subpixel = struct {
        pub const unknown = 0;
    };
    pub const transform = struct {
        pub const normal = 0;
        pub const @"90" = 1;
        pub const @"180" = 2;
        pub const @"270" = 3;
        pub const flipped = 4;
        pub const flipped_90 = 5;
        pub const flipped_180 = 6;
        pub const flipped_270 = 7;
    };
    pub const mode_flags = struct {
        pub const current = 1;
        pub const preferred = 2;
    };
};

pub const xdg_wm_base = struct {
    pub const name = "xdg_wm_base";
    /// Version 6 adds the suspended state.
    pub const version = 6;
    pub const request = struct {
        pub const destroy = 0;
        pub const create_positioner = 1;
        pub const get_xdg_surface = 2;
        pub const pong = 3;
    };
    pub const event = struct {
        pub const ping = 0;
    };
    pub const err = struct {
        pub const role = 0;
        pub const defunct_surfaces = 1;
        pub const not_the_topmost_popup = 2;
        pub const invalid_popup_parent = 3;
        pub const invalid_surface_state = 4;
        pub const invalid_positioner = 5;
    };
};

pub const xdg_surface = struct {
    pub const name = "xdg_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const get_toplevel = 1;
        pub const get_popup = 2;
        pub const set_window_geometry = 3;
        pub const ack_configure = 4;
    };
    pub const event = struct {
        pub const configure = 0;
    };
    pub const err = struct {
        pub const not_constructed = 1;
        pub const already_constructed = 2;
        pub const unconfigured_buffer = 3;
    };
};

/// Where a popup goes, relative to its parent.
pub const xdg_positioner = struct {
    pub const name = "xdg_positioner";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_size = 1;
        pub const set_anchor_rect = 2;
        pub const set_anchor = 3;
        pub const set_gravity = 4;
        pub const set_constraint_adjustment = 5;
        pub const set_offset = 6;
        /// Since version 3.
        pub const set_reactive = 7;
        pub const set_parent_size = 8;
        pub const set_parent_configure = 9;
    };
    /// Anchors (on the anchor rectangle) and gravities (the direction the
    /// popup extends from the anchor) share these values.
    pub const anchor = struct {
        pub const none = 0;
        pub const top = 1;
        pub const bottom = 2;
        pub const left = 3;
        pub const right = 4;
        pub const top_left = 5;
        pub const bottom_left = 6;
        pub const top_right = 7;
        pub const bottom_right = 8;
    };
    /// What it may do to stay on screen (`set_constraint_adjustment`).
    pub const constraint_adjustment = struct {
        pub const slide_x = 1;
        pub const slide_y = 2;
        pub const flip_x = 4;
        pub const flip_y = 8;
        pub const resize_x = 16;
        pub const resize_y = 32;
    };
    pub const err = struct {
        pub const invalid_input = 0;
    };
};

/// A menu, tooltip or the like: a surface above its parent.
pub const xdg_popup = struct {
    pub const name = "xdg_popup";
    pub const request = struct {
        pub const destroy = 0;
        pub const grab = 1;
        /// Since version 3.
        pub const reposition = 2;
    };
    pub const event = struct {
        pub const configure = 0;
        pub const popup_done = 1;
        /// Since version 3.
        pub const repositioned = 2;
    };
    pub const err = struct {
        pub const invalid_grab = 0;
    };
};

pub const xdg_toplevel = struct {
    pub const name = "xdg_toplevel";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_parent = 1;
        pub const set_title = 2;
        pub const set_app_id = 3;
        pub const show_window_menu = 4;
        pub const move = 5;
        pub const resize = 6;
        pub const set_max_size = 7;
        pub const set_min_size = 8;
        pub const set_maximized = 9;
        pub const unset_maximized = 10;
        pub const set_fullscreen = 11;
        pub const unset_fullscreen = 12;
        pub const set_minimized = 13;
    };
    pub const event = struct {
        pub const configure = 0;
        pub const close = 1;
        /// Since version 4.
        pub const configure_bounds = 2;
        /// Since version 5.
        pub const wm_capabilities = 3;
    };
    pub const state = struct {
        pub const maximized = 1;
        pub const fullscreen = 2;
        pub const resizing = 3;
        pub const activated = 4;
        /// Since version 2.
        pub const tiled_left = 5;
        pub const tiled_right = 6;
        pub const tiled_top = 7;
        pub const tiled_bottom = 8;
        /// Since version 6: the window cannot be seen (it is covered), so
        /// the client need not draw it.
        pub const suspended = 9;
    };
    pub const wm_capabilities = struct {
        pub const window_menu = 1;
        pub const maximize = 2;
        pub const fullscreen = 3;
        pub const minimize = 4;
    };
};

/// Server-side vs client-side window decoration negotiation
/// (`xdg-decoration-unstable-v1.xml`).
pub const zxdg_decoration_manager_v1 = struct {
    pub const name = "zxdg_decoration_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_toplevel_decoration = 1;
    };
};

pub const zxdg_toplevel_decoration_v1 = struct {
    pub const name = "zxdg_toplevel_decoration_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const set_mode = 1;
        pub const unset_mode = 2;
    };
    pub const event = struct {
        pub const configure = 0;
    };
    pub const mode = struct {
        pub const client_side = 1;
        pub const server_side = 2;
    };
    pub const err = struct {
        pub const unconfigured_buffer = 0;
        pub const already_constructed = 1;
        pub const orphaned = 2;
    };
};

pub const zwp_linux_dmabuf_v1 = struct {
    pub const name = "zwp_linux_dmabuf_v1";
    pub const version = 3;
    pub const request = struct {
        pub const destroy = 0;
        pub const create_params = 1;
    };
    pub const event = struct {
        pub const format = 0;
        pub const modifier = 1;
    };
};

pub const zwp_linux_buffer_params_v1 = struct {
    pub const name = "zwp_linux_buffer_params_v1";
    pub const request = struct {
        pub const destroy = 0;
        pub const add = 1;
        pub const create = 2;
        pub const create_immed = 3;
    };
    pub const event = struct {
        pub const created = 0;
        pub const failed = 1;
    };
    pub const err = struct {
        pub const already_used = 0;
        pub const plane_idx = 1;
        pub const plane_set = 2;
        pub const incomplete = 3;
        pub const invalid_format = 4;
        pub const invalid_dimensions = 5;
        pub const out_of_bounds = 6;
        pub const invalid_wl_buffer = 7;
    };
};

/// DRM fourcc codes (drm_fourcc.h).
pub const fourcc = struct {
    fn code(s: *const [4]u8) u32 {
        return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
    }
    pub const xrgb8888 = code("XR24");
    pub const argb8888 = code("AR24");
    /// Red in the top 5 bits.
    pub const rgb565 = code("RG16");
    /// Red in the low 5 bits.
    pub const bgr565 = code("BG16");
};

/// DRM format modifiers (drm_fourcc.h).
pub const modifier = struct {
    pub const linear: u64 = 0;
};

pub const wl_seat = struct {
    pub const name = "wl_seat";
    pub const version = 5;
    pub const request = struct {
        pub const get_pointer = 0;
        pub const get_keyboard = 1;
        pub const get_touch = 2;
        pub const release = 3;
    };
    pub const event = struct {
        pub const capabilities = 0;
        pub const name = 1;
    };
    pub const capability = struct {
        pub const pointer = 1;
        pub const keyboard = 2;
        pub const touch = 4;
    };
};

/// A touchscreen's touches, each with an ID while it lasts.
pub const wl_touch = struct {
    pub const name = "wl_touch";
    pub const request = struct {
        /// Since version 3.
        pub const release = 0;
    };
    pub const event = struct {
        /// serial, time, surface, id, x, y: on the surface.
        pub const down = 0;
        /// serial, time, id.
        pub const up = 1;
        /// time, id, x, y.
        pub const motion = 2;
        pub const frame = 3;
        /// The touches are the compositor's now (it moves a window, say):
        /// forget them.
        pub const cancel = 4;
    };
};

pub const wl_pointer = struct {
    pub const name = "wl_pointer";
    pub const request = struct {
        pub const set_cursor = 0;
        pub const release = 1;
    };
    pub const event = struct {
        pub const enter = 0;
        pub const leave = 1;
        pub const motion = 2;
        pub const button = 3;
        pub const axis = 4;
        pub const frame = 5;
        pub const axis_source = 6;
        pub const axis_stop = 7;
        pub const axis_discrete = 8;
    };
    pub const button_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
    pub const axis = struct {
        pub const vertical_scroll = 0;
        pub const horizontal_scroll = 1;
    };
    pub const axis_source = struct {
        pub const wheel = 0;
        pub const finger = 1;
        pub const continuous = 2;
        pub const wheel_tilt = 3;
    };
    pub const err = struct {
        pub const role = 0;
    };
};

pub const wl_keyboard = struct {
    pub const name = "wl_keyboard";
    pub const request = struct {
        pub const release = 0;
    };
    pub const event = struct {
        pub const keymap = 0;
        pub const enter = 1;
        pub const leave = 2;
        pub const key = 3;
        pub const modifiers = 4;
        pub const repeat_info = 5;
    };
    pub const keymap_format = struct {
        /// Raw Linux evdev key codes, without an XKB keymap.
        pub const no_keymap = 0;
        pub const xkb_v1 = 1;
    };
    pub const key_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
};

/// Copy and paste (the clipboard is the "selection") and drag and drop.
pub const wl_data_device_manager = struct {
    pub const name = "wl_data_device_manager";
    pub const version = 3;
    pub const request = struct {
        pub const create_data_source = 0;
        pub const get_data_device = 1;
    };
    /// Drag-and-drop actions (since version 3).
    pub const dnd_action = struct {
        pub const none = 0;
        pub const copy = 1;
        pub const move = 2;
        pub const ask = 4;
        pub const all = copy | move | ask;
    };
};

pub const wl_data_source = struct {
    pub const name = "wl_data_source";
    pub const request = struct {
        pub const offer = 0;
        pub const destroy = 1;
        /// Since version 3.
        pub const set_actions = 2;
    };
    pub const event = struct {
        pub const target = 0;
        /// Write the data, as this MIME type, to the file descriptor, then
        /// close it.
        pub const send = 1;
        /// Another source replaced it (or the drag failed): it can be
        /// destroyed.
        pub const cancelled = 2;
        pub const dnd_drop_performed = 3;
        pub const dnd_finished = 4;
        pub const action = 5;
    };
    pub const err = struct {
        pub const invalid_action_mask = 0;
        pub const invalid_source = 1;
    };
};

pub const wl_data_device = struct {
    pub const name = "wl_data_device";
    pub const request = struct {
        pub const start_drag = 0;
        pub const set_selection = 1;
        /// Since version 2.
        pub const release = 2;
    };
    pub const event = struct {
        /// A new wl_data_offer (its MIME types follow).
        pub const data_offer = 0;
        pub const enter = 1;
        pub const leave = 2;
        pub const motion = 3;
        pub const drop = 4;
        /// The clipboard's offer (or none), sent before keyboard focus
        /// and when it changes.
        pub const selection = 5;
    };
    pub const err = struct {
        pub const role = 0;
        pub const used_source = 1;
    };
};

pub const wl_data_offer = struct {
    pub const name = "wl_data_offer";
    pub const request = struct {
        pub const accept = 0;
        /// Asks for the data, as a MIME type, written to a file descriptor.
        pub const receive = 1;
        pub const destroy = 2;
        /// Since version 3.
        pub const finish = 3;
        pub const set_actions = 4;
    };
    pub const event = struct {
        pub const offer = 0;
        pub const source_actions = 1;
        pub const action = 2;
    };
    pub const err = struct {
        pub const invalid_finish = 0;
        pub const invalid_action_mask = 1;
        pub const invalid_action = 2;
        pub const invalid_offer = 3;
    };
};

/// The cursor-shape protocol (staging): clients choose the pointer's
/// picture by name rather than drawing it.
pub const wp_cursor_shape_manager_v1 = struct {
    pub const name = "wp_cursor_shape_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_pointer = 1;
        pub const get_tablet_tool_v2 = 2;
    };
};

pub const wp_cursor_shape_device_v1 = struct {
    pub const name = "wp_cursor_shape_device_v1";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_shape = 1;
    };
    /// CSS cursor names (version 1).
    pub const shape = struct {
        pub const default = 1;
        pub const context_menu = 2;
        pub const help = 3;
        pub const pointer = 4;
        pub const progress = 5;
        pub const wait = 6;
        pub const cell = 7;
        pub const crosshair = 8;
        pub const text = 9;
        pub const vertical_text = 10;
        pub const alias = 11;
        pub const copy = 12;
        pub const move = 13;
        pub const no_drop = 14;
        pub const not_allowed = 15;
        pub const grab = 16;
        pub const grabbing = 17;
        pub const e_resize = 18;
        pub const n_resize = 19;
        pub const ne_resize = 20;
        pub const nw_resize = 21;
        pub const s_resize = 22;
        pub const se_resize = 23;
        pub const sw_resize = 24;
        pub const w_resize = 25;
        pub const ew_resize = 26;
        pub const ns_resize = 27;
        pub const nesw_resize = 28;
        pub const nwse_resize = 29;
        pub const col_resize = 30;
        pub const row_resize = 31;
        pub const all_scroll = 32;
        pub const zoom_in = 33;
        pub const zoom_out = 34;
    };
    pub const err = struct {
        pub const invalid_shape = 1;
    };
};

/// Locking or confining the pointer to a surface
/// (pointer-constraints-unstable-v1.xml).
pub const zwp_pointer_constraints_v1 = struct {
    pub const name = "zwp_pointer_constraints_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const lock_pointer = 1;
        pub const confine_pointer = 2;
    };
    pub const err = struct {
        pub const already_constrained = 1;
    };
    pub const lifetime = struct {
        pub const oneshot = 1;
        pub const persistent = 2;
    };
};

pub const zwp_locked_pointer_v1 = struct {
    pub const name = "zwp_locked_pointer_v1";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_cursor_position_hint = 1;
        pub const set_region = 2;
    };
    pub const event = struct {
        pub const locked = 0;
        pub const unlocked = 1;
    };
};

pub const zwp_confined_pointer_v1 = struct {
    pub const name = "zwp_confined_pointer_v1";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_region = 1;
    };
    pub const event = struct {
        pub const confined = 0;
        pub const unconfined = 1;
    };
};

/// The pointer's movements as they are, not limited by the screen's edges
/// (relative-pointer-unstable-v1.xml).
pub const zwp_relative_pointer_manager_v1 = struct {
    pub const name = "zwp_relative_pointer_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_relative_pointer = 1;
    };
};

pub const zwp_relative_pointer_v1 = struct {
    pub const name = "zwp_relative_pointer_v1";
    pub const request = struct {
        pub const destroy = 0;
    };
    pub const event = struct {
        pub const relative_motion = 0;
    };
};

/// Presentation timing feedback (`presentation-time.xml`).
pub const wp_presentation = struct {
    pub const name = "wp_presentation";
    pub const version = 2;
    pub const request = struct {
        pub const destroy = 0;
        pub const feedback = 1;
    };
    pub const event = struct {
        pub const clock_id = 0;
    };
    pub const err = struct {
        pub const invalid_timestamp = 0;
        pub const invalid_flag = 1;
    };
    pub const clock = struct {
        /// `CLOCK_MONOTONIC` (1 on Linux).
        pub const monotonic = 1;
    };
};

pub const wp_presentation_feedback = struct {
    pub const name = "wp_presentation_feedback";
    pub const version = 2;
    pub const event = struct {
        pub const sync_output = 0;
        pub const presented = 1;
        pub const discarded = 2;
    };
    pub const kind = struct {
        pub const vsync = 0x1;
        pub const hw_clock = 0x2;
        pub const hw_completion = 0x4;
        pub const zero_copy = 0x8;
    };
};

/// Display refresh barrier constraints (`fifo-v1.xml`).
pub const wp_fifo_manager_v1 = struct {
    pub const name = "wp_fifo_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_fifo = 1;
    };
    pub const err = struct {
        pub const already_exists = 0;
    };
};

pub const wp_fifo_v1 = struct {
    pub const name = "wp_fifo_v1";
    pub const version = 1;
    pub const request = struct {
        pub const set_barrier = 0;
        pub const wait_barrier = 1;
        pub const destroy = 2;
    };
    pub const err = struct {
        pub const surface_destroyed = 0;
    };
};

/// Target presentation timestamp constraints (`commit-timing-v1.xml`).
pub const wp_commit_timing_manager_v1 = struct {
    pub const name = "wp_commit_timing_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_timer = 1;
    };
    pub const err = struct {
        pub const commit_timer_exists = 0;
    };
};

pub const wp_commit_timer_v1 = struct {
    pub const name = "wp_commit_timer_v1";
    pub const version = 1;
    pub const request = struct {
        pub const set_timestamp = 0;
        pub const destroy = 1;
    };
    pub const err = struct {
        pub const invalid_timestamp = 0;
        pub const timestamp_exists = 1;
        pub const surface_destroyed = 2;
    };
};

/// Explicit buffer synchronization via Linux DRM timeline syncobjs (`linux-drm-syncobj-v1.xml`).
pub const wp_linux_drm_syncobj_manager_v1 = struct {
    pub const name = "wp_linux_drm_syncobj_manager_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_surface = 1;
        pub const import_timeline = 2;
    };
    pub const err = struct {
        pub const surface_exists = 0;
        pub const invalid_timeline = 1;
    };
};

pub const wp_linux_drm_syncobj_timeline_v1 = struct {
    pub const name = "wp_linux_drm_syncobj_timeline_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
    };
};

pub const wp_linux_drm_syncobj_surface_v1 = struct {
    pub const name = "wp_linux_drm_syncobj_surface_v1";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const set_acquire_point = 1;
        pub const set_release_point = 2;
    };
    pub const err = struct {
        pub const no_surface = 1;
        pub const unsupported_buffer = 2;
        pub const no_buffer = 3;
        pub const no_acquire_point = 4;
        pub const no_release_point = 5;
        pub const conflicting_points = 6;
    };
};

/// Text input and input method integration (`text-input-unstable-v3.xml`).
pub const zwp_text_input_manager_v3 = struct {
    pub const name = "zwp_text_input_manager_v3";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const get_text_input = 1;
    };
};

pub const zwp_text_input_v3 = struct {
    pub const name = "zwp_text_input_v3";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const enable = 1;
        pub const disable = 2;
        pub const set_surrounding_text = 3;
        pub const set_text_change_cause = 4;
        pub const set_content_type = 5;
        pub const set_cursor_rectangle = 6;
        pub const commit = 7;
    };
    pub const event = struct {
        pub const enter = 0;
        pub const leave = 1;
        pub const preedit_string = 2;
        pub const commit_string = 3;
        pub const delete_surrounding_text = 4;
        pub const done = 5;
    };
    pub const change_cause = struct {
        pub const input_method = 0;
        pub const other = 1;
    };
    pub const content_hint = struct {
        pub const none = 0x0;
        pub const completion = 0x1;
        pub const spellcheck = 0x2;
        pub const auto_capitalization = 0x4;
        pub const lowercase = 0x8;
        pub const uppercase = 0x10;
        pub const titlecase = 0x20;
        pub const hidden_text = 0x40;
        pub const sensitive_data = 0x80;
        pub const latin = 0x100;
        pub const multiline = 0x200;
    };
    pub const content_purpose = struct {
        pub const normal = 0;
        pub const alpha = 1;
        pub const digits = 2;
        pub const number = 3;
        pub const phone = 4;
        pub const url = 5;
        pub const email = 6;
        pub const name = 7;
        pub const password = 8;
        pub const pin = 9;
        pub const date = 10;
        pub const time = 11;
        pub const datetime = 12;
        pub const terminal = 13;
    };
};

/// Linux input event codes (linux/input-event-codes.h).
pub const input = struct {
    pub const btn_left = 0x110;
    pub const btn_right = 0x111;
    pub const btn_middle = 0x112;
    pub const btn_side = 0x113;
    pub const btn_extra = 0x114;
    pub const btn_forward = 0x115;
    pub const btn_back = 0x116;
};
