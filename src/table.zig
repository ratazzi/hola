const std = @import("std");
const vaxis = @import("vaxis");
const global_io = @import("global_io.zig");

pub const Ansi = struct {
    pub const reset = vaxis.ctlseqs.sgr_reset;
    pub const bold = vaxis.ctlseqs.bold_set;
    pub const dim = vaxis.ctlseqs.dim_set;
    pub const green = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{2});
    pub const cyan = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{6});
    pub const yellow = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{3});
    pub const red = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{1});
    pub const magenta = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{5});
    pub const blue = std.fmt.comptimePrint(vaxis.ctlseqs.fg_base, .{4});
};

pub const CellStyle = struct {
    text: []const u8,
    color: []const u8 = "",
    bold: bool = false,
    dim: bool = false,

    pub fn plain(text: []const u8) CellStyle {
        return .{ .text = text };
    }

    pub fn colored(text: []const u8, color: []const u8) CellStyle {
        return .{ .text = text, .color = color };
    }

    pub fn label(text: []const u8, color: []const u8) CellStyle {
        return .{ .text = text, .color = color, .bold = true };
    }

    pub fn dimmed(text: []const u8) CellStyle {
        return .{ .text = text, .dim = true };
    }
};

pub const Column = struct {
    width: ?usize = null,
    alignment: Align = .left,
    padding: usize = 2,

    pub const Align = enum { left, right, center };
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    out: std.Io.File,
    colorize: bool,
    columns: []Column,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Row = struct {
        cells: []CellStyle,
    };

    pub fn init(allocator: std.mem.Allocator, out: std.Io.File, columns: []const Column) !Table {
        const cols_copy = try allocator.dupe(Column, columns);
        return .{
            .allocator = allocator,
            .out = out,
            .colorize = out.isTty(global_io.io()) catch false,
            .columns = cols_copy,
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.cells);
        }
        self.rows.deinit(self.allocator);
        self.allocator.free(self.columns);
        self.buffer.deinit(self.allocator);
    }

    pub fn addRow(self: *Table, cells: []const CellStyle) !void {
        if (cells.len != self.columns.len) return error.ColumnMismatch;
        const cells_copy = try self.allocator.dupe(CellStyle, cells);
        try self.rows.append(self.allocator, .{ .cells = cells_copy });
    }

    pub fn render(self: *Table) !void {
        if (self.rows.items.len == 0) return;

        try self.calculateColumnWidths();

        for (self.rows.items) |row| {
            try self.renderRow(row);
        }
    }

    fn calculateColumnWidths(self: *Table) !void {
        for (self.columns, 0..) |*col, i| {
            if (col.width != null) continue;

            var max_width: usize = 0;
            for (self.rows.items) |row| {
                // Strip ANSI escape codes to get actual text width
                const text_len = stripAnsiCodes(row.cells[i].text);
                if (text_len > max_width) max_width = text_len;
            }
            col.width = max_width;
        }
    }

    fn stripAnsiCodes(text: []const u8) usize {
        // Count actual text width by skipping ANSI escape sequences
        var width: usize = 0;
        var i: usize = 0;

        while (i < text.len) {
            if (i < text.len - 1 and text[i] == 0x1b and text[i + 1] == '[') {
                // Skip ANSI escape sequence
                i += 2; // Skip ESC[
                while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == ';' or text[i] == 'm' or text[i] == '?')) {
                    i += 1;
                }
            } else {
                width += 1;
                i += 1;
            }
        }

        return width;
    }

    fn renderRow(self: *Table, row: Row) !void {
        for (row.cells, 0..) |cell, i| {
            const col = self.columns[i];
            try self.renderCell(cell, col);
        }
        try self.out.writeStreamingAll(global_io.io(), "\n");
    }

    fn renderCell(self: *Table, cell: CellStyle, col: Column) !void {
        const width = col.width orelse 0;

        if (self.colorize) {
            if (cell.bold) try self.out.writeStreamingAll(global_io.io(), Ansi.bold);
            if (cell.dim) try self.out.writeStreamingAll(global_io.io(), Ansi.dim);
            if (cell.color.len > 0) try self.out.writeStreamingAll(global_io.io(), cell.color);
        }

        try self.out.writeStreamingAll(global_io.io(), cell.text);

        if (self.colorize and (cell.bold or cell.dim or cell.color.len > 0)) {
            try self.out.writeStreamingAll(global_io.io(), Ansi.reset);
        }

        // Calculate actual text width (without ANSI codes) for padding
        const text_len = if (self.colorize) stripAnsiCodes(cell.text) else cell.text.len;
        if (text_len < width) {
            try self.writeSpaces(width - text_len);
        }

        if (col.padding > 0) {
            try self.writeSpaces(col.padding);
        }
    }

    fn writeSpaces(self: *Table, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.out.writeStreamingAll(global_io.io(), " ");
        }
    }
};

