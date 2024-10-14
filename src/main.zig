const std = @import("std");
const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
    @cInclude("sqlite3.h");

    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("bluish/style_bluish.h");
});
const root = @import("root.zig");

const DB = root.DB;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("sqlite3 version: {s}\n", .{c.sqlite3_version});

    const screenWidth = 800;
    const screenHight = 600;

    var db = try DB.init(allocator, "todo.db");
    defer db.deinit();

    try db.migrate();

    _ = try db.getTodos();

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
        if (c.IsFileDropped()) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const dropped_files = c.LoadDroppedFiles();
            defer c.UnloadDroppedFiles(dropped_files);

            for (dropped_files.paths[0..dropped_files.count]) |file_path| {
                const file = try std.fs.openFileAbsolute(std.mem.sliceTo(file_path, 0), .{});
                defer file.close();

                var buf_reader = std.io.bufferedReader(file.reader());
                const reader = buf_reader.reader();

                var lines = std.ArrayList([:0]u8).init(alloc);

                while (try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 200)) |line| {
                    const trimmed = std.mem.trim(u8, line, " \n");
                    if (trimmed.len == 0) {
                        continue;
                    }
                    try lines.append(try alloc.dupeZ(u8, line));
                }

                try db.addTodos(lines.items);
            }

            refresh = true;
        }

        if (refresh) {
            db.clearTodos();
            _ = try db.getTodos();
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

        if (c.IsKeyPressed(c.KEY_ENTER)) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try db.addTodo(msg);
                @memset(&input, 0);
                refresh = true;
                editMode = true;
            }
        }

        for (db.todos.items, 0..) |todo, i| {
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
                    try db.uncompleteTodo(todo);
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
