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

const ROW_WIDTH = 545;

const DB = root.DB;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("sqlite3 version: {s}\n", .{c.sqlite3_version});

    const screenWidth = 800;
    const screenHeight = 600;

    var db = try DB.init("todo.db");
    defer db.deinit();

    var todo_manager = root.TodoManager.init(allocator, db);
    defer todo_manager.deinit();

    try todo_manager.migrate();

    _ = try todo_manager.getTodos();

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_VSYNC_HINT);
    c.InitWindow(screenWidth, screenHeight, "Todo App");
    defer c.CloseWindow();

    c.SetTargetFPS(60);

    c.GuiLoadStyleBluish();

    var refresh = false;

    var editMode = false;
    var input: [200:0]u8 = undefined;
    @memset(&input, 0);

    var priorityActive: c_int = 0;
    var priorityEdit = false;

    var currScreenWidth: f32 = undefined;
    var currScreenHeight: f32 = undefined;
    var panelScroll: c.Vector2 = undefined;
    var panelView: c.Rectangle = undefined;
    var panelRec: c.Rectangle = undefined;
    var panelContentRec: c.Rectangle = undefined;

    while (!c.WindowShouldClose()) {
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

        if (refresh) {
            todo_manager.clearTodos();
            _ = try todo_manager.getTodos();
            refresh = false;
        }

        currScreenWidth = @floatFromInt(c.GetScreenWidth());
        currScreenHeight = @floatFromInt(c.GetScreenHeight());

        panelRec = .{ .x = 0, .y = 100, .width = currScreenWidth, .height = currScreenHeight - 100 };
        panelContentRec = .{
            .x = 0,
            .y = 0,
            .width = @max(ROW_WIDTH, currScreenWidth - @as(f32, @floatFromInt(c.GuiGetStyle(c.LISTVIEW, c.SCROLLBAR_WIDTH))) - 5),
            .height = @as(f32, @floatFromInt(todo_manager.todos.items.len * 35)) + 5,
        };

        // Drawing

        c.BeginDrawing();
        defer c.EndDrawing();

        c.ClearBackground(c.RAYWHITE);

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 48);
        _ = c.GuiStatusBar(
            .{ .x = 0, .y = 0, .width = currScreenWidth, .height = 60 },
            "Todo App",
        );

        c.GuiSetStyle(c.DEFAULT, c.TEXT_SIZE, 24);
        if (c.GuiTextBox(.{ .x = 5, .y = 65, .width = 435, .height = 30 }, &input, 200, editMode) > 0) {
            editMode = !editMode;
        }

        if (c.GuiButton(.{ .x = 510, .y = 65, .width = 60, .height = 30 }, "Add") > 0) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try todo_manager.addTodo(msg, priorityActive);
                @memset(&input, 0);
                refresh = true;
                priorityActive = 0;
                editMode = true;
            }
        }

        if (c.IsKeyPressed(c.KEY_ENTER)) {
            const msg = std.mem.sliceTo(&input, 0);
            if (msg.len > 0) {
                try todo_manager.addTodo(msg, priorityActive);
                @memset(&input, 0);
                refresh = true;
                priorityActive = 0;
                editMode = true;
            }
        }

        _ = c.GuiScrollPanel(panelRec, null, panelContentRec, &panelScroll, &panelView);

        {
            c.BeginScissorMode(@intFromFloat(panelView.x), @intFromFloat(panelView.y), @intFromFloat(panelView.width), @intFromFloat(panelView.height));
            defer c.EndScissorMode();

            for (todo_manager.todos.items, 0..) |todo, i| {
                const x = 5 + panelRec.x + panelScroll.x;
                const y = @as(f32, @floatFromInt(35 * i)) + panelRec.y + panelScroll.y + 5;

                // don't render extra rows
                if (y > currScreenHeight or y < 65) {
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

                for (0..priority_label.len) |j| {
                    priority_label[j] = '!';
                }
                priority_label[priority_label.len] = 0;

                c.GuiSetStyle(c.LABEL, c.TEXT_ALIGNMENT, c.TEXT_ALIGN_CENTER);
                _ = c.GuiLabel(.{ .x = x + 440, .y = y, .width = 60, .height = 30 }, priority_label);

                if (c.GuiButton(.{ .x = x + 505, .y = y, .width = 30, .height = 30 }, "#143#") > 0) {
                    try todo_manager.deleteTodo(todo);
                    refresh = true;
                }
            }
        }

        if (c.GuiDropdownBox(
            .{ .x = 445, .y = 65, .width = 60, .height = 30 },
            "!;!!;!!!",
            &priorityActive,
            priorityEdit,
        ) > 0) {
            priorityEdit = !priorityEdit;
        }

        c.DrawFPS(0, 0);
    }
}
