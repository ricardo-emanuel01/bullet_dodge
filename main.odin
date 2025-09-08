package bullet_dodge


import "base:runtime"
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
BULLET_RADIUS :: 5

// To get the bullet type from unmarshalling
BulletType :: enum {
    bouncer,
    bulldozer,
    constructor
}

Wall :: struct {
    x1, y1, x2, y2: i16,
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
    time_survived:          f32,
    input:                  bit_set[Commands],
    length_generated_walls: u16,
    map_width:              u16,
    map_height:             u16,
    wall_thickness:         u8,
    player_radius:          u8
}

Sounds :: struct {
    background:       rl.Music,
    collision:        rl.Sound,
    fire:             rl.Sound,
    lose:             rl.Sound,
    wall_destruction: rl.Sound,
    wall_creation:    rl.Sound
}

Commands :: enum {
    Up,
    Down,
    Left,
    Right,
    Menu,
    Enter
}

Error :: union #shared_nil {
    json.Error,
    json.Unmarshal_Error,
    os.Error,
    runtime.Allocator_Error
}

// --------------------------- UTILITY FUNCTIONS

get_perp_vector :: proc(vector: Vec2) -> Vec2 {
    return linalg.vector_normalize( Vec2 { -1 * vector.y, vector.x } )
}

read_json_file :: proc(state: ^State, filename: string, allocator := context.allocator) -> Error {
    contents := os.read_entire_file_from_filename_or_err(filename, context.temp_allocator) or_return
    json.unmarshal(contents, state, allocator = allocator) or_return

    for &bullet_spawner in state.bullet_spawners {
        bullet_spawner.timer = bullet_spawner.spawn_frequency
    }

    state.player_position        = { 50, 50 }
    state.player_speed           = 200
    state.player_radius          = 15
    state.length_generated_walls = 200

    return nil
}

// ---------------------------

// --------------------------- UPDATE FUNCTIONS

