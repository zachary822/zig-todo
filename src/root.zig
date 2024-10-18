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
};

/// The thinnest of sqlite3 wrappers
pub const DB = struct {
    const Self = @This();

    db: *c.sqlite3,

    pub fn init(path: [:0]const u8) !Self {
        var c_db: ?*c.sqlite3 = undefined;

        if (c.SQLITE_OK != c.sqlite3_open(path, &c_db)) {
            std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(c_db)});
            return SqliteError.DbOpenError;
        }
        return .{
            .db = c_db.?,
        };
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

    pub fn query(self: Self, stmt: [:0]const u8, args: anytype) !void {
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

        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ select id, description, priority, datetime(completed_at, 'unixepoch', 'localtime')
            \\ from todo
            \\ order by created_at asc, id asc;
        ;

        try self.db.prepare(stmt, &prepared);
        defer _ = c.sqlite3_finalize(prepared);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(prepared)) {
            const id = c.sqlite3_column_int(prepared, 0);

            const c_desc = c.sqlite3_column_text(prepared, 1);
            const desc = try self.allocator.dupeZ(u8, std.mem.span(c_desc));

            const priority = c.sqlite3_column_int(prepared, 2);

            const completed = c.sqlite3_column_type(prepared, 3) != c.SQLITE_NULL;
            const completed_at = if (completed) blk: {
                const c_comp = c.sqlite3_column_text(prepared, 3);
                break :blk try self.allocator.dupeZ(u8, std.mem.span(c_comp));
            } else null;

            try self.todos.append(.{
                .id = id,
                .description = desc,
                .priority = priority,
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
        try self.db.query(stmt, .{todo.id});
    }

    pub fn uncompleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ update todo set completed_at = null where id = ?;
        ;

        try self.db.query(stmt, .{todo.id});
    }

    pub fn addTodo(self: Self, message: [:0]u8, priority: i64) !void {
        const stmt =
            \\ insert into todo (description, priority) values (?, ?);
        ;
        try self.db.query(stmt, .{ message, priority });
    }

    pub fn deleteTodo(self: Self, todo: Todo) !void {
        const stmt =
            \\ delete from todo where id = ?;
        ;
        try self.db.query(stmt, .{todo.id});
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

    var db = try DB.init("test.db");
    defer std.fs.cwd().deleteFile("test.db") catch {};
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

    var db = try DB.init("test.db");
    defer std.fs.cwd().deleteFile("test.db") catch {};
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
