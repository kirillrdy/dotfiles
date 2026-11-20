//! Typed Wayland client bindings over the native wire runtime.
pub const wire = @import("wayland-wire");
pub const protocol = @import("wayland-client");

/// Forces semantic analysis of every non-generic declaration below `T`.
fn analyze(comptime T: type) void {
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        const value = @field(T, name);
        if (@TypeOf(value) == type) {
            if (@typeInfo(value) == .@"struct") analyze(value);
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            if (!@typeInfo(@TypeOf(value)).@"fn".is_generic) _ = &value;
        } else _ = &value;
    }
}

test "every generated protocol binding compiles" {
    comptime analyze(protocol);
}
