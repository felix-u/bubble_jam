package main

import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "base:intrinsics"
import "base:runtime"
import "core:math"

breakpoint :: intrinsics.debug_trap

game_name :: "bubble"

Color :: enum { black, blue, purple, light_grey }
colors := [Color][4]u8{
    .black = { 0, 0, 0, 255 },
    .blue = { 0, 0, 255, 255 },
    .purple = { 100, 0, 255, 255 },
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
    guns,
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
    .guns = entity_view_init(&{}),
    .all = entity_view_init(&{}),
}

nb_cells_width : f32 = 64
nb_cells_height : f32 = nb_cells_width / f32(16) * f32(9)

cell_size : f32 = auto_cast f32(1.0)/nb_cells_width

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
delta_time: f32
screen_factors_update_frame_local :: proc() {
    screen_width = cast(f32) rl.GetScreenWidth()
    screen_height = cast(f32) rl.GetScreenHeight()
    dpi = rl.GetWindowScaleDPI().x
    delta_time = rl.GetFrameTime()

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

world_from_screen :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) world_from_screen(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value / screen_from_world_scalar_)
        when intrinsics.type_is_array(T) {
            result.y -= world_from_screen(screen_y_margin)
        }
    }
    return result;
}

obstacle_placement_unnormalized_rectangle := rl.Rectangle{0,0,0,0}
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

    gun_width :: 0.03
    gun_initial_state :: Entity{
        x = 0.5 - gun_width / 2,
        y = 0,
        width = gun_width,
        height = 0.01,
        color = .purple,
    }
    gun_id := push_entity(gun_initial_state, &views[.guns])

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
                obstacle_rectangle := absolute_normalized_rectangle(obstacle_placement_unnormalized_rectangle)
                if obstacle_rectangle.width < cell_size {
                    obstacle_rectangle.width = cell_size
                }
                if obstacle_rectangle.height < cell_size {
                    obstacle_rectangle.height = cell_size
                }
                snap_adjusted_obstacle_rectangle := rl.Rectangle{
                    x = math.floor(obstacle_rectangle.x / cell_size) * cell_size,
                    y = math.floor(obstacle_rectangle.y / cell_size) * cell_size,
                    width = math.round(obstacle_rectangle.width / cell_size) * cell_size,
                    height = math.round(obstacle_rectangle.height / cell_size) * cell_size,
                }
                obstacle_entity := Entity{
                    x = snap_adjusted_obstacle_rectangle.x,
                    y = snap_adjusted_obstacle_rectangle.y,
                    width = snap_adjusted_obstacle_rectangle.width,
                    height = snap_adjusted_obstacle_rectangle.height,
                    color = .black,
                }
                push_entity(obstacle_entity, &views[.obstacles])
                obstacle_placement_unnormalized_rectangle = rl.Rectangle{0,0,0,0}
            }
            else if rl.IsMouseButtonPressed(.LEFT) {
                world_mouse_pos := world_from_screen(rl.GetMousePosition())
                obstacle_placement_unnormalized_rectangle.x = world_mouse_pos.x
                obstacle_placement_unnormalized_rectangle.y = world_mouse_pos.y
            }
            else if rl.IsMouseButtonDown(.LEFT) {
                world_mouse_pos := world_from_screen(rl.GetMousePosition())
                obstacle_placement_unnormalized_rectangle.width = world_mouse_pos.x - obstacle_placement_unnormalized_rectangle.x
                obstacle_placement_unnormalized_rectangle.height = world_mouse_pos.y - obstacle_placement_unnormalized_rectangle.y
            }
            else if rl.IsMouseButtonPressed(.RIGHT) {
                // delete any colliding obstacles
                world_mouse_pos := world_from_screen(rl.GetMousePosition())
                for entity_id in views[.obstacles].indices {
                    entity := entity_backing_memory[entity_id]
                    did_mouse_rectangle_intersect := rl.CheckCollisionPointRec(world_mouse_pos, entity.rect)
                    if did_mouse_rectangle_intersect {
                        append_elem(&views[.freelist].indices, entity_id)
                        index, found := slice.linear_search(views[.obstacles].indices[:], entity_id)
                        if found {
                            unordered_remove(&views[.obstacles].indices, index)
                        }
                        index, found = slice.linear_search(views[.all].indices[:], entity_id)
                        if found {
                            unordered_remove(&views[.all].indices, index)
                        }
                    }
                }
            }
        }

        gun := &entity_backing_memory[gun_id]
        gun_move_speed_factor :: 0.7
        gun_move_speed := delta_time * gun_move_speed_factor

        gun_max_x := 1 - gun.width
        gun_max_y := world_height - gun.height
        if gun.y == 0 || gun.y == gun_max_y {
            if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) {
                gun.x -= gun_move_speed
                turning_corner := gun.x <= 0
                if turning_corner {
                    gun.x = 0
                    if gun.y == 0 do gun.y += gun_move_speed
                    else do gun.y -= gun_move_speed
                }
            }

            if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) {
                gun.x += gun_move_speed
                turning_corner := gun.x >= gun_max_x
                if turning_corner {
                    gun.x = gun_max_x
                    if gun.y == 0 do gun.y += gun_move_speed
                    else do gun.y -= gun_move_speed
                }
            }
        }

        if gun.x == 0 || gun.x == gun_max_x {
            if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) {
                gun.y -= gun_move_speed
                turning_corner := gun.y <= 0
                if turning_corner {
                    gun.y = 0
                    if gun.x == 0 do gun.x += gun_move_speed
                    else do gun.x -= gun_move_speed
                }
            }

            if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) {
                gun.y += gun_move_speed
                turning_corner := gun.y >= gun_max_y
                if turning_corner {
                    gun.y = gun_max_y
                    if gun.x == 0 do gun.x += gun_move_speed
                    else do gun.x -= gun_move_speed
                }
            }
        }

        for entity_id in views[.all].indices { // draw all entities
            entity := entity_backing_memory[entity_id]
            rl.DrawRectangleRec(screen_from_world(entity.rect), auto_cast colors[entity.color])
        }

        { // draw placement rectangle
            obstacle_placement_rectangle := absolute_normalized_rectangle(obstacle_placement_unnormalized_rectangle)
            rl.DrawRectangleRec(screen_from_world(obstacle_placement_rectangle), auto_cast colors[.black])
        }

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
