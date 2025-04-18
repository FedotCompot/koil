module client;
import common;
import common::msg;
import std::math;
import std::sort;
import std::io;
import std::collections::map;

const float NEAR_CLIPPING_PLANE = 0.1;
const float FAR_CLIPPING_PLANE = 10.0;
const float FOV = math::PI*0.5;
const float EPS = 1e-6;
const usz SPRITE_POOL_CAPACITY = 1000;
const usz PARTICLE_POOL_CAPACITY = 1000;
const float PARTICLE_LIFETIME = 1.0f;
const float PARTICLE_MAX_SPEED = 8;
const float PARTICLE_DAMP = 0.8;
const float PARTICLE_SCALE = 0.05;
const uint PING_COOLDOWN = 60;

const float ITEM_FREQ = 0.7;
const float ITEM_AMP = 0.07;

const int BOMB_PARTICLE_COUNT = 50;

const bool MINIMAP_SPRITES = true;
const float MINIMAP_SPRITE_SIZE = 0.2;
const float MINIMAP_SCALE = 0.07;

const uint SPRITE_ANGLES_COUNT = 8;

$exec("build/packer");

struct Color {
    char r;
    char g;
    char b;
    char a;
}

macro Vector2.angle_fixed(self) => platform::atan2f(self.y, self.x);
// // TODO: math::atan2 is broken. Does not work with sprite_angle_index() properly.
// // Investigate what's up and potentially report to C3.
// macro Vector2.angle(self) => math::atan2(self.y, self.x);

struct Image {
    usz width;
    usz height;
    Color *pixels;
}

struct Sprite {
    Image *image;
    // TODO: Use Vector3 instead
    // We can't do it right now due to some alignment restriction stuff
    Vector2 position;
    float z;
    float scale;
    IVector2 crop_position;
    IVector2 crop_size;

    float dist;  // Actual distance.
    float pdist; // Perpendicular distance.
    float t;     // Normalized horizontal position on the screen
}

struct SpritePool {
    Sprite[SPRITE_POOL_CAPACITY] items;
    int length;
    Sprite*[SPRITE_POOL_CAPACITY] visible_items;
    int visible_length;
}
SpritePool sprite_pool;

fn void reset_sprite_pool() {
    sprite_pool.length = 0;
    sprite_pool.visible_length = 0;
}

struct Particle {
    float lifetime;
    // TODO: Use Vector3 instead
    // We can't do it right now due to some alignment restriction stuff
    Vector2 position;
    float position_z;
    Vector2 velocity;
    float velocity_z;
}

struct ParticlePool {
    Particle[PARTICLE_POOL_CAPACITY] items;
    int length;
}
ParticlePool particle_pool;

struct Camera {
    Vector2 position;
    float direction;
    Vector2 fovLeft;
    Vector2 fovRight;
}

fn void Camera.update(Camera *camera) {
    float halfFov = FOV*0.5;
    float fovLen = NEAR_CLIPPING_PLANE/math::cos(halfFov);
    camera.fovLeft  = vector2::add(vector2::from_polar(camera.direction-halfFov, fovLen), camera.position);
    camera.fovRight = vector2::add(vector2::from_polar(camera.direction+halfFov, fovLen), camera.position);
}

struct Display {
    Image image;
    float *zbuffer;
}

Display display;

fn void resize_display(usz width, usz height) @extern("resize_display") @wasm
{
    if (display.image.pixels) mem::free(display.image.pixels);
    if (display.zbuffer) mem::free(display.zbuffer);
    display.image.width = width;
    display.image.height = height;
    display.image.pixels = mem::calloc(Color.sizeof*width*height);
    display.zbuffer = mem::calloc(float.sizeof*width);
}

fn Color *pixels_of_display() @extern("pixels_of_display") @wasm {
    return &display.image.pixels[0];
}

const Color SCENE_FLOOR1   = {0x17, 0x29, 0x29, 0xff};
const Color SCENE_FLOOR2   = {0x2f, 0x41, 0x41, 0xff};
const Color SCENE_CEILING1 = {0x29, 0x17, 0x17, 0xff};
const Color SCENE_CEILING2 = {0x41, 0x2f, 0x2f, 0xff};

fn Color scene_get_floor(Vector2 p) {
    if ((p.x.floor() + p.y.floor())%2 == 0) {
        return SCENE_FLOOR1;
    } else {
        return SCENE_FLOOR2;
    }
}

fn Color scene_get_ceiling(Vector2 p) {
    if ((p.x.floor() + p.y.floor())%2 == 0) {
        return SCENE_CEILING1;
    } else {
        return SCENE_CEILING2;
    }
}

