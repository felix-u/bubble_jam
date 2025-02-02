package game

import rl "vendor:raylib"
import "core:slice"
import "base:intrinsics"
import "core:math"
import "core:mem"
import la "core:math/linalg"
import "core:fmt"
import "core:encoding/json"
import "core:c"

breakpoint :: intrinsics.debug_trap

game_name :: "bubble"

Color :: enum { black, blue, dark_blue, purple, red, white, light_grey, green, orange, gold }
colors := [Color][4]u8{
    .black = { 0, 0, 0, 255 },
    .blue = { 0, 0, 255, 255 },
    .dark_blue = { 0, 50, 150, 255 },
    .purple = { 100, 0, 255, 255 },
    .red = { 255, 0, 0, 255 },
    .light_grey = { 200, 200, 200, 255 },
    .green = { 0, 200, 0, 255 },
    .gold = { 255, 215, 0, 255 },
    .white = { 255, 255, 255, 255 },
    .orange = { 0, 120, 170, 255 },
}

Entity :: struct {
    using rect: rl.Rectangle,
    velocity: [2]f32,
    accel: [2]f32,
    color: Color,
    pop_anim_timer: f32,
    pop_anim_time_amount: f32,
}

ENTITY_CAP :: 256
entity_backing_memory: [ENTITY_CAP]Entity

Entity_Index :: distinct int
entity_view_backing_memory: [ENTITY_CAP]Entity_Index
entity_view := slice.into_dynamic(entity_view_backing_memory[:])

Entity_View :: struct {
    indices: [dynamic]Entity_Index,
    backing_memory: [ENTITY_CAP]Entity_Index,
}

View_Id :: enum {
    freelist,
    active,
    bubbles,
    popping_bubbles,
    growers,
    splitters,
    obstacles,
    guns,
    end_goals,
    end_goals_completed,
}

Level :: struct {
    name: cstring,
    gun_initial_position: [2]f32,
    gun_id: Entity_Index,
    obstacles: [dynamic]Entity,
    end_goals: [dynamic]Entity,
    bubbles: [dynamic]Entity,
    hint: cstring,
}

current_level_index := 0
NUM_LEVELS :: 9

gun_width :: 0.02
gun_initial_state :: Entity{
    // NOTE(felix): position is set per-level
    width = gun_width, height = gun_width,
    color = .purple,
}

levels : [NUM_LEVELS]Level


level_data_filename := "assets/data.json"

write_levels_to_json_file :: proc() {
    json_opts := json.Marshal_Options{pretty=true,}
    json_data, err := json.marshal(levels, opt = json_opts, allocator = context.temp_allocator)
    if err != nil {
        fmt.eprintf("error marshalling json: %v\n", err)
        return
    }
    file_name := level_data_filename
    ok := write_entire_file(file_name, json_data)
    if !ok {
        fmt.eprintf("error writing to file: %v\n", file_name)
        return
    }
}

read_levels_from_json_file :: proc() {
    file_name := level_data_filename
    json_data, ok := read_entire_file(file_name)
    if !ok {
        fmt.eprintf("error reading from file: %v\n", file_name)
        return
    }
    err := json.unmarshal(json_data, &levels)
    if err != nil {
        fmt.eprintf("error unmarshalling json: %v\n", err)
        return
    }
}



reset_entities_from_level :: proc() {
    for view_id in View_Id {
        non_zero_resize(&views[view_id].indices, 0)
    }

    for i in 1 ..< ENTITY_CAP do append_elem(&views[.freelist].indices, cast(Entity_Index) i)

    level := &levels[current_level_index]

    for entity in level.obstacles {
        push_entity(entity, .obstacles)
    }
    for entity in level.end_goals {
        push_entity(entity, .end_goals)
    }
    for entity in level.bubbles {
        push_entity(entity, .bubbles)
    }

    gun := gun_initial_state
    gun.x = level.gun_initial_position.x
    gun.y = level.gun_initial_position.y

    level.gun_id = push_entity(gun, .guns)
}

Entity_Edit_Mode :: enum {
    none,
    bubble,
    obstacle,
    end_goal,
}
current_entity_edit_mode : Entity_Edit_Mode
entity_edit_mode_keypress_map := [Entity_Edit_Mode]rl.KeyboardKey {
    .bubble   = .B,
    .obstacle = .O,
    .end_goal = .G,
    .none     = .N,
}
entity_edit_mode_name_map := [Entity_Edit_Mode]cstring {
    .bubble   = "edit bubble mode",
    .obstacle = "edit obstacle mode",
    .end_goal = "edit end goal mode",
    .none     = "",
}

