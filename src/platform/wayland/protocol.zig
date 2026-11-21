//! Interface opcodes and constants of the Wayland protocols Shotlet speaks
//! (from wayland.xml, xdg-shell.xml and the extension protocols).

pub const wl_display = struct {
    pub const id: u32 = 1;
    // requests
    pub const sync = 0;
    pub const get_registry = 1;
    // events
    pub const ev_error = 0;
    pub const ev_delete_id = 1;
};

pub const wl_registry = struct {
    pub const bind = 0;
    pub const ev_global = 0;
    pub const ev_global_remove = 1;
};

pub const wl_callback = struct {
    pub const ev_done = 0;
};

pub const wl_compositor = struct {
    pub const create_surface = 0;
    pub const create_region = 1;
};

pub const wl_region = struct {
    pub const destroy = 0;
    pub const add = 1;
    pub const subtract = 2;
};

pub const wl_shm = struct {
    pub const create_pool = 0;
    pub const ev_format = 0;
    pub const format_argb8888: u32 = 0;
    pub const format_xrgb8888: u32 = 1;
};

pub const wl_shm_pool = struct {
    pub const create_buffer = 0;
    pub const destroy = 1;
};

pub const wl_buffer = struct {
    pub const destroy = 0;
    pub const ev_release = 0;
};

pub const wl_surface = struct {
    pub const destroy = 0;
    pub const attach = 1;
    pub const damage = 2;
    pub const frame = 3;
    pub const set_opaque_region = 4;
    pub const set_input_region = 5;
    pub const commit = 6;
    pub const set_buffer_scale = 8;
    pub const damage_buffer = 9;
    pub const offset = 10; // since v5
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_preferred_buffer_scale = 2;
};

pub const wl_seat = struct {
    pub const get_pointer = 0;
    pub const get_keyboard = 1;
    pub const ev_capabilities = 0;
    pub const ev_name = 1;
    pub const cap_pointer: u32 = 1;
    pub const cap_keyboard: u32 = 2;
};

pub const wl_pointer = struct {
    pub const set_cursor = 0;
    pub const release = 1; // since v3
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_motion = 2;
    pub const ev_button = 3;
    pub const ev_axis = 4;
    pub const ev_frame = 5;
    pub const ev_axis_value120 = 9; // since v8
};

pub const wl_keyboard = struct {
    pub const release = 0; // since v3
    pub const ev_keymap = 0;
    pub const ev_enter = 1;
    pub const ev_leave = 2;
    pub const ev_key = 3;
    pub const ev_modifiers = 4;
    pub const ev_repeat_info = 5;
};

pub const wl_output = struct {
    pub const release = 0; // since v3
    pub const ev_geometry = 0;
    pub const ev_mode = 1;
    pub const ev_done = 2; // since v2
    pub const ev_scale = 3; // since v2
    pub const ev_name = 4; // since v4
    pub const ev_description = 5; // since v4
    pub const mode_current: u32 = 1;
};

pub const zxdg_output_manager_v1 = struct {
    pub const destroy = 0;
    pub const get_xdg_output = 1;
};

pub const zxdg_output_v1 = struct {
    pub const destroy = 0;
    pub const ev_logical_position = 0;
    pub const ev_logical_size = 1;
    pub const ev_done = 2;
    pub const ev_name = 3; // since v2
    pub const ev_description = 4; // since v2
};

pub const zwp_text_input_manager_v3 = struct {
    pub const destroy = 0;
    pub const get_text_input = 1;
};

pub const zwp_text_input_v3 = struct {
    pub const destroy = 0;
    pub const enable = 1;
    pub const disable = 2;
    pub const set_surrounding_text = 3;
    pub const set_text_change_cause = 4;
    pub const set_content_type = 5;
    pub const set_cursor_rectangle = 6;
    pub const commit = 7;
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_preedit_string = 2;
    pub const ev_commit_string = 3;
    pub const ev_delete_surrounding_text = 4;
    pub const ev_done = 5;
};

pub const xdg_wm_base = struct {
    pub const create_positioner = 1;
    pub const get_xdg_surface = 2;
    pub const pong = 3;
    pub const ev_ping = 0;
};

pub const xdg_surface = struct {
    pub const destroy = 0;
    pub const get_toplevel = 1;
    pub const set_window_geometry = 3;
    pub const ack_configure = 4;
    pub const ev_configure = 0;
};

pub const xdg_toplevel = struct {
    pub const destroy = 0;
    pub const set_title = 2;
    pub const set_app_id = 3;
    pub const set_parent = 1;
    pub const show_window_menu = 4;
    pub const move = 5;
    pub const set_max_size = 7;
    pub const set_min_size = 8;
    pub const set_maximized = 9;
    pub const unset_maximized = 10;
    pub const set_fullscreen = 11;
    pub const set_minimized = 13;
    pub const ev_configure = 0;
    pub const ev_close = 1;
    pub const ev_configure_bounds = 2;
    pub const state_maximized: u32 = 1;
};

/// wlr-layer-shell-unstable-v1 (KDE, wlroots compositors; not mutter)
pub const zwlr_layer_shell_v1 = struct {
    pub const get_layer_surface = 0;
    pub const layer_bottom: u32 = 1;
    pub const layer_top: u32 = 2;
    pub const layer_overlay: u32 = 3;
};

pub const zwlr_layer_surface_v1 = struct {
    pub const set_size = 0;
    pub const set_anchor = 1;
    pub const set_exclusive_zone = 2;
    pub const set_margin = 3;
    pub const set_keyboard_interactivity = 4;
    pub const ack_configure = 6;
    pub const destroy = 7;
    pub const ev_configure = 0;
    pub const ev_closed = 1;
    pub const anchor_top: u32 = 1;
    pub const anchor_bottom: u32 = 2;
    pub const anchor_left: u32 = 4;
    pub const anchor_right: u32 = 8;
    pub const keyboard_none: u32 = 0;
    pub const keyboard_exclusive: u32 = 1;
    pub const keyboard_on_demand: u32 = 2; // since v4
};

pub const wp_viewporter = struct {
    pub const get_viewport = 1;
};

pub const wp_viewport = struct {
    pub const destroy = 0;
    pub const set_destination = 2;
};

pub const wp_fractional_scale_manager_v1 = struct {
    pub const get_fractional_scale = 1;
};

pub const wp_fractional_scale_v1 = struct {
    pub const ev_preferred_scale = 0;
};

pub const wl_data_device_manager = struct {
    pub const create_data_source = 0;
    pub const get_data_device = 1;
};

pub const wl_data_source = struct {
    pub const offer = 0;
    pub const destroy = 1;
    pub const set_actions = 2; // since v3
    pub const ev_target = 0;
    pub const ev_send = 1;
    pub const ev_cancelled = 2;
    pub const ev_dnd_drop_performed = 3; // since v3
    pub const ev_dnd_finished = 4; // since v3
    pub const ev_action = 5; // since v3
};

pub const wl_data_device = struct {
    pub const start_drag = 0;
    pub const set_selection = 1;
    pub const ev_data_offer = 0;
    pub const ev_enter = 1;
    pub const ev_leave = 2;
    pub const ev_motion = 3;
    pub const ev_drop = 4;
    pub const ev_selection = 5;
};

/// wl_data_device_manager.dnd_action bits
pub const dnd_action_copy: u32 = 1;
pub const dnd_action_move: u32 = 2;

pub const wl_data_offer = struct {
    pub const accept = 0;
    pub const receive = 1;
    pub const destroy = 2;
    pub const finish = 3; // since v3
    pub const set_actions = 4; // since v3
    pub const ev_offer = 0;
};
