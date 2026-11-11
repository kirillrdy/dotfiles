//! GTK-independent Wayland window hosting. Link only the libraries used here.
pub const c = @import("desktop-gtk.zig");
pub const surface = @import("desktop-surface.zig");
pub const keyboard = @import("desktop-keyboard.zig");
pub const consent = @import("desktop-consent.zig");

pub const form = @import("desktop-form.zig");
pub const auth = @import("desktop-auth-dialog.zig");
