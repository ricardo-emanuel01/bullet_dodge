package bullet_dodge


import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:mem"
import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:strings"
import fp "core:path/filepath"
import rl "vendor:raylib"


Vec2 :: [2]f32

// To get the bullet type from unmarshalling
BulletType :: enum {
    bouncer,
    bulldozer,
    constructor
}

Wall :: struct {
    x1, y1, x2, y2: u16,
    invulnerable:   bool // optional
}

BulletSpawner :: struct {
    spawn_frequency: f32,
    timer:           f32,
    bullet_type:     BulletType,
    x, y:            u16,
    velocity:        u8
}

Bullet :: struct {
    position:  Vec2,
    direction: Vec2,
    type:      BulletType,
    velocity:  u8
}

GameState :: enum {
    Playing,
    Menu,
    Close,
    Lose
}

State :: struct {
    walls:           [dynamic]Wall,
    bullet_spawners: [dynamic]BulletSpawner,
    bullets:         [dynamic]Bullet,
    
    player_position:        Vec2,
    player_speed:           f32,
    input:                  bit_set[Commands],
    time_survived:          f32,
    game_state:             GameState,
    length_generated_walls: u16,
    map_width:              u16,
    map_height:             u16,
    wall_thickness:         u8,
    player_radius:          u8
}

Commands :: enum {
    Up,
    Down,
    Left,
    Right,
    Menu,
    Enter
}

process_input :: proc(input: ^bit_set[Commands]) {
    input^ = {}

    if rl.IsKeyDown(rl.KeyboardKey.UP) {
        input^ += {.Up}
    }

    if rl.IsKeyDown(rl.KeyboardKey.DOWN) {
        input^ += {.Down}
    }

    if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
        input^ += {.Left}
    }

    if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
        input^ += {.Right}
    }

    if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
        input^ += {.Menu}
    }

    if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
        input^ += {.Enter}
    }

    return
}

read_json_file :: proc(state: ^State, filename: string, allocator := context.allocator) {
    contents, ok := os.read_entire_file_from_filename(filename, context.temp_allocator)

    json.unmarshal(contents, state, allocator = allocator)

    for &bullet_spawner in state.bullet_spawners {
        bullet_spawner.timer = bullet_spawner.spawn_frequency
    }

    state.player_position        = { 50, 50 }
    state.player_speed           = 200
    state.player_radius          = 15
    state.game_state             = .Menu
    state.length_generated_walls = 200
}

draw_walls :: proc(state: ^State) {
    for wall in state.walls {
        rl.DrawLineEx({f32(wall.x1), f32(wall.y1)}, {f32(wall.x2), f32(wall.y2)}, f32(state.wall_thickness), rl.WHITE)
    }
}

draw_bullets :: proc(bullets: [dynamic]Bullet) {
    color: rl.Color
    for bullet in bullets {
        switch bullet.type {
            case .bouncer:
                color = rl.WHITE
            case .bulldozer:
                color = rl.GREEN
            case .constructor:
                color = rl.BLUE
        }
        // TODO: Define the radius of each projectile
        rl.DrawCircleV(bullet.position, f32(5), color)
    }
}

fire :: proc(bullets: ^[dynamic]Bullet, bullet_spawner: BulletSpawner) {
    current_bullet: Bullet = {
        position  = {f32(bullet_spawner.x), f32(bullet_spawner.y)},
        direction = rl.Vector2Normalize({ rand.float32() * 2 - 1, rand.float32() * 2 - 1 }),
        type      = bullet_spawner.bullet_type,
        velocity  = bullet_spawner.velocity
    }

    append(bullets, current_bullet)
}

update_bullet_spawners :: proc(bullets: ^[dynamic]Bullet, bullet_spawners: ^[dynamic]BulletSpawner, frametime: f32) {
    for &bullet_spawner in bullet_spawners {
        bullet_spawner.timer -= frametime

        if bullet_spawner.timer <= f32(0) {
            fire(bullets, bullet_spawner)
            bullet_spawner.timer = bullet_spawner.spawn_frequency
        }
    }
}

update_bullets :: proc(bullets: ^[dynamic]Bullet, map_width: u16, map_height: u16, frametime: f32) {
    for i in 0..<len(bullets) {
        scale := f32(bullets[i].velocity) *frametime
        displacement := bullets[i].direction * scale
        bullets[i].position += displacement

        if bullets[i].position.x < f32(-5) || bullets[i].position.x > f32(map_width + 5) || bullets[i].position.y < f32(-5) || bullets[i].position.y > f32(map_height + 5) {
            unordered_remove(bullets, i)
        }
    }
}

