have entity_view contain poointer ot backign memory

            bullet_radius :: 0.01
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
            bullet_speed :: 0.5
            bullet.velocity *= bullet_speed