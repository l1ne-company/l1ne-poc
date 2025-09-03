const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const net = std.net;

const CLIArgs = union(enum) {
    const Start = struct {
        address: []const u8,
        logger: bool,
        sre: bool,
        replica: u8,
        max_replica: u8,

        // because is a POC the CPU & memory maximun will be defined in dummy-service (FAAS: Furry-as-a-Service)
        // and cpu_max & mem_max will represent percentage of the maximum of the amount of the pre-limite defined inside o FAAS
        mem_max: u8,
        cpu_max: u8,
    };

    pub const Help = fmt.comptimePrint(
        \\ homem-bosta
    , .{});
};

// CLIArgs store RAW data from user, desugared in compilers means transform human-friendly to machine-friendly
pub const DesugaredArgs = union(enum) {};
