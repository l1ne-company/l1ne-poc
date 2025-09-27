const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = cli.parse_args(allocator);

    // initialize things hehe

    switch (command) {
        .start => |start| {
            std.debug.print("Starting L1NE POC - deploying service instances...\n", .{});
            std.debug.print("  Service: {s}\n", .{start.service});
            std.debug.print("  Instances: {}\n", .{start.nodes.len});
            for (start.nodes.items[0..start.nodes.len], 0..) |node, i| {
                // Simple format for IPv4 addresses
                const bytes = @as(*const [4]u8, @ptrCast(&node.in.sa.addr));
                const port = std.mem.bigToNative(u16, node.in.sa.port);
                std.debug.print("    Instance {}: {}.{}.{}.{}:{}\n", .{ i + 1, bytes[0], bytes[1], bytes[2], bytes[3], port });
            }
            std.debug.print("  State Dir: {s}\n", .{start.state_dir});
            if (start.log_debug) {
                std.debug.print("  Debug logging: enabled\n", .{});
            }
        },
        .status => |status| {
            std.debug.print("Getting status...\n", .{});
            if (status.node) |node| {
                std.debug.print("  Node: {any}\n", .{node});
            } else {
                std.debug.print("  All nodes\n", .{});
            }
            std.debug.print("  Service: {s}\n", .{status.service});
            std.debug.print("  Format: {s}\n", .{status.format});
        },
        .wal => |wal| {
            std.debug.print("Managing centralized logs...\n", .{});
            if (wal.node) |node| {
                std.debug.print("  Node: {any}\n", .{node});
            } else {
                std.debug.print("  Node: all\n", .{});
            }
            std.debug.print("  Lines: {}\n", .{wal.lines});
            std.debug.print("  Follow: {}\n", .{wal.follow});
            std.debug.print("  Path: {s}\n", .{wal.path});
        },
        .version => |version| {
            std.debug.print("L1NE v0.0.1\n", .{});
            if (version.verbose) {
                std.debug.print("Compile-time configuration:\n", .{});
                std.debug.print("  Build mode: {}\n", .{@import("builtin").mode});
            }
        },
        .benchmark => |benchmark| {
            std.debug.print("Running benchmark...\n", .{});
            std.debug.print("  Duration: {} seconds\n", .{benchmark.duration});
            std.debug.print("  Connections: {}\n", .{benchmark.connections});
            if (benchmark.target) |target| {
                std.debug.print("  Target: {s}\n", .{target});
            }
        },
    }
}
