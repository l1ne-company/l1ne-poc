//! Parse and validate command-line arguments for the l1ne binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.
//!
//! Some flags are experimental: intentionally undocumented and are not a part of the official
//! surface area. Even experimental features must adhere to the same strict standard of safety,
//! but they come without any performance or usability guarantees.
//!
//! Experimental features are not gated by comptime option for safety: it is much easier to review
//! code for correctness when it is initially added to the main branch, rather when a comptime flag
//! is lifted.

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const net = std.net;
const types = @import("types.zig");

const KIB = types.KIB;
const MIB = types.MIB;
const GIB = types.GIB;

const default_address = "127.0.0.1"; // POC only
const orchestrator_port = 42069; // Orchestrator control plane port
const max_nodes = 4; // POC: Maximum 4 service instances (like pods) on same server
// Services and ports come from CLI: --service=name --nodes=port1,port2,port3

const CLIArgs = union(enum) {
    const Start = struct {
        // Required: service configuration
        service: []const u8,

        // Nodes to deploy to (comma-separated addresses)
        pid_addresses: []const u8,

        // Optional orchestrator settings
        address: ?[]const u8 = null, // Bind address for control plane
        cache_size: ?ByteSize = null,

        // Resource limits - POC uses FAAS (Femboy-as-a-Service) percentages
        mem_percent: u8 = 50, // 1-100% of FAAS limit
        cpu_percent: u8 = 50, // 1-100% of FAAS limit

        development: bool = false,
        positional: struct {
            path: []const u8,
        },

        // Everything below here is considered experimental, and requires `--experimental` to be
        // set. Experimental flags disable automatic upgrades with multiversion binaries; each
        // replica has to be manually restarted.
        // Experimental flags must default to null, except for bools which must be false.
        experimental: bool = false,

        logger: bool = false,
        sre: bool = false,
        replica: ?u8 = null,
        max_replica: ?u8 = null,
        // because is a POC the CPU & memory maximun will be defined here dummy-service (FAAS: Femboy-as-a-Service)
        // and cpu_max & mem_max weill represent percentage of the maximum of the amount of the pre-limite defined inside o FAAS
        // data in percentage 1-100 of the FAAS limit not actually computer poc only
        mem_max: ?u8 = null,
        cpu_max: ?u8 = null,

        limit_storage: ?ByteSize = null,
        limit_pipeline_requests: ?u32 = null,
        limit_request: ?ByteSize = null,
        log_debug: bool = false,
        timeout_prepare_ms: ?u64 = null,
    };

    const Version = struct {
        verbose: bool = false,
    };

    const Benchmark = struct {
        logger_debugger: bool = false,
        target: ?[]const u8 = null,
        duration: u32 = 60,
        connections: u32 = 100,
        validate: bool = false,
        addresses: ?[]const u8 = null,
        seed: ?[]const u8 = null,
        log_debug: bool = false,
    };

    const Status = struct {
        node: ?[]const u8 = null, // Specific node or all
        service: []const u8 = "", // Service name
        format: []const u8 = "json", // Output format
    };

    // WAL for centralized logging from all nodes
    const WAL = struct {
        node: ?[]const u8 = null, // Filter by specific node
        slot: ?usize = null, // Specific log entry
        lines: u32 = 100,
        follow: bool = false,
        path: []const u8, // Path to WAL storage
    };

    start: Start,
    status: Status,
    wal: WAL,
    version: Version,
    benchmark: Benchmark,

    pub const help =
        \\L1NE - Proof of Concept
        \\
        \\Usage:
        \\  l1ne [-h | --help]
        \\  l1ne start --service=<name> --nodes=<addr:port,...> <path> [--development] [--log-debug]
        \\  l1ne status --service=<name> [--node=<addr:port>] [--format=<json|text>]
        \\  l1ne wal <path> [--node=<addr:port>] [--lines=N] [--follow]
        \\  l1ne version [--verbose]
        \\  l1ne benchmark [--target=<url>] [--duration=<seconds>] [--connections=N]
        \\
        \\Commands:
        \\
        \\  start      Deploy service instances to specified network addresses
        \\  status     Show status of service instances
        \\  wal        View centralized Write-Ahead Log from instances
        \\  version    Print the L1NE version
        \\  benchmark  Run performance benchmarks
        \\
        \\Examples:
        \\  l1ne start --service=api --nodes=127.0.0.1:8080,127.0.0.1:8081 /tmp/state
        \\    Deploy 2 instances on ports 8080 and 8081
        \\
        \\  l1ne status --service=api --format=json
        \\    Show status of api service instances in JSON format
        \\
        \\  l1ne wal /tmp/state --lines=100 --follow
        \\    Tail the last 100 lines of the WAL and follow for new entries
        \\
        \\Options:
        \\
        \\  -h, --help
        \\        Print this help message and exit.
        \\
        \\  --service=<name>
        \\        Name of the service to deploy or query.
        \\
        \\  --nodes=<addresses>
        \\        Comma-separated list of IP:port pairs for service instances.
        \\        Example: 127.0.0.1:8080,127.0.0.1:8081
        \\
        \\  --node=<address>
        \\        Specific node address to query (for status/wal commands).
        \\
        \\  --format=<json|text>
        \\        Output format for status command (default: text).
        \\
        \\  --lines=<number>
        \\        Number of lines to display from WAL (default: 100).
        \\
        \\  --follow
        \\        Continuously monitor WAL for new entries.
        \\
        \\  --development
        \\        Enable development mode (relaxed safety checks).
        \\
        \\  --log-debug
        \\        Enable debug logging.
        \\
        \\  --verbose
        \\        Print detailed version information.
        \\
        \\  --target=<url>
        \\        Target URL for benchmark.
        \\
        \\  --duration=<seconds>
        \\        Duration of benchmark in seconds.
        \\
        \\  --connections=<number>
        \\        Number of concurrent connections for benchmark.
        \\
    ;
};

