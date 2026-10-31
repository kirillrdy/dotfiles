//! Native Wayland interface metadata. Request/event order and type tables
//! match the protocol XML; zig build test compares all tables with the reference
//! wayland-scanner output. Normal builds need no generated C sources.
const c = @import("desktop-gtk.zig");
pub const Interface = c.struct_wl_interface;
const Message = c.struct_wl_message;

// Copyright © 2017 Drew DeVault
//
// Permission to use, copy, modify, distribute, and sell this
// software and its documentation for any purpose is hereby granted
// without fee, provided that the above copyright notice appear in
// all copies and that both that copyright notice and this permission
// notice appear in supporting documentation, and that the name of
// the copyright holders not be used in advertising or publicity
// pertaining to distribution of the software without specific,
// written prior permission.  The copyright holders make no
// representations about the suitability of this software for any
// purpose.  It is provided "as is" without express or implied
// warranty.
//
// THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
// SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
// SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
// AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
// ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
// THIS SOFTWARE.
// Layer-shell v4. Popup creation is not exposed by our surface API; only its
// interface identity is needed by the get_popup request's type table.
const layer_popup_type = Interface{ .name = "xdg_popup", .version = 7, .method_count = 0, .methods = null, .event_count = 0, .events = null };
const layer_shell_types = [_][*c]const Interface{ &zwlr_layer_surface_v1_interface, &wl_surface_interface, &wl_output_interface, null, null };
const layer_scalar_types = [_][*c]const Interface{ null, null, null, null };
const layer_popup_types = [_][*c]const Interface{&layer_popup_type};
const layer_shell_requests = [_]Message{
    .{ .name = "get_layer_surface", .signature = "no?ous", .types = @constCast(&layer_shell_types) },
    .{ .name = "destroy", .signature = "3", .types = @constCast(&layer_scalar_types) },
};
const layer_surface_requests = [_]Message{
    .{ .name = "set_size", .signature = "uu", .types = @constCast(&layer_scalar_types) },
    .{ .name = "set_anchor", .signature = "u", .types = @constCast(&layer_scalar_types) },
    .{ .name = "set_exclusive_zone", .signature = "i", .types = @constCast(&layer_scalar_types) },
    .{ .name = "set_margin", .signature = "iiii", .types = @constCast(&layer_scalar_types) },
    .{ .name = "set_keyboard_interactivity", .signature = "u", .types = @constCast(&layer_scalar_types) },
    .{ .name = "get_popup", .signature = "o", .types = @constCast(&layer_popup_types) },
    .{ .name = "ack_configure", .signature = "u", .types = @constCast(&layer_scalar_types) },
    .{ .name = "destroy", .signature = "", .types = @constCast(&layer_scalar_types) },
    .{ .name = "set_layer", .signature = "2u", .types = @constCast(&layer_scalar_types) },
};
const layer_surface_events = [_]Message{
    .{ .name = "configure", .signature = "uuu", .types = @constCast(&layer_scalar_types) },
    .{ .name = "closed", .signature = "", .types = @constCast(&layer_scalar_types) },
};
pub export const zwlr_layer_shell_v1_interface = Interface{ .name = "zwlr_layer_shell_v1", .version = 4, .method_count = layer_shell_requests.len, .methods = &layer_shell_requests, .event_count = 0, .events = null };
pub export const zwlr_layer_surface_v1_interface = Interface{ .name = "zwlr_layer_surface_v1", .version = 4, .method_count = layer_surface_requests.len, .methods = &layer_surface_requests, .event_count = layer_surface_events.len, .events = &layer_surface_events };

// Copyright © 2017 Red Hat Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice (including the next
// paragraph) shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
// Logical output sizes keep percentage placement accurate at fractional scales.
const xdg_output_types = [_][*c]const Interface{ &zxdg_output_v1_interface, &wl_output_interface };
const xdg_output_manager_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(&layer_scalar_types) },
    .{ .name = "get_xdg_output", .signature = "no", .types = @constCast(&xdg_output_types) },
};
const xdg_output_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(&layer_scalar_types) },
};
const xdg_output_events = [_]Message{
    .{ .name = "logical_position", .signature = "ii", .types = @constCast(&layer_scalar_types) },
    .{ .name = "logical_size", .signature = "ii", .types = @constCast(&layer_scalar_types) },
    .{ .name = "done", .signature = "", .types = @constCast(&layer_scalar_types) },
    .{ .name = "name", .signature = "2s", .types = @constCast(&layer_scalar_types) },
    .{ .name = "description", .signature = "2s", .types = @constCast(&layer_scalar_types) },
};
pub export const zxdg_output_manager_v1_interface = Interface{ .name = "zxdg_output_manager_v1", .version = 3, .method_count = xdg_output_manager_requests.len, .methods = &xdg_output_manager_requests, .event_count = 0, .events = null };
pub export const zxdg_output_v1_interface = Interface{ .name = "zxdg_output_v1", .version = 3, .method_count = xdg_output_requests.len, .methods = &xdg_output_requests, .event_count = xdg_output_events.len, .events = &xdg_output_events };

extern const wl_buffer_interface: Interface;
extern const wl_output_interface: Interface;
extern const wl_pointer_interface: Interface;
extern const wl_seat_interface: Interface;

