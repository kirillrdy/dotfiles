//! Secret Service's specified legacy DH/HKDF/AES-CBC transport, plus plain sessions.
const std = @import("std");
const store = @import("desktop-secrets-store.zig");
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
pub const algorithm = "dh-ietf1024-sha256-aes128-cbc-pkcs7";
const prime_hex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF";
pub fn negotiate(encoded_peer: []const u8, public: *[128]u8) ![16]u8 {
    const peer = std.mem.trimStart(u8, encoded_peer, &.{0});
    if (peer.len == 0 or peer.len > 128) return error.InvalidPublicKey;
    var prime: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&prime, prime_hex);
    const Mod = std.crypto.ff.Modulus(1024);
    const Fe = Mod.Fe;
    const m = try Mod.fromBytes(&prime, .big);
    const g = try Fe.fromPrimitive(u8, m, 2);
    const y = try Fe.fromBytes(m, peer, .big);
    // Reject trivial peer keys, including p-1.
    if (Fe.compare(y, g) == .lt or Fe.compare(y, m.sub(try Fe.fromPrimitive(u8, m, 0), m.one())) != .lt) return error.InvalidPublicKey;
    var exponent: [32]u8 = undefined;
    defer store.wipe(&exponent);
    try store.random(&exponent);
    const pubkey = try m.powWithEncodedExponent(g, &exponent, .big);
    try pubkey.toBytes(public, .big);
    var shared: [128]u8 = undefined;
    defer store.wipe(&shared);
    try (try m.powWithEncodedExponent(y, &exponent, .big)).toBytes(&shared, .big);
    var prk = Hkdf.extract(&.{}, &shared);
    defer store.wipe(&prk);
    var key: [16]u8 = undefined;
    Hkdf.expand(&key, &.{}, prk);
    return key;
}
pub fn encode(a: std.mem.Allocator, key: [16]u8, iv: [16]u8, plain: []const u8) ![]u8 {
    const padding: u8 = @intCast(16 - plain.len % 16);
    const out = try a.alloc(u8, plain.len + padding);
    @memcpy(out[0..plain.len], plain);
    @memset(out[plain.len..], padding);
    var previous = iv;
    const aes = std.crypto.core.aes.Aes128.initEnc(key);
    var i: usize = 0;
    while (i < out.len) : (i += 16) {
        for (0..16) |j| out[i + j] ^= previous[j];
        aes.encrypt(out[i..][0..16], out[i..][0..16]);
        previous = out[i..][0..16].*;
    }
    return out;
}
pub fn decode(a: std.mem.Allocator, key: [16]u8, iv: []const u8, cipher: []const u8) ![]u8 {
    if (iv.len != 16 or cipher.len == 0 or cipher.len % 16 != 0) return error.InvalidCiphertext;
    const out = try a.alloc(u8, cipher.len);
    defer a.free(out);
    var previous = iv[0..16].*;
    const aes = std.crypto.core.aes.Aes128.initDec(key);
    var i: usize = 0;
    while (i < cipher.len) : (i += 16) {
        aes.decrypt(out[i..][0..16], cipher[i..][0..16]);
        for (0..16) |j| out[i + j] ^= previous[j];
        previous = cipher[i..][0..16].*;
    }
    const padding = out[out.len - 1];
    var invalid: u8 = @intFromBool(padding == 0 or padding > 16);
    for (0..16) |j| {
        if (j < padding) invalid |= out[out.len - 1 - j] ^ padding;
    }
    if (invalid != 0) return error.InvalidPadding;
    return a.dupe(u8, out[0 .. out.len - padding]);
}
test "CBC round trip and malformed inputs" {
    var wa = store.WipingAllocator{ .parent = std.testing.allocator };
    const a = wa.allocator();
    for ([_][]const u8{ "", "binary\x00secret", "sixteen bytes!!!?", "a longer secret spanning more than one block" }) |plain| {
        const cipher = try encode(a, @splat(7), @splat(9), plain);
        defer a.free(cipher);
        const decoded = try decode(a, @splat(7), &@as([16]u8, @splat(9)), cipher);
        defer a.free(decoded);
        try std.testing.expectEqualSlices(u8, plain, decoded);
    }
    try std.testing.expectError(error.InvalidCiphertext, decode(a, @splat(0), &.{}, &.{}));
}