pub const ByteSize = struct {
    value: u64,

    pub fn bytes(self: ByteSize) u64 {
        return self.value;
    }

    pub fn suffix(self: ByteSize) []const u8 {
        if (self.value >= GIB and self.value % GIB == 0) return "GiB";
        if (self.value >= MIB and self.value % MIB == 0) return "MiB";
        if (self.value >= KIB and self.value % KIB == 0) return "KiB";
        return "B";
    }
};

/// While CLIArgs store raw arguments as passed on the command line, Command ensures that arguments
/// are properly validated and desugared (e.g, sizes converted to counts where appropriate).
pub const Command = union(enum) {
    const Addresses = BoundedArray(std.net.Address, max_nodes);
    const Path = BoundedArray(u8, std.fs.max_path_bytes);

    pub const Start = struct {
        service: []const u8, // Service name to deploy
        nodes: Addresses, // Nodes to deploy to (one service per node)
        bind: std.net.Address, // Control plane bind address
        mem_percent: u8, // FAAS memory percentage
        cpu_percent: u8, // FAAS CPU percentage
        state_dir: []const u8,
        development: bool,
        log_debug: bool,
        sre: bool,
    };

    pub const Status = struct {
        node: ?std.net.Address,
        service: []const u8,
        format: []const u8,
    };

    pub const WAL = struct {
        path: []const u8,
        node: ?std.net.Address,
        slot: ?usize,
        lines: u32,
        follow: bool,
    };

    pub const Version = struct {
        verbose: bool,
    };

    pub const Benchmark = struct {
        logger_debugger: bool,
        target: ?[]const u8,
        duration: u32,
        connections: u32,
        validate: bool,
        addresses: ?Addresses,
        seed: ?[]const u8,
        log_debug: bool,
    };

    start: Start,
    status: Status,
    wal: WAL,
    version: Version,
    benchmark: Benchmark,
};

fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn unused_capacity_slice(self: *Self) []T {
            return self.items[self.len..];
        }

        pub fn resize(self: *Self, new_len: usize) !void {
            if (new_len > capacity) return error.Overflow;
            self.len = new_len;
        }

        pub fn capacity_total(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// Parse the command line arguments passed to the `l1ne` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(allocator: std.mem.Allocator) Command {
    var args = std.process.args();
    const cli_args = parse_cli_args(&args, allocator);

    return switch (cli_args) {
        .start => |start| .{ .start = parse_args_start(start) },
        .status => |status| .{ .status = parse_args_status(status) },
        .wal => |wal| .{ .wal = parse_args_wal(wal) },
        .version => |version| .{ .version = parse_args_version(version) },
        .benchmark => |benchmark| .{ .benchmark = parse_args_benchmark(benchmark) },
    };
}