fn void render_floor_and_ceiling(Image *display) {
    Camera camera = { .position = {me.position.x, me.position.y}, .direction = me.direction };
    camera.update();

    int pz = display.height/2;
    float bp = vector2::length(vector2::sub(camera.fovLeft, camera.position));
    for (int y = display.height/2; y < display.height; ++y) {
        int sz = display.height - y - 1;

        int ap = pz - sz;
        float b = (bp/ap)*pz/NEAR_CLIPPING_PLANE;
        Vector2 t1 = vector2::add(vector2::mul(vector2::normalize(vector2::sub(camera.fovLeft, camera.position)), vector2::xx(b)), camera.position);
        Vector2 t2 = vector2::add(vector2::mul(vector2::normalize(vector2::sub(camera.fovRight, camera.position)), vector2::xx(b)), camera.position);

        // TODO: Render rows up until FAR_CLIPPING_PLANE
        //   There is a small bug with how we are projecting the floor and ceiling which makes it non-trivial.
        //   I think we are projecting it too far, and the only reason it works is because we have no
        //   specific textures at specific places anywhere. So it works completely accidentally.
        //   We need to fix this bug first.
        //
        //   But if we manage to do that, this optimization should give a decent speed up 'cause we can render
        //   fewer rows.

        for (int x = 0; x < display.width; ++x) {
            Vector2 t = vector2::lerp(t1, t2, (float)x/display.width);

            float fog = vector2::length(vector2::sub(t, camera.position));

            Color floor_color = scene_get_floor(t);
            display.pixels[y*display.width + x].r = (char)(floor_color.r*fog).clamp(0, 255);
            display.pixels[y*display.width + x].g = (char)(floor_color.g*fog).clamp(0, 255);
            display.pixels[y*display.width + x].b = (char)(floor_color.b*fog).clamp(0, 255);
            display.pixels[y*display.width + x].a = 255;

            Color ceiling_color = scene_get_ceiling(t);
            display.pixels[sz*display.width + x].r = (char)(ceiling_color.r*fog).clamp(0, 255);
            display.pixels[sz*display.width + x].g = (char)(ceiling_color.g*fog).clamp(0, 255);
            display.pixels[sz*display.width + x].b = (char)(ceiling_color.b*fog).clamp(0, 255);
            display.pixels[sz*display.width + x].a = 255;
        }
    }
}

fn void render_column_of_wall(Image *display, float *zbuffer, Image *cell, int x, Vector2 p, Vector2 c) {
    float strip_height = display.height/zbuffer[x];
    float u = 0;
    Vector2 t = vector2::sub(p, c);
    if (math::abs(t.x) < EPS && t.y > 0) {
        u = t.y;
    } else if (math::abs(t.x - 1) < EPS && t.y > 0) {
        u = 1 - t.y;
    } else if (math::abs(t.y) < EPS && t.x > 0) {
        u = 1 - t.x;
    } else {
        u = t.x;
    }

    float y1f = (display.height - strip_height)*0.5f;
    int y1 = (int)math::ceil(y1f);
    int y2 = (int)math::floor(y1 + strip_height);
    int by1 = math::max(0, y1);
    int by2 = math::min((int)display.height, y2);
    int tx = (int)math::floor(u*cell.width);
    float sh = cell.height / strip_height;
    float shadow = math::min(1.0f/zbuffer[x]*4.0f, 1.0f);
    for (int y = by1; y < by2; ++y) {
        int ty = (int)math::floor((y - y1f)*sh);
        int destP = y*display.width + x;
        int srcP = ty*cell.width + tx;
        display.pixels[destP].r = (char)(cell.pixels[srcP].r);
        display.pixels[destP].g = (char)(cell.pixels[srcP].g*shadow);
        display.pixels[destP].b = (char)(cell.pixels[srcP].b*shadow);
    }
}

fn Vector2 hitting_cell(Vector2 p1, Vector2 p2) {
    return vector2::floor(vector2::add(p2, vector2::mul(vector2::copysign(Vector2{1.0f, 1.0f}, vector2::sub(p2, p1)), vector2::xx(EPS))));
}

fn float snap(float x, float dx) {
    if (dx > 0) return math::ceil(x + math::copysign(1.0f, dx)*EPS);
    if (dx < 0) return math::floor(x + math::copysign(1.0f, dx)*EPS);
    return x;
}

