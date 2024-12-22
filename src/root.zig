const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteError = error{
    DbOpenError,
    StepError,
    ExecError,
    BindError,
    ResetError,
    PrepareError,
    ReturnTypeError,
};

/// The thinnest of sqlite3 wrappers
pub const DB = struct {
    const Self = @This();

    db: ?*c.sqlite3,
    path: [:0]const u8,

    pub fn init(path: [:0]const u8) Self {
        return .{
            .db = null,
            .path = path,
        };
    }

    pub fn connect(self: *Self) !void {
        if (c.SQLITE_OK != c.sqlite3_open(self.path, &self.db)) {
            std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return SqliteError.DbOpenError;
        }
    }

    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn exec(self: Self, stmt: [:0]const u8) !void {
        var errmsg: [*c]u8 = undefined;

        if (c.SQLITE_OK != c.sqlite3_exec(self.db, stmt, null, null, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec failed: {s} \n", .{errmsg});
            return SqliteError.ExecError;
        }
    }

    pub fn prepare(self: Self, stmt: [:0]const u8, prepared: [*c]?*c.sqlite3_stmt) !void {
        const err = c.sqlite3_prepare_v2(self.db, stmt, @intCast(stmt.len + 1), prepared, null);
        if (err != c.SQLITE_OK) {
            return SqliteError.PrepareError;
        }
    }

    pub fn query(self: Self, comptime T: type, allocator: std.mem.Allocator, stmt: [:0]const u8, args: anytype) ![]T {
        var err: c_int = undefined;
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);

        if (args_type_info != .Struct) {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        const fields_info = args_type_info.Struct.fields;

        if (fields_info.len > 32766) {
            @compileError("too many bind parameters");
        }

        var prepared: ?*c.sqlite3_stmt = undefined;
        try self.prepare(stmt, &prepared);
        defer _ = c.sqlite3_finalize(prepared);

        inline for (fields_info, 0..) |info, i| {
            const value = @field(args, info.name);

            err = switch (@typeInfo(info.type)) {
                .ComptimeInt, .Int => c.sqlite3_bind_int64(prepared, i + 1, value),
                .ComptimeFloat, .Float => c.sqlite3_bind_double(prepared, i + 1, value),
                .Pointer => |ptr_info| switch (ptr_info.size) {
                    .Slice => c.sqlite3_bind_blob(prepared, i + 1, @ptrCast(value), @intCast(value.len), c.SQLITE_STATIC),
                    else => unreachable,
                },
                .Optional => |opt_info| if (value) |val| switch (@typeInfo(opt_info.child)) {
                    .ComptimeInt, .Int => c.sqlite3_bind_int64(prepared, i + 1, val),
                    .ComptimeFloat, .Float => c.sqlite3_bind_double(prepared, i + 1, val),
                    .Pointer => |ptr_info| switch (ptr_info.size) {
                        .Slice => c.sqlite3_bind_blob(prepared, i + 1, @ptrCast(val), @intCast(value.len), c.SQLITE_STATIC),
                        else => unreachable,
                    },
                    else => unreachable,
                } else c.sqlite3_bind_null(prepared, i + 1),
                .Null => c.sqlite3_bind_null(prepared, i + 1),
                else => unreachable,
            };

            if (err != c.SQLITE_OK) {
                return SqliteError.BindError;
            }
        }

        var rc = c.sqlite3_step(prepared);

        const res_type_info = @typeInfo(T);

        if (res_type_info != .Struct and res_type_info != .Void) {
            return SqliteError.ReturnTypeError;
        }

        var results: std.ArrayList(T) = std.ArrayList(T).init(allocator);
        defer results.deinit();

        const res_fields_info = comptime blk: {
            if (res_type_info == .Struct) {
                break :blk res_type_info.Struct.fields;
            }
            break :blk &[_]std.builtin.Type.StructField{};
        };

        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {
            if (res_fields_info.len > 0) {
                var row: T = undefined;
                inline for (res_fields_info, 0..) |info, i| {
                    @field(row, info.name) = switch (@typeInfo(info.type)) {
                        .ComptimeInt, .Int => c.sqlite3_column_int(prepared, i),
                        .ComptimeFloat, .Float => c.sqlite3_column_double(prepared, i),
                        .Pointer => |ptr_info| switch (ptr_info.size) {
                            .Slice => try getSlice(ptr_info.child, allocator, prepared, i),
                            else => unreachable,
                        },
                        .Optional => |opt_info| if (c.sqlite3_column_type(prepared, i) == c.SQLITE_NULL) null else switch (@typeInfo(opt_info.child)) {
                            .ComptimeInt, .Int => c.sqlite3_column_int(prepared, i),
                            .ComptimeFloat, .Float => c.sqlite3_column_double(prepared, i),
                            .Pointer => |ptr_info| switch (ptr_info.size) {
                                .Slice => try getSlice(ptr_info.child, allocator, prepared, i),
                                else => unreachable,
                            },
                            else => unreachable,
                        },
                        else => unreachable,
                    };
                }
                try results.append(row);
            }
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }

        return results.toOwnedSlice();
    }

    fn getSlice(comptime T: type, allocator: std.mem.Allocator, prepared: ?*c.sqlite3_stmt, i: c_int) ![:0]T {
        return switch (c.sqlite3_column_type(prepared, i)) {
            c.SQLITE_TEXT => blk: {
                const c_str = c.sqlite3_column_text(prepared, i);
                break :blk try allocator.dupeZ(u8, std.mem.span(c_str));
            },
            c.SQLITE_BLOB => blk: {
                const size: usize = @intCast(c.sqlite3_column_bytes(prepared, i));
                const c_str = @as([*c]const T, @ptrCast(c.sqlite3_column_blob(prepared, i)))[0..size];
                const blob = try allocator.allocSentinel(T, size, 0);

                std.mem.copyForwards(T, blob, c_str);

                break :blk blob;
            },
            else => unreachable,
        };
    }
};

test "test query" {
    const allocator = std.testing.allocator;

    var db = DB.init(":memory:");
    try db.connect();
    defer db.deinit();
    const results = try db.query(struct { a: ?[:0]const u8 }, allocator, "SELECT x'deadbeef00'", .{});

    for (results) |row| {
        if (row.a) |a| {
            allocator.free(a);
        }
    }
    allocator.free(results);
}

test "test query null" {
    const allocator = std.testing.allocator;

    var db = DB.init(":memory:");
    try db.connect();
    defer db.deinit();
    const results = try db.query(void, allocator, "SELECT ?", .{null});
    allocator.free(results);
}

test "test query optional" {
    const allocator = std.testing.allocator;

    var db = DB.init(":memory:");
    try db.connect();
    defer db.deinit();
    const thing: ?i64 = 23;
    const results = try db.query(struct { a: ?i64 }, allocator, "SELECT ?", .{thing});
    allocator.free(results);
}

pub const TodoManager = struct {
    const Self = @This();

    pub const Todo = struct {
        id: i64,
        description: [:0]u8,
        priority: i64,
        completed_at: ?[:0]u8,
    };

    db: DB,
    allocator: std.mem.Allocator,

    todos: std.ArrayList(Todo),

    pub fn init(allocator: std.mem.Allocator, db: DB) Self {
        return .{
            .db = db,
            .todos = std.ArrayList(Todo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearTodos();
        self.todos.deinit();
    }

    pub fn migrate(self: Self) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS todo (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  description TEXT NOT NULL,
            \\  priority INTEGER DEFAULT (0),
            \\  completed_at INTEGER,
            \\  created_at INTEGER DEFAULT (UNIXEPOCH())
            \\);
            \\
            \\CREATE VIRTUAL TABLE IF NOT EXISTS todo_fts USING fts5(description, content='todo', content_rowid='id');
            \\
            \\CREATE TRIGGER IF NOT EXISTS tbl_ai AFTER INSERT ON todo BEGIN
            \\  INSERT INTO todo_fts(rowid, description) VALUES (new.id, new.description);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS tbl_ad AFTER DELETE ON todo BEGIN
            \\  INSERT INTO todo_fts(todo_fts, rowid, description) VALUES ('delete', old.id, old.description);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS tbl_au AFTER UPDATE ON todo BEGIN
            \\  INSERT INTO todo_fts(todo_fts, rowid, description) VALUES ('delete', old.id, old.description);
            \\  INSERT INTO todo_fts(rowid, description) VALUES (new.id, new.description);
            \\END;
        );
    }

    pub fn clearTodos(self: *Self) void {
        for (self.todos.items) |item| {
            self.allocator.free(item.description);
            if (item.completed_at) |comp| self.allocator.free(comp);
        }
        self.todos.clearAndFree();
    }

    pub fn getTodos(self: *Self) !std.ArrayList(Todo) {
        self.clearTodos();

        const stmt =
            \\ select id, description, priority, datetime(completed_at, 'unixepoch', 'localtime')
            \\ from todo
            \\ order by created_at asc, id asc;
        ;

        const results = try self.db.query(Self.Todo, self.allocator, stmt, .{});
        defer self.allocator.free(results);

        try self.todos.appendSlice(results);

        return self.todos;
    }

    pub fn completeTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ update todo set completed_at = unixepoch() where id = ?;
        ;
        _ = try self.db.query(void, self.allocator, stmt, .{todo.id});
    }

    pub fn uncompleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ update todo set completed_at = null where id = ?;
        ;

        _ = try self.db.query(void, self.allocator, stmt, .{todo.id});
    }

    pub fn updatePriority(self: Self, todo: Todo, priority: i64) !void {
        const stmt =
            \\ update todo set priority = ? % 3 where id = ?
        ;

        _ = try self.db.query(void, self.allocator, stmt, .{ priority, todo.id });
    }

    pub fn addTodo(self: Self, message: [:0]u8, priority: i64) !void {
        const stmt =
            \\ insert into todo (description, priority) values (?, ?);
        ;
        _ = try self.db.query(void, self.allocator, stmt, .{ message, priority });
    }

    pub fn deleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ delete from todo where id = ?;
        ;
        _ = try self.db.query(void, self.allocator, stmt, .{todo.id});
    }

    pub fn addTodos(self: Self, todos: [][:0]u8) !void {
        try self.db.exec("BEGIN;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        const stmt =
            \\ insert into todo (description) values (?);
        ;

        {
            var err: c_int = undefined;
            var prepared: ?*c.sqlite3_stmt = undefined;
            try self.db.prepare(stmt, &prepared);
            defer _ = c.sqlite3_finalize(prepared);

            for (todos) |todo| {
                err = c.sqlite3_bind_text(prepared, 1, todo, @intCast(todo.len), c.SQLITE_STATIC);

                if (err != c.SQLITE_OK) {
                    return SqliteError.BindError;
                }

                var rc = c.sqlite3_step(prepared);

                while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {}

                if (rc != c.SQLITE_DONE) {
                    return SqliteError.StepError;
                }

                err = c.sqlite3_reset(prepared);

                if (err != c.SQLITE_OK) {
                    return SqliteError.ResetError;
                }

                _ = c.sqlite3_clear_bindings(prepared);
            }
        }

        try self.db.exec("COMMIT;");
    }
};

test "can fetch todos" {
    const allocator = testing.allocator;

    var db = DB.init(":memory:");
    try db.connect();
    defer db.deinit();

    var todo_manager = TodoManager.init(allocator, db);
    defer todo_manager.deinit();

    try todo_manager.migrate();

    try db.exec(
        \\ insert into todo (description) values ('a'), ('b');
    );

    _ = try todo_manager.getTodos();
}

test "can add todos" {
    const allocator = testing.allocator;

    var db = DB.init(":memory:");
    try db.connect();
    defer db.deinit();

    var todo_manager = TodoManager.init(allocator, db);
    defer todo_manager.deinit();

    try todo_manager.migrate();

    var todos: [2][:0]u8 = undefined;

    todos[0] = @constCast("todo 1");
    todos[1] = @constCast("todo 2 :)");

    try todo_manager.addTodos(&todos);

    _ = try todo_manager.getTodos();

    for (todo_manager.todos.items, 0..) |todo, i| {
        try testing.expect(std.mem.eql(u8, todos[i], todo.description));
    }
}
