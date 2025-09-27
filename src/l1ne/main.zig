const std = @import("std");
const cli = @import("cli.zig");
const master = @import("master.zig");
const systemd = @import("systemd.zig");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();
    const command = cli.parse_args(gpa);

    // Initialize logging
    // Note: In Zig 0.15, std.log.default_level cannot be modified at runtime
    // Debug logging would need to be handled differently

    switch (command) {
        .start => |start| {
            std.log.info("Starting L1NE POC - deploying service instances...", .{});
            std.log.info("  Service: {s}", .{start.service});
            std.log.info("  Instances: {}", .{start.nodes.len});
            for (start.nodes.items[0..start.nodes.len], 0..) |node, i| {
                std.log.info("    Instance {}: {any}", .{ i + 1, node });
            }
            std.log.info("  State Dir: {s}", .{start.state_dir});
            
            // Initialize and start the master orchestrator
            var orchestrator = try master.Master.init(gpa, start);
            defer orchestrator.deinit();
            
            // Run the orchestrator (this blocks)
            try orchestrator.start(start);
        },
        .status => |status| {
            // Query systemd for service status
            if (systemd.isUnderSystemd()) {
                std.log.info("Querying systemd for service status...", .{});
                
                // Use systemctl to get status (simplified for POC)
                const result = try std.process.Child.run(.{
                    .allocator = gpa,
                    .argv = &[_][]const u8{
                        "systemctl",
                        "--user",
                        "status",
                        "--no-pager",
                        "--output=json",
                        "l1ne-*",
                    },
                });
                defer gpa.free(result.stdout);
                defer gpa.free(result.stderr);
                
                switch (result.term) {
                    .Exited => |code| {
                        if (code == 0) {
                            std.debug.print("{s}\n", .{result.stdout});
                        } else {
                            std.debug.print("No L1NE services running\n", .{});
                        }
                    },
                    else => {
                        std.debug.print("Failed to query systemd status\n", .{});
                    },
                }
            } else {
                std.debug.print("Getting status (not under systemd)...\n", .{});
                if (status.node) |node| {
                    std.debug.print("  Node: {any}\n", .{node});
                } else {
                    std.debug.print("  All nodes\n", .{});
                }
                std.debug.print("  Service: {s}\n", .{status.service});
                std.debug.print("  Format: {s}\n", .{status.format});
            }
        },
        .wal => |wal| {
            std.debug.print("Managing centralized logs...\n", .{});
            if (wal.node) |node| {
                std.debug.print("  Node: {any}\n", .{node});
            } else {
                std.debug.print("  Node: all\n", .{});
            }
            std.debug.print("  Lines: {d}\n", .{wal.lines});
            std.debug.print("  Follow: {any}\n", .{wal.follow});
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