update_bullet_spawners :: proc(bullets: ^[dynamic]Bullet, bullet_spawners: ^[dynamic]BulletSpawner, fire_sound_fx: rl.Sound, frametime: f32) {
    fire :: proc(bullets: ^[dynamic]Bullet, bullet_spawner: BulletSpawner) {
        current_bullet: Bullet = {
            position  = {f32(bullet_spawner.x), f32(bullet_spawner.y)},
            direction = rl.Vector2Normalize({ rand.float32() * 2 - 1, rand.float32() * 2 - 1 }),
            type      = bullet_spawner.bullet_type,
            velocity  = bullet_spawner.velocity
        }

        append(bullets, current_bullet)
    }
    
    for &bullet_spawner in bullet_spawners {
        bullet_spawner.timer -= frametime

        if bullet_spawner.timer <= f32(0) {
            fire(bullets, bullet_spawner)
            rl.PlaySound(fire_sound_fx)
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

// ---------------------------

// --------------------------- COLLISION LOGIC

check_collision_bullets_walls :: proc(bullets: ^[dynamic]Bullet, walls: ^[dynamic]Wall, sounds: Sounds, length: u16, thickness: u8) {
    check_collision :: proc(wall: Wall, bullet: Bullet, wall_thickness: u8, collision_point, collision_normal_vector: ^Vec2) -> bool {
        circle_radius_f32 := f32(BULLET_RADIUS)
        first_end   := Vec2 { f32(wall.x1), f32(wall.y1) }
        second_end  := Vec2 { f32(wall.x2), f32(wall.y2) }
        wall_vector := second_end - first_end
        wall_normal_vector := get_perp_vector(wall_vector)

        p1 := first_end  + wall_normal_vector * f32(wall_thickness) / f32(2)
        p2 := first_end  - wall_normal_vector * f32(wall_thickness) / f32(2)
        p3 := second_end + wall_normal_vector * f32(wall_thickness) / f32(2)
        p4 := second_end - wall_normal_vector * f32(wall_thickness) / f32(2)

        collision_point^ = bullet.position + bullet.direction * circle_radius_f32
        if rl.CheckCollisionCircleLine(bullet.position, circle_radius_f32, p1, p2) {
            collision_normal_vector^ = linalg.vector_normalize(-1 * wall_vector)
        } else if rl.CheckCollisionCircleLine(bullet.position, circle_radius_f32, p1, p3) {
            collision_normal_vector^ = linalg.vector_normalize(wall_normal_vector)    
        } else if rl.CheckCollisionCircleLine(bullet.position, circle_radius_f32, p3, p4) {
            collision_normal_vector^ = linalg.vector_normalize(wall_vector)
        } else if rl.CheckCollisionCircleLine(bullet.position, circle_radius_f32, p2, p4) {
            collision_normal_vector^ = linalg.vector_normalize(-1 * wall_normal_vector)
        } else { return false }

        return true
    }

    create_new_wall :: proc(walls: ^[dynamic]Wall, impact_direction, collision_point: Vec2, length: u16) {
        new_wall_vector: Vec2 = get_perp_vector(impact_direction)
        p1 := collision_point + new_wall_vector * f32(length) / f32(2)
        p2 := collision_point - new_wall_vector * f32(length) / f32(2)
        invulnerable := false

        if rand.uint32() % u32(2) == 1 { invulnerable = true }
        new_wall: Wall = {
            x1 = i16(p1.x),
            y1 = i16(p1.y),
            x2 = i16(p2.x),
            y2 = i16(p2.y),
            invulnerable = invulnerable
        }

        append(walls, new_wall)
    }

    for i in 0..<len(bullets) {
        ray_cast: [2]Vec2 = { bullets[i].position, bullets[i].position + bullets[i].direction * (f32(thickness) + f32(BULLET_RADIUS)) }
        collision_point, collision_normal_vector: Vec2

        // TODO: Check for the closest one
        for j in 0..<len(walls) {
            if check_collision(walls[j], bullets[i], thickness, &collision_point, &collision_normal_vector) {
                switch bullets[i].type {
                    case .bouncer:
                        rl.PlaySound(sounds.collision)
                        negative_bullet_direction := -1 * bullets[i].direction
                        current_bullet_direction  := bullets[i].direction

                        component_to_normal_vec := collision_normal_vector * linalg.vector_dot(negative_bullet_direction, collision_normal_vector)
                        bullets[i].direction = current_bullet_direction + 2 * component_to_normal_vec

                    case .constructor:
                        rl.PlaySound(sounds.wall_creation)
                        create_new_wall(walls, bullets[i].direction, collision_point, length)
                        unordered_remove(bullets, i)

                    case .bulldozer:
                        if !walls[j].invulnerable {
                            rl.PlaySound(sounds.wall_destruction)
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
        if rl.CheckCollisionCircles(state.player_position, f32(state.player_radius), bullet.position, f32(BULLET_RADIUS)) {
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

// ---------------------------

// --------------------------- DRAW FUNCTIONS

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
                color = rl.GRAY
            case .constructor:
                color = rl.BLUE
        }

        rl.DrawCircleV(bullet.position, f32(BULLET_RADIUS), color)
    }
}

draw_state :: proc(state: ^State) {
    draw_walls(state)
    draw_bullets(state.bullets)
    rl.DrawCircleV(state.player_position, f32(state.player_radius), rl.RED)
}

draw_HUD :: proc(state: ^State, frametime: f32) {
    defer free_all(context.temp_allocator)
    time_survived_str := fmt.aprintf("You survived %.2v seconds", state.time_survived, allocator = context.temp_allocator)
    frametime_str := fmt.aprintf("frametime: %v seconds", frametime, allocator = context.temp_allocator)
    walls_str := fmt.aprintf("walls: %v", len(state.walls), allocator = context.temp_allocator)
    bullets_str := fmt.aprintf("bullets: %v", len(state.bullets), allocator = context.temp_allocator)

    rl.DrawFPS(5, 5)
    rl.DrawText(strings.clone_to_cstring(time_survived_str, allocator = context.temp_allocator), 5, 25, 20, rl.LIME)
    rl.DrawText(strings.clone_to_cstring(frametime_str, allocator = context.temp_allocator), 5, 45, 20, rl.LIME)
    rl.DrawText(strings.clone_to_cstring(walls_str, allocator = context.temp_allocator), 5, 65, 20, rl.LIME)
    rl.DrawText(strings.clone_to_cstring(bullets_str, allocator = context.temp_allocator), 5, 85, 20, rl.LIME)
}

draw_game :: proc(state: ^State, frametime: f32) {
    rl.ClearBackground(rl.BLACK)
    draw_state(state)
    draw_HUD(state, frametime)
}

// ---------------------------

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

@require_results
manage_GUI :: proc(state: ^State, window_size: Vec2, list_view_visibility: ^bool, current_levels: ^[]string) -> (level_selected: i32, err: Error) {
    level_selected = -1

    selection_button := rl.Rectangle { window_size[0] / 2 - 60, 20, 120, 40 }
    if rl.GuiButton(selection_button, "select your level") {
        list_view_visibility^ = !list_view_visibility^
    }

    if list_view_visibility^ {
        scroll_index: i32

        current_levels^ = fp.glob("levels/*.json", context.temp_allocator) or_else []string{}

        level_file_names := make([dynamic]string, context.temp_allocator)

        for level_fp in current_levels {
            _, filename := fp.split(level_fp)
            append(&level_file_names,  filename)
        }

        level_names_view := strings.join(level_file_names[:], ";", allocator = context.temp_allocator) or_return

        level_names_view_cstring := strings.clone_to_cstring(level_names_view, allocator = context.temp_allocator)

        dropdown_menu_rectangle := rl.Rectangle {window_size[0] / 2 - 60, 60, 120, f32(len(level_file_names)) * 35}
        rl.GuiListView(dropdown_menu_rectangle, level_names_view_cstring, &scroll_index, &level_selected)
    }

    return level_selected, nil
}

main :: proc() {
    arena_mem := make([]byte, 1 * mem.Megabyte)
    arena: mem.Arena
    mem.arena_init(&arena, arena_mem)
    arena_alloc := mem.arena_allocator(&arena)

    game_state := GameState.Menu
    list_view_visibility := false
    window_size: Vec2 = {200, 400}
    state: ^State

    rl.SetConfigFlags({ rl.ConfigFlag.MSAA_4X_HINT });
    rl.InitWindow(i32(window_size[0]), i32(window_size[1]), "Bullet Dodge")
    rl.InitAudioDevice()
    rl.SetTargetFPS(120)
    rl.SetExitKey(rl.KeyboardKey.KEY_NULL)

    sounds := Sounds {
        background       = rl.LoadMusicStream("sounds/background.ogg"),
        fire             = rl.LoadSound("sounds/fire.ogg"),
        lose             = rl.LoadSound("sounds/lose.ogg"),
        collision        = rl.LoadSound("sounds/collision.ogg"),
        wall_creation    = rl.LoadSound("sounds/wall_creation.ogg"),
        wall_destruction = rl.LoadSound("sounds/wall_destruction.ogg")
    }

    for game_state != .Close {
        frametime: f32
        switch game_state {
            case .Playing:
            {
                if !rl.IsMusicStreamPlaying(sounds.background) { rl.PlayMusicStream(sounds.background) }
                rl.UpdateMusicStream(sounds.background)

                frametime = rl.GetFrameTime()
                state.time_survived += frametime
                process_input(&state.input)
                if Commands.Menu in state.input {
                    game_state = .Menu
                    window_size = {200, 400}
                    rl.SetWindowSize(i32(window_size.x), i32(window_size.y))
                } else {
                    update_bullet_spawners(&state.bullets, &state.bullet_spawners, sounds.fire, frametime)
                    update_bullets(&state.bullets, state.map_width, state.map_height, frametime)
                    update_player(state, frametime)
                    check_collision_bullets_walls(&state.bullets, &state.walls, sounds, state.length_generated_walls, state.wall_thickness)
                    if check_collision_player(state) {
                        game_state = .Lose
                        window_size = {500, 200}
                        rl.PlaySound(sounds.lose)
                        rl.SetWindowSize(i32(window_size.x), i32(window_size.y))
                        break
                    }
    
                    rl.BeginDrawing()
                        draw_game(state, frametime)
                    rl.EndDrawing()
                }
            }
            case .Menu:
            {
                current_levels: []string
                if rl.IsMusicStreamPlaying(sounds.background) { rl.StopMusicStream(sounds.background) }
                if rl.IsKeyPressed(rl.KeyboardKey.ENTER) {
                    game_state = .Close
                    break
                }

                rl.BeginDrawing()
                    rl.ClearBackground(rl.BLACK)
                    level_selected, error_GUI := manage_GUI(state, window_size, &list_view_visibility, &current_levels)

                    if (error_GUI == nil) {
                        if level_selected >= 0 {
                            if state != nil {
                                free_all(arena_alloc)
                            }
    
                            state = new(State, arena_alloc)
                            game_state = .Playing
                            error_reading_JSON := read_json_file(state, current_levels[level_selected], arena_alloc)
                            if error_reading_JSON == nil {
                                window_size = {f32(state.map_width), f32(state.map_height)}
                                rl.SetWindowSize(i32(state.map_width), i32(state.map_height))
                            } else {
                                fmt.eprintln("Error:", error_reading_JSON)
                                game_state = .Close
                            }
                        }
                    } else {
                        fmt.eprintln("Error:", error_GUI)
                        game_state = .Close
                    }
                rl.EndDrawing()
            }
            case .Lose:
            {
                process_input(&state.input)
                if Commands.Menu in state.input {
                    game_state = .Menu
                    window_size = {200, 400}
                    rl.SetWindowSize(i32(window_size.x), i32(window_size.y))
                }

                rl.BeginDrawing()
                    draw_game(state, frametime)
                rl.EndDrawing()
            }
            case .Close: {}
        }
    }

    rl.UnloadMusicStream(sounds.background)
    rl.UnloadSound(sounds.fire)
    rl.UnloadSound(sounds.lose)
    rl.UnloadSound(sounds.collision)
    rl.UnloadSound(sounds.wall_creation)
    rl.UnloadSound(sounds.wall_destruction)
    rl.CloseAudioDevice()
    rl.CloseWindow()
}
