package main

import rl "vendor:raylib"
import "core:slice"
import "base:intrinsics"
import "core:math"
import "core:mem"
import la "core:math/linalg"
import "core:fmt"

breakpoint :: intrinsics.debug_trap

game_name :: "bubble"

Color :: enum { black, blue, purple, red, white, light_grey, green, gold }
colors := [Color][4]u8{
    .black = { 0, 0, 0, 255 },
    .blue = { 0, 0, 255, 255 },
    .purple = { 100, 0, 255, 255 },
    .red = { 255, 0, 0, 255 },
    .light_grey = { 200, 200, 200, 255 },
    .green = { 0, 200, 0, 255 },
    .gold = { 255, 215, 0, 255 },
    .white = { 255, 255, 255, 255 },
}

Entity :: struct {
    using rect: rl.Rectangle,
    velocity: [2]f32,
    accel: [2]f32,
    color: Color,
    pop_anim_timer: f32,
    pop_anim_time_amount: f32,
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
    name: string,
    entities: map[View_Id][dynamic]Entity
}

curr_level_index := 0
NUM_LEVELS :: 2

levels_init :: proc() -> [NUM_LEVELS]Level {
    levels := [NUM_LEVELS]Level{
        {
            name = "level 1",
            entities = map[View_Id][dynamic]Entity{
                .bubbles = [dynamic]Entity{
                    Entity{
                        x = 0.5,
                        y = 0.1,
                        width = 0.05,
                        color = .red,
                    },
                },
                .obstacles = [dynamic]Entity{
                    Entity{
                        x = 0.3,
                        y = 0.3,
                        width = 0.1,
                        height = 0.1,
                        color = .black,
                    },
                },
                .end_goals = [dynamic]Entity{
                    Entity{
                        x = 0.7,
                        y = 0.1,
                        width = 0.1,
                        height = 0.1,
                        color = .green,
                    },
                    Entity{
                        x = 0.7,
                        y = 0.3,
                        width = 0.1,
                        height = 0.1,
                        color = .green,
                    }
                },
            },
        },
        {
            name = "level 2",
            entities = map[View_Id][dynamic]Entity{
                .bubbles = [dynamic]Entity{
                    Entity{
                        x = 0.2,
                        y = 0.3,
                        width = 0.05,
                        color = .red,
                    },
                },
                .obstacles = [dynamic]Entity{
                    Entity{
                        x = 0.3,
                        y = 0.3,
                        width = 0.1,
                        height = 0.1,
                        color = .black,
                    },
                },
                .end_goals = [dynamic]Entity{
                    Entity{
                        x = 0.7,
                        y = 0.1,
                        width = 0.1,
                        height = 0.1,
                        color = .green,
                    },
                },
            },
        },

    }
    return levels
}
levels := levels_init()



reset_entities_from_level :: proc() {
    for view_id in View_Id {
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
        non_zero_resize(&views[view_id].indices, 0)
    }

    for i in 1 ..< ENTITY_CAP do append_elem(&views[.freelist].indices, cast(Entity_Index) i)

    for view_id, entities in levels[curr_level_index].entities {
        for entity in entities {
            push_entity(entity, view_id)
        }
    }
}

Entity_Edit_Mode :: enum {
    bubble,
    obstacle,
    end_goal,
    none,
}
current_entity_edit_mode : Entity_Edit_Mode = .bubble
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
    .none     = "no edit mode",
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
        index, found := slice.linear_search(view.indices[:], entity_id)
        assert(found)
        unordered_remove(&view.indices, index)
    }
}

screen_size := [2]f32{ 960, 540 }
screen_from_world_scalar: f32
screen_margin: [2]f32
dpi: f32 = 1
delta_time: f32
screen_taller_than_world, screen_wider_than_world: bool
screen_factors_update_frame_local :: proc() {
    screen_size.x = cast(f32) rl.GetScreenWidth()
    screen_size.y = cast(f32) rl.GetScreenHeight()
    dpi = rl.GetWindowScaleDPI().x
    delta_time = rl.GetFrameTime()

    height_over_width := screen_size.y / screen_size.x
    screen_taller_than_world = height_over_width > world_height
    screen_wider_than_world = !screen_taller_than_world

    if screen_taller_than_world {
        screen_from_world_scalar = screen_size.x / dpi
        screen_margin.x = 0

        playable_area_screen_height := screen_size.x * world_height
        overheight := screen_size.y - playable_area_screen_height
        screen_margin.y = overheight / 2 / dpi
    } else {
        screen_from_world_scalar = screen_size.x / dpi
        screen_margin.y = 0

        playable_area_screen_width := screen_size.y / world_height
        overwidth := screen_size.x - playable_area_screen_width
        screen_margin.x = overwidth / 2 / dpi
    }
}

