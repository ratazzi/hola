const std = @import("std");

/// indicatif - A Zig port of the Rust indicatif library
/// Provides progress bars, spinners, and multi-progress management for CLI applications

pub const ProgressBar = @import("indicatif/progress_bar.zig").ProgressBar;
pub const MultiProgress = @import("indicatif/multi_progress.zig").MultiProgress;
pub const ProgressStyle = @import("indicatif/progress_style.zig").ProgressStyle;
pub const Spinner = @import("indicatif/spinner.zig").Spinner;
pub const format = @import("indicatif/format.zig");

// Re-export common types
pub const HumanBytes = format.HumanBytes;
pub const HumanDuration = format.HumanDuration;
pub const HumanCount = format.HumanCount;

test {
    std.testing.refAllDecls(@This());
}
