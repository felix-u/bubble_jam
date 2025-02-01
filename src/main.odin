package main

import rl "vendor:raylib"

game_name :: "bubble"

main :: proc() {
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})

    rl.InitWindow(960, 540, game_name)
    defer rl.CloseWindow()

    rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
    rl.MaximizeWindow()

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground({150, 150, 150, 255})

        rl.DrawText("bonjour", 300, 300, 40, {0, 0, 0, 255})
    }
}
