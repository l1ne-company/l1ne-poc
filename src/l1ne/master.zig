const std = @import("std");
const net = std.net;
const systemd = @import("systemd.zig");
const cli = @import("cli.zig");

/// Master orchestrator that manages service instances
pub const Master = struct {
    allocator: std.mem.Allocator,
    bind_address: net.Address,
    services: std.ArrayList(ServiceInstance),
    systemd_notifier: ?systemd.Notifier,
    watchdog: ?systemd.Watchdog,
    
    const ServiceInstance = struct {
        name: []const u8,
        address: net.Address,
        pid: ?std.posix.pid_t,
        status: Status,
        resources: ResourceLimits,
        cgroup_monitor: ?systemd.CgroupMonitor,
        
        const Status = enum {
            starting,
            running,
            stopping,
            stopped,
            failed,
        };
        
        const ResourceLimits = struct {
            memory_percent: u8,
            cpu_percent: u8,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator, config: cli.Command.Start) !Master {
        var notifier: ?systemd.Notifier = null;
        var watchdog: ?systemd.Watchdog = null;
        
        // Initialize systemd integration if available
        if (systemd.isUnderSystemd()) {
            notifier = systemd.Notifier.init(allocator);
            if (notifier) |*n| {
                watchdog = try systemd.Watchdog.init(n, allocator);
            }
        }
        
        return Master{
            .allocator = allocator,
            .bind_address = config.bind,
            .services = std.ArrayList(ServiceInstance).empty,
            .systemd_notifier = notifier,
            .watchdog = watchdog,
        };
    }
    
    pub fn deinit(self: *Master) void {
        if (self.systemd_notifier) |*notifier| {
            notifier.deinit();
        }
        for (self.services.items) |*service| {
            if (service.cgroup_monitor) |*monitor| {
                monitor.deinit();
            }
        }
        self.services.deinit(self.allocator);
    }
    
    /// Start the master orchestrator
    pub fn start(self: *Master, config: cli.Command.Start) !void {
        // Notify systemd we're starting
        if (self.systemd_notifier) |*notifier| {
            try notifier.status("Starting L1NE orchestrator...");
        }
        
        // Deploy service instances
        for (config.nodes.slice()) |node_addr| {
            try self.deployInstance(config.service, node_addr, .{
                .memory_percent = config.mem_percent,
                .cpu_percent = config.cpu_percent,
            });
        }
        
        // Start load balancer
        var server = try net.Address.listen(self.bind_address, .{
            .reuse_address = true,
        });
        defer server.deinit();
        
        // Notify systemd we're ready
        if (self.systemd_notifier) |*notifier| {
            try notifier.ready();
            try notifier.status(try std.fmt.allocPrint(
                self.allocator,
                "Managing {d} instances of {s}",
                .{ config.nodes.len, config.service }
            ));
        }
        
        std.log.info("L1NE orchestrator listening on {any}", .{self.bind_address});
        
        // Main loop
        while (true) {
            // Send watchdog keepalive if needed
            if (self.watchdog) |*wd| {
                try wd.keepaliveIfNeeded();
            }
            
            // Accept connections and load balance
            if (server.accept()) |conn| {
                // Round-robin load balancing
                const instance = self.selectHealthyInstance() orelse {
                    conn.stream.close();
                    continue;
                };
                
                // Forward to selected instance
                self.forwardConnection(conn, instance) catch |err| {
                    std.log.err("Failed to forward connection: {any}", .{err});
                };
            } else |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            }
        }
    }
    
    /// Deploy a service instance
    fn deployInstance(
        self: *Master,
        service_name: []const u8,
        address: net.Address,
        limits: ServiceInstance.ResourceLimits,
    ) !void {
        std.log.info("Deploying {s} instance at {any}", .{ service_name, address });
        
        // Create instance record
        const instance = ServiceInstance{
            .name = try self.allocator.dupe(u8, service_name),
            .address = address,
            .pid = null,
            .status = .starting,
            .resources = limits,
            .cgroup_monitor = null,
        };
        
        try self.services.append(self.allocator, instance);
        
        // If systemd is available, create transient service
        if (systemd.isUnderSystemd()) {
            var svc_mgr = systemd.ServiceManager.init(self.allocator);
            
            const unit_name = try std.fmt.allocPrint(
                self.allocator,
                "l1ne-{s}-{d}",
                .{ service_name, address.getPort() }
            );
            
            // Convert percentages to actual values
            // Base: 50M memory, 10% CPU (from FAAS POC)
            const memory_max: usize = @as(usize, 50 * 1024 * 1024) * @as(usize, limits.memory_percent) / 100;
            const cpu_quota = @as(u8, 10) * limits.cpu_percent / 100;
            
            try svc_mgr.startTransientService(.{
                .unit_name = unit_name,
                .exec_args = &[_][]const u8{
                    "./faas-service/target/release/faas-service",
                },
                .uid = std.os.linux.getuid(),
                .gid = std.os.linux.getgid(),
                .memory_max = memory_max,
                .cpu_quota = cpu_quota,
            });
            
            // Initialize cgroup monitor
            const last_instance = &self.services.items[self.services.items.len - 1];
            last_instance.cgroup_monitor = try systemd.CgroupMonitor.init(
                self.allocator,
                unit_name
            );
            last_instance.status = .running;
        } else {
            // Fallback to regular process spawning
            var child = std.process.Child.init(
                &[_][]const u8{"./faas-service/target/release/faas-service"},
                self.allocator
            );
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Inherit;
            
            try child.spawn();
            
            const last_instance = &self.services.items[self.services.items.len - 1];
            last_instance.pid = child.id;
            last_instance.status = .running;
        }
    }
    
    /// Select a healthy instance for load balancing
    fn selectHealthyInstance(self: *Master) ?*ServiceInstance {
        for (self.services.items) |*instance| {
            if (instance.status == .running) {
                return instance;
            }
        }
        return null;
    }
    
    /// Forward connection to service instance
    fn forwardConnection(self: *Master, conn: net.Server.Connection, instance: *ServiceInstance) !void {
        _ = self;
        defer conn.stream.close();
        
        // Connect to backend service
        const backend = try net.tcpConnectToAddress(instance.address);
        defer backend.close();
        
        // Simple proxy: forward data between client and backend
        var buf: [4096]u8 = undefined;
        
        // This is simplified - in production you'd want bidirectional forwarding
        while (true) {
            const n = try conn.stream.read(&buf);
            if (n == 0) break;
            try backend.writeAll(buf[0..n]);
        }
    }
    
    /// Get status of all service instances
    pub fn getStatus(self: *Master) ![]ServiceStatus {
        var statuses = try self.allocator.alloc(ServiceStatus, self.services.items.len);
        
        for (self.services.items, 0..) |*instance, i| {
            var memory_usage: ?u64 = null;
            var cpu_usage: ?systemd.CgroupMonitor.CpuStats = null;
            
            if (instance.cgroup_monitor) |*monitor| {
                memory_usage = monitor.getMemoryUsage() catch null;
                cpu_usage = monitor.getCpuUsage() catch null;
            }
            
            statuses[i] = .{
                .name = instance.name,
                .address = instance.address,
                .status = instance.status,
                .memory_usage = memory_usage,
                .cpu_stats = cpu_usage,
            };
        }
        
        return statuses;
    }
    
    pub const ServiceStatus = struct {
        name: []const u8,
        address: net.Address,
        status: ServiceInstance.Status,
        memory_usage: ?u64,
        cpu_stats: ?systemd.CgroupMonitor.CpuStats,
    };
};
