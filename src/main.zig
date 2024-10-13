const std = @import("std");
const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
    @cInclude("sqlite3.h");
});

const SqliteError = error{
    DbOpenError,
    StepError,
    ExecError,
};

const DB = struct {
    db: *c.sqlite3,

    fn init(path: [:0]const u8) !@This() {
        var c_db: ?*c.sqlite3 = undefined;

        if (c.SQLITE_OK != c.sqlite3_open(path, &c_db)) {
            std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(c_db)});
            return SqliteError.DbOpenError;
        }
        return .{ .db = c_db.? };
    }

    fn deinit(self: @This()) void {
        _ = c.sqlite3_close(self.db);
    }

    fn exec(self: @This(), query: [:0]const u8) !void {
        var errmsg: [*c]u8 = undefined;

        if (c.SQLITE_OK != c.sqlite3_exec(self.db, query, null, null, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec failed: {s} \n", .{errmsg});
            return SqliteError.ExecError;
        }
    }
};

pub fn main() !void {
    // const allocator = std.heap.c_allocator;
    std.debug.print("sqlite3 version: {s}\n", .{c.sqlite3_version});

    const screenWidth = 1024;
    const screenHight = 768;

    const db = try DB.init("todo.db");
    defer db.deinit();

    try db.exec(
        \\ create table if not exists todo (
        \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\   description TEXT NOT NULL,
        \\   completed_at INTEGER
        \\ );
    );

    var prepared: ?*c.sqlite3_stmt = undefined;
    const stmt =
        \\ select description, datetime(completed_at, 'unixepoch', 'localtime') from todo
    ;

    _ = c.sqlite3_prepare_v2(db.db, stmt, stmt.len + 1, &prepared, null);
    var rc = c.sqlite3_step(prepared);

    while (rc == c.SQLITE_ROW) {
        const completed = c.sqlite3_column_type(prepared, 1) != c.SQLITE_NULL;

        const todo = c.sqlite3_column_text(prepared, 0);

        if (completed) {
            std.debug.print("Todo: {s} completed on {s}\n", .{ todo, c.sqlite3_column_text(prepared, 1) });
        } else {
            std.debug.print("Todo: {s}\n", .{todo});
        }

        rc = c.sqlite3_step(prepared);
    }

    if (rc != c.SQLITE_DONE) {
        return SqliteError.StepError;
    }
    _ = c.sqlite3_finalize(prepared);

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(screenWidth, screenHight, "Hello world!");
    defer c.CloseWindow();

    c.SetTargetFPS(120);
    c.GuiLoadStyle("style_bluish.rgs");

    var showMessageBox = false;

    while (!c.WindowShouldClose()) {
        c.BeginDrawing();
        defer c.EndDrawing();

        c.ClearBackground(c.RAYWHITE);
        c.DrawFPS(0, 0);

        if (c.GuiButton(.{
            .x = 24,
            .y = 24,
            .width = 120,
            .height = 30,
        }, "#191#Show Message") > 0) {
            showMessageBox = true;
        }

        if (showMessageBox) {
            const result = c.GuiMessageBox(
                .{
                    .x = 85,
                    .y = 70,
                    .width = 250,
                    .height = 100,
                },
                "#191#Message Box",
                "Hi! This is a message!",
                "Ok;Cancel",
            );

            if (result >= 0) {
                showMessageBox = false;
            }
        }
    }
}