fn parse_cli_args(args_iterator: anytype, allocator: std.mem.Allocator) CLIArgs {
    _ = allocator;
    _ = args_iterator.next(); // Skip program name

    const command_str = args_iterator.next() orelse {
        std.debug.print("{s}\n", .{CLIArgs.help});
        std.process.exit(0);
    };

    if (std.mem.eql(u8, command_str, "-h") or std.mem.eql(u8, command_str, "--help")) {
        std.debug.print("{s}\n", .{CLIArgs.help});
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_str, "start")) {
        return .{ .start = parse_start_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "status")) {
        return .{ .status = parse_status_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "wal")) {
        return .{ .wal = parse_wal_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "version")) {
        return .{ .version = parse_version_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "benchmark")) {
        return .{ .benchmark = parse_benchmark_args(args_iterator) };
    } else {
        fatal("Unknown command: {s}", .{command_str});
    }
}

// Deploy merged into Start - no longer needed
// fn parse_deploy_args(args_iterator: anytype) CLIArgs.Deploy { ... }

fn parse_status_args(args_iterator: anytype) CLIArgs.Status {
    var result = CLIArgs.Status{};

    while (args_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--node=")) {
            result.node = arg["--node=".len..];
        }
    }

    return result;
}

fn parse_wal_args(args_iterator: anytype) CLIArgs.WAL {
    var result = CLIArgs.WAL{
        .path = "",
    };

    while (args_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--node=")) {
            result.node = arg["--node=".len..];
        } else if (std.mem.startsWith(u8, arg, "--slot=")) {
            result.slot = std.fmt.parseInt(usize, arg["--slot=".len..], 10) catch {
                fatal("Invalid slot: {s}", .{arg});
            };
        } else if (std.mem.startsWith(u8, arg, "--lines=")) {
            result.lines = std.fmt.parseInt(u32, arg["--lines=".len..], 10) catch {
                fatal("Invalid lines: {s}", .{arg});
            };
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            result.follow = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            result.path = arg;
        }
    }

    if (result.path.len == 0) fatal("WAL path is required", .{});

    return result;
}

// Format removed - no longer needed for orchestrator
// fn parse_format_args(args_iterator: anytype) CLIArgs.Format {
//     var result = CLIArgs.Format{
//         .replica_count = 0,
//         .positional = .{ .path = "" },
//     };
//
//     while (args_iterator.next()) |arg| {
//         if (std.mem.startsWith(u8, arg, "--cluster=")) {
//             const value_str = arg["--cluster=".len..];
//             result.cluster = std.fmt.parseInt(u128, value_str, 10) catch {
//                 fatal("Invalid cluster ID: {s}", .{value_str});
//             };
//         } else if (std.mem.startsWith(u8, arg, "--replica=")) {
//             const value_str = arg["--replica=".len..];
//             result.replica = std.fmt.parseInt(u8, value_str, 10) catch {
//                 fatal("Invalid replica index: {s}", .{value_str});
//             };
//         } else if (std.mem.startsWith(u8, arg, "--standby=")) {
//             const value_str = arg["--standby=".len..];
//             result.standby = std.fmt.parseInt(u8, value_str, 10) catch {
//                 fatal("Invalid standby index: {s}", .{value_str});
//             };
//         } else if (std.mem.startsWith(u8, arg, "--replica-count=")) {
//             const value_str = arg["--replica-count=".len..];
//             result.replica_count = std.fmt.parseInt(u8, value_str, 10) catch {
//                 fatal("Invalid replica count: {s}", .{value_str});
//             };
//         } else if (std.mem.eql(u8, arg, "--development")) {
//             result.development = true;
//         } else if (std.mem.eql(u8, arg, "--log-debug")) {
//             result.log_debug = true;
//         } else if (!std.mem.startsWith(u8, arg, "--")) {
//             result.positional.path = arg;
//         }
//     }
//
//     if (result.positional.path.len == 0) {
//         fatal("Missing required data file path", .{});
//     }
//
//     return result;
// }