// wlr-screencopy-unstable-v1.c
// /*
//  * Copyright © 2018 Simon Ser
//  * Copyright © 2019 Andri Yngvason
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice (including the next
//  * paragraph) shall be included in all copies or substantial portions of the
//  * Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const wlr_screencopy_unstable_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    null,
    &zwlr_screencopy_frame_v1_interface,
    null,
    &wl_output_interface,
    &zwlr_screencopy_frame_v1_interface,
    null,
    &wl_output_interface,
    null,
    null,
    null,
    null,
    &wl_buffer_interface,
    &wl_buffer_interface,
};
const zwlr_screencopy_manager_v1_requests = [_]Message{
    .{ .name = "capture_output", .signature = "nio", .types = @constCast(wlr_screencopy_unstable_v1_types[4..].ptr) },
    .{ .name = "capture_output_region", .signature = "nioiiii", .types = @constCast(wlr_screencopy_unstable_v1_types[7..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
};
const zwlr_screencopy_frame_v1_requests = [_]Message{
    .{ .name = "copy", .signature = "o", .types = @constCast(wlr_screencopy_unstable_v1_types[14..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "copy_with_damage", .signature = "2o", .types = @constCast(wlr_screencopy_unstable_v1_types[15..].ptr) },
};
const zwlr_screencopy_frame_v1_events = [_]Message{
    .{ .name = "buffer", .signature = "uuuu", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "flags", .signature = "u", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "ready", .signature = "uuu", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "failed", .signature = "", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "damage", .signature = "2uuuu", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "linux_dmabuf", .signature = "3uuu", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
    .{ .name = "buffer_done", .signature = "3", .types = @constCast(wlr_screencopy_unstable_v1_types[0..].ptr) },
};
pub export const zwlr_screencopy_manager_v1_interface: Interface = .{
    .name = "zwlr_screencopy_manager_v1",
    .version = 3,
    .method_count = 3,
    .methods = &zwlr_screencopy_manager_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const zwlr_screencopy_frame_v1_interface: Interface = .{
    .name = "zwlr_screencopy_frame_v1",
    .version = 3,
    .method_count = 3,
    .methods = &zwlr_screencopy_frame_v1_requests,
    .event_count = 7,
    .events = &zwlr_screencopy_frame_v1_events,
};

// wlr-data-control-unstable-v1.c
// /*
//  * Copyright © 2018 Simon Ser
//  * Copyright © 2019 Ivan Molodetskikh
//  *
//  * Permission to use, copy, modify, distribute, and sell this
//  * software and its documentation for any purpose is hereby granted
//  * without fee, provided that the above copyright notice appear in
//  * all copies and that both that copyright notice and this permission
//  * notice appear in supporting documentation, and that the name of
//  * the copyright holders not be used in advertising or publicity
//  * pertaining to distribution of the software without specific,
//  * written prior permission.  The copyright holders make no
//  * representations about the suitability of this software for any
//  * purpose.  It is provided "as is" without express or implied
//  * warranty.
//  *
//  * THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
//  * SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
//  * FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  * SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
//  * AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
//  * ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
//  * THIS SOFTWARE.
//  */
const wlr_data_control_unstable_v1_types = [_][*c]const Interface{
    null,
    null,
    &zwlr_data_control_source_v1_interface,
    &zwlr_data_control_device_v1_interface,
    &wl_seat_interface,
    &zwlr_data_control_source_v1_interface,
    &zwlr_data_control_source_v1_interface,
    &zwlr_data_control_offer_v1_interface,
    &zwlr_data_control_offer_v1_interface,
    &zwlr_data_control_offer_v1_interface,
};
const zwlr_data_control_manager_v1_requests = [_]Message{
    .{ .name = "create_data_source", .signature = "n", .types = @constCast(wlr_data_control_unstable_v1_types[2..].ptr) },
    .{ .name = "get_data_device", .signature = "no", .types = @constCast(wlr_data_control_unstable_v1_types[3..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
};
const zwlr_data_control_device_v1_requests = [_]Message{
    .{ .name = "set_selection", .signature = "?o", .types = @constCast(wlr_data_control_unstable_v1_types[5..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
    .{ .name = "set_primary_selection", .signature = "2?o", .types = @constCast(wlr_data_control_unstable_v1_types[6..].ptr) },
};
const zwlr_data_control_device_v1_events = [_]Message{
    .{ .name = "data_offer", .signature = "n", .types = @constCast(wlr_data_control_unstable_v1_types[7..].ptr) },
    .{ .name = "selection", .signature = "?o", .types = @constCast(wlr_data_control_unstable_v1_types[8..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
    .{ .name = "primary_selection", .signature = "2?o", .types = @constCast(wlr_data_control_unstable_v1_types[9..].ptr) },
};
const zwlr_data_control_source_v1_requests = [_]Message{
    .{ .name = "offer", .signature = "s", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
};
const zwlr_data_control_source_v1_events = [_]Message{
    .{ .name = "send", .signature = "sh", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
    .{ .name = "cancelled", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
};
const zwlr_data_control_offer_v1_requests = [_]Message{
    .{ .name = "receive", .signature = "sh", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
};
const zwlr_data_control_offer_v1_events = [_]Message{
    .{ .name = "offer", .signature = "s", .types = @constCast(wlr_data_control_unstable_v1_types[0..].ptr) },
};
pub export const zwlr_data_control_manager_v1_interface: Interface = .{
    .name = "zwlr_data_control_manager_v1",
    .version = 2,
    .method_count = 3,
    .methods = &zwlr_data_control_manager_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const zwlr_data_control_device_v1_interface: Interface = .{
    .name = "zwlr_data_control_device_v1",
    .version = 2,
    .method_count = 3,
    .methods = &zwlr_data_control_device_v1_requests,
    .event_count = 4,
    .events = &zwlr_data_control_device_v1_events,
};
pub export const zwlr_data_control_source_v1_interface: Interface = .{
    .name = "zwlr_data_control_source_v1",
    .version = 1,
    .method_count = 2,
    .methods = &zwlr_data_control_source_v1_requests,
    .event_count = 2,
    .events = &zwlr_data_control_source_v1_events,
};
pub export const zwlr_data_control_offer_v1_interface: Interface = .{
    .name = "zwlr_data_control_offer_v1",
    .version = 1,
    .method_count = 2,
    .methods = &zwlr_data_control_offer_v1_requests,
    .event_count = 1,
    .events = &zwlr_data_control_offer_v1_events,
};

// ext-foreign-toplevel-list-v1.c
// /*
//  * Copyright © 2018 Ilia Bozhinov
//  * Copyright © 2020 Isaac Freund
//  * Copyright © 2022 wb9688
//  * Copyright © 2023 i509VCB
//  *
//  * Permission to use, copy, modify, distribute, and sell this
//  * software and its documentation for any purpose is hereby granted
//  * without fee, provided that the above copyright notice appear in
//  * all copies and that both that copyright notice and this permission
//  * notice appear in supporting documentation, and that the name of
//  * the copyright holders not be used in advertising or publicity
//  * pertaining to distribution of the software without specific,
//  * written prior permission.  The copyright holders make no
//  * representations about the suitability of this software for any
//  * purpose.  It is provided "as is" without express or implied
//  * warranty.
//  *
//  * THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
//  * SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
//  * FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  * SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
//  * AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
//  * ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
//  * THIS SOFTWARE.
//  */
const ext_foreign_toplevel_list_v1_types = [_][*c]const Interface{
    null,
    &ext_foreign_toplevel_handle_v1_interface,
};
const ext_foreign_toplevel_list_v1_requests = [_]Message{
    .{ .name = "stop", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
};
const ext_foreign_toplevel_list_v1_events = [_]Message{
    .{ .name = "toplevel", .signature = "n", .types = @constCast(ext_foreign_toplevel_list_v1_types[1..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
};
const ext_foreign_toplevel_handle_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
};
const ext_foreign_toplevel_handle_v1_events = [_]Message{
    .{ .name = "closed", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
    .{ .name = "done", .signature = "", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
    .{ .name = "title", .signature = "s", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
    .{ .name = "app_id", .signature = "s", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
    .{ .name = "identifier", .signature = "s", .types = @constCast(ext_foreign_toplevel_list_v1_types[0..].ptr) },
};
pub export const ext_foreign_toplevel_list_v1_interface: Interface = .{
    .name = "ext_foreign_toplevel_list_v1",
    .version = 1,
    .method_count = 2,
    .methods = &ext_foreign_toplevel_list_v1_requests,
    .event_count = 2,
    .events = &ext_foreign_toplevel_list_v1_events,
};
pub export const ext_foreign_toplevel_handle_v1_interface: Interface = .{
    .name = "ext_foreign_toplevel_handle_v1",
    .version = 1,
    .method_count = 1,
    .methods = &ext_foreign_toplevel_handle_v1_requests,
    .event_count = 5,
    .events = &ext_foreign_toplevel_handle_v1_events,
};

// ext-image-capture-source-v1.c
// /*
//  * Copyright © 2022 Andri Yngvason
//  * Copyright © 2024 Simon Ser
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice (including the next
//  * paragraph) shall be included in all copies or substantial portions of the
//  * Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const ext_image_capture_source_v1_types = [_][*c]const Interface{
    &ext_image_capture_source_v1_interface,
    &wl_output_interface,
    &ext_image_capture_source_v1_interface,
    &ext_foreign_toplevel_handle_v1_interface,
};
const ext_image_capture_source_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_capture_source_v1_types[0..].ptr) },
};
const ext_output_image_capture_source_manager_v1_requests = [_]Message{
    .{ .name = "create_source", .signature = "no", .types = @constCast(ext_image_capture_source_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_capture_source_v1_types[0..].ptr) },
};
const ext_foreign_toplevel_image_capture_source_manager_v1_requests = [_]Message{
    .{ .name = "create_source", .signature = "no", .types = @constCast(ext_image_capture_source_v1_types[2..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_capture_source_v1_types[0..].ptr) },
};
pub export const ext_image_capture_source_v1_interface: Interface = .{
    .name = "ext_image_capture_source_v1",
    .version = 1,
    .method_count = 1,
    .methods = &ext_image_capture_source_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const ext_output_image_capture_source_manager_v1_interface: Interface = .{
    .name = "ext_output_image_capture_source_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &ext_output_image_capture_source_manager_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const ext_foreign_toplevel_image_capture_source_manager_v1_interface: Interface = .{
    .name = "ext_foreign_toplevel_image_capture_source_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &ext_foreign_toplevel_image_capture_source_manager_v1_requests,
    .event_count = 0,
    .events = null,
};

// ext-image-copy-capture-v1.c
// /*
//  * Copyright © 2021-2023 Andri Yngvason
//  * Copyright © 2024 Simon Ser
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice (including the next
//  * paragraph) shall be included in all copies or substantial portions of the
//  * Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const ext_image_copy_capture_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    null,
    &ext_image_copy_capture_session_v1_interface,
    &ext_image_capture_source_v1_interface,
    null,
    &ext_image_copy_capture_cursor_session_v1_interface,
    &ext_image_capture_source_v1_interface,
    &wl_pointer_interface,
    &ext_image_copy_capture_frame_v1_interface,
    &wl_buffer_interface,
    &ext_image_copy_capture_session_v1_interface,
};
const ext_image_copy_capture_manager_v1_requests = [_]Message{
    .{ .name = "create_session", .signature = "nou", .types = @constCast(ext_image_copy_capture_v1_types[4..].ptr) },
    .{ .name = "create_pointer_cursor_session", .signature = "noo", .types = @constCast(ext_image_copy_capture_v1_types[7..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
const ext_image_copy_capture_session_v1_requests = [_]Message{
    .{ .name = "create_frame", .signature = "n", .types = @constCast(ext_image_copy_capture_v1_types[10..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
const ext_image_copy_capture_session_v1_events = [_]Message{
    .{ .name = "buffer_size", .signature = "uu", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "shm_format", .signature = "u", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "dmabuf_device", .signature = "a", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "dmabuf_format", .signature = "ua", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "done", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "stopped", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
const ext_image_copy_capture_frame_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "attach_buffer", .signature = "o", .types = @constCast(ext_image_copy_capture_v1_types[11..].ptr) },
    .{ .name = "damage_buffer", .signature = "iiii", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "capture", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
const ext_image_copy_capture_frame_v1_events = [_]Message{
    .{ .name = "transform", .signature = "u", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "damage", .signature = "iiii", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "presentation_time", .signature = "uuu", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "ready", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "failed", .signature = "u", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
const ext_image_copy_capture_cursor_session_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "get_capture_session", .signature = "n", .types = @constCast(ext_image_copy_capture_v1_types[12..].ptr) },
};
const ext_image_copy_capture_cursor_session_v1_events = [_]Message{
    .{ .name = "enter", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "leave", .signature = "", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "position", .signature = "ii", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
    .{ .name = "hotspot", .signature = "ii", .types = @constCast(ext_image_copy_capture_v1_types[0..].ptr) },
};
pub export const ext_image_copy_capture_manager_v1_interface: Interface = .{
    .name = "ext_image_copy_capture_manager_v1",
    .version = 1,
    .method_count = 3,
    .methods = &ext_image_copy_capture_manager_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const ext_image_copy_capture_session_v1_interface: Interface = .{
    .name = "ext_image_copy_capture_session_v1",
    .version = 1,
    .method_count = 2,
    .methods = &ext_image_copy_capture_session_v1_requests,
    .event_count = 6,
    .events = &ext_image_copy_capture_session_v1_events,
};
pub export const ext_image_copy_capture_frame_v1_interface: Interface = .{
    .name = "ext_image_copy_capture_frame_v1",
    .version = 1,
    .method_count = 4,
    .methods = &ext_image_copy_capture_frame_v1_requests,
    .event_count = 5,
    .events = &ext_image_copy_capture_frame_v1_events,
};
pub export const ext_image_copy_capture_cursor_session_v1_interface: Interface = .{
    .name = "ext_image_copy_capture_cursor_session_v1",
    .version = 1,
    .method_count = 2,
    .methods = &ext_image_copy_capture_cursor_session_v1_requests,
    .event_count = 4,
    .events = &ext_image_copy_capture_cursor_session_v1_events,
};

// desktop-overview-v1.c
// /* SPDX-License-Identifier: MIT
//  */
const dotfiles_overview_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    null,
    null,
    null,
    null,
};
const dotfiles_overview_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "refresh", .signature = "", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "activate", .signature = "s", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "close", .signature = "s", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "switch_workspace", .signature = "u", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "move", .signature = "su", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
};
const dotfiles_overview_v1_events = [_]Message{
    .{ .name = "workspace", .signature = "usu", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "window", .signature = "suiiiiu", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
    .{ .name = "done", .signature = "", .types = @constCast(dotfiles_overview_v1_types[0..].ptr) },
};
pub export const dotfiles_overview_v1_interface: Interface = .{
    .name = "dotfiles_overview_v1",
    .version = 1,
    .method_count = 6,
    .methods = &dotfiles_overview_v1_requests,
    .event_count = 3,
    .events = &dotfiles_overview_v1_events,
};

// virtual-pointer.c
// /*
//  * Copyright © 2019 Josef Gajdusek
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice (including the next
//  * paragraph) shall be included in all copies or substantial portions of the
//  * Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const wlr_virtual_pointer_unstable_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    null,
    null,
    &wl_seat_interface,
    &zwlr_virtual_pointer_v1_interface,
    &wl_seat_interface,
    &wl_output_interface,
    &zwlr_virtual_pointer_v1_interface,
};
const zwlr_virtual_pointer_v1_requests = [_]Message{
    .{ .name = "motion", .signature = "uff", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "motion_absolute", .signature = "uuuuu", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "button", .signature = "uuu", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "axis", .signature = "uuf", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "frame", .signature = "", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "axis_source", .signature = "u", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "axis_stop", .signature = "uu", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "axis_discrete", .signature = "uufi", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
};
const zwlr_virtual_pointer_manager_v1_requests = [_]Message{
    .{ .name = "create_virtual_pointer", .signature = "?on", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[5..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[0..].ptr) },
    .{ .name = "create_virtual_pointer_with_output", .signature = "2?o?on", .types = @constCast(wlr_virtual_pointer_unstable_v1_types[7..].ptr) },
};
pub export const zwlr_virtual_pointer_v1_interface: Interface = .{
    .name = "zwlr_virtual_pointer_v1",
    .version = 2,
    .method_count = 9,
    .methods = &zwlr_virtual_pointer_v1_requests,
    .event_count = 0,
    .events = null,
};
pub export const zwlr_virtual_pointer_manager_v1_interface: Interface = .{
    .name = "zwlr_virtual_pointer_manager_v1",
    .version = 2,
    .method_count = 3,
    .methods = &zwlr_virtual_pointer_manager_v1_requests,
    .event_count = 0,
    .events = null,
};

pub const zwlr_screencopy_frame_v1 = opaque {};
pub const zwlr_screencopy_manager_v1 = opaque {};
pub const zwlr_data_control_device_v1 = opaque {};
pub const zwlr_data_control_manager_v1 = opaque {};
pub const zwlr_data_control_source_v1 = opaque {};
pub const zwlr_data_control_offer_v1 = opaque {};
pub const ext_foreign_toplevel_handle_v1 = opaque {};
pub const ext_foreign_toplevel_list_v1 = opaque {};
pub const ext_foreign_toplevel_image_capture_source_manager_v1 = opaque {};
pub const ext_image_capture_source_v1 = opaque {};
pub const ext_image_copy_capture_frame_v1 = opaque {};
pub const ext_image_copy_capture_manager_v1 = opaque {};
pub const ext_image_copy_capture_session_v1 = opaque {};
pub const dotfiles_overview_v1 = opaque {};

pub const ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT = @as(c_int, 0);
pub const ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT_REGION = @as(c_int, 1);
pub const ZWLR_SCREENCOPY_MANAGER_V1_DESTROY = @as(c_int, 2);
pub const ZWLR_SCREENCOPY_FRAME_V1_COPY = @as(c_int, 0);
pub const ZWLR_SCREENCOPY_FRAME_V1_DESTROY = @as(c_int, 1);
pub const ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT = @as(c_int, 1);

pub const ZWLR_DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE = @as(c_int, 0);
pub const ZWLR_DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE = @as(c_int, 1);
pub const ZWLR_DATA_CONTROL_MANAGER_V1_DESTROY = @as(c_int, 2);
pub const ZWLR_DATA_CONTROL_DEVICE_V1_SET_SELECTION = @as(c_int, 0);
pub const ZWLR_DATA_CONTROL_DEVICE_V1_DESTROY = @as(c_int, 1);
pub const ZWLR_DATA_CONTROL_SOURCE_V1_OFFER = @as(c_int, 0);
pub const ZWLR_DATA_CONTROL_SOURCE_V1_DESTROY = @as(c_int, 1);

pub const EXT_FOREIGN_TOPLEVEL_LIST_V1_DESTROY = @as(c_int, 1);
pub const EXT_FOREIGN_TOPLEVEL_HANDLE_V1_DESTROY = @as(c_int, 0);
pub const EXT_IMAGE_CAPTURE_SOURCE_V1_DESTROY = @as(c_int, 0);
pub const EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_CREATE_SOURCE = @as(c_int, 0);
pub const EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_DESTROY = @as(c_int, 1);
pub const EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_CREATE_SESSION = @as(c_int, 0);
pub const EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_DESTROY = @as(c_int, 2);
pub const EXT_IMAGE_COPY_CAPTURE_SESSION_V1_CREATE_FRAME = @as(c_int, 0);
pub const EXT_IMAGE_COPY_CAPTURE_SESSION_V1_DESTROY = @as(c_int, 1);
pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DESTROY = @as(c_int, 0);
pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ATTACH_BUFFER = @as(c_int, 1);
pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DAMAGE_BUFFER = @as(c_int, 2);
pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_CAPTURE = @as(c_int, 3);

pub const DOTFILES_OVERVIEW_V1_DESTROY = @as(c_int, 0);
pub const DOTFILES_OVERVIEW_V1_REFRESH = @as(c_int, 1);
pub const DOTFILES_OVERVIEW_V1_ACTIVATE = @as(c_int, 2);
pub const DOTFILES_OVERVIEW_V1_CLOSE = @as(c_int, 3);
pub const DOTFILES_OVERVIEW_V1_SWITCH_WORKSPACE = @as(c_int, 4);
pub const DOTFILES_OVERVIEW_V1_MOVE = @as(c_int, 5);

pub const zwlr_screencopy_frame_v1_listener = extern struct {
    buffer: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void = null,
    flags: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void = null,
    ready: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) callconv(.c) void = null,
    failed: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1) callconv(.c) void = null,
    damage: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, x: u32, y: u32, width: u32, height: u32) callconv(.c) void = null,
    linux_dmabuf: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32) callconv(.c) void = null,
    buffer_done: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1) callconv(.c) void = null,
};

pub const zwlr_data_control_source_v1_listener = extern struct {
    send: ?*const fn (data: ?*anyopaque, zwlr_data_control_source_v1: ?*zwlr_data_control_source_v1, mime_type: [*c]const u8, fd: i32) callconv(.c) void = null,
    cancelled: ?*const fn (data: ?*anyopaque, zwlr_data_control_source_v1: ?*zwlr_data_control_source_v1) callconv(.c) void = null,
};

pub const ext_foreign_toplevel_list_v1_listener = extern struct {
    toplevel: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_list_v1: ?*ext_foreign_toplevel_list_v1, toplevel: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    finished: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_list_v1: ?*ext_foreign_toplevel_list_v1) callconv(.c) void = null,
};

pub const ext_foreign_toplevel_handle_v1_listener = extern struct {
    closed: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    title: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void = null,
    app_id: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void = null,
    identifier: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, identifier: [*c]const u8) callconv(.c) void = null,
};

pub const ext_image_copy_capture_session_v1_listener = extern struct {
    buffer_size: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, width: u32, height: u32) callconv(.c) void = null,
    shm_format: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, format: u32) callconv(.c) void = null,
    dmabuf_device: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, device: [*c]c.struct_wl_array) callconv(.c) void = null,
    dmabuf_format: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, format: u32, modifiers: [*c]c.struct_wl_array) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1) callconv(.c) void = null,
    stopped: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1) callconv(.c) void = null,
};

pub const ext_image_copy_capture_frame_v1_listener = extern struct {
    transform: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, transform: u32) callconv(.c) void = null,
    damage: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, x: i32, y: i32, width: i32, height: i32) callconv(.c) void = null,
    presentation_time: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) callconv(.c) void = null,
    ready: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1) callconv(.c) void = null,
    failed: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, reason: u32) callconv(.c) void = null,
};

pub const dotfiles_overview_v1_listener = extern struct {
    workspace: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1, index: u32, name: [*c]const u8, active: u32) callconv(.c) void = null,
    window: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1, identifier: [*c]const u8, workspace: u32, x: i32, y: i32, width: i32, height: i32, sticky: u32) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1) callconv(.c) void = null,
};

pub fn zwlr_screencopy_manager_v1_capture_output(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT, &zwlr_screencopy_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), overlay_cursor, output);
    return @ptrCast(@alignCast(frame));
}

pub fn zwlr_screencopy_manager_v1_capture_output_region(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output, x: i32, y: i32, width: i32, height: i32) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT_REGION, &zwlr_screencopy_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), overlay_cursor, output, x, y, width, height);
    return @ptrCast(@alignCast(frame));
}

pub fn zwlr_screencopy_manager_v1_destroy(mgr: ?*zwlr_screencopy_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn zwlr_screencopy_frame_v1_add_listener(frame: ?*zwlr_screencopy_frame_v1, listener: [*c]const zwlr_screencopy_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(frame)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwlr_screencopy_frame_v1_get_version(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) u32 {
    return c.wl_proxy_get_version(@ptrCast(@alignCast(frame)));
}

pub fn zwlr_screencopy_frame_v1_copy(frame: ?*zwlr_screencopy_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), ZWLR_SCREENCOPY_FRAME_V1_COPY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, buffer);
}

pub fn zwlr_screencopy_frame_v1_destroy(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), ZWLR_SCREENCOPY_FRAME_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 1);
}

pub fn zwlr_data_control_manager_v1_create_data_source(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) ?*zwlr_data_control_source_v1 {
    const id = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE, &zwlr_data_control_source_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(id));
}

pub fn zwlr_data_control_manager_v1_get_data_device(mgr: ?*zwlr_data_control_manager_v1, seat: ?*c.struct_wl_seat) callconv(.c) ?*zwlr_data_control_device_v1 {
    const id = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE, &zwlr_data_control_device_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), seat);
    return @ptrCast(@alignCast(id));
}

pub fn zwlr_data_control_manager_v1_destroy(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn zwlr_data_control_device_v1_set_selection(device: ?*zwlr_data_control_device_v1, source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(device)), ZWLR_DATA_CONTROL_DEVICE_V1_SET_SELECTION, null, c.wl_proxy_get_version(@ptrCast(@alignCast(device))), 0, source);
}

pub fn zwlr_data_control_device_v1_destroy(device: ?*zwlr_data_control_device_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(device)), ZWLR_DATA_CONTROL_DEVICE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(device))), 1);
}

pub fn zwlr_data_control_source_v1_add_listener(source: ?*zwlr_data_control_source_v1, listener: [*c]const zwlr_data_control_source_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(source)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwlr_data_control_source_v1_offer(source: ?*zwlr_data_control_source_v1, mime_type: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), ZWLR_DATA_CONTROL_SOURCE_V1_OFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 0, mime_type);
}

pub fn zwlr_data_control_source_v1_destroy(source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), ZWLR_DATA_CONTROL_SOURCE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 1);
}