pub const SimpleTable = struct {
    allocator: std.mem.Allocator,
    out: std.Io.File,
    colorize: bool,

    pub fn init(allocator: std.mem.Allocator, out: std.Io.File) SimpleTable {
        return .{
            .allocator = allocator,
            .out = out,
            .colorize = out.isTty(global_io.io()) catch false,
        };
    }

    pub fn printHeader(self: SimpleTable, label: []const u8, detail: []const u8) !void {
        if (self.colorize) {
            try self.out.writeStreamingAll(global_io.io(), Ansi.dim);
            try self.out.writeStreamingAll(global_io.io(), label);
            try self.out.writeStreamingAll(global_io.io(), Ansi.reset);
            try self.out.writeStreamingAll(global_io.io(), " ");
            try self.out.writeStreamingAll(global_io.io(), detail);
            try self.out.writeStreamingAll(global_io.io(), "\n");
        } else {
            try self.out.writeStreamingAll(global_io.io(), label);
            try self.out.writeStreamingAll(global_io.io(), " ");
            try self.out.writeStreamingAll(global_io.io(), detail);
            try self.out.writeStreamingAll(global_io.io(), "\n");
        }
    }

    pub fn printSummary(self: SimpleTable, items: []const SummaryItem) !void {
        if (self.colorize) {
            try self.out.writeStreamingAll(global_io.io(), Ansi.dim);
            try self.out.writeStreamingAll(global_io.io(), "[summary]");
            try self.out.writeStreamingAll(global_io.io(), Ansi.reset);
        } else {
            try self.out.writeStreamingAll(global_io.io(), "[summary]");
        }

        for (items, 0..) |item, i| {
            if (i > 0) try self.out.writeStreamingAll(global_io.io(), " | ");
            try self.out.writeStreamingAll(global_io.io(), " ");

            if (self.colorize and item.color.len > 0) {
                try self.out.writeStreamingAll(global_io.io(), item.color);
            }

            var buf: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {d}", .{ item.label, item.value });
            try self.out.writeStreamingAll(global_io.io(), text);

            if (self.colorize and item.color.len > 0) {
                try self.out.writeStreamingAll(global_io.io(), Ansi.reset);
            }
        }
        try self.out.writeStreamingAll(global_io.io(), "\n");
    }

    pub fn printDimmed(self: SimpleTable, text: []const u8) !void {
        if (self.colorize) {
            try self.out.writeStreamingAll(global_io.io(), Ansi.dim);
            try self.out.writeStreamingAll(global_io.io(), text);
            try self.out.writeStreamingAll(global_io.io(), Ansi.reset);
        } else {
            try self.out.writeStreamingAll(global_io.io(), text);
        }
    }

    pub const SummaryItem = struct {
        label: []const u8,
        value: usize,
        color: []const u8 = "",
    };
};

test "table basic" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const out = std.Io.File{ .handle = undefined };
    var table = try Table.init(allocator, out, &.{
        .{ .width = 10 },
        .{ .width = 20 },
    });
    defer table.deinit();

    try table.addRow(&.{
        CellStyle.plain("Hello"),
        CellStyle.plain("World"),
    });

    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}
