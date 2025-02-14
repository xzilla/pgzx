const std = @import("std");
const mem = @import("mem.zig");
const err = @import("err.zig");
const c = @import("c.zig");
const datum = @import("datum.zig");

pub fn connect() err.PGError!void {
    const status = c.SPI_connect();
    if (status == c.SPI_ERROR_CONNECT) {
        return err.PGError.SPIConnectFailed;
    }
}

pub fn connectNonAtomic() err.PGError!void {
    const status = c.SPI_connect_ext(c.SPI_OPT_NONATOMIC);
    try checkStatus(status);
}

pub fn finish() void {
    _ = c.SPI_finish();
}

pub const Args = struct {
    types: []const c.Oid,
    values: []const c.NullableDatum,

    pub fn has_nulls(self: *const Args) bool {
        for (self.values) |value| {
            if (value.isnull) {
                return true;
            }
        }
        return false;
    }
};

pub const ExecOptions = struct {
    read_only: bool = false,
    limit: c_long = 0,
    args: ?Args = null,
};

pub const SPIError = err.PGError || std.mem.Allocator.Error;

pub fn exec(sql: [:0]const u8, options: ExecOptions) SPIError!c_int {
    if (options.args) |args| {
        if (args.types.len != args.values.len) {
            return err.PGError.SPIArgument;
        }

        var arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const n = args.types.len;
        const nulls: [*c]const u8 = blk: {
            if (args.has_nulls()) {
                var buf = try allocator.alloc(u8, n);
                for (args.values, 0..) |value, i| {
                    buf[i] = if (value.isnull) 'n' else ' ';
                }
                break :blk buf.ptr;
            } else {
                break :blk null;
            }
        };

        const values: [*c]c.Datum = blk: {
            var buf = try allocator.alloc(c.Datum, n);
            for (args.values, 0..) |arg, i| {
                buf[i] = arg.value;
            }
            break :blk buf.ptr;
        };

        const status = c.SPI_execute_with_args(
            sql.ptr,
            @intCast(n),
            @constCast(args.types.ptr),
            values,
            nulls,
            options.read_only,
            options.limit,
        );
        try checkStatus(status);
        return status;
    } else {
        const status = c.SPI_execute(sql.ptr, options.read_only, options.limit);
        try checkStatus(status);
        return status;
    }
}

pub fn query(sql: [:0]const u8, options: ExecOptions) SPIError!Rows {
    _ = try exec(sql, options);
    return Rows.init();
}

pub fn scanProcessed(row: usize, values: anytype) !void {
    if (c.SPI_processed <= row) {
        return err.PGError.SPIInvalidRowIndex;
    }

    var column: c_int = 1;
    inline for (std.meta.fields(@TypeOf(values)), 0..) |field, i| {
        column = try scanField(field.type, values[i], row, column);
    }
}

fn scanField(comptime fieldType: type, to: anytype, row: usize, column: c_int) !c_int {
    const fieldInfo = @typeInfo(fieldType);
    if (fieldInfo != .Pointer) {
        @compileError("scanField requires a pointer");
    }
    if (fieldInfo.Pointer.size == .Slice) {
        @compileError("scanField requires a single pointer, not a slice");
    }

    const childType = fieldInfo.Pointer.child;
    if (@typeInfo(childType) == .Struct) {
        var structColumn = column;
        inline for (std.meta.fields(childType)) |field| {
            const childPtr = &@field(to.*, field.name);
            structColumn = try scanField(@TypeOf(childPtr), childPtr, row, structColumn);
        }
        return structColumn;
    } else {
        const value = try convBinValue(childType, c.SPI_tuptable, row, column);
        to.* = value;
        return column + 1;
    }
}

pub const Rows = struct {
    row: isize = -1,

    const Self = @This();

    fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        c.SPI_freetuptable(c.SPI_tuptable);
        self.row = -1;
    }

    pub fn next(self: *Self) bool {
        const next_idx = self.row + 1;
        if (next_idx >= c.SPI_processed) {
            return false;
        }
        self.row = next_idx;
        return true;
    }

    pub fn scan(self: *Self, values: anytype) !void {
        if (self.row < 0) {
            return err.PGError.SPIInvalidRowIndex;
        }
        try scanProcessed(@intCast(self.row), values);
    }
};

pub fn RowsOf(comptime T: type) type {
    return struct {
        rows: Rows,

        const Self = @This();

        pub fn init(rows: Rows) Self {
            return .{ .rows = rows };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit();
        }

        pub fn next(self: *Self) !?T {
            if (!self.rows.next()) {
                return null;
            }
            var value: T = undefined;
            try self.rows.scan(.{&value});
            return value;
        }
    };
}

pub fn convProcessed(comptime T: type, row: c_int, col: c_int) !T {
    if (c.SPI_processed <= row) {
        return err.PGError.SPIInvalidRowIndex;
    }
    return convBinValue(T, c.SPI_tuptable, row, col);
}

pub fn convBinValue(comptime T: type, table: *c.SPITupleTable, row: usize, col: c_int) !T {
    // TODO: check index?

    var nd: c.NullableDatum = undefined;
    nd.value = c.SPI_getbinval(table.*.vals[row], table.*.tupdesc, col, @ptrCast(&nd.isnull));
    try checkStatus(c.SPI_result);
    return try datum.fromNullableDatum(T, nd);
}

fn checkStatus(st: c_int) err.PGError!void {
    switch (st) {
        c.SPI_ERROR_CONNECT => return err.PGError.SPIConnectFailed,
        c.SPI_ERROR_ARGUMENT => return err.PGError.SPIArgument,
        c.SPI_ERROR_COPY => return err.PGError.SPICopy,
        c.SPI_ERROR_TRANSACTION => return err.PGError.SPITransaction,
        c.SPI_ERROR_OPUNKNOWN => return err.PGError.SPIOpUnknown,
        c.SPI_ERROR_UNCONNECTED => return err.PGError.SPIUnconnected,
        c.SPI_ERROR_NOATTRIBUTE => return err.PGError.SPINoAttribute,
        else => {
            if (st < 0) {
                return err.PGError.SPIError;
            }
        },
    }
}