pub fn ext_foreign_toplevel_list_v1_add_listener(list: ?*ext_foreign_toplevel_list_v1, listener: [*c]const ext_foreign_toplevel_list_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(list)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_foreign_toplevel_list_v1_destroy(list: ?*ext_foreign_toplevel_list_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(list)), EXT_FOREIGN_TOPLEVEL_LIST_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(list))), 1);
}

pub fn ext_foreign_toplevel_handle_v1_add_listener(handle: ?*ext_foreign_toplevel_handle_v1, listener: [*c]const ext_foreign_toplevel_handle_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(handle)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_foreign_toplevel_handle_v1_destroy(handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(handle)), EXT_FOREIGN_TOPLEVEL_HANDLE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(handle))), 1);
}

pub fn ext_image_capture_source_v1_destroy(source: ?*ext_image_capture_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), EXT_IMAGE_CAPTURE_SOURCE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 1);
}

pub fn ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1, handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) ?*ext_image_capture_source_v1 {
    const source = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_CREATE_SOURCE, &ext_image_capture_source_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), handle);
    return @ptrCast(@alignCast(source));
}

pub fn ext_foreign_toplevel_image_capture_source_manager_v1_destroy(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn ext_image_copy_capture_manager_v1_create_session(mgr: ?*ext_image_copy_capture_manager_v1, source: ?*ext_image_capture_source_v1, options: u32) callconv(.c) ?*ext_image_copy_capture_session_v1 {
    const session = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_CREATE_SESSION, &ext_image_copy_capture_session_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), source, options);
    return @ptrCast(@alignCast(session));
}