fn Vector2 ray_step(Vector2 p1, Vector2 p2) {
    // y = k*x + c
    // x = (y - c)/k
    //
    // p1 = (x1, y1)
    // p2 = (x2, y2)
    //
    // | y1 = k*x1 + c
    // | y2 = k*x2 + c
    //
    // dy = y2 - y1
    // dx = x2 - x1
    // c = y1 - k*x1
    // k = dy/dx
    Vector2 p3 = p2;
    float dx = p2.x - p1.x;
    float dy = p2.y - p1.y;
    if (dx != 0) {
        float k = dy/dx;
        float c = p1.y - k*p1.x;

        {
            float x3 = snap(p2.x, dx);
            float y3 = x3*k + c;
            p3 = {x3, y3};
        }

        if (k != 0) {
            float y3 = snap(p2.y, dy);
            float x3 = (y3 - c)/k;
            Vector2 p3t = {x3, y3};
            if (vector2::distance(p2, p3t) < vector2::distance(p2, p3)) {
                p3 = p3t;
            }
        }
    } else {
        float y3 = snap(p2.y, dy);
        float x3 = p2.x;
        p3 = {x3, y3};
    }

    return p3;
}

fn Vector2 cast_ray(Scene *scene, Vector2 p1, Vector2 p2) {
    Vector2 start = p1;
    while (vector2::distance(start, p1) < FAR_CLIPPING_PLANE) {
        Vector2 c = hitting_cell(p1, p2);
        if (scene.get_tile(c)) break;
        Vector2 p3 = ray_step(p1, p2);
        p1 = p2;
        p2 = p3;
    }
    return p2;
}

fn void render_walls(Image *display, float *zbuffer, Image *wall, Scene *scene) {
    Camera camera = { .position = {me.position.x, me.position.y}, .direction = me.direction };
    camera.update();

    Vector2 d = vector2::from_polar(camera.direction, 1.0f);
    for (int x = 0; x < display.width; ++x) {
        Vector2 p = cast_ray(scene, camera.position, vector2::lerp(camera.fovLeft, camera.fovRight, (float)x/display.width));
        Vector2 c = hitting_cell(camera.position, p);
        Vector2 v = vector2::sub(p, camera.position);
        zbuffer[x] = vector2::dot(v, d);
        if (scene.get_tile(c)) render_column_of_wall(display, zbuffer, wall, x, p, c);
    }
}

fn void cull_and_sort_sprites(SpritePool *sprite_pool) {
    Camera camera = { .position = {me.position.x, me.position.y}, .direction = me.direction };
    camera.update();

    Vector2 dir = vector2::from_polar(camera.direction, 1.0f);
    Vector2 fov = vector2::sub(camera.fovRight, camera.fovLeft);

    sprite_pool.visible_length = 0;
    for (int i = 0; i < sprite_pool.length; ++i) {
        Sprite *sprite = &sprite_pool.items[i];

        Vector2 sp = vector2::sub(sprite.position, camera.position);
        float spl = vector2::length(sp);
        if (spl <= NEAR_CLIPPING_PLANE) continue; // Sprite is too close
        if (spl >= FAR_CLIPPING_PLANE) continue;  // Sprite is too far

        float cos = vector2::dot(sp, dir)/spl;
        // TODO: @perf the sprites that are invisible on the screen but within FOV 180° are not culled
        // It may or may not impact the performance of renderSprites()
        if (cos < 0) continue;  // Sprite is outside of the maximal FOV 180°
        sprite.dist = NEAR_CLIPPING_PLANE/cos;
        sp = vector2::sub(vector2::add(vector2::mul(vector2::normalize(sp),vector2::xx(sprite.dist)), camera.position), camera.fovLeft);
        sprite.t = vector2::length(sp)/vector2::length(fov)*math::copysign(1.0f, vector2::dot(sp, fov));
        sprite.pdist = vector2::dot(vector2::sub(sprite.position, camera.position), dir);

        // TODO: I'm not sure if these checks are necessary considering the `spl <= NEAR_CLIPPING_PLANE` above
        if (sprite.pdist < NEAR_CLIPPING_PLANE) continue;
        if (sprite.pdist >= FAR_CLIPPING_PLANE) continue;

        sprite_pool.visible_items[sprite_pool.visible_length++] = sprite;
    }

    quicksort(sprite_pool.visible_items[0..sprite_pool.visible_length-1],
              fn int(Sprite *a, Sprite *b) => (int)math::copysign(1.0f, b.pdist - a.pdist));
}

fn void push_sprite(SpritePool *sprite_pool, Image *image, Vector3 position, float scale, IVector2 crop_position, IVector2 crop_size) {
    if (sprite_pool.length >= SPRITE_POOL_CAPACITY) return;

    usz last = sprite_pool.length;

    sprite_pool.items[last].image = image;
    sprite_pool.items[last].position = {position.x, position.y};
    sprite_pool.items[last].z = position.z;
    sprite_pool.items[last].scale = scale;
    sprite_pool.items[last].pdist = 0;
    sprite_pool.items[last].dist = 0;
    sprite_pool.items[last].t = 0;
    sprite_pool.items[last].crop_position = crop_position;
    sprite_pool.items[last].crop_size = crop_size;

    sprite_pool.length += 1;
}

