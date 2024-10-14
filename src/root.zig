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
};

pub const DB = struct {
    const Self = @This();
    pub const Todo = struct {
        id: i64,
        description: [:0]u8,
        completed_at: ?[:0]u8,
    };

    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    todos: std.ArrayList(Todo),

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8) !Self {
        var c_db: ?*c.sqlite3 = undefined;

        if (c.SQLITE_OK != c.sqlite3_open(path, &c_db)) {
            std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(c_db)});
            return SqliteError.DbOpenError;
        }
        return .{
            .db = c_db.?,
            .allocator = allocator,
            .todos = std.ArrayList(Todo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);

        self.clearTodos();
        self.todos.deinit();
    }

    pub fn exec(self: Self, stmt: [:0]const u8) !void {
        var errmsg: [*c]u8 = undefined;

        if (c.SQLITE_OK != c.sqlite3_exec(self.db, stmt, null, null, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec failed: {s} \n", .{errmsg});
            return SqliteError.ExecError;
        }
    }

    pub fn migrate(self: Self) !void {
        try self.exec(
            \\ create table if not exists todo (
            \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\   description TEXT NOT NULL,
            \\   completed_at INTEGER,
            \\   created_at INTEGER DEFAULT (unixepoch())
            \\ );
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

        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ select id, description, datetime(completed_at, 'unixepoch', 'localtime')
            \\ from todo
            \\ order by id asc, created_at asc
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        defer _ = c.sqlite3_finalize(prepared);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {
            const id = c.sqlite3_column_int(prepared, 0);

            const c_desc = c.sqlite3_column_text(prepared, 1);
            const desc = try self.allocator.dupeZ(u8, std.mem.span(c_desc));

            const completed = c.sqlite3_column_type(prepared, 2) != c.SQLITE_NULL;
            const completed_at = if (completed) blk: {
                const c_comp = c.sqlite3_column_text(prepared, 2);
                break :blk try self.allocator.dupeZ(u8, std.mem.span(c_comp));
            } else null;

            try self.todos.append(.{
                .id = id,
                .description = desc,
                .completed_at = completed_at,
            });
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }

        return self.todos;
    }

    pub fn completeTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ update todo set completed_at = unixepoch() where id = ?;
        ;
        try self.query(stmt, .{todo.id});
    }

    pub fn uncompleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ update todo set completed_at = null where id = ?;
        ;

        try self.query(stmt, .{todo.id});
    }

    pub fn addTodo(self: Self, message: [:0]u8) !void {
        const stmt =
            \\ insert into todo (description) values (?);
        ;
        try self.query(stmt, .{message});
    }

    pub fn deleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ delete from todo where id = ?;
        ;
        try self.query(stmt, .{todo.id});
    }

    pub fn addTodos(self: Self, todos: [][:0]u8) !void {
        try self.exec("BEGIN;");
        errdefer self.exec("ROLLBACK;") catch {};

        const stmt =
            \\ insert into todo (description) values (?);
        ;

        var prepared: ?*c.sqlite3_stmt = undefined;
        _ = c.sqlite3_prepare_v2(self.db, stmt, @intCast(stmt.len + 1), &prepared, null);
        defer {
            _ = c.sqlite3_finalize(prepared);
            self.exec("COMMIT;") catch {};
        }

        for (todos) |todo| {
            const err = c.sqlite3_bind_text(prepared, 1, todo, @intCast(todo.len), c.SQLITE_STATIC);
            defer _ = c.sqlite3_reset(prepared);

            if (err != c.SQLITE_OK) {
                return SqliteError.BindError;
            }

            var rc = c.sqlite3_step(prepared);

            while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {}

            if (rc != c.SQLITE_DONE) {
                return SqliteError.StepError;
            }
        }
    }

    pub fn query(self: Self, stmt: [:0]const u8, args: anytype) !void {
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
        _ = c.sqlite3_prepare_v2(self.db, stmt, @intCast(stmt.len + 1), &prepared, null);
        defer _ = c.sqlite3_finalize(prepared);

        inline for (fields_info, 0..) |info, i| {
            const value = @field(args, info.name);

            const err = switch (@typeInfo(info.type)) {
                .ComptimeInt, .Int => c.sqlite3_bind_int64(prepared, i + 1, value),
                .ComptimeFloat, .Float => c.sqlite3_bind_double(prepared, i + 1, value),
                .Pointer => |ptr_info| switch (ptr_info.size) {
                    .One => switch (@typeInfo(ptr_info.child)) {
                        .Array => c.sqlite3_bind_text(prepared, 1, value, @intCast(value.len), c.SQLITE_STATIC),
                        else => {},
                    },
                    .Slice => c.sqlite3_bind_text(prepared, 1, value, @intCast(value.len), c.SQLITE_STATIC),
                    else => {},
                },
                else => {},
            };

            if (err != c.SQLITE_OK) {
                return SqliteError.BindError;
            }
        }

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {}

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }
    }
};

test "can fetch todos" {
    const allocator = testing.allocator;

    var db = try DB.init(allocator, "test.db");
    defer std.fs.cwd().deleteFile("test.db") catch {};
    defer db.deinit();

    try db.migrate();

    try db.exec(
        \\ insert into todo (description) values ('a'), ('b');
    );

    _ = try db.getTodos();
}