pub fn ext_image_copy_capture_manager_v1_destroy(mgr: ?*ext_image_copy_capture_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn ext_image_copy_capture_session_v1_add_listener(session: ?*ext_image_copy_capture_session_v1, listener: [*c]const ext_image_copy_capture_session_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(session)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_image_copy_capture_session_v1_create_frame(session: ?*ext_image_copy_capture_session_v1) callconv(.c) ?*ext_image_copy_capture_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(session)), EXT_IMAGE_COPY_CAPTURE_SESSION_V1_CREATE_FRAME, &ext_image_copy_capture_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(session))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(frame));
}

pub fn ext_image_copy_capture_session_v1_destroy(session: ?*ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(session)), EXT_IMAGE_COPY_CAPTURE_SESSION_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(session))), 1);
}

pub fn ext_image_copy_capture_frame_v1_add_listener(frame: ?*ext_image_copy_capture_frame_v1, listener: [*c]const ext_image_copy_capture_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(frame)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_image_copy_capture_frame_v1_destroy(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 1);
}

pub fn ext_image_copy_capture_frame_v1_attach_buffer(frame: ?*ext_image_copy_capture_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ATTACH_BUFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, buffer);
}

pub fn ext_image_copy_capture_frame_v1_damage_buffer(frame: ?*ext_image_copy_capture_frame_v1, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DAMAGE_BUFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, x, y, width, height);
}