fn void render_sprites(Image *display, float *zbuffer, SpritePool *sprite_pool) {
    for (int i = 0; i < sprite_pool.visible_length; ++i) {
        Sprite *sprite = sprite_pool.visible_items[i];
        float cx = display.width*sprite.t;
        float cy = display.height*0.5f;
        float maxSpriteSize = display.height/sprite.pdist;
        float spriteSize = maxSpriteSize*sprite.scale;
        int x1 = (int)math::floor(cx - spriteSize*0.5f);
        int x2 = (int)math::floor(x1 + spriteSize - 1.0f);
        int bx1 = math::max(0, x1);
        int bx2 = math::min(display.width-1, x2);
        int y1 = (int)math::floor(cy + maxSpriteSize*0.5f - maxSpriteSize*sprite.z);
        int y2 = (int)math::floor(y1 + spriteSize - 1);
        int by1 = math::max(0, y1);
        int by2 = math::min(display.height-1, y2);

        Color *src = &sprite.image.pixels[0];
        Color *dest = &display.pixels[0];
        for (int x = bx1; x <= bx2; ++x) {
            if (sprite.pdist < zbuffer[x]) {
                for (int y = by1; y <= by2; ++y) {
                    int tx = (int)math::floor((float)(x - x1)/spriteSize*sprite.crop_size.x);
                    int ty = (int)math::floor((float)(y - y1)/spriteSize*sprite.crop_size.y);
                    int srcP = (ty + sprite.crop_position.y)*sprite.image.width + (tx + sprite.crop_position.x);
                    int destP = y*display.width + x;
                    float alpha = src[srcP].a/255.0f;
                    dest[destP].r = (char)(dest[destP].r*(1 - alpha) + src[srcP].r*alpha);
                    dest[destP].g = (char)(dest[destP].g*(1 - alpha) + src[srcP].g*alpha);
                    dest[destP].b = (char)(dest[destP].b*(1 - alpha) + src[srcP].b*alpha);
                }
            }
        }
    }
}

fn void emit_particle(Vector3 source, ParticlePool *particle_pool) {
    foreach (&particle: particle_pool.items) {
        if (particle.lifetime <= 0) {
            particle.lifetime = PARTICLE_LIFETIME;

            particle.position = {source.x, source.y};
            particle.position_z = source.z;

            float angle = platform::random()*2.0f*(float)math::PI;
            particle.velocity.x = math::cos(angle);
            particle.velocity.y = math::sin(angle);
            particle.velocity_z = platform::random()*0.5f + 0.5f;

            float velocity_mag = PARTICLE_MAX_SPEED*platform::random();
            particle.velocity = vector2::mul(particle.velocity, vector2::xx(velocity_mag));
            particle.velocity_z *= velocity_mag;
            break;
        }
    }
}

fn void update_particles(Image *image, SpritePool *sprite_pool, float deltaTime, Scene *scene, ParticlePool *particle_pool) {
    foreach (&particle: particle_pool.items) {
        if (particle.lifetime > 0) {
            particle.lifetime -= deltaTime;
            particle.velocity_z -= common::BOMB_GRAVITY*deltaTime;

            Vector2 new_position = vector2::add(particle.position, vector2::mul(particle.velocity, vector2::xx(deltaTime)));
            if (scene.get_tile(new_position)) {
                float dx = math::abs(math::floor(particle.position.x) - math::floor(new_position.x));
                float dy = math::abs(math::floor(particle.position.y) - math::floor(new_position.y));

                if (dx > 0) particle.velocity.x *= -1;
                if (dy > 0) particle.velocity.y *= -1;
                particle.velocity = vector2::mul(particle.velocity, vector2::xx(PARTICLE_DAMP));
            } else {
                particle.position = new_position;
            }

            float nz = particle.position_z + particle.velocity_z*deltaTime;
            if (nz < PARTICLE_SCALE || nz > 1.0) {
                particle.velocity_z *= -1;
                particle.velocity = vector2::mul(particle.velocity, vector2::xx(PARTICLE_DAMP));
            } else {
                particle.position_z = nz;
            }

            if (particle.lifetime > 0) {
                push_sprite(sprite_pool,
                            image,
                            {particle.position.x, particle.position.y, particle.position_z},
                            PARTICLE_SCALE,
                            {0, 0}, {image.width, image.height});
            }
        }
    }
}

fn void kill_all_items(Item[]* items) {
    foreach (&item: *items) {
        item.alive = false;
    }
}