update_player :: proc(state: ^State, frametime: f32) {
    direction: Vec2
    if Commands.Up in state.input {
        direction.y = -1
    }

    if Commands.Down in state.input {
        direction.y = 1
    }

    if Commands.Left in state.input {
        direction.x = -1
    }

    if Commands.Right in state.input {
        direction.x = 1
    }

    direction = rl.Vector2Normalize(direction)
    state.player_position += direction * f32(state.player_speed) * frametime
}

check_collision_bullets_walls :: proc(bullets: ^[dynamic]Bullet, walls: ^[dynamic]Wall, length: u16, thickness: u8) {
    for i in 0..<len(bullets) {
        ray_cast: [2]Vec2 = { bullets[i].position, bullets[i].position + bullets[i].direction * (f32(thickness) + f32(5)) }
        collision_point: Vec2

        // TODO: Check for the closest one
        for j in 0..<len(walls) {
            if rl.CheckCollisionLines(ray_cast[0], ray_cast[1], Vec2 {f32(walls[j].x1), f32(walls[j].y1)}, Vec2 {f32(walls[j].x2), f32(walls[j].y2)}, &collision_point) {
                switch bullets[i].type {
                    case .bouncer:
                        bullets[i].direction *= -1
                        wall_vector: Vec2 = linalg.vector_normalize(Vec2 {f32(walls[j].x2), f32(walls[j].y2)} - Vec2 {f32(walls[j].x1), f32(walls[j].y1)})
                        wall_normal_vector: Vec2 = { -1 * wall_vector.y, wall_vector.x }
                        if rl.Vector2DotProduct(wall_normal_vector, bullets[i].direction) < f32(0) {
                            wall_normal_vector *= -1
                        }

                        angle_wall_normal_ray := linalg.angle_between(bullets[i].direction, wall_normal_vector)
                        
                        new_direction := rl.Vector2Rotate(bullets[i].direction, 2 * angle_wall_normal_ray)
                        if linalg.angle_between(new_direction, wall_normal_vector) > angle_wall_normal_ray + f32(0.01) || linalg.angle_between(new_direction, wall_normal_vector) < angle_wall_normal_ray - f32(0.01) {
                            bullets[i].direction = rl.Vector2Rotate(bullets[i].direction, -2 * angle_wall_normal_ray)
                        } else {
                            bullets[i].direction = new_direction
                        }

                    case .constructor:
                        create_new_wall(walls, bullets[i].direction, collision_point, length)
                        unordered_remove(bullets, i)

                    case .bulldozer:
                        if !walls[j].invulnerable {
                            unordered_remove(walls, j)
                            unordered_remove(bullets, i)
                        }
                }

                break
            }
        }
    }
}

check_collision_player :: proc(state: ^State) -> bool {
    for bullet in state.bullets {
        if rl.CheckCollisionCircles(state.player_position, f32(state.player_radius), bullet.position, f32(5)) {
            return true
        }
    }

    for wall in state.walls {
        if rl.CheckCollisionCircleLine(state.player_position, f32(state.player_radius), Vec2 {f32(wall.x1), f32(wall.y1)}, Vec2 {f32(wall.x2), f32(wall.y2)}) {
            return true
        }
    }

    return false
}

create_new_wall :: proc(walls: ^[dynamic]Wall, impact_direction, collision_point: Vec2, length: u16) {
    new_wall_vector: Vec2 = rl.Vector2Normalize({ -1 * impact_direction.y, impact_direction.x })
    p1 := collision_point + new_wall_vector * f32(length) / f32(2)
    p2 := collision_point - new_wall_vector * f32(length) / f32(2)
    new_wall: Wall = {
        x1 = u16(p1.x),
        y1 = u16(p1.y),
        x2 = u16(p2.x),
        y2 = u16(p2.y),
        invulnerable = false
    }

    append(walls, new_wall)
}