entity_view_init :: proc(view: ^Entity_View) -> Entity_View {
    view.indices = slice.into_dynamic(view.backing_memory[:])
    return view^
}

views := [View_Id]Entity_View{
    .bubbles = entity_view_init(&{}),
    .popping_bubbles = entity_view_init(&{}),
    .growers = entity_view_init(&{}),
    .splitters = entity_view_init(&{}),
    .obstacles = entity_view_init(&{}),
    .freelist = entity_view_init(&{}),
    .end_goals = entity_view_init(&{}),
    .end_goals_completed = entity_view_init(&{}),
    .guns = entity_view_init(&{}),
    .active = entity_view_init(&{}),
}

nb_cells_width : f32 = 64
nb_cells_height : f32 = nb_cells_width / f32(16) * f32(9)

cell_size : f32 = auto_cast f32(1.0)/nb_cells_width

push_entity :: proc(entity: Entity, views_to_append: ..View_Id) -> Entity_Index {
    index, ok := pop_safe(&views[.freelist].indices)
    append_elem(&views[.active].indices, index)
    assert(ok)
    entity_backing_memory[index] = entity

    for id in views_to_append do append_elem(&views[id].indices, index)
    return index
}

remove_entity :: proc(entity_id: Entity_Index, view_ids: ..View_Id, free: bool = true) {
    if free {
        append_elem(&views[.freelist].indices, entity_id)
        index, found := slice.linear_search(views[.active].indices[:], entity_id)
        assert(found)
        unordered_remove(&views[.active].indices, index)
    }

    for view_id in view_ids {
        view := &views[view_id]
        index, _ := slice.linear_search(view.indices[:], entity_id)
        unordered_remove(&view.indices, index)
    }
}

screen_size := [2]f32{ 1200, 675 }
screen_from_world_scalar: f32
screen_margin_y: f32
dpi: f32 = 1
delta_time: f32
screen_factors_update_frame_local :: proc() {
    screen_size.x = cast(f32) rl.GetScreenWidth()
    screen_size.y = cast(f32) rl.GetScreenHeight()
    dpi = rl.GetWindowScaleDPI().x
    delta_time = rl.GetFrameTime()

    screen_from_world_scalar = screen_size.x / dpi

    height_over_width := screen_size.y / screen_size.x
    screen_taller_than_world := height_over_width > world_height

    if screen_taller_than_world {
        playable_area_screen_height := screen_size.x * world_height
        overheight := screen_size.y - playable_area_screen_height
        screen_margin_y = overheight / 2 / dpi
    } else do screen_margin_y = 0
}

screen_from_world :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) screen_from_world(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value * screen_from_world_scalar)
        when intrinsics.type_is_array(T) {
            result.y += screen_margin_y
        }
    }
    return result
}

world_from_screen :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) world_from_screen(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value / screen_from_world_scalar)
        when intrinsics.type_is_array(T) {
            result.y -= world_from_screen(screen_margin_y)
        }
    }
    return result;
}

placement_unnormalized_rectangle := rl.Rectangle{0,0,0,0}
absolute_normalized_rectangle :: proc(r: rl.Rectangle) -> rl.Rectangle {
    ret := rl.Rectangle{
        x = math.min(r.x, r.x + r.width),
        y = math.min(r.y, r.y + r.height),
        width = math.abs(r.width),
        height = math.abs(r.height),
    }
    return ret
}

bubble_placement_circle := [3]f32{0,0,0}

world_height: f32 : 9.0 / 16.0

snap_rectangle_to_grid :: proc(r: rl.Rectangle) -> rl.Rectangle {
    ret := rl.Rectangle{
        x = math.floor(r.x / cell_size) * cell_size,
        y = math.floor(r.y / cell_size) * cell_size,
        width = math.ceil(r.width / cell_size) * cell_size,
        height = math.ceil(r.height / cell_size) * cell_size,
    }
    return ret
}

save_screen_flash_time_amount : f32 = 0.5
save_screen_flash_timer := f32(0)