pub fn ext_image_copy_capture_frame_v1_capture(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_CAPTURE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0);
}

pub fn dotfiles_overview_v1_add_listener(overview: ?*dotfiles_overview_v1, listener: [*c]const dotfiles_overview_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(overview)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn dotfiles_overview_v1_destroy(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 1);
}

pub fn dotfiles_overview_v1_refresh(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_REFRESH, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0);
}

pub fn dotfiles_overview_v1_activate(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_ACTIVATE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier);
}

pub fn dotfiles_overview_v1_close(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_CLOSE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier);
}

pub fn dotfiles_overview_v1_switch_workspace(overview: ?*dotfiles_overview_v1, index: u32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_SWITCH_WORKSPACE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, index);
}

pub fn dotfiles_overview_v1_move(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8, index: u32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_MOVE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier, index);
}

// ext-session-lock-v1: native metadata, checked against wayland-scanner.
// /*
//  * Copyright 2021 Isaac Freund
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  * THE SOFTWARE.
//
// */
extern const wl_surface_interface: Interface;
const ext_session_lock_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    &ext_session_lock_v1_interface,
    &ext_session_lock_surface_v1_interface,
    &wl_surface_interface,
    &wl_output_interface,
};
const ext_session_lock_manager_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
    .{ .name = "lock", .signature = "n", .types = @constCast(ext_session_lock_v1_types[3..].ptr) },
};
const ext_session_lock_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
    .{ .name = "get_lock_surface", .signature = "noo", .types = @constCast(ext_session_lock_v1_types[4..].ptr) },
    .{ .name = "unlock_and_destroy", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
};
const ext_session_lock_v1_events = [_]Message{
    .{ .name = "locked", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
};
const ext_session_lock_surface_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
    .{ .name = "ack_configure", .signature = "u", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
};
const ext_session_lock_surface_v1_events = [_]Message{
    .{ .name = "configure", .signature = "uuu", .types = @constCast(ext_session_lock_v1_types[0..].ptr) },
};
pub export const ext_session_lock_manager_v1_interface: Interface = .{ .name = "ext_session_lock_manager_v1", .version = 1, .method_count = 2, .methods = &ext_session_lock_manager_v1_requests, .event_count = 0, .events = null };
pub export const ext_session_lock_v1_interface: Interface = .{ .name = "ext_session_lock_v1", .version = 1, .method_count = 3, .methods = &ext_session_lock_v1_requests, .event_count = 2, .events = &ext_session_lock_v1_events };
pub export const ext_session_lock_surface_v1_interface: Interface = .{ .name = "ext_session_lock_surface_v1", .version = 1, .method_count = 2, .methods = &ext_session_lock_surface_v1_requests, .event_count = 1, .events = &ext_session_lock_surface_v1_events };

// ext-idle-notify-v1: native metadata, checked against wayland-scanner.
// /*
//  * Copyright © 2015 Martin Gräßlin
//  * Copyright © 2022 Simon Ser
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice (including the next
//  * paragraph) shall be included in all copies or substantial portions of the
//  * Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const ext_idle_notify_v1_types = [_][*c]const Interface{
    &ext_idle_notification_v1_interface,
    null,
    &wl_seat_interface,
    &ext_idle_notification_v1_interface,
    null,
    &wl_seat_interface,
};
const ext_idle_notifier_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_idle_notify_v1_types[0..].ptr) },
    .{ .name = "get_idle_notification", .signature = "nuo", .types = @constCast(ext_idle_notify_v1_types[0..].ptr) },
    .{ .name = "get_input_idle_notification", .signature = "2nuo", .types = @constCast(ext_idle_notify_v1_types[3..].ptr) },
};
const ext_idle_notification_v1_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = @constCast(ext_idle_notify_v1_types[0..].ptr) },
};
const ext_idle_notification_v1_events = [_]Message{
    .{ .name = "idled", .signature = "", .types = @constCast(ext_idle_notify_v1_types[0..].ptr) },
    .{ .name = "resumed", .signature = "", .types = @constCast(ext_idle_notify_v1_types[0..].ptr) },
};
pub export const ext_idle_notifier_v1_interface: Interface = .{ .name = "ext_idle_notifier_v1", .version = 2, .method_count = 3, .methods = &ext_idle_notifier_v1_requests, .event_count = 0, .events = null };
pub export const ext_idle_notification_v1_interface: Interface = .{ .name = "ext_idle_notification_v1", .version = 2, .method_count = 1, .methods = &ext_idle_notification_v1_requests, .event_count = 2, .events = &ext_idle_notification_v1_events };

