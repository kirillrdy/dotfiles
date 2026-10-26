//! Native Wayland interface metadata. Request/event order and type tables
//! match the protocol XML; test-protocols compares all tables with the reference
//! wayland-scanner output. Normal builds need no generated C sources.
const c = @import("gtk");
pub const Interface = c.struct_wl_interface;
const Message = c.struct_wl_message;

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