main :: proc() {
    allocator_data: AllocatorData
    arena_mem := make([]byte, 1 * mem.Megabyte)
    arena: mem.Arena
    mem.arena_init(&arena, arena_mem)
    arena_alloc := mem.arena_allocator(&arena)
    game_state := GameState.Menu
    list_view_visibility := false
    window_size: Vec2 = {200, 200}

    state: ^State

    rl.SetConfigFlags({ rl.ConfigFlag.MSAA_4X_HINT });
    rl.InitWindow(i32(window_size[0]), i32(window_size[1]), "testing")
    rl.SetTargetFPS(60)
    rl.SetExitKey(rl.KeyboardKey.KEY_NULL)

    for game_state != .Close {
        frametime: f32
        switch game_state {
            case .Playing:
            {
                frametime = rl.GetFrameTime()
                state.time_survived += frametime
                process_input(&state.input)
                if Commands.Menu in state.input {
                    game_state = .Menu
                    window_size = {200, 200}
                    rl.SetWindowSize(i32(window_size.x), i32(window_size.y))
                } else {
                    update_bullet_spawners(&state.bullets, &state.bullet_spawners, frametime)
                    update_bullets(&state.bullets, state.map_width, state.map_height, frametime)
                    update_player(state, frametime)
                    check_collision_bullets_walls(&state.bullets, &state.walls, state.length_generated_walls, state.wall_thickness)
                    if check_collision_player(state) {
                        game_state = .Lose
                        window_size = {200, 200}
                        fmt.println(window_size)
                        rl.SetWindowSize(i32(window_size.x), i32(window_size.y))
                        break
                    }
    
                    time_survived_str := fmt.aprintf("You survived until now: %v seconds", state.time_survived, allocator = context.temp_allocator)
                    frametime_str := fmt.aprintf("frametime: %v seconds", frametime, allocator = context.temp_allocator)
                    walls_str := fmt.aprintf("walls: %v", len(state.walls), allocator = context.temp_allocator)
                    bullets_str := fmt.aprintf("bullets: %v", len(state.bullets), allocator = context.temp_allocator)
    
                    rl.BeginDrawing()
                        rl.ClearBackground(rl.BLACK)
                        rl.DrawFPS(5, 5)
                        rl.DrawText(strings.clone_to_cstring(time_survived_str, allocator = context.temp_allocator), 5, 25, 20, rl.WHITE)
                        rl.DrawText(strings.clone_to_cstring(frametime_str, allocator = context.temp_allocator), 5, 45, 20, rl.WHITE)
                        rl.DrawText(strings.clone_to_cstring(walls_str, allocator = context.temp_allocator), 5, 65, 20, rl.WHITE)
                        rl.DrawText(strings.clone_to_cstring(bullets_str, allocator = context.temp_allocator), 5, 85, 20, rl.WHITE)
                        draw_walls(state)
                        draw_bullets(state.bullets)
                        rl.DrawCircleV(state.player_position, f32(state.player_radius), rl.RED)
                    rl.EndDrawing()
                    free_all(context.temp_allocator)
                }
            }
            case .Menu:
            {
                if rl.IsKeyPressed(rl.KeyboardKey.ENTER) {
                    game_state = .Close
                    break
                }

                rl.BeginDrawing()
                    rl.ClearBackground(rl.BLACK)
                    selection_button := rl.Rectangle {window_size[0] / 2 - 60, 20, 120, 40}
                    if rl.GuiButton(selection_button, "select your level") {
                        list_view_visibility = !list_view_visibility
                    }

                    if list_view_visibility {
                        scroll_index: i32
                        level_selected: i32 = -1
    
                        curr_maps := fp.glob("levels/*.json", context.temp_allocator) or_else []string{}
    
                        level_file_names := make([dynamic]string, context.temp_allocator)
    
                        for map_filepath in curr_maps {
                            _, filename := fp.split(map_filepath)
                            append(&level_file_names,  filename)
                        }
    
                        level_names_view, err := strings.join(level_file_names[:], ";", allocator = context.temp_allocator)
                        assert(err == nil)
                        level_names_view_cstring := strings.clone_to_cstring(level_names_view, allocator = context.temp_allocator)
    
                        dropdown_menu_rectangle := rl.Rectangle {window_size[0] / 2 - 60, 60, 120, f32(len(level_file_names)) * 35}
                        rl.GuiListView(dropdown_menu_rectangle, level_names_view_cstring, &scroll_index, &level_selected)
    
                        if level_selected >= 0 {
                            if state != nil {
                                free_all(arena_alloc)
                            }
    
                            state = new(State, arena_alloc)
                            game_state = .Playing
                            read_json_file(state, curr_maps[level_selected], arena_alloc)
                            window_size = {f32(state.map_width), f32(state.map_height)}
                            rl.SetWindowSize(i32(state.map_width), i32(state.map_height))
                        }
                    }
                rl.EndDrawing()
            }
            case .Lose:
            {
                game_state = .Close
            }
            case .Close:
            {

            }
        }
    }

    rl.CloseWindow()
}