fn parse_start_args(args_iterator: anytype) CLIArgs.Start {
    var result = CLIArgs.Start{
        .service = "",
        .pid_addresses = "",
        .positional = .{ .path = "" },
    };

    while (args_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--service=")) {
            result.service = arg["--service=".len..];
        } else if (std.mem.startsWith(u8, arg, "--nodes=") or std.mem.startsWith(u8, arg, "--pid-addresses=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--nodes=")) "--nodes=".len else "--pid-addresses=".len;
            result.pid_addresses = arg[prefix_len..];
        } else if (std.mem.startsWith(u8, arg, "--address=") or std.mem.startsWith(u8, arg, "--bind=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--bind=")) "--bind=".len else "--address=".len;
            result.address = arg[prefix_len..];
        } else if (std.mem.startsWith(u8, arg, "--cache-size=")) {
            result.cache_size = parse_byte_size(arg["--cache-size=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--limit-storage=")) {
            result.limit_storage = parse_byte_size(arg["--limit-storage=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--limit-request=")) {
            result.limit_request = parse_byte_size(arg["--limit-request=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--limit-pipeline-requests=")) {
            const value_str = arg["--limit-pipeline-requests=".len..];
            result.limit_pipeline_requests = std.fmt.parseInt(u32, value_str, 10) catch {
                fatal("Invalid pipeline requests limit: {s}", .{value_str});
            };
        } else if (std.mem.startsWith(u8, arg, "--timeout-prepare-ms=")) {
            const value_str = arg["--timeout-prepare-ms=".len..];
            result.timeout_prepare_ms = std.fmt.parseInt(u64, value_str, 10) catch {
                fatal("Invalid timeout: {s}", .{value_str});
            };
        } else if (std.mem.eql(u8, arg, "--logger")) {
            result.logger = true;
        } else if (std.mem.eql(u8, arg, "--sre")) {
            result.sre = true;
        } else if (std.mem.startsWith(u8, arg, "--replica=")) {
            const value_str = arg["--replica=".len..];
            result.replica = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid replica: {s}", .{value_str});
            };
        } else if (std.mem.startsWith(u8, arg, "--max-replica=")) {
            const value_str = arg["--max-replica=".len..];
            result.max_replica = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid max-replica: {s}", .{value_str});
            };
        } else if (std.mem.startsWith(u8, arg, "--mem-max=") or std.mem.startsWith(u8, arg, "--mem-percent=")) {
            const is_percent = std.mem.startsWith(u8, arg, "--mem-percent=");
            const prefix_len = if (is_percent) "--mem-percent=".len else "--mem-max=".len;
            const value_str = arg[prefix_len..];
            const field_name = if (is_percent) "mem_percent" else "mem_max";
            const val = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid {s}: {s}", .{ field_name, value_str });
            };
            if (is_percent) {
                result.mem_percent = val;
            } else {
                result.mem_max = val;
            }
        } else if (std.mem.startsWith(u8, arg, "--cpu-max=") or std.mem.startsWith(u8, arg, "--cpu-percent=")) {
            const is_percent = std.mem.startsWith(u8, arg, "--cpu-percent=");
            const prefix_len = if (is_percent) "--cpu-percent=".len else "--cpu-max=".len;
            const value_str = arg[prefix_len..];
            const field_name = if (is_percent) "cpu_percent" else "cpu_max";
            const val = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid {s}: {s}", .{ field_name, value_str });
            };
            if (is_percent) {
                result.cpu_percent = val;
            } else {
                result.cpu_max = val;
            }
        } else if (std.mem.eql(u8, arg, "--experimental")) {
            result.experimental = true;
        } else if (std.mem.eql(u8, arg, "--development")) {
            result.development = true;
        } else if (std.mem.eql(u8, arg, "--log-debug")) {
            result.log_debug = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            result.positional.path = arg;
        }
    }

    if (result.service.len == 0) {
        fatal("--service is required", .{});
    }
    if (result.pid_addresses.len == 0) {
        fatal("--nodes (or --pid-addresses) is required", .{});
    }
    if (result.positional.path.len == 0) {
        fatal("Missing required data file path", .{});
    }

    return result;
}

fn parse_version_args(args_iterator: anytype) CLIArgs.Version {
    var result = CLIArgs.Version{};

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        }
    }

    return result;
}