screen_from_world :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) screen_from_world(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value * screen_from_world_scalar)
        when intrinsics.type_is_array(T) {
            result.x += screen_margin.x
            result.y += screen_margin.y
        } else do result += screen_margin.x
    }
    return result
}

world_from_screen :: #force_inline proc(value: $T) -> T {
    when T == rl.Rectangle {
        result := transmute(T) world_from_screen(transmute([4]f32) value)
    } else {
        result: T = auto_cast (auto_cast value / screen_from_world_scalar)
        when intrinsics.type_is_array(T) {
            result.y -= world_from_screen(screen_margin.y)
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

main :: proc() {
    when ODIN_DEBUG { 	// memory leak tracking
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		temp_track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&temp_track, context.temp_allocator)
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)

		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					fmt.eprintf(
						"%v leaked %v bytes\n",
						entry.location,
						entry.size,
					)
				}
			}
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
	}

    for i in 1 ..< ENTITY_CAP do append_elem(&views[.freelist].indices, cast(Entity_Index) i)

    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})

    rl.InitWindow(auto_cast screen_size.x, auto_cast screen_size.y, game_name)
    defer rl.CloseWindow()

    target_fps := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
    rl.SetTargetFPS(target_fps)
    rl.MaximizeWindow()

    gun_width :: 0.02
    gun_initial_state :: Entity{
        x = 0.5 - gun_width / 2,
        y = 0,
        width = gun_width,
        height = gun_width,
        color = .purple,
    }
    gun_id := push_entity(gun_initial_state, .guns)

    initial_bubble_radius :: 0.05
    bubble_initial_state := Entity{
        x = 0.5,
        y = 0.3,
        width = initial_bubble_radius,
        color = .blue,
    }
    push_entity(bubble_initial_state, .bubbles)

    for !rl.WindowShouldClose() {
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
            case .obstacle:
            {
                if rl.IsMouseButtonReleased(.LEFT) && obstacle_placement_unnormalized_rectangle.width != 0 && obstacle_placement_unnormalized_rectangle.height != 0 {

                    obstacle_rectangle := absolute_normalized_rectangle(obstacle_placement_unnormalized_rectangle)
                    if obstacle_rectangle.width < cell_size {
                        obstacle_rectangle.width = cell_size
                    }
                    if obstacle_rectangle.height < cell_size {
                        obstacle_rectangle.height = cell_size
                    }
                    snap_adjusted_obstacle_rectangle := snap_rectangle_to_grid(obstacle_rectangle)
                    obstacle_entity := Entity{
                        x = snap_adjusted_obstacle_rectangle.x,
                        y = snap_adjusted_obstacle_rectangle.y,
                        width = snap_adjusted_obstacle_rectangle.width,
                        height = snap_adjusted_obstacle_rectangle.height,
                        color = .black,
                    }
                    push_entity(obstacle_entity, .obstacles)
                    obstacle_placement_unnormalized_rectangle = rl.Rectangle{0,0,0,0}
                }
                else if rl.IsMouseButtonPressed(.LEFT) {
                    using obstacle_placement_unnormalized_rectangle
                    x = world_mouse_pos.x
                    y = world_mouse_pos.y

                } else if rl.IsMouseButtonDown(.LEFT) {
                    using obstacle_placement_unnormalized_rectangle
                    if x != 0 && y != 0 {
                        width = world_mouse_pos.x - x
                        height = world_mouse_pos.y - y
                    }
                }
                else if rl.IsMouseButtonPressed(.RIGHT) {
                    // delete any colliding obstacles
                    for entity_id in views[.obstacles].indices {
                        entity := entity_backing_memory[entity_id]
                        did_mouse_rectangle_intersect := rl.CheckCollisionPointRec(world_mouse_pos, entity.rect)

                        if did_mouse_rectangle_intersect {
                            remove_entity(entity_id, .obstacles)
                        }
                    }
                }
            }
            case .end_goal:
            {
                if rl.IsMouseButtonPressed(.LEFT) {
                    end_goal_rectangle := rl.Rectangle{
                        x = world_mouse_pos.x,
                        y = world_mouse_pos.y,
                        width = cell_size,
                        height = cell_size,
                    }

                    snap_adjusted_end_goal_rectangle := rl.Rectangle{
                        x = math.floor(end_goal_rectangle.x / cell_size) * cell_size,
                        y = math.floor(end_goal_rectangle.y / cell_size) * cell_size,
                        width = math.round(end_goal_rectangle.width / cell_size) * cell_size,
                        height = math.round(end_goal_rectangle.height / cell_size) * cell_size,
                    }
                    end_goal_entity := Entity{
                        rect = snap_adjusted_end_goal_rectangle,
                        color = .green,
                    }
                    push_entity(end_goal_entity, .end_goals)
                }
            }
            case .none: {}
            }

            if rl.IsKeyPressed(.F8) { // save to levels
                for view_id, &entity_dynamic_array in levels[curr_level_index].entities {
                    non_zero_resize(&entity_dynamic_array, 0)
                    for entity_id in views[view_id].indices {
                        entity := entity_backing_memory[entity_id]
                        append_elem(&entity_dynamic_array, entity)
                    }
                }
                save_screen_flash_timer = save_screen_flash_time_amount
            }

            if rl.IsKeyPressed(.F9) { // reset current level
                reset_entities_from_level()
            }


            { // level switching
                input_level_one_requested := rl.IsKeyPressed(.ONE)
                input_level_two_requested := rl.IsKeyPressed(.TWO)

                if input_level_one_requested {
                    curr_level_index = 0
                    reset_entities_from_level()
                }
                if input_level_two_requested {
                    curr_level_index = 1
                    reset_entities_from_level()
                }
            }

            for edit_mode in Entity_Edit_Mode { // change edit mode
                if rl.IsKeyPressed(entity_edit_mode_keypress_map[edit_mode]) {
                    current_entity_edit_mode = edit_mode
                }
            }
        }

        gun := &entity_backing_memory[gun_id]

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

        gun.x = clamp(gun.x, 0, max_x(gun))
        gun.y = clamp(gun.y, 0, max_y(gun))

        shoot_grower := !rl.IsKeyDown(.LEFT_SHIFT) && rl.IsMouseButtonPressed(.LEFT) && current_entity_edit_mode == .none
        shoot_splitter := !rl.IsKeyDown(.LEFT_SHIFT) && rl.IsMouseButtonPressed(.RIGHT) && current_entity_edit_mode == .none
        shoot_bullet := shoot_grower || shoot_splitter
        if shoot_bullet {
            target := world_mouse_pos
            gun_center := [2]f32{ gun.x + gun.width / 2, gun.y + gun.height / 2 }

            bullet_radius :: 0.01
            bullet := Entity{
                x = gun_center.x - bullet_radius,
                y = gun_center.y - bullet_radius,
                width = bullet_radius * 2,
                height = bullet_radius * 2,
                color = .blue if shoot_grower else .red,
            }
            bullet.velocity = { target.x - bullet.x, target.y - bullet.y }
            bullet.velocity = la.normalize(bullet.velocity)
            bullet_speed :: 0.5
            bullet.velocity *= bullet_speed

            view_id: View_Id = .growers if shoot_grower else .splitters
            push_entity(bullet, view_id)
        }

        bubbles: for entity_id in views[.bubbles].indices { // update bubbles
            using entity := &entity_backing_memory[entity_id]

            for splitter_id in views[.splitters].indices {
                splitter := &entity_backing_memory[splitter_id]

                intersect := rl.CheckCollisionCircleRec({ x, y }, width, splitter.rect)

                if !intersect do continue

                vector := la.normalize(splitter.velocity)
                velocity_factor :: 0.1
                new_velocity := vector * velocity_factor
                first_bubble_velocity_rotated_90_degrees := rl.Vector2Rotate(new_velocity, 0.6)
                second_bubble_velocity_rotate_90_degrees := rl.Vector2Rotate(new_velocity, -0.6)
                entity.width /= 2
                entity.velocity = first_bubble_velocity_rotated_90_degrees

                new_bubble := Entity{
                    x = entity.x,
                    y = entity.y,
                    width = entity.width,
                    color = entity.color,
                    velocity = second_bubble_velocity_rotate_90_degrees,
                }
                push_entity(new_bubble, .bubbles)

                remove_entity(splitter_id, .splitters)

                continue bubbles
            }

            for grower_id in views[.growers].indices {
                grower := &entity_backing_memory[grower_id]

                intersect := rl.CheckCollisionCircleRec({ x, y }, width, grower.rect)

                if !intersect do continue

                vector := la.normalize(grower.velocity)
                velocity_factor :: 0.1
                entity.velocity = vector * velocity_factor
                entity.width *= 1.05

                remove_entity(grower_id, .growers)
            }

            colliding_screen_edge_horizontal := x - width <= 0 || 1 <= x + width
            colliding_screen_edge_vertical := y - width <= 0 || world_height <= y + width
            if colliding_screen_edge_horizontal || colliding_screen_edge_vertical {
                remove_entity(entity_id, .bubbles, free = false)

                pop_anim_time_amount = 0.25
                pop_anim_timer = pop_anim_time_amount

                append_elem(&views[.popping_bubbles].indices, entity_id)
                continue bubbles
            }
        }

        for entity_id in views[.active].indices { // move
            entity := &entity_backing_memory[entity_id]
            entity.x += entity.velocity.x * delta_time
            entity.y += entity.velocity.y * delta_time
        }

        for bubble_id in views[.bubbles].indices { // "pop" bubbles if they touch an obstacle or get too small
            entity := &entity_backing_memory[bubble_id]
            if entity.width < 0.003 { // too small
                remove_entity(bubble_id, .bubbles, free = false)

                entity.pop_anim_time_amount = 0.25
                entity.pop_anim_timer = entity.pop_anim_time_amount

                append_elem(&views[.popping_bubbles].indices, bubble_id)
                continue
            }
            for obstacle_id in views[.obstacles].indices { // touches obstacle
                obstacle := entity_backing_memory[obstacle_id]

                screen_bubble_pos := screen_from_world([2]f32{ entity.x, entity.y })
                screen_bubble_radius := screen_from_world(entity.width)
                screen_obstacle_rectangle := screen_from_world(obstacle.rect)

                did_bubble_collide_with_obstacle := rl.CheckCollisionCircleRec([2]f32{screen_bubble_pos.x, screen_bubble_pos.y}, screen_bubble_radius, screen_obstacle_rectangle)
                if did_bubble_collide_with_obstacle {
                    remove_entity(bubble_id, .bubbles, free = false)

                    entity.pop_anim_time_amount = 0.25
                    entity.pop_anim_timer = entity.pop_anim_time_amount

                    append_elem(&views[.popping_bubbles].indices, bubble_id)
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
            rl.DrawCircleV(screen_pos, screen_radius, auto_cast colors[bubble.color])
        }

        { // draw ed stuff
            obstacle_placement_rectangle := absolute_normalized_rectangle(obstacle_placement_unnormalized_rectangle)
            rl.DrawRectangleRec(screen_from_world(obstacle_placement_rectangle), auto_cast colors[.black])

            edit_mode_text := entity_edit_mode_name_map[current_entity_edit_mode]
            draw_text(edit_mode_text, [2]f32{0.01, 0.01}, 0.02, .black)

            screen_bubble_placement_circle := screen_from_world(bubble_placement_circle)
            transparent_blue := rl.Color{ 0, 0, 255, 100 }
            rl.DrawCircle(i32(screen_bubble_placement_circle.x), i32(screen_bubble_placement_circle.y), screen_bubble_placement_circle.z, auto_cast transparent_blue)
        }

        { // draw debug visualizer
            // draw small circle where mouse is being held down with left click
            if rl.IsMouseButtonDown(.LEFT) {
                screen_pos := screen_from_world([2]f32{ world_mouse_pos.x, world_mouse_pos.y })
                rl.DrawCircleV(screen_pos, 20, auto_cast colors[.red])
                rl.DrawCircleV(screen_pos, 5, auto_cast colors[.white])
            }
        }

        draw_grid(cell_size)

        boundary_color := rl.Color{ 255, 0, 0, 150 }
        thickness_world :: 0.01
        thickness := screen_from_world(cast(f32) thickness_world)

        top_boundary_start := screen_from_world([2]f32{ 0, -thickness_world })
        top_boundary_end := screen_from_world([2]f32{ 1, -thickness_world })
        rl.DrawLineEx(top_boundary_start, top_boundary_end, thickness * 2, boundary_color)

        left_boundary_start := screen_from_world([2]f32{ -thickness_world, 0 })
        left_boundary_end := screen_from_world([2]f32{ -thickness_world, world_height })
        rl.DrawLineEx(left_boundary_start, left_boundary_end, thickness * 2, boundary_color)

        boundary_color.g = 100

        bottom_boundary_start := screen_from_world([2]f32{ 0, world_height + thickness_world })
        bottom_boundary_end := screen_from_world([2]f32{ 1, world_height + thickness_world })
        rl.DrawLineEx(bottom_boundary_start, bottom_boundary_end, thickness * 2, boundary_color)

        right_boundary_start := screen_from_world([2]f32{ 1 + thickness_world, 0 })
        right_boundary_end := screen_from_world([2]f32{ 1 + thickness_world, world_height })
        rl.DrawLineEx(right_boundary_start, right_boundary_end, thickness * 2, boundary_color)
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

draw_text :: proc(text: cstring, position_world: [2]f32, font_size_world: f32, color: Color = .black, rotation: f32 = 0, spacing: f32 = 1) {
    font := rl.GetFontDefault()
    position := screen_from_world(position_world)
    origin := [2]f32{}
    font_size := screen_from_world(font_size_world)
    tint := colors[color]
    rl.DrawTextPro(font, text, position, origin, rotation, font_size, spacing, auto_cast tint)
}