fn bool apply_items_collected_batch_message(ItemsCollectedBatchMessage *message, Item[]* items) {
    usz count = (message.byte_length - ItemsCollectedBatchMessage.sizeof)/int.sizeof;

    for (usz i = 0; i < count; ++i) {
        int itemIndex = message.payload[i];

        if (!(0 <= itemIndex && itemIndex < items.len)) {
            io::printn(string::tformat("Received bogus-amogus ItemCollected message from server. Invalid index %d", itemIndex));
            return false;
        }

        Item *item = &(*items)[itemIndex];

        if (item.alive) {
            item.alive = false;
            platform::play_sound(ITEM_PICKUP, me.position.x, me.position.y, item.position.x, item.position.y);
        }
    }

    return true;
}

fn bool apply_items_spawned_batch_message(ItemsSpawnedBatchMessage *message, Item[]* items) {
    usz count = (message.byte_length - ItemsCollectedBatchMessage.sizeof)/ItemSpawned.sizeof;
    for (usz i = 0; i < count; ++i) {
        int itemIndex = message.payload[i].itemIndex;
        if (!(0 <= itemIndex && itemIndex < items.len)) {
            io::printn(string::tformat("Received bogus-amogus ItemSpawned message from server. Invalid item index %d", itemIndex));
            return false;
        }
        Item *item = &(*items)[itemIndex];
        item.alive = true;
        item.kind = message.payload[i].itemKind;
        item.position.x = message.payload[i].x;
        item.position.y = message.payload[i].y;
    }

    return true;
}

fn void render_items(SpritePool *sprite_pool, Item[]* items, float time, Image *key_image, Image *bomb_image) {
    foreach (item: *items) {
        if (item.alive) {
            float z = 0.25f + ITEM_AMP - ITEM_AMP*math::sin(ITEM_FREQ*(float)math::PI*time + item.position.x + item.position.y);
            switch (item.kind) {
                case KEY:
                    push_sprite(sprite_pool, key_image, {item.position.x, item.position.y, z}, 0.25f, {0, 0}, {key_image.width, key_image.height});
                case BOMB:
                    push_sprite(sprite_pool, bomb_image, {item.position.x, item.position.y, z}, 0.25f, {0, 0}, {bomb_image.width, bomb_image.height});
            }
        }
    }
}

fn void update_items_offline(Item[]* items) {
    foreach (item_index, &item: *items) {
        if (common::collect_item(me, item)) {
            platform::play_sound(ITEM_PICKUP, me.position.x, me.position.y, item.position.x, item.position.y);
        }
    }
}

fn void update_items(SpritePool *sprite_pool, float time, Item[] *items, Image *key_image, Image *bomb_image) {
    // Rendering the items as sprites
    render_items(sprite_pool, items, time, key_image, bomb_image);

    // Offline mode. Updating items state without asking the server.
    if (platform::is_offline_mode()) {
        update_items_offline(items);
    }
}


fn void explode_bomb(Vector3 bomb_position, Vector2 player_position, ParticlePool *particle_pool) {
    platform::play_sound(BOMB_BLAST, player_position.x, player_position.y, bomb_position.x, bomb_position.y);
    for (int i = 0; i < BOMB_PARTICLE_COUNT; ++i) {
        emit_particle(bomb_position, particle_pool);
    }
}

fn void update_bombs_on_client_side(SpritePool *sprite_pool, ParticlePool *particle_pool, Image *bomb_image, Scene *scene, float delta_time, Bombs *bombs) {
    foreach (&bomb: *bombs) {
        if (bomb.lifetime > 0) {
            push_sprite(sprite_pool, bomb_image, {bomb.position.x, bomb.position.y, bomb.position_z}, common::BOMB_SCALE, {0, 0}, {bomb_image.width, bomb_image.height});

            if (common::update_bomb(bomb, scene, delta_time)) {
                platform::play_sound(BOMB_RICOCHET, me.position.x, me.position.y, bomb.position.x, bomb.position.y);
            }

            if (platform::is_offline_mode() && bomb.lifetime <= 0) {
                explode_bomb({bomb.position.x, bomb.position.y, bomb.position_z}, me.position, particle_pool);
            }
        }
    }
}

fn bool apply_bombs_spawned_batch_message(BombsSpawnedBatchMessage *message, Bombs *bombs) {
    usz count = (message.byte_length - BombsSpawnedBatchMessage.sizeof)/BombSpawned.sizeof;
    for (usz i = 0; i < count; ++i) {
        int bombIndex = message.payload[i].bombIndex;
        if (!(0 <= bombIndex && bombIndex < bombs.len)) {
            io::printn(string::tformat("Received bogus-amogus BombSpawned message from server. Invalid bomb index %d", bombIndex));
            return false;
        }
        Bomb *bomb = &(*bombs)[bombIndex];
        bomb.lifetime   = message.payload[i].lifetime;
        bomb.position.x = message.payload[i].x;
        bomb.position.y = message.payload[i].y;
        bomb.position_z = message.payload[i].z;
        bomb.velocity.x = message.payload[i].dx;
        bomb.velocity.y = message.payload[i].dy;
        bomb.velocity_z = message.payload[i].dz;
    }

    return true;
}