fn parse_benchmark_args(args_iterator: anytype) CLIArgs.Benchmark {
    var result = CLIArgs.Benchmark{};

    while (args_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) {
            result.target = arg["--target=".len..];
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            const value_str = arg["--duration=".len..];
            result.duration = std.fmt.parseInt(u32, value_str, 10) catch {
                fatal("Invalid duration: {s}", .{value_str});
            };
        } else if (std.mem.startsWith(u8, arg, "--connections=")) {
            const value_str = arg["--connections=".len..];
            result.connections = std.fmt.parseInt(u32, value_str, 10) catch {
                fatal("Invalid connections: {s}", .{value_str});
            };
        } else if (std.mem.eql(u8, arg, "--validate")) {
            result.validate = true;
        } else if (std.mem.startsWith(u8, arg, "--addresses=")) {
            result.addresses = arg["--addresses=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            result.seed = arg["--seed=".len..];
        } else if (std.mem.eql(u8, arg, "--logger-debugger")) {
            result.logger_debugger = true;
        } else if (std.mem.eql(u8, arg, "--log-debug")) {
            result.log_debug = true;
        }
    }

    return result;
}

// Deploy merged into Start - no longer needed
// fn parse_args_deploy(deploy: CLIArgs.Deploy) Command.Deploy { ... }

fn parse_args_status(status: CLIArgs.Status) Command.Status {
    return .{
        .node = if (status.node) |n| parse_address_and_port(n, "--node", orchestrator_port) else null,
        .service = status.service,
        .format = status.format,
    };
}

fn parse_args_wal(wal: CLIArgs.WAL) Command.WAL {
    return .{
        .path = wal.path,
        .node = if (wal.node) |n| parse_address_and_port(n, "--node", orchestrator_port) else null,
        .slot = wal.slot,
        .lines = wal.lines,
        .follow = wal.follow,
    };
}

// Format removed - no longer needed for orchestrator
// fn parse_args_format(format: CLIArgs.Format) Command.Format {
//     if (format.replica_count == 0) {
//         fatal("--replica-count: value needs to be greater than zero", .{});
//     }
//     if (format.replica_count > 5) { // Old code - will be removed
//         fatal("--replica-count: value is too large ({}), at most {} is allowed", .{
//             format.replica_count,
//             5,
//         });
//     }
//
//     if (format.replica == null and format.standby == null) {
//         fatal("--replica: argument is required", .{});
//     }
//
//     if (format.replica != null and format.standby != null) {
//         fatal("--standby: conflicts with '--replica'", .{});
//     }
//
//     if (format.replica) |replica| {
//         if (replica >= format.replica_count) {
//             fatal("--replica: value is too large ({}), at most {} is allowed", .{
//                 replica,
//                 format.replica_count - 1,
//             });
//         }
//     }
//
//     if (format.standby) |standby| {
//         if (standby < format.replica_count) {
//             fatal("--standby: value is too small ({}), at least {} is required", .{
//                 standby,
//                 format.replica_count,
//             });
//         }
//         if (standby >= format.replica_count + 3) { // Old code
//             fatal("--standby: value is too large ({}), at most {} is allowed", .{
//                 standby,
//                 format.replica_count + 3 - 1,
//             });
//         }
//     }
//
//     const replica = (format.replica orelse format.standby).?;
//     assert(replica < 7);
//     assert(replica < format.replica_count + 3);
//
//     const cluster_random = std.crypto.random.int(u128);
//     assert(cluster_random != 0);
//     const cluster = format.cluster orelse cluster_random;
//     if (format.cluster == null) {
//         std.log.info("generated random cluster id: {}\n", .{cluster});
//     } else if (format.cluster.? == 0) {
//         std.log.warn("a cluster id of 0 is reserved for testing and benchmarking, " ++
//             "do not use in production", .{});
//         std.log.warn("omit --cluster=0 to randomly generate a suitable id\n", .{});
//     }
//
//     return .{
//         .cluster = cluster,
//         .replica = replica,
//         .replica_count = format.replica_count,
//         .development = format.development,
//         .path = format.positional.path,
//         .log_debug = format.log_debug,
//     };
// }

