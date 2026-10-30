const std = @import("std");
const store = @import("../desktop-secrets-store.zig");
const p = @import("secrets-posix");
test "vault rejects wrong passwords and tampering; locking erases values; restart restores binary secrets" {
    var wa = store.WipingAllocator{ .parent = std.testing.allocator };
    const a = wa.allocator();
    var pattern = "/tmp/desktop-secrets-test-XXXXXX".*;
    const directory = p.mkdtemp(&pattern) orelse return error.TempDirectory;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/vault.json", .{directory}, 0);
    defer a.free(path);
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/lock", .{directory}, 0);
    defer a.free(lock_path);
    defer {
        _ = p.unlink(path);
        _ = p.unlink(lock_path);
        _ = p.rmdir(directory);
    }
    {
        var v = try store.Vault.init(a, std.mem.span(directory));
        defer v.deinit();
        try std.testing.expectError(error.VaultInUse, store.Vault.init(a, std.mem.span(directory)));
        try v.unlock("vault-test-password");
        try v.setValue(1, "binary\x00secret\xff", "application/octet-stream");
        try v.save();
        v.lock();
        try std.testing.expect(v.key == null and v.values.len == 0);
        try std.testing.expectError(error.AuthenticationFailed, v.unlock("wrong-password"));
        try std.testing.expect(v.key == null);
        try v.unlock("vault-test-password");
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
        try v.setValue(1, "uncommitted", "text/plain");
        try v.restore();
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
    }
    {
        var v = try store.Vault.init(a, std.mem.span(directory));
        defer v.deinit();
        try v.unlock("vault-test-password");
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
        v.lock();
        v.envelope.?.value.tag[0] ^= 1;
        try std.testing.expectError(error.AuthenticationFailed, v.unlock("vault-test-password"));
    }
}
