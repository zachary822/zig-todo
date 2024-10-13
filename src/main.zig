const std = @import("std");
const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
    @cInclude("sqlite3.h");

    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("bluish/style_bluish.h");
});

const Todo = struct {
    id: i64,
    description: [:0]u8,
    completed_at: ?[:0]u8,
};

const SqliteError = error{
    DbOpenError,
    StepError,
    ExecError,
};

const DB = struct {
    const Self = @This();

    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, path: [:0]const u8) !Self {
        var c_db: ?*c.sqlite3 = undefined;

        if (c.SQLITE_OK != c.sqlite3_open(path, &c_db)) {
            std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(c_db)});
            return SqliteError.DbOpenError;
        }
        return .{ .db = c_db.?, .allocator = allocator };
    }

    fn deinit(self: Self) void {
        _ = c.sqlite3_close(self.db);
    }

    fn exec(self: Self, query: [:0]const u8) !void {
        var errmsg: [*c]u8 = undefined;

        if (c.SQLITE_OK != c.sqlite3_exec(self.db, query, null, null, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec failed: {s} \n", .{errmsg});
            return SqliteError.ExecError;
        }
    }

    fn getTodos(self: Self, todos: *std.ArrayList(Todo)) !void {
        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ select id, description, datetime(completed_at, 'unixepoch', 'localtime')
            \\ from todo
            \\ order by id asc, created_at asc
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int(prepared, 0);

            const c_desc = c.sqlite3_column_text(prepared, 1);
            const desc = try self.allocator.allocSentinel(u8, std.mem.len(c_desc), 0);
            std.mem.copyForwards(u8, desc, std.mem.sliceTo(c_desc, 0));

            const completed = c.sqlite3_column_type(prepared, 2) != c.SQLITE_NULL;
            const completed_at = if (completed) blk: {
                const c_comp = c.sqlite3_column_text(prepared, 2);
                const comp = try self.allocator.allocSentinel(u8, std.mem.len(c_comp), 0);
                std.mem.copyForwards(u8, comp, std.mem.sliceTo(c_comp, 0));
                break :blk comp;
            } else null;

            try todos.append(.{
                .id = id,
                .description = desc,
                .completed_at = completed_at,
            });

            rc = c.sqlite3_step(prepared);
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }
        _ = c.sqlite3_finalize(prepared);
    }

    fn completeTodo(self: Self, todo: Todo) !void {
        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ update todo set completed_at = unixepoch() where id = ?;
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        _ = c.sqlite3_bind_int64(prepared, 1, todo.id);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) {
            rc = c.sqlite3_step(prepared);
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }
        _ = c.sqlite3_finalize(prepared);
    }

    fn clearTodo(self: Self, todo: Todo) !void {
        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ update todo set completed_at = null where id = ?;
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        _ = c.sqlite3_bind_int64(prepared, 1, todo.id);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) {
            rc = c.sqlite3_step(prepared);
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }

        _ = c.sqlite3_finalize(prepared);
    }

    fn addTodo(self: Self, message: [:0]u8) !void {
        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ insert into todo (description) values (?);
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        _ = c.sqlite3_bind_text(prepared, 1, message, @intCast(message.len), c.SQLITE_STATIC);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) {
            rc = c.sqlite3_step(prepared);
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }

        _ = c.sqlite3_finalize(prepared);
    }

    fn deleteTodo(self: Self, todo: Todo) !void {
        var prepared: ?*c.sqlite3_stmt = undefined;
        const stmt =
            \\ delete from todo where id = ?;
        ;

        _ = c.sqlite3_prepare_v2(self.db, stmt, stmt.len + 1, &prepared, null);
        _ = c.sqlite3_bind_int64(prepared, 1, todo.id);

        var rc = c.sqlite3_step(prepared);

        while (rc == c.SQLITE_ROW) {
            rc = c.sqlite3_step(prepared);
        }

        if (rc != c.SQLITE_DONE) {
            return SqliteError.StepError;
        }

        _ = c.sqlite3_finalize(prepared);
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("sqlite3 version: {s}\n", .{c.sqlite3_version});

    const screenWidth = 1024;
    const screenHight = 768;

    const db = try DB.init(allocator, "todo.db");
    defer db.deinit();

    try db.exec(
        \\ create table if not exists todo (
        \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\   description TEXT NOT NULL,
        \\   completed_at INTEGER,
        \\   created_at INTEGER DEFAULT (unixepoch())
        \\ );
    );

    var todos = std.ArrayList(Todo).init(allocator);
    defer {
        for (todos.items) |item| {
            allocator.free(item.description);
            if (item.completed_at) |comp| allocator.free(comp);
        }
        todos.deinit();
    }

    try db.getTodos(&todos);

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(screenWidth, screenHight, "Hello world!");
    defer c.CloseWindow();

    c.SetTargetFPS(60);

    c.GuiLoadStyleBluish();

    var refresh = false;

    var editMode = false;
    var input: [200:0]u8 = undefined;
    @memset(&input, 0);

    while (!c.WindowShouldClose()) {
        if (refresh) {
            for (todos.items) |item| {
                allocator.free(item.description);
                if (item.completed_at) |comp| allocator.free(comp);
            }
            todos.clearAndFree();

            try db.getTodos(&todos);

            refresh = false;
        }

        c.BeginDrawing();
        defer c.EndDrawing();

        c.ClearBackground(c.RAYWHITE);

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 48);
        _ = c.GuiStatusBar(
            .{ .x = 0, .y = 0, .width = @floatFromInt(c.GetScreenWidth()), .height = 60 },
            "Todo App",
        );

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 24);

        if (c.GuiTextBox(.{ .x = 5, .y = 65, .width = 500, .height = 30 }, &input, 200, editMode) > 0) {
            editMode = !editMode;
        }

        if (c.GuiButton(.{ .x = 510, .y = 65, .width = 60, .height = 30 }, "Add") > 0) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try db.addTodo(msg);
                @memset(&input, 0);
                refresh = true;
            }
        }

        if (!editMode and c.IsKeyPressed(c.KEY_ENTER)) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try db.addTodo(msg);
                @memset(&input, 0);
                refresh = true;
            }
        }

        for (todos.items, 0..) |todo, i| {
            const y: f32 = @floatFromInt(35 * i + 100);
            var checked = todo.completed_at != null;

            if (c.GuiCheckBox(
                .{
                    .x = 5,
                    .y = y,
                    .width = 30,
                    .height = 30,
                },
                @ptrCast(todo.description),
                &checked,
            ) > 0) {
                if (checked) {
                    try db.completeTodo(todo);
                } else {
                    try db.clearTodo(todo);
                }
                refresh = true;
            }

            if (c.GuiButton(.{ .x = 510, .y = y, .width = 30, .height = 30 }, "#143#") > 0) {
                try db.deleteTodo(todo);
                refresh = true;
            }
        }

        c.DrawFPS(0, 0);
    }
}
