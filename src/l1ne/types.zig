const std = @import("std");
const assert = std.debug.assert;
// const net = std.net;

pub const KIB = 1 << 10;
pub const MIB = 1 << 20;
pub const GIB = 1 << 30;

comptime {
    assert(KIB == 1024);
    assert(MIB == 1024 * KIB);
    assert(GIB == 1024 * MIB);
}
