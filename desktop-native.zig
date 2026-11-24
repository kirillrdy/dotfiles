//! GTK-independent Wayland window hosting. Link only the libraries used here.
pub const mainloop = @import("desktop-loop.zig");
pub const util = @import("desktop-util.zig");
pub const surface = @import("desktop-surface.zig");
pub const keyboard = @import("desktop-keyboard.zig");

pub const form = @import("desktop-form.zig");
pub const auth = @import("desktop-auth-dialog.zig");
