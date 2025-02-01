package main

import rl "vendor:raylib"
import "core:slice"
import "core:fmt"
import "core:strings"
import "base:intrinsics"
import "base:runtime"

breakpoint :: intrinsics.debug_trap

game_name :: "bubble"

Color :: enum { black, blue, light_grey }
colors := [Color][4]u8{
    .black = { 0, 0, 0, 255 },
    .blue = { 0, 0, 255, 255 },
    .light_grey = { 200, 200, 200, 255 },
}

Entity :: struct {
    using rect: rl.Rectangle,
    velocity: [2]f32,
    accel: [2]f32,
    color: Color,
}

ENTITY_CAP :: 64
entity_backing_memory: [ENTITY_CAP]Entity
entity_backing_array := slice.into_dynamic(entity_backing_memory[:])

Entity_Index :: distinct int
entity_view_backing_memory: [ENTITY_CAP]Entity_Index
entity_view := slice.into_dynamic(entity_view_backing_memory[:])

push_entity :: proc(entity: Entity) {
    id := len(entity_backing_array)
    append_elem(&entity_backing_array, entity)
    append_elem(&entity_view, auto_cast id)
}

screen_width: f32 = 960
screen_from_world_scalar: f32
screen_width_update_frame_local :: proc() {
    screen_width = cast(f32) rl.GetScreenWidth()
    screen_from_world_scalar = screen_width / rl.GetWindowScaleDPI().x
}

screen_from_world_rect :: #force_inline proc(rect: rl.Rectangle) -> rl.Rectangle {
    result := transmute([4]f32) rect * screen_from_world_scalar
    return transmute(rl.Rectangle) result
}

main :: proc() {
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})

    rl.InitWindow(auto_cast screen_width, 540, game_name)
    defer rl.CloseWindow()

    rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
    rl.MaximizeWindow()

    bubble_initial_state := Entity{
        x = 0, y = 0,
        width = 0.01, height = 0.01,
        color = .blue,
    }
    push_entity(bubble_initial_state)

    ratios := [?]f32{ 0.1, 0.25, 0.5, 0.8, 0.9, 0.99, 1 }
    height :: 0.01
    position: f32 = height * 2
    for ratio in ratios {
        entity := Entity{
            x = 0,
            y = position,
            width = ratio,
            height = height,
            color = .blue,
        }
        push_entity(entity)

        position += height * 2
    }

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground(auto_cast colors[.light_grey])

        screen_width_update_frame_local()

        for entity_id in entity_view {
            entity := &entity_backing_array[entity_id]

            rl.DrawRectangleRec(screen_from_world_rect(entity.rect), auto_cast colors[entity.color])
        }

        text := fmt.tprint(len(entity_view), "bonjour")
        draw_text(text, { 0.1, 0.3 }, 0.05)
    }
}

draw_text :: proc(text_string: string, position_normalised: [2]f32, font_size_normalised: f32, color: Color = .black, origin_normalised: [2]f32 = {}, rotation: f32 = 0, spacing: f32 = 1) {
    temp := runtime.default_temp_allocator_temp_begin()
    defer runtime.default_temp_allocator_temp_end(temp)

    font := rl.GetFontDefault()
    text := strings.clone_to_cstring(text_string, context.temp_allocator)
    position := position_normalised * screen_from_world_scalar
    origin := origin_normalised * screen_from_world_scalar
    font_size := font_size_normalised * screen_from_world_scalar
    tint := colors[color]
    rl.DrawTextPro(font, text, position, origin, rotation, font_size, spacing, auto_cast tint)
}