fn bool apply_bombs_exploded_batch_message(BombsExplodedBatchMessage *message, Bombs *bombs, ParticlePool *particle_pool) {
    usz count = (message.byte_length - BombsExplodedBatchMessage.sizeof)/BombExploded.sizeof;
    for (usz i = 0; i < count; ++i) {
        int bombIndex = message.payload[i].bombIndex;
        if (!(0 <= bombIndex && bombIndex < bombs.len)) {
            io::printn(string::tformat("Received bogus-amogus BombExploded message from server. Invalid bomb index %d", bombIndex));
            return false;
        }
        Bomb *bomb = &(*bombs)[bombIndex];
        bomb.lifetime = 0.0;
        bomb.position.x = message.payload[i].x;
        bomb.position.y = message.payload[i].y;
        bomb.position_z = message.payload[i].z;
        explode_bomb({bomb.position.x, bomb.position.y, bomb.position_z}, me.position, particle_pool);
    }

    return true;
}

struct Control {
    int key_code;
    Moving moving;
}

// window.addEventListener('keydown', (e) => console.log(e))
// > keydown { target: body , key: "ArrowDown", charCode: 0, keyCode: 40 }
// > keydown { target: body , key: "ArrowUp", charCode: 0, keyCode: 38 }
// > keydown { target: body , key: "ArrowRight", charCode: 0, keyCode: 39 }
// > keydown { target: body , key: "ArrowLeft", charCode: 0, keyCode: 37 }
// > keydown { target: body , key: "a", charCode: 0, keyCode: 65 }
// > keydown { target: body , key: "s", charCode: 0, keyCode: 83 }
// > keydown { target: body , key: "d", charCode: 0, keyCode: 68 }
// > keydown { target: body , key: "w", charCode: 0, keyCode: 87 }
const Control[*] CONTROL_KEYS = {
    {37, TURNING_LEFT},
    {39, TURNING_RIGHT},
    {38, MOVING_FORWARD},
    {40, MOVING_BACKWARD},
    {65, TURNING_LEFT},
    {68, TURNING_RIGHT},
    {87, MOVING_FORWARD},
    {83, MOVING_BACKWARD},
};

fn bool apply_hello_message_to_me(HelloPlayer hello_player, Item[]* items) {
    // TODO: maybe we should reset everything (bombs, etc) on hello message
    // So to let the server recreate the world properly
    kill_all_items(items);
    me.id         = hello_player.id;
    me.position.x = hello_player.x;
    me.position.y = hello_player.y;
    me.direction  = hello_player.direction;
    me.moving     = 0;
    me.hue        = hello_player.hue;
    return true;
}

fn void apply_players_joined_batch_message(PlayersJoinedBatchMessage *message) {
    usz count = (message.byte_length - PlayersJoinedBatchMessage.sizeof)/PlayerStruct.sizeof;
    for (usz i = 0; i < count; ++i) {
        PlayerStruct *player_struct = &message.payload[i];
        uint id = player_struct.id;
        if (try player = other_players.get_ref(id)) {
            player.position.x = player_struct.x;
            player.position.y = player_struct.y;
            player.direction = player_struct.direction;
            player.moving = player_struct.moving;
            player.hue = player_struct.hue;
        } else if (me.id == id) {
            // Recieved info about ourselves joining. It can actually happen.
            me.position.x = player_struct.x;
            me.position.y = player_struct.y;
            me.direction  = player_struct.direction;
            me.moving     = player_struct.moving;
            me.hue        = player_struct.hue;
        } else {
            other_players.set(id, {
                .id = id,
                .position = {player_struct.x, player_struct.y},
                .direction = player_struct.direction,
                .moving = player_struct.moving,
                .hue = player_struct.hue,
            });
        }
    }
}

fn void apply_players_left_batch_message(PlayersLeftBatchMessage *message) {
    usz count = message.count();
    for (usz i = 0; i < count; ++i) {
        other_players.remove(message.payload[i]);
    }
}

