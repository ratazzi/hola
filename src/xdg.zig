const std = @import("std");

/// XDG Base Directory Specification paths for hola
/// See: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
pub const XDG = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Get XDG_CONFIG_HOME directory for hola
    /// Default: ~/.config/hola
    /// Environment variable: XDG_CONFIG_HOME (if set, uses $XDG_CONFIG_HOME/hola)
    pub fn getConfigHome(self: Self) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "XDG_CONFIG_HOME")) |xdg_config| {
            defer self.allocator.free(xdg_config);
            return std.fs.path.join(self.allocator, &.{ xdg_config, "hola" });
        } else |_| {
            const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, ".config", "hola" });
        }
    }

    /// Get XDG_DATA_HOME directory for hola
    /// Default: ~/.local/share/hola
    /// Environment variable: XDG_DATA_HOME (if set, uses $XDG_DATA_HOME/hola)
    pub fn getDataHome(self: Self) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "XDG_DATA_HOME")) |xdg_data| {
            defer self.allocator.free(xdg_data);
            return std.fs.path.join(self.allocator, &.{ xdg_data, "hola" });
        } else |_| {
            const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, ".local", "share", "hola" });
        }
    }

    /// Get XDG_CACHE_HOME directory for hola
    /// Default: ~/.cache/hola
    /// Environment variable: XDG_CACHE_HOME (if set, uses $XDG_CACHE_HOME/hola)
    pub fn getCacheHome(self: Self) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "XDG_CACHE_HOME")) |xdg_cache| {
            defer self.allocator.free(xdg_cache);
            return std.fs.path.join(self.allocator, &.{ xdg_cache, "hola" });
        } else |_| {
            const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, ".cache", "hola" });
        }
    }

    /// Get XDG_STATE_HOME directory for hola
    /// Default: ~/.local/state/hola
    /// Environment variable: XDG_STATE_HOME (if set, uses $XDG_STATE_HOME/hola)
    pub fn getStateHome(self: Self) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "XDG_STATE_HOME")) |xdg_state| {
            defer self.allocator.free(xdg_state);
            return std.fs.path.join(self.allocator, &.{ xdg_state, "hola" });
        } else |_| {
            const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, ".local", "state", "hola" });
        }
    }

    /// Get config file path
    /// Searches in order:
    /// 1. $XDG_CONFIG_HOME/hola/hola.toml
    /// 2. ~/.config/hola/hola.toml (fallback)
    pub fn getConfigFile(self: Self) ![]const u8 {
        const config_home = try self.getConfigHome();
        defer self.allocator.free(config_home);
        return std.fs.path.join(self.allocator, &.{ config_home, "hola.toml" });
    }

    /// Get logs directory path
    /// Default: ~/.local/state/hola/logs
    pub fn getLogsDir(self: Self) ![]const u8 {
        const state_home = try self.getStateHome();
        defer self.allocator.free(state_home);
        return std.fs.path.join(self.allocator, &.{ state_home, "logs" });
    }

    /// Get cache downloads directory path
    /// Default: ~/.cache/hola/downloads
    pub fn getDownloadsDir(self: Self) ![]const u8 {
        const cache_home = try self.getCacheHome();
        defer self.allocator.free(cache_home);
        return std.fs.path.join(self.allocator, &.{ cache_home, "downloads" });
    }

    /// Get default config root directory (for git clone)
    /// Default: ~/.local/share/hola/config
    pub fn getDefaultConfigRoot(self: Self) ![]const u8 {
        const data_home = try self.getDataHome();
        defer self.allocator.free(data_home);
        return std.fs.path.join(self.allocator, &.{ data_home, "config" });
    }
};

test "XDG paths" {
    const allocator = std.testing.allocator;
    const xdg = XDG.init(allocator);

    // Test config home
    const config_home = try xdg.getConfigHome();
    defer allocator.free(config_home);
    std.debug.print("\nConfig home: {s}\n", .{config_home});

    // Test data home
    const data_home = try xdg.getDataHome();
    defer allocator.free(data_home);
    std.debug.print("Data home: {s}\n", .{data_home});

    // Test cache home
    const cache_home = try xdg.getCacheHome();
    defer allocator.free(cache_home);
    std.debug.print("Cache home: {s}\n", .{cache_home});

    // Test state home
    const state_home = try xdg.getStateHome();
    defer allocator.free(state_home);
    std.debug.print("State home: {s}\n", .{state_home});

    // Test logs dir
    const logs_dir = try xdg.getLogsDir();
    defer allocator.free(logs_dir);
    std.debug.print("Logs dir: {s}\n", .{logs_dir});

    // Test downloads dir
    const downloads_dir = try xdg.getDownloadsDir();
    defer allocator.free(downloads_dir);
    std.debug.print("Downloads dir: {s}\n", .{downloads_dir});
}