create_pop_ripple_from_circle :: proc(pos: [2]f32, radius: f32, color: Color) {
    new_popping_bubble := Entity{
        x = pos.x,
        y = pos.y,
        width = radius,
        color = color,
    }
    new_popping_bubble.pop_anim_time_amount = 0.25
    new_popping_bubble.pop_anim_timer = new_popping_bubble.pop_anim_time_amount
    push_entity(new_popping_bubble, .popping_bubbles)
    new_popping_bubble.width /= 2
    new_popping_bubble.pop_anim_time_amount = 0.22
    new_popping_bubble.pop_anim_timer = new_popping_bubble.pop_anim_time_amount
    push_entity(new_popping_bubble, .popping_bubbles)
    new_popping_bubble.width = 0.0001
    new_popping_bubble.pop_anim_time_amount = 0.19
    new_popping_bubble.pop_anim_timer = new_popping_bubble.pop_anim_time_amount
    push_entity(new_popping_bubble, .popping_bubbles)

    reset_and_play_sfx(pop_sfx)
}

editor_handle_input_for_placement_rectangle_and_rectangular_entity_creation  :: proc(view_id: View_Id, world_mouse_pos: [2]f32, color_for_creation: Color = .black)
{
    if rl.IsMouseButtonReleased(.LEFT) && placement_unnormalized_rectangle.width != 0 && placement_unnormalized_rectangle.height != 0 {
        using normalized_rectangle_to_place := absolute_normalized_rectangle(placement_unnormalized_rectangle)

        clamp_low :: max
        width = clamp_low(width, cell_size)
        height = clamp_low(height, cell_size)

        snap_adjusted_normalized_rectangle_to_place := snap_rectangle_to_grid(normalized_rectangle_to_place)
        entity := Entity{
            rect = snap_adjusted_normalized_rectangle_to_place,
            color = color_for_creation,
        }
        push_entity(entity, view_id)
        placement_unnormalized_rectangle = rl.Rectangle{0,0,0,0}
    }
    else if rl.IsMouseButtonPressed(.LEFT) {
        using placement_unnormalized_rectangle
        x = world_mouse_pos.x
        y = world_mouse_pos.y
    } else if rl.IsMouseButtonDown(.LEFT) {
        using placement_unnormalized_rectangle
        if x != 0 && y != 0 {
            width = world_mouse_pos.x - x
            height = world_mouse_pos.y - y
        }
    }
    else if rl.IsMouseButtonPressed(.RIGHT) {
        for entity_id in views[view_id].indices {
            entity := entity_backing_memory[entity_id]
            did_mouse_rectangle_intersect := rl.CheckCollisionPointRec(world_mouse_pos, entity.rect)

            if did_mouse_rectangle_intersect {
                remove_entity(entity_id, view_id)
            }
        }
    }
}

level_transition_state: struct {
    active: bool,
    using non_text_related: struct {
        old_level_index, new_level_index: int,
        curtain: rl.Rectangle,
        curtain_color: Color,
        render_curtain: bool,
    },
    text: cstring,
    opacity: int,
    text_fading: enum { in_, out },
    text_still_fading: bool,
}

begin_transition_to_level :: proc(new_level_index: int) {
    assert(new_level_index < NUM_LEVELS)

    level_transition_state = {
        active = true,
        old_level_index = current_level_index,
        new_level_index = new_level_index,
        curtain = { x = -1, width = 1, height = world_height },
        render_curtain = true,
    }

    using level_transition_state
    retrying_same_level := new_level_index == current_level_index

    curtain_color = .red if retrying_same_level else .blue
    text = "again!" if retrying_same_level else levels[new_level_index].name
}

pop_sfx : rl.Sound
grow_sfx : rl.Sound
end_goal_hit_sfx : rl.Sound
switch_sides_sfx : rl.Sound



reset_and_play_sfx :: proc(sfx: rl.Sound) {
    rl.StopSound(sfx)
    rl.PlaySound(sfx)
}

run := true
track: mem.Tracking_Allocator
temp_track: mem.Tracking_Allocator

target_fps: c.int

init :: proc() {

    when ODIN_DEBUG { 	// memory leak tracking
		mem.tracking_allocator_init(&track, context.allocator)
		mem.tracking_allocator_init(&temp_track, context.temp_allocator)
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
	}
    for i in 1 ..< ENTITY_CAP do append_elem(&views[.freelist].indices, cast(Entity_Index) i)

    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})

    rl.InitAudioDevice()

    pop_sfx = rl.LoadSound("assets/pop-sfx.wav")
    grow_sfx = rl.LoadSound("assets/grow-sfx.wav")
    end_goal_hit_sfx = rl.LoadSound("assets/end-goal-hit-sfx.wav")
    switch_sides_sfx = rl.LoadSound("assets/switch-sides-sfx.wav")
    rl.SetSoundVolume(switch_sides_sfx, 0.6)
    rl.SetSoundPitch(switch_sides_sfx, 0.8)
    rl.SetSoundVolume(grow_sfx, 0.6)
    rl.SetSoundPitch(grow_sfx, 1.8)
    rl.SetSoundVolume(end_goal_hit_sfx, 0.5)
    rl.SetSoundPitch(end_goal_hit_sfx, 1.8)

    rl.SetSoundVolume(pop_sfx, 1)

    rl.InitWindow(auto_cast screen_size.x, auto_cast screen_size.y, game_name)

    target_fps = rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
    target_fps = math.min(target_fps, 144) // I had a bug on my monitor which is a very high refresh rate of 240. 144 Hz is pretty standard high, so we just set it to that.
    rl.SetTargetFPS(target_fps)
    rl.MaximizeWindow()
    rl.RestoreWindow()

    read_levels_from_json_file()
    reset_entities_from_level()
}

parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(c.int(w), c.int(h))
}

update :: proc() {
    if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.B) {
        delta_time = 1 / cast(f32) target_fps
        breakpoint()
    }
    if rl.IsKeyPressed(.F11) {
        rl.ToggleFullscreen()
    }

    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(auto_cast colors[.light_grey])

    if save_screen_flash_timer > 0 {
        save_screen_flash_timer -= delta_time
        rl.ClearBackground(auto_cast colors[.green])
    }

    screen_factors_update_frame_local()
    mouse_pos := rl.GetMousePosition()
    world_mouse_pos := world_from_screen(mouse_pos)

    { // ed
        switch current_entity_edit_mode {
        case .bubble:
        {
            if rl.IsMouseButtonPressed(.LEFT) {
                bubble_placement_circle = [3]f32{world_mouse_pos.x, world_mouse_pos.y, 0}
            }
            if rl.IsMouseButtonReleased(.LEFT) {
                new_bubble_entity := Entity {
                    x = bubble_placement_circle[0],
                    y = bubble_placement_circle[1],
                    width = bubble_placement_circle[2],
                    color = .blue,
                }
                push_entity(new_bubble_entity, .bubbles)
                bubble_placement_circle = [3]f32{0,0,0}
            }
            if rl.IsMouseButtonDown(.LEFT) {
                snap_to_vertical_center := rl.IsKeyDown(.C)
                if snap_to_vertical_center {
                    bubble_placement_circle.y = world_height / 2
                }

                snap_to_horizontal_center := rl.IsKeyDown(.Y)
                if snap_to_horizontal_center do bubble_placement_circle.x = 0.5

                vector_from_center_to_mouse := [2]f32{world_mouse_pos.x - bubble_placement_circle[0], world_mouse_pos.y - bubble_placement_circle[1]}
                length := la.length(vector_from_center_to_mouse)
                bubble_placement_circle[2] = length
            }
            if rl.IsMouseButtonPressed(.RIGHT) {
                for bubble_id in views[.bubbles].indices {
                    bubble := entity_backing_memory[bubble_id]
                    did_mouse_circle_intersect := rl.CheckCollisionPointCircle(world_mouse_pos, [2]f32{bubble.x, bubble.y}, bubble.width)
                    if did_mouse_circle_intersect {
                        remove_entity(bubble_id, .bubbles)
                    }
                }
            }
        }
        case .obstacle: editor_handle_input_for_placement_rectangle_and_rectangular_entity_creation(.obstacles, world_mouse_pos)
        case .end_goal: editor_handle_input_for_placement_rectangle_and_rectangular_entity_creation(.end_goals, world_mouse_pos, .green)
        case .none: {}
        }

        if rl.IsKeyPressed(.F8) { // save to levels
            level := &levels[current_level_index]

            non_zero_resize(&level.bubbles, 0)
            non_zero_resize(&level.obstacles, 0)
            non_zero_resize(&level.end_goals, 0)

            gun_rect := entity_backing_memory[level.gun_id].rect
            level.gun_initial_position = { gun_rect.x, gun_rect.y }

            for entity_id in views[.bubbles].indices {
                entity := entity_backing_memory[entity_id]
                append_elem(&level.bubbles, entity)
            }
            for entity_id in views[.obstacles].indices {
                entity := entity_backing_memory[entity_id]
                append_elem(&level.obstacles, entity)
            }
            for entity_id in views[.end_goals].indices {
                entity := entity_backing_memory[entity_id]
                append_elem(&level.end_goals, entity)
            }
            save_screen_flash_timer = save_screen_flash_time_amount

            write_levels_to_json_file()
        }

        if rl.IsKeyPressed(.F9) { // reset current level
            reset_entities_from_level()
        }

        level_select: { // level switching
            level_number := 0
            for digit in 1..=9 {
                if !rl.IsKeyPressed(auto_cast ('0' + digit)) do continue
                level_number = digit
                break
            }
            if level_number == 0 do break level_select
            assert(level_number <= NUM_LEVELS)

            selected_level_index := level_number - 1
            begin_transition_to_level(selected_level_index)
        }

        for edit_mode in Entity_Edit_Mode { // change edit mode
            if rl.IsKeyPressed(entity_edit_mode_keypress_map[edit_mode]) {
                current_entity_edit_mode = edit_mode
            }
        }
    }

    level := &levels[current_level_index]
    gun := &entity_backing_memory[level.gun_id]

    gun_move_speed_factor :: 0.7
    gun_move_speed := delta_time * gun_move_speed_factor

    max_x :: proc(entity: ^Entity) -> f32 { return 1 - entity.width }
    max_y :: proc(entity: ^Entity) -> f32 { return world_height - entity.height }

    gun_on_horizontal_edge := gun.y == 0 || gun.y == max_y(gun)
    if gun_on_horizontal_edge {
        if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do gun.x -= gun_move_speed
        if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do gun.x += gun_move_speed

        turning_corner := gun.x <= 0 || max_x(gun) <= gun.x
        if turning_corner {
            if gun.y == 0 do gun.y += gun_move_speed
            else do gun.y -= gun_move_speed
        }
    }

    gun_on_vertical_edge := !gun_on_horizontal_edge
    gun_on_vertical_edge &&= gun.x == 0 || gun.x == max_x(gun)
    if gun_on_vertical_edge {
        if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do gun.y -= gun_move_speed
        if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) do gun.y += gun_move_speed

        turning_corner := gun.y <= 0 || max_y(gun) <= gun.y
        if turning_corner {
            if gun.x == 0 do gun.x += gun_move_speed
            else do gun.x -= gun_move_speed
        }
    }

    if rl.IsKeyPressed(.SPACE) {
        if gun_on_horizontal_edge {
            if gun.y == 0 do gun.y = max_y(gun)
            else if gun.y == max_y(gun) do gun.y = 0
        } else if gun_on_vertical_edge {
            if gun.x == 0 do gun.x = max_x(gun)
            else if gun.x == max_x(gun) do gun.x = 0
        }

        reset_and_play_sfx(switch_sides_sfx)

        create_pop_ripple_from_circle([2]f32{gun.x, gun.y}, gun.width, gun.color)
    }

    snap_to_edge_center := rl.IsKeyPressed(.C) && !rl.IsMouseButtonDown(.LEFT)
    if snap_to_edge_center {
        if gun_on_horizontal_edge do gun.x = 0.5 - gun.width / 2
        else do gun.y = (world_height - gun.height) / 2
    }

    gun.x = clamp(gun.x, 0, max_x(gun))
    gun.y = clamp(gun.y, 0, max_y(gun))

    shoot_grower := !rl.IsKeyDown(.LEFT_SHIFT) && rl.IsMouseButtonPressed(.LEFT) && current_entity_edit_mode == .none
    shoot_splitter := !rl.IsKeyDown(.LEFT_SHIFT) && rl.IsMouseButtonPressed(.RIGHT) && current_entity_edit_mode == .none
    shoot_bullet := shoot_grower || shoot_splitter
    if shoot_bullet {
        gun_center := [2]f32{ gun.x + gun.width / 2, gun.y + gun.height / 2 }

        bullet_radius :: 0.005
        bullet := Entity{
            x = gun_center.x - bullet_radius,
            y = gun_center.y - bullet_radius,
            width = bullet_radius * 2,
            height = bullet_radius * 2,
            color = .blue if shoot_grower else .red,
        }

        target := world_mouse_pos - [2]f32{ bullet.width, bullet.height } / 2

        bullet.velocity = { target.x - bullet.x, target.y - bullet.y }
        bullet.velocity = la.normalize(bullet.velocity)
        bullet_speed :: 1.3
        bullet.velocity *= bullet_speed

        view_id: View_Id = .growers if shoot_grower else .splitters
        push_entity(bullet, view_id)
    }

    bubbles: for entity_id in views[.bubbles].indices { // update bubbles
        using entity := &entity_backing_memory[entity_id]

        for splitter_id in views[.splitters].indices {
            splitter := &entity_backing_memory[splitter_id]

            screen_bubble_pos := screen_from_world([2]f32{ entity.x, entity.y })
            screen_bubble_radius := screen_from_world(entity.width)
            screen_splitter_rectangle := screen_from_world(splitter.rect)
            intersect := rl.CheckCollisionCircleRec(screen_bubble_pos, screen_bubble_radius, screen_splitter_rectangle)

            if !intersect do continue

            new_popping_bubble := entity^
            create_pop_ripple_from_circle([2]f32{new_popping_bubble.x, new_popping_bubble.y}, new_popping_bubble.width, new_popping_bubble.color)

            vector := la.normalize(splitter.velocity)
            velocity_factor :: 0.1
            new_velocity := vector * velocity_factor
            first_bubble_velocity_rotated_90_degrees := rl.Vector2Rotate(new_velocity, math.to_radians_f32(45))
            second_bubble_velocity_rotated_90_degrees := rl.Vector2Rotate(new_velocity, math.to_radians_f32(-45))
            entity.width /= 2

            entity.velocity = first_bubble_velocity_rotated_90_degrees

            new_bubble := Entity{
                x = entity.x,
                y = entity.y,
                width = entity.width,
                color = entity.color,
                velocity = second_bubble_velocity_rotated_90_degrees,
            }
            push_entity(new_bubble, .bubbles)

            remove_entity(splitter_id, .splitters)

            continue bubbles
        }

        for grower_id in views[.growers].indices {
            grower := &entity_backing_memory[grower_id]
            screen_bubble_pos := screen_from_world([2]f32{ entity.x, entity.y })
            screen_bubble_radius := screen_from_world(entity.width)
            screen_grower_rectangle := screen_from_world(grower.rect)
            intersect := rl.CheckCollisionCircleRec(screen_bubble_pos, screen_bubble_radius, screen_grower_rectangle)

            if !intersect do continue

            vector := la.normalize(grower.velocity)
            velocity_factor :: 0.1
            entity.velocity = vector * velocity_factor
            entity.width *= 1.05

            reset_and_play_sfx(grow_sfx)

            remove_entity(grower_id, .growers)
        }

        colliding_screen_edge_horizontal := x - width <= 0 || 1 <= x + width
        colliding_screen_edge_vertical := y - width <= 0 || world_height <= y + width
        if colliding_screen_edge_horizontal || colliding_screen_edge_vertical {
            new_popping_bubble := entity^
            create_pop_ripple_from_circle([2]f32{new_popping_bubble.x, new_popping_bubble.y}, new_popping_bubble.width, new_popping_bubble.color)
            remove_entity(entity_id, .bubbles, free = true)
            continue bubbles
        }
    }

    for entity_id in views[.active].indices { // move
        entity := &entity_backing_memory[entity_id]
        entity.x += entity.velocity.x * delta_time
        entity.y += entity.velocity.y * delta_time
    }

    bubble_to_small_amount : f32 = 0.003
    for bubble_id in views[.bubbles].indices { // "pop" bubbles if they touch an obstacle or get too small
        entity := &entity_backing_memory[bubble_id]
        if entity.width < bubble_to_small_amount { // too small
            new_popping_bubble := entity^
            create_pop_ripple_from_circle([2]f32{new_popping_bubble.x, new_popping_bubble.y}, new_popping_bubble.width, new_popping_bubble.color)

            remove_entity(bubble_id, .bubbles, free = false)

            continue
        }
        for obstacle_id in views[.obstacles].indices { // touches obstacle
            obstacle := entity_backing_memory[obstacle_id]

            screen_bubble_pos := screen_from_world([2]f32{ entity.x, entity.y })
            screen_bubble_radius := screen_from_world(entity.width)
            screen_obstacle_rectangle := screen_from_world(obstacle.rect)

            did_bubble_collide_with_obstacle := rl.CheckCollisionCircleRec([2]f32{screen_bubble_pos.x, screen_bubble_pos.y}, screen_bubble_radius, screen_obstacle_rectangle)
            if did_bubble_collide_with_obstacle {
                new_popping_bubble := entity^
                create_pop_ripple_from_circle([2]f32{new_popping_bubble.x, new_popping_bubble.y}, new_popping_bubble.width, new_popping_bubble.color)

                remove_entity(bubble_id, .bubbles, free = true)

                entity.pop_anim_time_amount = 0.25
                entity.pop_anim_timer = entity.pop_anim_time_amount
                break
            }
        }
        for end_goal_index in views[.end_goals].indices { // touches end goal
            end_goal_entity := &entity_backing_memory[end_goal_index]
            screen_bubble_pos := screen_from_world([2]f32{ entity.x, entity.y })
            screen_bubble_radius := screen_from_world(entity.width)
            screen_end_goal_rectangle := screen_from_world(end_goal_entity.rect)

            did_bubble_collide_with_end_goal := rl.CheckCollisionCircleRec([2]f32{screen_bubble_pos.x, screen_bubble_pos.y}, screen_bubble_radius, screen_end_goal_rectangle)
            if did_bubble_collide_with_end_goal {
                remove_entity(bubble_id, .bubbles, free = false)

                entity.pop_anim_time_amount = 0.25
                entity.pop_anim_timer = entity.pop_anim_time_amount
                append_elem(&views[.popping_bubbles].indices, bubble_id)

                remove_entity(end_goal_index, .end_goals, free = false)

                end_goal_entity.color = .gold
                append_elem(&views[.end_goals_completed].indices, end_goal_index)

                reset_and_play_sfx(end_goal_hit_sfx)
                break
            }
        }
    }

    for entity_id in views[.popping_bubbles].indices { // popping bubbles update
        entity := &entity_backing_memory[entity_id]
        entity.pop_anim_timer -= delta_time
        entity.width += delta_time * 0.5
        if entity.pop_anim_timer <= 0 {
            remove_entity(entity_id, .popping_bubbles)
        }
    }

    projectile_views :: [?]View_Id{ .splitters, .growers }
    for view_id in projectile_views {
        view := &views[view_id]
        for entity_id in view.indices {
            using entity := &entity_backing_memory[entity_id]
            offscreen := x + width <= 0 || 1 <= x
            offscreen ||= y + height <= 0 || world_height <= y
            if offscreen {
                remove_entity(entity_id, view_id, free = false)
                remove_entity(entity_id)
            }
        }
    }


    draw_grid(cell_size)


    for entity_id in views[.popping_bubbles].indices { // draw popping bubbles
        // will be drawn as circle lines instead of solid
        bubble := &entity_backing_memory[entity_id]
        screen_pos := screen_from_world([2]f32{ bubble.x, bubble.y })
        screen_radius := screen_from_world(bubble.width)
        rl.DrawCircleLinesV(screen_pos, screen_radius, auto_cast colors[bubble.color])
    }


    for entity_id in views[.active].indices { // draw all entities
        entity := entity_backing_memory[entity_id]
        rl.DrawRectangleRec(screen_from_world(entity.rect), auto_cast colors[entity.color])
    }

    for entity_id in views[.bubbles].indices { // draw all bubbles
        bubble := &entity_backing_memory[entity_id]
        screen_pos := screen_from_world([2]f32{ bubble.x, bubble.y })
        screen_radius := screen_from_world(bubble.width)
        color := bubble.color
        if bubble.width <= bubble_to_small_amount * 2 do color = .orange
        rl.DrawCircleV(screen_pos, screen_radius, auto_cast colors[color])
    }

    { // draw ed stuff
        obstacle_placement_rectangle := absolute_normalized_rectangle(placement_unnormalized_rectangle)
        rl.DrawRectangleRec(screen_from_world(obstacle_placement_rectangle), auto_cast colors[.black])

        edit_mode_text := entity_edit_mode_name_map[current_entity_edit_mode]
        draw_text(edit_mode_text, [2]f32{0.01, 0.01}, 0.02, .black)

        screen_bubble_placement_circle := screen_from_world(bubble_placement_circle)
        transparent_blue := rl.Color{ 0, 0, 255, 100 }
        rl.DrawCircle(i32(screen_bubble_placement_circle.x), i32(screen_bubble_placement_circle.y), screen_bubble_placement_circle.z, auto_cast transparent_blue)
    }

    won := len(views[.end_goals].indices) == 0
    won &&= !level_transition_state.active
    won &&= current_entity_edit_mode == .none
    if won {
        new_level_index := (current_level_index + 1) % NUM_LEVELS
        begin_transition_to_level(new_level_index)
    }

    lost := !won && len(views[.bubbles].indices) == 0
    lost &&= !level_transition_state.active
    lost &&= current_entity_edit_mode == .none

    voluntary_quick_redo := rl.IsKeyPressed(.R)
    redo := lost || voluntary_quick_redo

    if redo {
        begin_transition_to_level(current_level_index)
    }


    hint_font_size: f32 = 0.03
    padding := [2]f32{ hint_font_size * 0.75, hint_font_size * 1.5 }
    draw_text(level.hint, { padding.x, world_height - padding.y }, hint_font_size)

    { // draw debug visualizer
        // draw small circle where mouse is being held down with left click
        if rl.IsMouseButtonDown(.LEFT) {
            screen_pos := screen_from_world([2]f32{ world_mouse_pos.x, world_mouse_pos.y })
            rl.DrawCircleV(screen_pos, 20, auto_cast colors[.red])
            rl.DrawCircleV(screen_pos, 5, auto_cast colors[.white])
        }
    }


    level_transition_animation: {
        using level_transition_state

        level_transition_speed :: 2
        text_fade_amount :: level_transition_speed

        handle_curtain: if active {
            text_still_fading = true

            old_curtain_x := curtain.x
            if (curtain.x >= 1) {
                level_transition_state.non_text_related = {}
                break handle_curtain
            }

            curtain.x += level_transition_speed * delta_time

            if old_curtain_x < 0 && 0 <= curtain.x {
                current_level_index = new_level_index
                reset_entities_from_level()
            }
        }

        if render_curtain {
            rl.DrawRectangleRec(screen_from_world(curtain), auto_cast colors[curtain_color])
        }

        if text_still_fading {
            opacity += text_fade_amount * 4 if text_fading == .in_ else -text_fade_amount
            opacity = clamp(0, opacity, 255)

            font_size :: 50
            text_width_screen := cast(f32) rl.MeasureText(text, font_size)
            pad: f32 : 0.05
            text_position := [2]f32{
                screen_from_world(pad),
                screen_from_world(world_height - pad) - font_size
            }
            rectangle_color := colors[.white]
            rectangle_color.a = auto_cast opacity

            text_color := colors[.dark_blue]
            text_color.a = rectangle_color.a
            rl.DrawRectangleRec({ x = text_position.x - screen_from_world(pad / 2), y = text_position.y, width = text_width_screen + screen_from_world(pad / 2), height = font_size }, auto_cast rectangle_color)
            rl.DrawTextEx(rl.GetFontDefault(), text, text_position, font_size, 1, auto_cast text_color)

            if text_fading == .in_ && opacity == 255 do text_fading = .out
            else if text_fading == .out && opacity == 0 {
                text_still_fading = false
                active = false
            }
        }
    }

    boundary_color := rl.Color{ 180, 180, 180, 255 }

    thickness_world :: world_height * 2
    thickness := screen_from_world(cast(f32) thickness_world)

    top_boundary_start := screen_from_world([2]f32{ 0, -thickness_world })
    top_boundary_end := screen_from_world([2]f32{ 1, -thickness_world })
    rl.DrawLineEx(top_boundary_start, top_boundary_end, thickness * 2, boundary_color)

    bottom_boundary_start := screen_from_world([2]f32{ 0, world_height + thickness_world })
    bottom_boundary_end := screen_from_world([2]f32{ 1, world_height + thickness_world })
    rl.DrawLineEx(bottom_boundary_start, bottom_boundary_end, thickness * 2, boundary_color)
}


