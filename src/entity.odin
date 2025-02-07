package game

import rl "vendor:raylib"
import "core:slice"

ENTITY_CAP :: 256

Entity_Index :: distinct int

Entity :: struct {
    using rect: rl.Rectangle,
    velocity: [2]f32,
    accel: [2]f32,
    color: Color,
    pop_anim_timer: f32,
    pop_anim_time_amount: f32,
}

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


entity_backing_memory: [ENTITY_CAP]Entity

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


entity_view_init :: proc(view: ^Entity_View) -> Entity_View {
    view.indices = slice.into_dynamic(view.backing_memory[:])
    return view^
}


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