fn parse_args_start(start: CLIArgs.Start) Command.Start {
    // Allowlist of stable flags. --development will disable automatic multiversion
    // upgrades too, but the flag itself is stable.
    const stable_args = .{
        "service",      "pid_addresses",
        "address",      "cache_size",
        "mem_percent",  "cpu_percent",
        "positional",   "development",
        "experimental",
    };
    inline for (std.meta.fields(@TypeOf(start))) |field| {
        @setEvalBranchQuota(10_000);
        const stable_field = comptime for (stable_args) |stable_arg| {
            assert(std.meta.fieldIndex(@TypeOf(start), stable_arg) != null);
            if (std.mem.eql(u8, field.name, stable_arg)) {
                break true;
            }
        } else false;
        if (stable_field) continue;

        const flag_name = comptime blk: {
            var result: [2 + field.name.len]u8 = ("--" ++ field.name).*;
            std.mem.replaceScalar(u8, &result, '_', '-');
            break :blk result;
        };

        // Validate at compile time that experimental fields have proper defaults
        comptime {
            // For experimental fields, ensure they default to null or false
            const TypeInfo = @typeInfo(field.type);
            const is_optional = TypeInfo == .optional;
            const is_bool = field.type == bool;

            if (!is_bool and !is_optional) {
                @compileError("Experimental field '" ++ field.name ++ "' must be optional or bool");
            }
        }

        // Runtime check: if experimental field is set, require --experimental flag
        if (field.type == bool) {
            if (@field(start, field.name) and !start.experimental) {
                fatal(
                    "{s} is marked experimental, add `--experimental` to continue.",
                    .{flag_name},
                );
            }
        } else {
            if (@field(start, field.name) != null and !start.experimental) {
                fatal(
                    "{s} is marked experimental, add `--experimental` to continue.",
                    .{flag_name},
                );
            }
        }
    }

    const addresses = parse_addresses(start.pid_addresses, "--pid-addresses");

    const storage_size_limit = if (start.limit_storage) |ls|
        ls.bytes()
    else
        10 * GIB;

    if (storage_size_limit > 1024 * GIB) {
        fatal("--limit-storage: size exceeds maximum: {}", .{1024 * GIB});
    }
    if (storage_size_limit < 64 * MIB) {
        fatal("--limit-storage: size is below minimum: {}", .{64 * MIB});
    }
    if (storage_size_limit % 512 != 0) {
        fatal("--limit-storage: size must be a multiple of sector size ({})", .{512});
    }

    const pipeline_limit = start.limit_pipeline_requests orelse 100;
    if (pipeline_limit > 1024) {
        fatal("--limit-pipeline-requests: count {} exceeds maximum: {}", .{
            pipeline_limit,
            1024,
        });
    }

    const request_limit = if (start.limit_request) |rl|
        @as(u32, @intCast(rl.bytes()))
    else
        @as(u32, 1 * MIB);

    if (request_limit > 1 * MIB) {
        fatal("--limit-request: size exceeds maximum: {}", .{1 * MIB});
    }
    if (request_limit < 4096) {
        fatal("--limit-request: size is below minimum: 4096", .{});
    }

    // Validate mem and cpu percentages
    if (start.mem_percent == 0 or start.mem_percent > 100) {
        fatal("--mem-percent must be between 1 and 100", .{});
    }
    if (start.cpu_percent == 0 or start.cpu_percent > 100) {
        fatal("--cpu-percent must be between 1 and 100", .{});
    }

    const parsed_address = if (start.address) |addr|
        parse_address_and_port(addr, "--address", orchestrator_port)
    else
        parse_address_and_port("0.0.0.0", "--address", orchestrator_port);

    return .{
        .service = start.service,
        .nodes = addresses,
        .bind = parsed_address,
        .mem_percent = start.mem_percent,
        .cpu_percent = start.cpu_percent,
        .state_dir = start.positional.path,
        .development = start.development,
        .log_debug = start.log_debug,
        .sre = start.sre,
    };
}

fn parse_args_version(version: CLIArgs.Version) Command.Version {
    return .{
        .verbose = version.verbose,
    };
}

fn parse_args_benchmark(benchmark: CLIArgs.Benchmark) Command.Benchmark {
    const addresses = if (benchmark.addresses) |addr|
        parse_addresses(addr, "--addresses")
    else
        null;

    return .{
        .logger_debugger = benchmark.logger_debugger,
        .target = benchmark.target,
        .duration = benchmark.duration,
        .connections = benchmark.connections,
        .validate = benchmark.validate,
        .addresses = addresses,
        .seed = benchmark.seed,
        .log_debug = benchmark.log_debug,
    };
}


