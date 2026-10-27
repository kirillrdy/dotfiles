//! Compare the checked-in ABI against independently translated system headers.
const std = @import("std");
const api = @import("api");
const reference = @import("reference");

fn checkType(comptime A: type, comptime B: type) void {
    const left = @typeInfo(A);
    const right = @typeInfo(B);
    if (left == .@"opaque" or right == .@"opaque") return;
    if (left == .@"struct" and @sizeOf(A) == 0) return; // Incomplete toolkit handle.
    if (left == .pointer and right == .optional and @typeInfo(right.optional.child) == .pointer) {
        checkType(A, right.optional.child);
        return;
    }
    if (left == .optional and right == .pointer and @typeInfo(left.optional.child) == .pointer) {
        checkType(left.optional.child, B);
        return;
    }
    // glibc exposes connect's address parameter as a GNU transparent union of
    // pointers. Its C ABI is the same as the ordinary sockaddr pointer.
    if (left == .pointer and right == .@"union") {
        inline for (right.@"union".field_types) |field| checkType(A, field);
        return;
    }
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) @compileError("ABI type category differs: " ++ @typeName(A) ++ " / " ++ @typeName(B));
    switch (left) {
        .@"fn" => |func| {
            const other = right.@"fn";
            if (func.param_types.len != other.param_types.len or !std.meta.eql(func.attrs, other.attrs)) @compileError("ABI function signature differs");
            if (func.return_type) |T| checkType(T, other.return_type.?);
            inline for (func.param_types, other.param_types) |param, other_param| if (param) |T| checkType(T, other_param.?);
        },
        .pointer => |ptr| {
            const other = right.pointer;
            if (@sizeOf(A) != @sizeOf(B) or ptr.attrs.@"const" != other.attrs.@"const") @compileError("ABI pointer differs");
            if (@typeInfo(ptr.child) == .@"fn") checkType(ptr.child, other.child);
        },
        .optional => |opt| checkType(opt.child, right.optional.child),
        .@"struct", .@"union" => {
            if (@sizeOf(A) != @sizeOf(B) or @alignOf(A) != @alignOf(B)) @compileError("ABI layout differs: " ++ @typeName(A));
            inline for (std.meta.fieldNames(A)) |field| {
                if (!@hasField(B, field)) @compileError("ABI field missing: " ++ field);
                if (left == .@"struct" and @offsetOf(A, field) != @offsetOf(B, field)) @compileError("ABI field offset differs: " ++ field);
            }
        },
        .int => if (left.int.bits != right.int.bits or left.int.signedness != right.int.signedness) @compileError("ABI integer differs"),
        .float => if (left.float.bits != right.float.bits) @compileError("ABI float differs"),
        else => {},
    }
}

test "explicit desktop declarations match the installed C ABI" {
    comptime {
        @setEvalBranchQuota(200000);
        for (std.meta.declarations(api)) |decl| {
            if (std.mem.startsWith(u8, decl, "__")) continue;
            if (!@hasDecl(reference, decl)) @compileError("C header declaration missing: " ++ decl);
            const A = @TypeOf(@field(api, decl));
            const B = @TypeOf(@field(reference, decl));
            if (A == type) {
                checkType(@field(api, decl), @field(reference, decl));
            } else if ((@typeInfo(A) == .int or @typeInfo(A) == .comptime_int) and (@typeInfo(B) == .int or @typeInfo(B) == .comptime_int)) {
                if (@field(api, decl) != @field(reference, decl)) @compileError("C constant differs: " ++ decl);
            } else {
                checkType(A, B);
                if (@typeInfo(A) == .comptime_int and @field(api, decl) != @field(reference, decl)) @compileError("C constant differs: " ++ decl);
            }
        }
    }
}
