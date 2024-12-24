const std = @import("std");
const config = @import("config");
const c = @cImport({
    if (config.debug) {
        @cInclude("sqlite3.h");
    }
    @cInclude("raylib.h");
    @cInclude("raygui.h");

    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("bluish/style_bluish.h");
});
const root = @import("root.zig");

const ROW_WIDTH = 545;

const DB = root.DB;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    if (config.debug) {
        std.debug.print("sqlite3 version: {s}\n", .{c.sqlite3_version});
    }

    const screenWidth = 800;
    const screenHeight = 600;

    var db = DB.init("todo.db");
    try db.connect();
    defer db.deinit();

    var todo_manager = root.TodoManager.init(allocator, db);
    defer todo_manager.deinit();

    try todo_manager.migrate();

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(screenWidth, screenHeight, "Todo App");
    defer c.CloseWindow();

    c.SetTargetFPS(60);

    c.GuiLoadStyleBluish();

    var refresh = true;

    var edit_mode = false;
    var input: [200:0]u8 = undefined;
    @memset(&input, 0);

    var priority_active: c_int = 0;
    var priority_edit = false;

    var curr_screen_width: f32 = undefined;
    var curr_screen_height: f32 = undefined;
    var panel_scroll: c.Vector2 = undefined;
    var panel_view: c.Rectangle = undefined;
    var panel_rec: c.Rectangle = undefined;
    var panel_content_rec: c.Rectangle = undefined;

    var mx: c_int = undefined;
    var my: c_int = undefined;

    while (!c.WindowShouldClose()) {
        if (refresh) {
            todo_manager.clearTodos();
            _ = try todo_manager.getTodos();
            refresh = false;
        }

        if (c.IsFileDropped()) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const dropped_files = c.LoadDroppedFiles();
            defer c.UnloadDroppedFiles(dropped_files);

            for (dropped_files.paths[0..dropped_files.count]) |file_path| {
                const file = try std.fs.openFileAbsolute(std.mem.span(file_path), .{});
                defer file.close();

                var buf_reader = std.io.bufferedReader(file.reader());
                const reader = buf_reader.reader();

                var lines = std.ArrayList([:0]u8).init(alloc);

                while (try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 1024)) |line| {
                    const trimmed = std.mem.trim(u8, line, " \n");
                    if (trimmed.len == 0) {
                        continue;
                    }
                    try lines.append(try alloc.dupeZ(u8, trimmed));
                }

                if (lines.items.len > 0) {
                    try todo_manager.addTodos(lines.items);
                    refresh = true;
                }
            }
        }

        curr_screen_width = @floatFromInt(c.GetScreenWidth());
        curr_screen_height = @floatFromInt(c.GetScreenHeight());

        panel_rec = .{ .x = 0, .y = 100, .width = curr_screen_width, .height = curr_screen_height - 100 };
        panel_content_rec = .{
            .x = 0,
            .y = 0,
            .width = @max(ROW_WIDTH, curr_screen_width - @as(f32, @floatFromInt(c.GuiGetStyle(c.LISTVIEW, c.SCROLLBAR_WIDTH))) - 5),
            .height = @as(f32, @floatFromInt(todo_manager.todos.items.len * 35)) + 5,
        };

        mx = c.GetMouseX();
        my = c.GetMouseY();

        // Drawing

        c.BeginDrawing();
        defer c.EndDrawing();

        c.ClearBackground(c.RAYWHITE);

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 48);
        _ = c.GuiStatusBar(
            .{ .x = 0, .y = 0, .width = curr_screen_width, .height = 60 },
            "Todo App",
        );

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 24);

        if (c.GuiTextBox(.{ .x = 5, .y = 65, .width = 435, .height = 30 }, &input, 200, edit_mode) > 0) {
            edit_mode = !edit_mode;
        }

        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_RIGHT) and (mx >= 5 and mx <= 440) and (my >= 65 and my <= 95)) {
            const paste = std.mem.span(c.GetClipboardText());

            std.mem.copyForwards(u8, &input, paste[0..@min(paste.len, 200)]);
            edit_mode = true;
        }

        if (c.GuiButton(.{ .x = 510, .y = 65, .width = 60, .height = 30 }, "Add") > 0) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try todo_manager.addTodo(msg, priority_active);
                @memset(&input, 0);
                refresh = true;
                priority_active = 0;
                edit_mode = true;
            }
        }

        if (c.IsKeyPressed(c.KEY_ENTER)) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try todo_manager.addTodo(msg, priority_active);
                @memset(&input, 0);
                refresh = true;
                priority_active = 0;
                edit_mode = true;
            }
        }

        _ = c.GuiScrollPanel(panel_rec, null, panel_content_rec, &panel_scroll, &panel_view);

        {
            c.BeginScissorMode(@intFromFloat(panel_view.x), @intFromFloat(panel_view.y), @intFromFloat(panel_view.width), @intFromFloat(panel_view.height));
            defer c.EndScissorMode();

            for (todo_manager.todos.items, 0..) |todo, i| {
                const x = 5 + panel_rec.x + panel_scroll.x;
                const y = @as(f32, @floatFromInt(35 * i)) + panel_rec.y + panel_scroll.y + 5;

                // don't render extra rows
                if (y > curr_screen_height or y < 65) {
                    continue;
                }

                var checked = todo.completed_at != null;

                if (c.GuiCheckBox(
                    .{ .x = x, .y = y, .width = 30, .height = 30 },
                    @ptrCast(todo.description),
                    &checked,
                ) > 0) {
                    if (checked) {
                        try todo_manager.completeTodo(todo);
                    } else {
                        try todo_manager.uncompleteTodo(todo);
                    }
                    refresh = true;
                }

                const priority_label = try allocator.allocSentinel(u8, @intCast(todo.priority + 1), 0);
                defer allocator.free(priority_label);
                @memset(priority_label, '!');

                if (c.GuiButton(.{ .x = x + 440, .y = y, .width = 60, .height = 30 }, priority_label) > 0) {
                    try todo_manager.updatePriority(todo, todo.priority + 1);
                    refresh = true;
                }

                if (c.GuiButton(.{ .x = x + 505, .y = y, .width = 30, .height = 30 }, "#143#") > 0) {
                    try todo_manager.deleteTodo(todo);
                    refresh = true;
                }
            }
        }

        if (c.GuiDropdownBox(
            .{ .x = 445, .y = 65, .width = 60, .height = 30 },
            "!;!!;!!!",
            &priority_active,
            priority_edit,
        ) > 0) {
            priority_edit = !priority_edit;
        }

        if (config.debug) {
            c.DrawFPS(0, 0);
        }
    }
}