fn bool apply_players_moving_batch_message(PlayersMovingBatchMessage *message) {
    usz count = message.count();
    for (usz i = 0; i < count; ++i) {
        PlayerStruct *player_struct = &message.payload[i];
        uint id = player_struct.id;
        if (try player = other_players.get_ref(id)) {
            player.moving = player_struct.moving;
            player.position.x = player_struct.x;
            player.position.y = player_struct.y;
            player.direction = player_struct.direction;
        } else if (me.id == id) {
            me.moving = player_struct.moving;
            me.position.x = player_struct.x;
            me.position.y = player_struct.y;
            me.direction = player_struct.direction;
        } else {
            io::printn(string::tformat("Received bogus-amogus message from server. We don't know anything about player with id %d", id));
            return false;
        }
    }
    return true;
}

fn uint sprite_angle_index(Vector2 camera_position, Player entity) {
    const float PI =  math::PI;
    const float TAU = 2*math::PI;
    return (uint)math::floor(common::proper_mod(common::proper_mod(entity.direction, TAU) - common::proper_mod(vector2::sub(entity.position, camera_position).angle_fixed(), TAU) - PI + PI/8, TAU)/TAU*SPRITE_ANGLES_COUNT);
}

fn void update_all_players(Scene *scene, float delta_time) {
    other_players.@each_entry(; OtherPlayersEntry *entry) {
        common::update_player(&entry.value, scene, delta_time);
    };
    common::update_player(&me, scene, delta_time);
}

fn void render_other_players(SpritePool *sprite_pool, Image *player_image) {
    other_players.@each_entry(; OtherPlayersEntry *entry) {
        uint index = sprite_angle_index(me.position, entry.value);
        push_sprite(sprite_pool, player_image, {entry.value.position.x, entry.value.position.y, 1}, 1, {55*index, 0}, {55, 55});
    };
}

fn void key_down(uint key_code) @extern("key_down") @wasm {
    foreach (control: CONTROL_KEYS) {
        if (control.key_code == key_code) {
            Moving direction = control.moving;

            if (!platform::is_offline_mode()) {
                platform::send_message(&&AmmaMovingMessage {
                    .byte_length = AmmaMovingMessage.sizeof,
                    .kind = AMMA_MOVING,
                    .payload = {
                        .start = 1,
                        .direction = direction,
                    },
                });
            } else {
                me.moving |= 1<<(uint)direction;
            }
            return;
        }
    }

    const uint KEY_SPACE = 32;
    if (key_code == KEY_SPACE) {
        if (!platform::is_offline_mode()) {
            AmmaThrowingMessage *message = mem::tcalloc(AmmaThrowingMessage.sizeof);
            message.byte_length = AmmaThrowingMessage.sizeof;
            message.kind = AMMA_THROWING;
            platform::send_message(message);
        } else {
            common::throw_bomb(me.position, me.direction, &common::bombs);
        }
    }
}

fn void key_up(uint key_code) @extern("key_up") @wasm {
    foreach (control: CONTROL_KEYS) {
        if (control.key_code == key_code) {
            Moving direction = control.moving;

            if (!platform::is_offline_mode()) {
                platform::send_message(&&AmmaMovingMessage {
                    .byte_length = AmmaMovingMessage.sizeof,
                    .kind = AMMA_MOVING,
                    .payload = {
                        .start = 0,
                        .direction = direction,
                    }
                });
            } else {
                me.moving &= ~(1<<(uint)direction);
            }
            return;
        }
    }
}

fn Asset *asset_by_filename(String filename) {
    foreach (&asset: assets) {
        if (asset.filename == filename) {
            return asset;
        }
    }
    return null;
}

fn void render_game(float delta_time, float time) @extern("render_game") @wasm {
    Asset *asset = null;

    asset = asset_by_filename("assets/images/custom/key.png");
    assert(asset);
    Image key_image = {asset.width, asset.height, (Color*)&pack[asset.offset]};

    asset = asset_by_filename("assets/images/custom/bomb.png");
    assert(asset);
    Image bomb_image = {asset.width, asset.height, (Color*)&pack[asset.offset]};

    asset = asset_by_filename("assets/images/custom/particle.png");
    assert(asset);
    Image particle_image = {asset.width, asset.height, (Color*)&pack[asset.offset]};

    asset = asset_by_filename("assets/images/custom/wall.png");
    assert(asset);
    Image wall_image = {asset.width, asset.height, (Color*)&pack[asset.offset]};

    asset = asset_by_filename("assets/images/custom/player.png");
    assert(asset);
    Image player_image = {asset.width, asset.height, (Color*)&pack[asset.offset]};

    update_all_players(&common::scene, delta_time);
    update_items(&sprite_pool, time, &common::items, &key_image, &bomb_image);
    update_bombs_on_client_side(&sprite_pool, &particle_pool, &bomb_image, &common::scene, delta_time, &common::bombs);
    update_particles(&particle_image, &sprite_pool, delta_time, &common::scene, &particle_pool);

    render_other_players(&sprite_pool, &player_image);

    render_floor_and_ceiling(&display.image);
    render_walls(&display.image, display.zbuffer, &wall_image, &common::scene);
    cull_and_sort_sprites(&sprite_pool);
    render_sprites(&display.image, display.zbuffer, &sprite_pool);

    ping_server_if_needed();
    reset_sprite_pool();
    common::reset_temp_mark();
}