// wlr-output-management-unstable-v1.xml
// /*
//  * Copyright © 2019 Purism SPC
//  *
//  * Permission to use, copy, modify, distribute, and sell this
//  * software and its documentation for any purpose is hereby granted
//  * without fee, provided that the above copyright notice appear in
//  * all copies and that both that copyright notice and this permission
//  * notice appear in supporting documentation, and that the name of
//  * the copyright holders not be used in advertising or publicity
//  * pertaining to distribution of the software without specific,
//  * written prior permission.  The copyright holders make no
//  * representations about the suitability of this software for any
//  * purpose.  It is provided "as is" without express or implied
//  * warranty.
//  *
//  * THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
//  * SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
//  * FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  * SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
//  * AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
//  * ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
//  * THIS SOFTWARE.
//  */
const wlr_output_management_unstable_v1_types = [_][*c]const Interface{
    null,
    null,
    null,
    &zwlr_output_configuration_v1_interface,
    null,
    &zwlr_output_head_v1_interface,
    &zwlr_output_mode_v1_interface,
    &zwlr_output_mode_v1_interface,
    &zwlr_output_configuration_head_v1_interface,
    &zwlr_output_head_v1_interface,
    &zwlr_output_head_v1_interface,
    &zwlr_output_mode_v1_interface,
};
const zwlr_output_manager_v1_requests = [_]Message{
    .{ .name = "create_configuration", .signature = "nu", .types = @constCast(wlr_output_management_unstable_v1_types[3..].ptr) },
    .{ .name = "stop", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_manager_v1_events = [_]Message{
    .{ .name = "head", .signature = "n", .types = @constCast(wlr_output_management_unstable_v1_types[5..].ptr) },
    .{ .name = "done", .signature = "u", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_head_v1_requests = [_]Message{
    .{ .name = "release", .signature = "3", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_head_v1_events = [_]Message{
    .{ .name = "name", .signature = "s", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "description", .signature = "s", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "physical_size", .signature = "ii", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "mode", .signature = "n", .types = @constCast(wlr_output_management_unstable_v1_types[6..].ptr) },
    .{ .name = "enabled", .signature = "i", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "current_mode", .signature = "o", .types = @constCast(wlr_output_management_unstable_v1_types[7..].ptr) },
    .{ .name = "position", .signature = "ii", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "transform", .signature = "i", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "scale", .signature = "f", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "make", .signature = "2s", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "model", .signature = "2s", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "serial_number", .signature = "2s", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "adaptive_sync", .signature = "4u", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_mode_v1_requests = [_]Message{
    .{ .name = "release", .signature = "3", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_mode_v1_events = [_]Message{
    .{ .name = "size", .signature = "ii", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "refresh", .signature = "i", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "preferred", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "finished", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_configuration_v1_requests = [_]Message{
    .{ .name = "enable_head", .signature = "no", .types = @constCast(wlr_output_management_unstable_v1_types[8..].ptr) },
    .{ .name = "disable_head", .signature = "o", .types = @constCast(wlr_output_management_unstable_v1_types[10..].ptr) },
    .{ .name = "apply", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "test", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "destroy", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_configuration_v1_events = [_]Message{
    .{ .name = "succeeded", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "failed", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "cancelled", .signature = "", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
const zwlr_output_configuration_head_v1_requests = [_]Message{
    .{ .name = "set_mode", .signature = "o", .types = @constCast(wlr_output_management_unstable_v1_types[11..].ptr) },
    .{ .name = "set_custom_mode", .signature = "iii", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "set_position", .signature = "ii", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "set_transform", .signature = "i", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "set_scale", .signature = "f", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
    .{ .name = "set_adaptive_sync", .signature = "4u", .types = @constCast(wlr_output_management_unstable_v1_types[0..].ptr) },
};
pub export const zwlr_output_manager_v1_interface: Interface = .{
    .name = "zwlr_output_manager_v1",
    .version = 4,
    .method_count = 2,
    .methods = &zwlr_output_manager_v1_requests,
    .event_count = 3,
    .events = &zwlr_output_manager_v1_events,
};
pub export const zwlr_output_head_v1_interface: Interface = .{
    .name = "zwlr_output_head_v1",
    .version = 4,
    .method_count = 1,
    .methods = &zwlr_output_head_v1_requests,
    .event_count = 14,
    .events = &zwlr_output_head_v1_events,
};
pub export const zwlr_output_mode_v1_interface: Interface = .{
    .name = "zwlr_output_mode_v1",
    .version = 3,
    .method_count = 1,
    .methods = &zwlr_output_mode_v1_requests,
    .event_count = 4,
    .events = &zwlr_output_mode_v1_events,
};
pub export const zwlr_output_configuration_v1_interface: Interface = .{
    .name = "zwlr_output_configuration_v1",
    .version = 4,
    .method_count = 5,
    .methods = &zwlr_output_configuration_v1_requests,
    .event_count = 3,
    .events = &zwlr_output_configuration_v1_events,
};
pub export const zwlr_output_configuration_head_v1_interface: Interface = .{
    .name = "zwlr_output_configuration_head_v1",
    .version = 4,
    .method_count = 6,
    .methods = &zwlr_output_configuration_head_v1_requests,
    .event_count = 0,
    .events = null,
};
