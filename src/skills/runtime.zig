const std = @import("std");

pub const Syscall = enum {
    file_read,
    file_write,
    file_delete,
    net_connect,
    net_listen,
    process_spawn,
    env_get,
    env_set,
};

pub const Capability = struct {
    syscall: Syscall,
    allowed: bool,
    name: []const u8,
};

pub const SkillManifest = struct {
    name: []const u8,
    version: []const u8,
    capabilities: []const Capability,
};

pub const SkillResult = struct {
    success: bool,
    output: []const u8,
    err_msg: ?[]const u8,
};

pub const SkillRuntime = struct {
    allocator: std.mem.Allocator,
    skills: std.StringHashMapUnmanaged(SkillManifest),
    syscall_policy: std.EnumMap(Syscall, bool),

    pub fn init(allocator: std.mem.Allocator) SkillRuntime {
        var runtime = SkillRuntime{
            .allocator = allocator,
            .skills = .{},
            .syscall_policy = .{},
        };

        runtime.syscall_policy.put(.file_read, true);
        runtime.syscall_policy.put(.file_write, true);
        runtime.syscall_policy.put(.file_delete, false);
        runtime.syscall_policy.put(.net_connect, false);
        runtime.syscall_policy.put(.net_listen, false);
        runtime.syscall_policy.put(.process_spawn, false);
        runtime.syscall_policy.put(.env_get, true);
        runtime.syscall_policy.put(.env_set, false);

        return runtime;
    }

    pub fn deinit(self: *SkillRuntime) void {
        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.skills.deinit(self.allocator);
    }

    pub fn register(self: *SkillRuntime, manifest: SkillManifest) !void {
        const name = try self.allocator.dupe(u8, manifest.name);
        try self.skills.putNoClobber(self.allocator, name, manifest);
        std.debug.print("[skills] registered: {s} v{s}\n", .{ manifest.name, manifest.version });
    }

    pub fn isRegistered(self: *SkillRuntime, name: []const u8) bool {
        return self.skills.contains(name);
    }

    pub fn canExecute(self: *SkillRuntime, manifest: SkillManifest) bool {
        for (manifest.capabilities) |cap| {
            const allowed = self.syscall_policy.get(cap.syscall) orelse false;
            if (cap.allowed and !allowed) {
                std.debug.print("[skills] denied: {s} requires {s} which is blocked\n", .{
                    manifest.name,
                    @tagName(cap.syscall),
                });
                return false;
            }
        }
        return true;
    }

    pub fn execute(self: *SkillRuntime, skill_name: []const u8, input: []const u8) !SkillResult {
        const manifest = self.skills.get(skill_name) orelse {
            return SkillResult{
                .success = false,
                .output = "",
                .err_msg = "skill not found",
            };
        };

        if (!self.canExecute(manifest)) {
            return SkillResult{
                .success = false,
                .output = "",
                .err_msg = "capability denied by policy",
            };
        }

        std.debug.print("[skills] executing: {s} with input ({} bytes)\n", .{
            skill_name,
            input.len,
        });

        return SkillResult{
            .success = true,
            .output = input,
            .err_msg = null,
        };
    }

    pub fn listSkills(self: *SkillRuntime) ![][]const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer list.deinit(self.allocator);

        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            try list.append(self.allocator, entry.key_ptr.*);
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn updatePolicy(self: *SkillRuntime, syscall: Syscall, allowed: bool) void {
        self.syscall_policy.put(syscall, allowed);
        std.debug.print("[skills] policy updated: {s} = {}\n", .{ @tagName(syscall), allowed });
    }

    pub fn getPolicy(self: *SkillRuntime, syscall: Syscall) bool {
        return self.syscall_policy.get(syscall) orelse false;
    }

    pub fn registeredCount(self: *SkillRuntime) usize {
        return self.skills.count();
    }
};