fn parse_addresses(raw_addresses: []const u8, comptime flag: []const u8) Command.Addresses {
    comptime assert(std.mem.startsWith(u8, flag, "--"));
    var result = Command.Addresses.init();
    var iter = std.mem.tokenizeScalar(u8, raw_addresses, ',');

    while (iter.next()) |addr_str| {
        const addr = parse_address_and_port(addr_str, flag, orchestrator_port);

        // Check for duplicate addresses
        for (result.slice()) |existing_addr| {
            if (std.net.Address.eql(existing_addr, addr)) {
                fatal("{s}: duplicate node address detected: {s}", .{ flag, addr_str });
            }
        }

        result.push(addr) catch {
            fatal("{s}: too many addresses, at most {} are allowed", .{ flag, max_nodes });
        };
    }

    if (result.len == 0) {
        fatal("{s}: at least one address is required", .{flag});
    }

    return result;
}

fn parse_address_and_port(raw_address: []const u8, comptime flag: []const u8, port_default: u16) std.net.Address {
    comptime assert(std.mem.startsWith(u8, flag, "--"));

    var addr_str = raw_address;
    var port: u16 = port_default;

    // Check for IPv6 format [::1]:port
    if (std.mem.startsWith(u8, addr_str, "[")) {
        const close_bracket = std.mem.indexOf(u8, addr_str, "]") orelse {
            fatal("{s}: invalid IPv6 address format", .{flag});
        };
        const ipv6_str = addr_str[1..close_bracket];
        if (close_bracket + 1 < addr_str.len and addr_str[close_bracket + 1] == ':') {
            const port_str = addr_str[close_bracket + 2 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                fatal("{s}: invalid port: {s}", .{ flag, port_str });
            };
        }
        addr_str = ipv6_str;
    } else if (std.mem.lastIndexOf(u8, addr_str, ":")) |colon_pos| {
        const port_str = addr_str[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch {
            // Try to parse as just port number
            if (std.fmt.parseInt(u16, addr_str, 10)) |port_only| {
                return std.net.Address.parseIp(default_address, port_only) catch {
                    fatal("{s}: invalid address or port: {s}", .{ flag, addr_str });
                };
            } else |_| {
                fatal("{s}: invalid port: {s}", .{ flag, port_str });
            }
        };
        addr_str = addr_str[0..colon_pos];
    } else {
        // Try to parse as just port number
        if (std.fmt.parseInt(u16, addr_str, 10)) |port_only| {
            return std.net.Address.parseIp(default_address, port_only) catch {
                fatal("{s}: invalid address: {s}", .{ flag, addr_str });
            };
        } else |_| {}
    }

    const address = std.net.Address.parseIp(addr_str, port) catch {
        fatal("{s}: invalid IP address: {s}", .{ flag, addr_str });
    };

    return address;
}

fn parse_byte_size(str: []const u8) ByteSize {
    var value: u64 = 0;
    var suffix_start: usize = 0;

    for (str, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
            suffix_start = i + 1;
        } else {
            break;
        }
    }

    const suffix = str[suffix_start..];
    const multiplier: u64 = if (std.mem.eql(u8, suffix, "KiB"))
        KIB
    else if (std.mem.eql(u8, suffix, "MiB"))
        MIB
    else if (std.mem.eql(u8, suffix, "GiB"))
        GIB
    else if (suffix.len == 0 or std.mem.eql(u8, suffix, "B"))
        1
    else
        fatal("Invalid size suffix: {s}", .{suffix});

    return .{ .value = value * multiplier };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

// CLIArgs store RAW data from user, desugared in compilers means transform human-friendly to machine-friendly
// convert user raw inputs to system types and validate at comptime type shit
pub const DesugaredArgs = union(enum) {};

comptime {
    // Validate that all struct fields have proper defaults
    assert(@sizeOf(CLIArgs.Start) > 0);
    // assert(@sizeOf(CLIArgs.Format) > 0); // Format removed
    assert(@sizeOf(CLIArgs.Version) > 0);
    assert(@sizeOf(CLIArgs.Benchmark) > 0);
    // Validate help text compiles
    _ = CLIArgs.help;
}