shutdown :: proc() {
    when ODIN_DEBUG {
        if len(track.bad_free_array) > 0 {
            for entry in track.bad_free_array {
                fmt.eprintf(
                    "%v bad free at %v\n",
                    entry.location,
                    entry.memory,
                )
            }
        }
        if len(temp_track.allocation_map) > 0 {
            for _, entry in temp_track.allocation_map {
                fmt.eprintf(
                    "temp_allocator %v leaked %v bytes\n",
                    entry.location,
                    entry.size,
                )
            }
        }
        if len(temp_track.bad_free_array) > 0 {
            for entry in temp_track.bad_free_array {
                fmt.eprintf(
                    "temp_allocator %v bad free at %v\n",
                    entry.location,
                    entry.memory,
                )
            }
        }
        mem.tracking_allocator_destroy(&track)
        mem.tracking_allocator_destroy(&temp_track)
    }
    rl.CloseAudioDevice()
	rl.CloseWindow()
}


should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// Never run this proc in browser. It contains a 16 ms sleep on web!
		if rl.WindowShouldClose() {
			run = false
		}
	}

	return run
}

main :: proc() {
    init()
    for !rl.WindowShouldClose() do update()
    shutdown()
}

draw_grid :: proc(cell_size: f32, color: Color = .black) {
    tint := rl.Color{0,0,0,10}
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

draw_text :: proc(text: cstring, position_world: [2]f32, font_size_world: f32, color: Color = .black, rotation: f32 = 0, spacing: f32 = 1) {
    font := rl.GetFontDefault()
    position := screen_from_world(position_world)
    origin := [2]f32{}
    font_size := screen_from_world(font_size_world)
    tint := colors[color]
    rl.DrawTextPro(font, text, position, origin, rotation, font_size, spacing, auto_cast tint)
}