uint ping_cooldown = PING_COOLDOWN;
fn void ping_server_if_needed() {
    if (!platform::is_offline_mode()) {
        ping_cooldown -= 1;
        if (ping_cooldown == 0) {
            platform::send_message(&&PingMessage {
                .byte_length = PingMessage.sizeof,
                .kind = PING,
                .payload = platform::now_msecs(),
            });
            ping_cooldown = PING_COOLDOWN;
        }
    }
}

uint ping = 0;
fn void process_pong_message(PongMessage *message) {
    ping = platform::now_msecs() - message.payload;
}

fn uint ping_msecs() @extern("ping_msecs") @wasm {
    return ping;
}

fn bool process_message(Message *message) @extern("process_message") @wasm {
    if (common::verify_hello_message(message)) {
        apply_hello_message_to_me(((HelloMessage*)message).payload, &common::items);
        return true;
    }
    if (common::verify_players_joined_batch_message(message)) {
        apply_players_joined_batch_message((PlayersJoinedBatchMessage*)message);
        return true;
    }
    if (common::verify_players_left_batch_message(message)) {
        apply_players_left_batch_message((PlayersLeftBatchMessage*)message);
        return true;
    }
    if (common::verify_players_moving_batch_message(message)) {
        if (!apply_players_moving_batch_message((PlayersMovingBatchMessage*)message)) return false;
        return true;
    }
    if (common::verify_pong_message(message)) {
        process_pong_message((PongMessage*)message);
        return true;
    }
    if (common::verify_items_collected_batch_message(message)) {
        if (!apply_items_collected_batch_message((ItemsCollectedBatchMessage*)message, &common::items)) return false;
        return true;
    }
    if (common::verify_items_spawned_batch_message(message)) {
        if (!apply_items_spawned_batch_message((ItemsSpawnedBatchMessage*)message, &common::items)) return false;
        return true;
    }
    if (common::verify_bombs_spawned_batch_message(message)) {
        if (!apply_bombs_spawned_batch_message((BombsSpawnedBatchMessage*)message, &common::bombs)) return false;
        return true;
    }
    if (common::verify_bombs_exploded_batch_message(message)) {
        if (!apply_bombs_exploded_batch_message((BombsExplodedBatchMessage*)message, &common::bombs, &particle_pool)) return false;
        return true;
    }
    // TODO: print the bytes of the bogus amogus message
    io::printn(string::tformat("Received bogus-amogus message from server. %s", message));
    return false;
}

Player me;
def OtherPlayersEntry = Entry(<uint, Player>);
HashMap(<uint, Player>) other_players;

fn uint players_count() @extern("players_count") @wasm {
    return other_players.len() + 1; // +1 including `me`
}

fn void unregister_all_other_players() @extern("unregister_all_other_players") @wasm {
    other_players.clear();
}

fn void entry() @init(2048) @private {
    // NOTE: ideally we need to override os::native_fputc_fn as well
    // because io::printn uses it to print newline at the end of the
    // message. But since js_write() in server.mts is implemented as a
    // single console.log(), that newline is added implicitly anyway.
    os::native_fwrite_fn = fn usz!(void* f, char[] buffer) {
        client::platform::write(&buffer[0], buffer.len);
        return buffer.len;
    };
    common::temp_mark = allocator::temp().used;
    common::load_default_scene();
}

module client::platform;

// WARNING! Must be synchronized with AssetSound in client.mts
enum AssetSound {
    BOMB_BLAST,
    BOMB_RICOCHET,
    ITEM_PICKUP,
}

// TODO: Use std::math::random instead (when you finally figure out how to use it)
extern fn float random() @extern("platform_random");
extern fn void play_sound(AssetSound sound, float player_position_x, float player_position_y, float object_position_x, float object_position_y) @extern("platform_play_sound");
extern fn bool is_offline_mode() @extern("platform_is_offline_mode");
extern fn bool send_message(void *message) @extern("platform_send_message");
extern fn uint now_msecs() @extern("platform_now_msecs");
extern fn void write(void *buffer, usz buffer_sz) @extern("platform_write");
extern fn float atan2f(float y, float x) @extern("platform_atan2f");

// TODO: "magnet" items into the player
// TODO: Blast particles should fade out as they age
// TODO: Bomb collision should take into account the bomb's size
// TODO: Try lighting with normal maps that come with some of the assets
// TODO: Try cel shading the walls (using normals and stuff)
