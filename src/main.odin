package main

import rl "vendor:raylib"
import "core:slice"
import "core:fmt"
import "core:strings"
import "base:intrinsics"
import "base:runtime"
import "core:math"

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

Entity_Index :: distinct int
entity_view_backing_memory: [ENTITY_CAP]Entity_Index
entity_view := slice.into_dynamic(entity_view_backing_memory[:])

Entity_View :: struct {
    indices: [dynamic]Entity_Index,
    backing_memory: [ENTITY_CAP]Entity_Index,
}

View_Id :: enum {
    bubbles,
    obstacles,
    freelist,
    all,
}

entity_view_init :: proc(view: ^Entity_View) -> Entity_View {
    view.indices = slice.into_dynamic(view.backing_memory[:])
    return view^
}

views := [View_Id]Entity_View{
    .bubbles = entity_view_init(&{}),
    .obstacles = entity_view_init(&{}),
    .freelist = entity_view_init(&{}),
    .all = entity_view_init(&{}),
}

nb_cells_width : f32 = 32
nb_cells_height : f32 = nb_cells_width / f32(16) * f32(9)

cell_size : f32 = auto_cast f32(1.0)/nb_cells_width

// push_entity :: proc(entity: Entity) {
//     id := len(entity_backing_array)
//     append_elem(&entity_backing_array, entity)
//     append_elem(&entity_view, auto_cast id)
// }

push_entity :: proc(entity: Entity, views_to_append: ..^Entity_View) -> Entity_Index {
    index, ok := pop_safe(&views[.freelist].indices)
    append_elem(&views[.all].indices, index)
    if !ok do return Entity_Index(0)
    entity_backing_memory[index] = entity
    
    for view in views_to_append do append_elem(&view.indices, index)
    return index
}

screen_width: f32 = 960
screen_height: f32 = 540
screen_from_world_scalar_: f32
screen_y_margin: f32
dpi: f32 = 1
screen_factors_update_frame_local :: proc() {
    screen_width = cast(f32) rl.GetScreenWidth()
    screen_height = cast(f32) rl.GetScreenHeight()

    dpi = rl.GetWindowScaleDPI().x
    screen_from_world_scalar_ = screen_width / dpi

    playable_area_screen_height := screen_width * world_height
    overheight := screen_height - playable_area_screen_height

    if overheight <= 0 {
        screen_y_margin = 0
        return
    }

    screen_y_margin = overheight / 2 / dpi
}

screen_from_world :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) screen_from_world(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value * screen_from_world_scalar_)
        when intrinsics.type_is_array(T) {
            result.y += screen_y_margin
        }
    }
    return result
}

world_from_screen_position :: #force_inline proc(position: [2]f32) -> [2]f32 {
    return position / screen_from_world_scalar_
}
world_from_screen_rect :: #force_inline proc(rect: rl.Rectangle) -> rl.Rectangle {
    result := transmute([4]f32) rect / screen_from_world_scalar_
    return transmute(rl.Rectangle) result
}

absolute_normalized_rectangle :: proc(r: rl.Rectangle) -> rl.Rectangle {
    ret := rl.Rectangle{
        x = math.min(r.x, r.x + r.width),
        y = math.min(r.y, r.y + r.height),
        width = math.abs(r.width),
        height = math.abs(r.height),
    }
    return ret
}

world_height: f32 : 9.0 / 16.0

main :: proc() {

    for i in 1 ..< ENTITY_CAP do append_elem(&views[.freelist].indices, cast(Entity_Index) i)

    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})

    rl.InitWindow(auto_cast screen_width, auto_cast screen_height, game_name)
    defer rl.CloseWindow()

    rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
    rl.MaximizeWindow()

    bubble_initial_state := Entity{
        x = 0, y = 0,
        width = 0.01, height = 0.01,
        color = .blue,
    }
    push_entity(bubble_initial_state, &views[.bubbles])

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

    push_entity({
        x = 0,
        width = 1,
        y = world_height,
        height = 10,
    })

    for !rl.WindowShouldClose() {
        if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.B) {
            // TODO(felix): cap delta time here
            breakpoint()
        }

        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground(auto_cast colors[.light_grey])

        screen_factors_update_frame_local()

        { // ed
            if rl.IsMouseButtonReleased(.LEFT) {
                // if obstacle_placement_unnormalized_rectangle.width > 0.0 {

                // }

                // obstacle_placement_unnormalized_rectangle := rl.Rectangle{0,0,0,0}
            }
            else if rl.IsMouseButtonPressed(.LEFT) {
                world_mouse_pos := world_from_screen_position(rl.GetMousePosition())
                r := rl.Rectangle{
                    x = world_mouse_pos.x,
                    y = world_mouse_pos.y,
                    width = cell_size,
                    height = cell_size,
                }
                // world_from_screen_rect(r)
                obstacle_entity := Entity{
                    x = r.x,
                    y = r.y,
                    width = r.width,
                    height = r.height,
                    color = .black,
                }
                push_entity(obstacle_entity, &views[.obstacles])
            }
        }

        for entity_id in views[.all].indices { // draw all entities
            entity := &entity_backing_memory[entity_id]

            rl.DrawRectangleRec(screen_from_world(entity.rect), auto_cast colors[entity.color])
        }

        text := fmt.tprint(len(entity_view), "bonjour")
        draw_text(text, { 0.1, 0.3 }, 0.05)

        draw_grid(cell_size)

        boundary_color := rl.Color{ 255, 0, 0, 255 }
        thickness_world :: 0.01
        thickness := screen_from_world(cast(f32) thickness_world)

        top_boundary_start := screen_from_world([2]f32{ 0, -thickness_world })
        top_boundary_end := screen_from_world([2]f32{ 1, -thickness_world })
        rl.DrawLineEx(top_boundary_start, top_boundary_end, thickness * 2, boundary_color)

        bottom_boundary_start := screen_from_world([2]f32{ 0, world_height + thickness_world })
        bottom_boundary_end := screen_from_world([2]f32{ 1, world_height + thickness_world })
        rl.DrawLineEx(bottom_boundary_start, bottom_boundary_end, thickness * 2, boundary_color)
    }
}

draw_grid :: proc(cell_size: f32, color: Color = .black) {
    tint := colors[color]
    for x : f32 = 0.0; x < 1.0; x += cell_size {
        screen_start_pos := screen_from_world([2]f32{ x, 0 })
        screen_end_pos := screen_from_world([2]f32{ x, 1 })
        rl.DrawLineEx(screen_start_pos, screen_end_pos, 1, auto_cast tint)

    }
    for y: f32 = 0.0; y < 16/9; y += cell_size {
        screen_start_pos := screen_from_world([2]f32{ 0, y })
        screen_end_pos := screen_from_world([2]f32{ 1, y })
        rl.DrawLineEx(screen_start_pos, screen_end_pos, 1, auto_cast tint)
    }
}

draw_text :: proc(text_string: string, position_world: [2]f32, font_size_world: f32, color: Color = .black, rotation: f32 = 0, spacing: f32 = 1) {
    temp := runtime.default_temp_allocator_temp_begin()
    defer runtime.default_temp_allocator_temp_end(temp)

    font := rl.GetFontDefault()
    text := strings.clone_to_cstring(text_string, context.temp_allocator)
    position := screen_from_world(position_world)
    origin := [2]f32{}
    font_size := screen_from_world(font_size_world)
    tint := colors[color]
    rl.DrawTextPro(font, text, position, origin, rotation, font_size, spacing, auto_cast tint)
}
