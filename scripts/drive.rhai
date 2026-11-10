// drive.rhai — the road, the car and the run.
//
// THE TREADMILL. The car never leaves the origin. `pos` is how far it has
// driven; every frame the 64 road tiles are laid out ahead of it from the
// track arrays, the way a scanline racer lays out its strips:
//
//     x = f*f*c0;  dx = -f*c0;            (f = how far into the first tile)
//     for each tile ahead:  place at x;  x += dx;  dx += curve[tile]
//
// so the road is always tangent under the car and bends away ahead of it.
// A tile is never yawed: it is SHEARED sideways by dx/SEG, which keeps road
// edges, grid lines and neighbours continuous however hard the bend. Flint
// has no shear, so each tile is two entities: `seg_i` (yaw + non-uniform
// scale) and its child `tile_i` (yaw + pitch), the SVD of the shear.
//
// Everything published for the HUD and audio goes through the game_state
// component on this entity. Globals are visible only in the callbacks
// (Rhai), which is why on_update is one long function.

import "pools" as pl;

// ── tuning ──────────────────────────────────────────────────────
let SEG = 8.0;               // tile length (tools/gen_tiles.py L)
let ROAD = 6.0;              // road half width
let BACK = 2;                // tiles kept behind the car
let VMAX = 83.0;             // m/s, 299 km/h
let STAGE_SEGS = 500;        // ~4 km a stage
let START_TIME = 70.0;
let EXTEND = [0.0, 58.0, 56.0, 54.0, 52.0];
let STAGE_NAMES = ["SUNSET COAST", "NEON CITY", "PINE RIDGE", "COMPOSITION", "DAYBREAK"];
let CURVE_MAX = [0.075, 0.100, 0.140, 0.150, 0.110];
let HILL_AMP = [9.0, 5.0, 26.0, 14.0, 18.0];
let GEAR_TOP = [0.0, 17.0, 32.0, 48.0, 65.0, 84.0];
let TYPE_NAMES = ["", "palm", "pine", "lamp", "sign", "tower_a", "tower_b", "tower_c", "circle", "triangle", "square"];

// ── palettes, one row a stage ───────────────────────────────────
// Materials are linear colour (x3 ambient = radiance); sky values are
// display colours for styles/horizon.
let P_GRID = [[0.50, 0.03, 0.34], [0.03, 0.34, 0.62], [0.03, 0.50, 0.30], [0.62, 0.50, 0.06], [0.62, 0.26, 0.14]];
let P_EDGE = [[1.00, 0.16, 0.62], [0.16, 0.86, 1.00], [0.50, 1.00, 0.50], [1.00, 0.10, 0.06], [1.00, 0.72, 0.40]];
let P_LANE = [[0.85, 0.80, 1.00], [0.75, 0.90, 1.00], [0.90, 1.00, 0.85], [1.00, 0.95, 0.70], [1.00, 0.92, 0.80]];
let P_SHOULDER = [[0.055, 0.006, 0.055], [0.006, 0.02, 0.07], [0.005, 0.035, 0.028], [0.008, 0.016, 0.10], [0.05, 0.02, 0.026]];
let P_ROAD = [[0.006, 0.003, 0.012], [0.003, 0.004, 0.012], [0.003, 0.007, 0.009], [0.006, 0.006, 0.008], [0.012, 0.007, 0.012]];
let P_GROUND = [[0.010, 0.001, 0.014], [0.001, 0.003, 0.014], [0.001, 0.008, 0.008], [0.004, 0.004, 0.006], [0.016, 0.006, 0.012]];
let P_WIRE = [[0.60, 0.10, 0.70], [0.10, 0.30, 0.90], [0.10, 0.70, 0.50], [0.80, 0.80, 0.70], [0.90, 0.50, 0.40]];
let P_FOG = [[0.30, 0.03, 0.17], [0.02, 0.05, 0.22], [0.02, 0.14, 0.14], [0.05, 0.05, 0.10], [0.50, 0.22, 0.20]];
let S_TOP = [[0.07, 0.02, 0.20], [0.01, 0.01, 0.07], [0.01, 0.05, 0.10], [0.03, 0.03, 0.06], [0.10, 0.14, 0.40]];
let S_LOW = [[0.50, 0.07, 0.40], [0.06, 0.12, 0.42], [0.06, 0.34, 0.36], [0.14, 0.14, 0.30], [0.98, 0.52, 0.42]];
let S_GLOW = [[1.00, 0.36, 0.62], [0.24, 0.50, 1.00], [0.20, 1.00, 0.76], [0.40, 0.48, 1.00], [1.00, 0.80, 0.60]];
let S_SUN_HI = [[1.00, 0.86, 0.28], [0.92, 0.97, 1.00], [1.00, 0.95, 0.64], [1.00, 0.84, 0.10], [1.00, 0.98, 0.86]];
let S_SUN_LO = [[1.00, 0.17, 0.50], [0.34, 0.80, 1.00], [1.00, 0.46, 0.22], [0.92, 0.12, 0.10], [1.00, 0.62, 0.36]];
let S_GROUND = [[0.05, 0.01, 0.07], [0.01, 0.02, 0.07], [0.01, 0.05, 0.05], [0.03, 0.03, 0.04], [0.09, 0.04, 0.07]];
// sun_y, sun_size, sun_gain, stripes, rings, stars, glow_gain, haze
let S_NUM = [
    [0.150, 0.215, 1.15, 1.0, 0.0, 0.70, 1.10, 0.060],
    [0.300, 0.085, 1.20, 0.0, 0.0, 1.50, 0.90, 0.050],
    [0.110, 0.170, 1.00, 1.0, 0.0, 1.10, 1.00, 0.060],
    [0.200, 0.200, 1.15, 0.0, 1.0, 0.45, 0.80, 0.045],
    [0.050, 0.260, 1.10, 0.6, 0.0, 0.12, 1.30, 0.110],
];

// ── state ───────────────────────────────────────────────────────
let ready = false;
let mode = "title";
let mode_t = 0.0;
let auto = false;
let pos = 0.0;
let speed = 0.0;
let px = 0.0;
let steer_s = 0.0;
let time_left = 0.0;
let score = 0.0;
let hi_score = 0.0;
let stage = 0;
let gear = 1;
let rpm = 0.0;
let offroad = 0.0;
let skid = 0.0;
let crash_t = 0.0;
let crash_dir = 1.0;
let shake = 0.0;
let heading = 0.0;
let sun_lean = 0.0;
let count_n = 4;
let near_count = 0;
let ap_lane = 0.0;
let start_pos = 0.0;
let last_sky_key = -1;

// ── track ───────────────────────────────────────────────────────
let t_curve = [];
let t_y = [];
let t_left = [];
let t_right = [];
let t_lo = [];
let t_ro = [];
let stage_start = [];
let gates = [];
let n_seg = 0;

// ── entities ────────────────────────────────────────────────────
let id_seg = [];
let id_tile = [];
let tile_seg = [];
let id_pool = [];
let pool_size = [];
let used_prev = [];
let id_gate = [];
let id_traffic = [];
let id_mount = [];
let id_car = -1;
let vis_x = [];
let vis_dx = [];
let vis_y = [];

// ── traffic ─────────────────────────────────────────────────────
let tr_pos = [];
let tr_x = [];
let tr_v = [];
let tr_side = [];

fn lcg(s) { (s * 1103515245 + 12345) % 2147483648 }
fn unit(s) { s.to_float() / 2147483648.0 }
fn hash01(i, salt) { (((i * 7919 + salt * 104729 + 13) * 2654435761) % 4294967296).to_float() / 4294967296.0 }
fn smooth01(t) { let u = clamp(t, 0.0, 1.0); u * u * (3.0 - 2.0 * u) }
fn mix3(a, b, t) { [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t] }

fn on_init() {
    let me = self_entity();
    let NT = pl::N_TILES;

    // ---- the road: five stages of eased curves and hills ---------
    let seed = 20261109;
    let y = 0.0;
    for i in 0..30 { t_curve.push(0.0); t_y.push(0.0); }
    for s in 0..5 {
        stage_start.push(t_curve.len());
        let n0 = t_curve.len();
        let last_sign = 1.0;
        while t_curve.len() - n0 < STAGE_SEGS {
            seed = lcg(seed); let r_kind = unit(seed);
            seed = lcg(seed); let r_len = unit(seed);
            seed = lcg(seed); let r_mag = unit(seed);
            seed = lcg(seed); let r_sign = unit(seed);
            seed = lcg(seed); let r_hill = unit(seed);
            let enter = 10 + (r_len * 10.0).to_int();
            let hold = 6 + (r_mag * 12.0).to_int();
            let c = 0.0;
            if r_kind > 0.28 {
                let sign = if r_sign > 0.62 { last_sign } else { -last_sign };
                last_sign = sign;
                c = (0.045 + r_mag * CURVE_MAX[s]) * sign;
                hold = 8 + (r_len * 30.0).to_int();
            }
            let dy = (r_hill - 0.5) * 2.0 * HILL_AMP[s];
            // keep the land near sea level so the horizon stays honest
            if y + dy > 40.0 || y + dy < -40.0 { dy = -dy; }
            let n = enter + hold + enter;
            let y0 = y;
            for i in 0..n {
                let k = 1.0;
                if i < enter {
                    k = smooth01(i.to_float() / enter.to_float());
                } else if i >= enter + hold {
                    k = 1.0 - smooth01((i - enter - hold).to_float() / enter.to_float());
                }
                let t = i.to_float() / n.to_float();
                t_curve.push(c * k);
                t_y.push(y0 + dy * (0.5 - 0.5 * cos(PI() * t)));
            }
            y = y0 + dy;
        }
    }
    stage_start.push(t_curve.len());
    // the run-out past the goal: straight, settling flat
    for i in 0..(NT + 140) { t_curve.push(0.0); t_y.push(y); }
    n_seg = t_curve.len() - 1;

    // the first 30 and each gate's 6 tiles are straight and level
    for g in 0..6 {
        let at = stage_start[g];
        gates.push(at);
    }

    // ---- scenery, by stage ---------------------------------------
    for i in 0..t_curve.len() {
        let l = 0; let r = 0; let lo = 10.0; let ro = 10.0;
        let s = 0;
        for q in 1..5 { if i >= stage_start[q] { s = q; } }
        let past_goal = i >= stage_start[5];
        let h1 = hash01(i, 1); let h2 = hash01(i, 2); let h3 = hash01(i, 3);
        let near_gate = false;
        for g in gates { if i > g - 3 && i < g + 3 { near_gate = true; } }
        if !near_gate && i > 6 {
            if s == 0 && !past_goal {
                if i % 4 == 0 { l = 1; r = 1; lo = 9.4 + h1 * 2.6; ro = 9.4 + h2 * 2.6; }
                if i % 44 == 22 { r = 4; ro = 11.5; }
                if i % 44 == 0 { l = 4; lo = 11.5; }
            } else if s == 1 {
                if i % 2 == 0 { l = 5 + (h1 * 2.99).to_int(); lo = 38.0 + h2 * 80.0; }
                else { r = 5 + (h2 * 2.99).to_int(); ro = 38.0 + h1 * 80.0; }
                if i % 10 == 0 { l = 3; lo = 8.6; }
                if i % 10 == 5 { r = 3; ro = 8.6; }
            } else if s == 2 {
                if i % 2 == 0 { l = 2; lo = 9.5 + h1 * h1 * 46.0; }
                else { r = 2; ro = 9.5 + h2 * h2 * 46.0; }
            } else if s == 3 {
                if i % 4 == 0 { l = 8 + (h1 * 2.99).to_int(); lo = 10.5 + h2 * 18.0; }
                if i % 4 == 2 { r = 8 + (h3 * 2.99).to_int(); ro = 10.5 + h1 * 18.0; }
            } else {
                if i % 6 == 0 { l = 1; lo = 9.6 + h1 * 12.0; }
                if i % 6 == 3 { r = 1; ro = 9.6 + h2 * 12.0; }
                if i % 30 == 15 { r = 8 + (h3 * 2.99).to_int(); ro = 22.0 + h1 * 20.0; }
            }
        }
        t_left.push(l); t_right.push(r); t_lo.push(lo); t_ro.push(ro);
    }

    // ---- entities -------------------------------------------------
    for i in 0..NT {
        id_seg.push(get_entity(`seg_${i}`));
        id_tile.push(get_entity(`tile_${i}`));
        tile_seg.push(-1);
        vis_x.push(0.0); vis_dx.push(0.0); vis_y.push(0.0);
    }
    let sizes = pl::pools();
    for t in 0..TYPE_NAMES.len() {
        let ids = [];
        let n = 0;
        if t > 0 {
            n = sizes[TYPE_NAMES[t]];
            for i in 0..n { ids.push(get_entity(`${TYPE_NAMES[t]}_${i}`)); }
        }
        id_pool.push(ids); pool_size.push(n); used_prev.push(n);
    }
    for i in 0..sizes["gate"] { id_gate.push(get_entity(`gate_${i}`)); }
    for i in 0..pl::N_TRAFFIC {
        id_traffic.push(get_entity(`traffic_${i}`));
        tr_pos.push(0.0); tr_x.push(0.0); tr_v.push(40.0); tr_side.push(1.0);
    }
    for i in 0..pl::N_MOUNT { id_mount.push(get_entity(`mount_${i}`)); }
    id_car = get_entity("car");
    // nothing here casts a shadow, and thin neon lines want every sample
    set_quality(#{ shadows: false, msaa: 4 });
    set_material_override(id_car, "tail", 0.55, 0.012, 0.03, 1.0);
    set_material_override(id_car, "body", 0.030, 0.003, 0.010, 1.0);
    for id in id_traffic { set_material_override(id, "tail", 0.50, 0.01, 0.02, 1.0); }

    // ---- run ------------------------------------------------------
    let hs = persist_get("hi_score");
    if hs != () { hi_score = hs; }
    start_pos = 8.0 * SEG + 2.0;
    pos = start_pos;
    auto = get_field(me, "game_state", "autopilot");
    if auto {
        let ss = get_field(me, "game_state", "start_stage");
        stage = ss;
        pos = (stage_start[ss] + 60).to_float() * SEG;
        speed = get_field(me, "game_state", "start_speed");
        mode = "drive";
        time_left = 60.0;
    }
    for i in 0..tr_pos.len() {
        tr_pos[i] = pos + 120.0 + i.to_float() * 95.0 + hash01(i, 9) * 60.0;
        tr_x[i] = ((hash01(i, 5) * 2.99).to_int() - 1).to_float() * 4.0;
        tr_v[i] = 30.0 + hash01(i, 7) * 18.0;
    }
    ready = true;
}

fn on_update() {
    if !ready { return; }
    let me = self_entity();
    let dt = min(delta_time(), 0.05);
    let now = total_time();
    let NT = pl::N_TILES;
    let NTR = tr_pos.len();
    mode_t += dt;
    let ev = "";
    let ev_val = 0.0;

    // ═══ mode ═══════════════════════════════════════════════════
    let start_pressed = is_action_just_pressed("start");
    if mode == "title" {
        if start_pressed && mode_t > 0.4 {
            mode = "countdown"; mode_t = 0.0; count_n = 4;
            pos = start_pos; speed = 0.0; px = 0.0; steer_s = 0.0; stage = 0;
            time_left = START_TIME; score = 0.0; near_count = 0; crash_t = 0.0; heading = 0.0;
            for i in 0..NTR {
                tr_pos[i] = pos + 160.0 + i.to_float() * 110.0 + hash01(i, 9) * 70.0;
                tr_x[i] = ((hash01(i, 5) * 2.99).to_int() - 1).to_float() * 4.0;
            }
            ev = "start";
        }
    } else if mode == "countdown" {
        let n = 3 - (mode_t / 0.9).to_int();
        if n < count_n {
            count_n = n;
            if n > 0 { ev = "count"; ev_val = n.to_float(); }
            else { ev = "go"; mode = "drive"; mode_t = 0.0; }
        }
    } else if mode == "drive" {
        if !auto {
            time_left -= dt;
            if time_left <= 0.0 { time_left = 0.0; mode = "over"; mode_t = 0.0; ev = "over"; }
            if is_action_just_pressed("restart") { mode = "title"; mode_t = 0.0; }
        }
    } else {
        // over | finish: coast, then back to the title
        if (start_pressed && mode_t > 1.5) || mode_t > 14.0 { mode = "title"; mode_t = 0.0; }
    }
    let driving = mode == "drive";
    let self_drive = auto || mode == "title";

    // ═══ where on the road ══════════════════════════════════════
    let basef = pos / SEG;
    let base = basef.to_int();
    let f = basef - base.to_float();
    let c0 = t_curve[base] + (t_curve[base + 1] - t_curve[base]) * f;
    let sp = speed / VMAX;

    // ═══ input ══════════════════════════════════════════════════
    let in_steer = 0.0; let in_gas = 0.0; let in_brake = 0.0;
    if self_drive {
        // pick the lane with the clearest road ahead
        let best = ap_lane; let best_cost = 1000000.0;
        for li in 0..3 {
            let lx = (li - 1).to_float() * 4.0;
            let cost = abs(lx - px) * 0.12;
            if abs(lx - ap_lane) > 1.0 { cost += 0.8; }
            for t in 0..NTR {
                let rel = tr_pos[t] - pos;
                if rel > -6.0 && rel < 130.0 && abs(tr_x[t] - lx) < 2.6 { cost += 6.0 + (130.0 - rel) * 0.08; }
            }
            if cost < best_cost { best_cost = cost; best = lx; }
        }
        ap_lane = best;
        let hold = c0 * 62.0 * sp * sp / (4.0 + 10.0 * sp);
        in_steer = clamp((ap_lane - px) * 0.30 + hold, -1.0, 1.0);
        in_gas = 1.0;
        let cap = if mode == "title" { 52.0 } else { VMAX };
        if speed > cap { in_gas = 0.0; }
        for t in 0..NTR {
            let rel = tr_pos[t] - pos;
            let closing = speed - tr_v[t];
            if rel > 0.0 && closing > 0.0 && rel < 14.0 + closing * closing / 36.0 && abs(tr_x[t] - px) < 2.5 { in_gas = 0.0; in_brake = 1.0; }
        }
    } else if driving {
        in_steer = clamp(action_value("steer"), -1.0, 1.0);
        in_gas = clamp(action_value("accelerate"), 0.0, 1.0);
        in_brake = clamp(action_value("brake"), 0.0, 1.0);
    }
    if crash_t > 0.0 { in_steer = 0.0; in_gas = 0.0; in_brake = 0.0; }

    // ═══ car ════════════════════════════════════════════════════
    let was_gear = gear;
    if mode == "countdown" {
        // revving on the line
        rpm = 0.30 + 0.25 * (0.5 + 0.5 * sin(now * 9.0)) * clamp(action_value("accelerate") + 0.4, 0.0, 1.0);
        speed = 0.0;
    } else {
        let acc = 0.0;
        if in_gas > 0.0 { acc += in_gas * 17.0 * (1.0 - sp * sqrt(max(sp, 0.0))); }
        else { acc -= 3.5 + 6.0 * sp; }
        acc -= in_brake * 44.0;
        let off = abs(px) > ROAD + 0.9;
        if off && speed > 26.0 { acc -= 34.0; }
        if mode == "over" || mode == "finish" { acc = -16.0 - 20.0 * sp; }
        if crash_t > 0.0 { acc = -speed * 2.6 - 6.0; }
        speed = clamp(speed + acc * dt, 0.0, VMAX);
        offroad += ((if off && speed > 3.0 { 1.0 } else { 0.0 }) - offroad) * min(1.0, dt * 8.0);

        steer_s += (in_steer - steer_s) * min(1.0, dt * 8.5);
        let grip = min(1.0, speed / 9.0);
        let lat = steer_s * (4.0 + 10.0 * sp) * grip;
        let push = c0 * 62.0 * sp * sp;
        px += (lat - push) * dt;
        skid += (clamp((abs(push) - 7.0) / 7.0, 0.0, 1.0) * clamp(abs(steer_s) * 1.4, 0.0, 1.0) - skid) * min(1.0, dt * 6.0);
        if crash_t > 0.0 {
            crash_t -= dt;
            let home = clamp(px, -4.0, 4.0);
            px += (home - px) * min(1.0, dt * 2.2);
        }
        px = clamp(px, -23.0, 23.0);
        pos += speed * dt;
        // gears, for the ear and the dash
        gear = 1;
        for g in 1..5 { if speed > GEAR_TOP[g] - 0.5 { gear = g + 1; } }
        if was_gear > gear && speed > GEAR_TOP[gear] - 3.0 { gear = was_gear; }
        let lo = GEAR_TOP[gear - 1] * 0.72; let hi = GEAR_TOP[gear];
        rpm = clamp(0.22 + 0.78 * (speed - lo) / (hi - lo), 0.12, 1.0);
        if driving { score += speed * dt * (1.0 + sp) * 6.0; }
    }
    if gear != was_gear && mode != "countdown" { set_field(me, "game_state", "shifted", now); }

    // the road ends: the title loops, a run finishes
    if mode == "title" && pos > (stage_start[5] - 20).to_float() * SEG { pos = start_pos; }
    if pos > (n_seg - NT - 6).to_float() * SEG { pos = (n_seg - NT - 6).to_float() * SEG; speed = 0.0; }

    // checkpoints
    basef = pos / SEG;
    base = basef.to_int();
    f = basef - base.to_float();
    if stage < 5 && base >= stage_start[stage + 1] {
        stage += 1;
        if stage >= 5 {
            if driving && !auto {
                mode = "finish"; mode_t = 0.0; ev = "finish";
                ev_val = floor(time_left * 10.0) * 1000.0;
                score += ev_val;
            }
            stage = 5;
        } else if driving {
            time_left += EXTEND[stage];
            ev = "checkpoint"; ev_val = EXTEND[stage];
        }
    }
    if mode == "title" && stage >= 5 { stage = 0; }
    if (mode == "over" || mode == "finish") && mode_t < 0.02 && score > hi_score {
        hi_score = score; persist_set("hi_score", hi_score);
    }
    let stage_i = min(stage.to_float(), 4.0).to_int();
    let py = t_y[base] + (t_y[base + 1] - t_y[base]) * f;
    let slope0 = (t_y[base + 1] - t_y[base]) / SEG;

    // ═══ lay the road ═══════════════════════════════════════════
    let cb = t_curve[base];
    let dx = -f * cb;
    let x = f * f * cb;
    // behind the car
    let bx = x; let bdx = dx;
    for k in 1..(BACK + 1) {
        bdx -= t_curve[base - k];
        bx -= bdx;
        vis_x[BACK - k] = bx; vis_dx[BACK - k] = bdx; vis_y[BACK - k] = t_y[base - k] - py;
    }
    for k in 0..(NT - BACK) {
        let sg = base + k;
        vis_x[BACK + k] = x; vis_dx[BACK + k] = dx; vis_y[BACK + k] = t_y[sg] - py;
        x += dx;
        dx += t_curve[sg];
    }
    for kk in 0..NT {
        let k = kk - BACK;
        let sg = base + k;
        let j = sg % NT;
        let s = vis_dx[kk] / SEG;
        // shear [[1,-s],[0,1]] = Rot(phi) * diag(sx, sz) * Rot(theta)
        let q = sqrt(1.0 + s * s * 0.25);
        let r = abs(s) * 0.5;
        let a1 = if s > 0.0 { -0.5 * PI() } else if s < 0.0 { 0.5 * PI() } else { 0.0 };
        let a2 = atan2(s * 0.5, 1.0);
        let theta = (a2 - a1) * 0.5;
        let phi = (a2 + a1) * 0.5;
        let seg_id = id_seg[j];
        set_position(seg_id, vis_x[kk], vis_y[kk], -(k.to_float() - f) * SEG);
        set_rotation(seg_id, 0.0, rad_to_deg(-phi), 0.0);
        set_field(seg_id, "transform", "scale", [q + r, 1.0, q - r]);
        let pitch = atan2(t_y[sg + 1] - t_y[sg], SEG);
        let hb = -theta * 0.5; let hp = pitch * 0.5;
        set_rotation_quat(id_tile[j], cos(hb) * sin(hp), sin(hb) * cos(hp), -sin(hb) * sin(hp), cos(hb) * cos(hp));

        // a tile that just came round to the horizon takes the colours of
        // the stage it now lies in: a new stage arrives from the distance
        if tile_seg[j] != sg {
            tile_seg[j] = sg;
            let s0 = 0;
            for qn in 1..5 { if sg >= stage_start[qn] { s0 = qn; } }
            let s1 = min((s0 + 1).to_float(), 4.0).to_int();
            let t = smooth01((sg - (stage_start[s0 + 1] - 56)).to_float() / 56.0);
            if s0 == 4 { t = 0.0; }
            let tid = id_tile[j];
            let c = mix3(P_GRID[s0], P_GRID[s1], t);     set_material_override(tid, "grid", c[0], c[1], c[2], 1.0);
            c = mix3(P_EDGE[s0], P_EDGE[s1], t);         set_material_override(tid, "edge", c[0], c[1], c[2], 1.0);
            c = mix3(P_LANE[s0], P_LANE[s1], t);         set_material_override(tid, "lane", c[0], c[1], c[2], 1.0);
            c = mix3(P_SHOULDER[s0], P_SHOULDER[s1], t); set_material_override(tid, "shoulder", c[0], c[1], c[2], 1.0);
            c = mix3(P_ROAD[s0], P_ROAD[s1], t);         set_material_override(tid, "road", c[0], c[1], c[2], 1.0);
            c = mix3(P_GROUND[s0], P_GROUND[s1], t);     set_material_override(tid, "ground", c[0], c[1], c[2], 1.0);
        }
    }

    // ═══ scenery ════════════════════════════════════════════════
    let used = [];
    for t in 0..TYPE_NAMES.len() { used.push(0); }
    let hit_prop = false;
    for kk in BACK..(NT - 1) {
        let k = kk - BACK;
        let sg = base + k;
        let z = -(k.to_float() - f) * SEG;
        for side in 0..2 {
            let ty = if side == 0 { t_left[sg] } else { t_right[sg] };
            if ty > 0 {
                let n = used[ty];
                if n < pool_size[ty] {
                    let off = if side == 0 { -t_lo[sg] } else { t_ro[sg] };
                    let wx = vis_x[kk] + off;
                    let id = id_pool[ty][n];
                    set_position(id, wx, vis_y[kk], z);
                    let yaw = hash01(sg, 11 + side) * 360.0;
                    if ty == 3 { yaw = if side == 0 { 180.0 } else { 0.0 }; }
                    if ty == 4 || ty >= 8 { yaw = (hash01(sg, 4) - 0.5) * 24.0; }
                    if ty >= 5 && ty <= 7 { yaw = (hash01(sg, 4) * 3.99).to_int().to_float() * 90.0; }
                    set_rotation(id, 0.0, yaw, 0.0);
                    used[ty] = n + 1;
                    if k <= 1 && abs(z) < 2.4 && ty != 3 && ty < 5 && abs(px - wx) < 1.5 { hit_prop = true; }
                    if k <= 1 && abs(z) < 2.4 && ty >= 8 && abs(px - wx) < 1.0 { hit_prop = true; }
                    if k <= 1 && abs(z) < 2.4 && ty == 3 && abs(px - wx) < 0.9 { hit_prop = true; }
                }
            }
        }
    }
    for t in 1..TYPE_NAMES.len() {
        for n in used[t]..used_prev[t] { set_position(id_pool[t][n], 0.0, -1000.0, 0.0); }
        used_prev[t] = used[t];
    }
    // gates
    let gn = 0;
    for g in gates {
        let k = g - base;
        if k > -BACK && k < NT - BACK - 1 && gn < id_gate.len() {
            let kk = k + BACK;
            set_position(id_gate[gn], vis_x[kk], vis_y[kk], -(k.to_float() - f) * SEG);
            set_rotation(id_gate[gn], 0.0, -rad_to_deg(atan2(vis_dx[kk], SEG)), 0.0);
            gn += 1;
        }
    }
    for n in gn..id_gate.len() { set_position(id_gate[n], 0.0, -1000.0, 0.0); }

    // ═══ traffic ════════════════════════════════════════════════
    let reach = (NT - BACK - 3).to_float() * SEG;
    for t in 0..NTR {
        tr_pos[t] += tr_v[t] * dt;
        let rel = tr_pos[t] - pos;
        if rel < -40.0 || rel > 1400.0 {
            // come back in over the horizon
            tr_pos[t] = pos + reach + 40.0 + random() * 520.0;
            tr_x[t] = ((random() * 2.99).to_int() - 1).to_float() * 4.0;
            tr_v[t] = 28.0 + random() * 20.0;
            tr_side[t] = 1.0;
            rel = tr_pos[t] - pos;
        }
        // overtaken: a close pass is worth something
        let side_now = if rel >= 0.0 { 1.0 } else { -1.0 };
        if side_now < 0.0 && tr_side[t] > 0.0 && driving && crash_t <= 0.0 {
            let gap = abs(px - tr_x[t]);
            if gap < 3.3 && speed - tr_v[t] > 12.0 {
                near_count += 1;
                ev = "near_miss"; ev_val = 500.0 + floor(sp * 10.0) * 100.0;
                score += ev_val;
            } else if gap < 6.5 { if ev == "" { ev = "pass"; } }
        }
        tr_side[t] = side_now;
        let id = id_traffic[t];
        if rel > -(BACK.to_float() - 0.2) * SEG && rel < reach {
            let kf = rel / SEG + f;
            let k = floor(kf).to_int();
            let fr = kf - k.to_float();
            let kk = k + BACK;
            let wx = vis_x[kk] + vis_dx[kk] * fr + tr_x[t];
            let wy = vis_y[kk] + (vis_y[kk + 1] - vis_y[kk]) * fr;
            set_position(id, wx, wy, -rel);
            set_rotation(id, rad_to_deg(atan2(vis_y[kk + 1] - vis_y[kk], SEG)), -rad_to_deg(atan2(vis_dx[kk], SEG)), 0.0);
            // contact
            if abs(rel) < 4.3 && abs(px - wx) < 1.85 && crash_t <= 0.0 && mode != "countdown" {
                if speed - tr_v[t] > 24.0 {
                    crash_t = 1.5; crash_dir = if px > wx { 1.0 } else { -1.0 };
                    ev = "crash"; shake = 1.0;
                    tr_v[t] = min(tr_v[t] + 14.0, 60.0);
                } else if speed > tr_v[t] - 2.0 {
                    speed = max(tr_v[t] - 4.0, 0.0);
                    px += (if px > wx { 1.0 } else { -1.0 }) * 0.5;
                    if ev == "" { ev = "bump"; }
                    shake = max(shake, 0.5);
                    tr_pos[t] += 3.0;
                }
            }
        } else {
            set_position(id, 0.0, -1000.0, 0.0);
        }
    }
    if hit_prop && crash_t <= 0.0 && speed > 8.0 && mode != "title" {
        crash_t = 1.7; crash_dir = if px > 0.0 { -1.0 } else { 1.0 };
        ev = "crash"; shake = 1.0;
    }

    // ═══ the car ════════════════════════════════════════════════
    let spin = 0.0;
    if crash_t > 0.0 { spin = crash_dir * 720.0 * smooth01(1.0 - crash_t / 1.6); }
    let rumble = offroad * sp * 0.05 * sin(now * 61.0);
    set_position(id_car, px, rumble, 0.0);
    set_rotation(id_car, rad_to_deg(atan2(slope0, 1.0)), -steer_s * (5.0 + 9.0 * skid) + spin, -steer_s * 2.2 * sp);

    // ═══ mountains, sun, sky ════════════════════════════════════
    heading += c0 * speed * dt * 0.6;
    let ring = pl::N_MOUNT.to_float() * 315.0;
    for i in 0..id_mount.len() {
        let mx = i.to_float() * 315.0 - heading;
        mx = mx - floor(mx / ring) * ring - ring * 0.5;
        set_position(id_mount[i], mx, -6.0 - py * 0.15, -640.0);
        set_field(id_mount[i], "transform", "scale", [0.45, 0.45 + 0.1 * hash01(i, 3), 0.45]);
    }
    sun_lean += (-c0 * 1.5 * sp - sun_lean) * min(1.0, dt * 1.6);

    // the sky runs a little ahead of the tiles under the car
    let sgs = base + 26;
    let k0 = 0;
    for qn in 1..5 { if sgs >= stage_start[qn] { k0 = qn; } }
    let k1 = min((k0 + 1).to_float(), 4.0).to_int();
    let kt = smooth01((sgs - (stage_start[k0 + 1] - 70)).to_float() / 70.0);
    if k0 == 4 { kt = 0.0; }
    set_post_style_param("horizon", "sky_top", mix3(S_TOP[k0], S_TOP[k1], kt));
    set_post_style_param("horizon", "sky_low", mix3(S_LOW[k0], S_LOW[k1], kt));
    set_post_style_param("horizon", "glow", mix3(S_GLOW[k0], S_GLOW[k1], kt));
    set_post_style_param("horizon", "sun_hi", mix3(S_SUN_HI[k0], S_SUN_HI[k1], kt));
    set_post_style_param("horizon", "sun_lo", mix3(S_SUN_LO[k0], S_SUN_LO[k1], kt));
    set_post_style_param("horizon", "ground", mix3(S_GROUND[k0], S_GROUND[k1], kt));
    let na = S_NUM[k0]; let nb = S_NUM[k1];
    // the last stage's sun climbs as the goal comes up
    let rise = 0.0;
    if k0 == 4 { rise = 0.12 * clamp((base - stage_start[4]).to_float() / STAGE_SEGS.to_float(), 0.0, 1.0); }
    set_post_style_param("horizon", "sun_y", na[0] + (nb[0] - na[0]) * kt + rise - slope0 * 0.0);
    set_post_style_param("horizon", "sun_size", na[1] + (nb[1] - na[1]) * kt);
    set_post_style_param("horizon", "sun_gain", na[2] + (nb[2] - na[2]) * kt);
    set_post_style_param("horizon", "stripes", na[3] + (nb[3] - na[3]) * kt);
    set_post_style_param("horizon", "rings", na[4] + (nb[4] - na[4]) * kt);
    set_post_style_param("horizon", "stars", na[5] + (nb[5] - na[5]) * kt);
    set_post_style_param("horizon", "glow_gain", na[6] + (nb[6] - na[6]) * kt);
    set_post_style_param("horizon", "haze", na[7] + (nb[7] - na[7]) * kt);
    set_post_style_param("horizon", "sun_x", sun_lean);
    set_post_style_param("horizon", "stripe_phase", now * 0.10);
    let fog = mix3(P_FOG[k0], P_FOG[k1], kt);
    set_fog_color(fog[0], fog[1], fog[2]);
    // the slow things: only when the blend has moved a step
    let sky_key = k0 * 100 + (kt * 40.0).to_int();
    let accent = mix3(P_EDGE[k0], P_EDGE[k1], kt);
    let second = mix3(P_GRID[k0], P_GRID[k1], kt);
    if sky_key != last_sky_key {
        last_sky_key = sky_key;
        let w = mix3(P_WIRE[k0], P_WIRE[k1], kt);
        for id in id_mount { set_material_override(id, "wire", w[0], w[1], w[2], 1.0); }
        set_material_override(id_car, "under", accent[0] * 0.035, accent[1] * 0.035, accent[2] * 0.035, 1.0);
        set_material_override(id_car, "trim", accent[0] * 0.6, accent[1] * 0.6, accent[2] * 0.6, 1.0);
        for id in id_gate { set_material_override(id, "neon", accent[0], accent[1], accent[2], 1.0); }
    }

    // ═══ camera ═════════════════════════════════════════════════
    shake = max(0.0, shake - dt * 1.8);
    let jx = (shake * 0.35 + offroad * sp * 0.07) * sin(now * 47.0);
    let jy = (shake * 0.28 + offroad * sp * 0.09) * sin(now * 59.0 + 1.3);
    let ahead = vis_x[BACK + 5];
    let rise5 = vis_y[BACK + 6];
    if mode == "title" {
        let a = now * 0.16;
        set_camera_position(px + 6.4 * sin(a), 1.25 + 0.75 * (1.0 + sin(now * 0.11)), 4.0 + 5.2 * cos(a) + 3.0);
        set_camera_target(px + ahead * 0.3, 0.9 + rise5 * 0.3, -14.0);
        set_camera_fov(58.0);
        set_camera_roll(0.0);
    } else {
        set_camera_position(px * 0.80 + jx, 2.30 + jy + rise5 * 0.06, 7.4 - sp * 0.5);
        set_camera_target(px * 0.56 + ahead * 0.55 + jx, 1.05 + rise5 * 0.55 + jy, -30.0);
        set_camera_fov(60.0 + 15.0 * sp * sp);
        set_camera_roll(-steer_s * 0.018 * sp - c0 * 0.13 * sp);
    }
    set_radial_blur(clamp((sp - 0.6) * 0.3, 0.0, 0.10));
    set_post_style_param("crt", "aberration", 0.5 + 1.6 * sp * sp + shake * 3.0);

    // ═══ publish ════════════════════════════════════════════════
    set_field(me, "game_state", "mode", mode);
    set_field(me, "game_state", "mode_time", mode_t);
    set_field(me, "game_state", "speed", speed);
    set_field(me, "game_state", "speed_kmh", speed * 3.6);
    set_field(me, "game_state", "rpm", rpm);
    set_field(me, "game_state", "gear", gear);
    set_field(me, "game_state", "throttle", in_gas);
    set_field(me, "game_state", "steer", steer_s);
    set_field(me, "game_state", "time_left", time_left);
    set_field(me, "game_state", "score", score);
    set_field(me, "game_state", "hi_score", hi_score);
    set_field(me, "game_state", "stage", stage_i);
    set_field(me, "game_state", "stage_name", STAGE_NAMES[stage_i]);
    let s_lo = stage_start[stage_i]; let s_hi = stage_start[stage_i + 1];
    set_field(me, "game_state", "stage_progress", clamp((basef - s_lo.to_float()) / (s_hi - s_lo).to_float(), 0.0, 1.0));
    set_field(me, "game_state", "run_progress", clamp((basef - stage_start[0].to_float()) / (stage_start[5] - stage_start[0]).to_float(), 0.0, 1.0));
    set_field(me, "game_state", "offroad", offroad);
    set_field(me, "game_state", "skid", skid);
    set_field(me, "game_state", "crash", max(crash_t, 0.0));
    set_field(me, "game_state", "countdown", count_n);
    set_field(me, "game_state", "near_count", near_count);
    set_field(me, "game_state", "accent_r", accent[0]);
    set_field(me, "game_state", "accent_g", accent[1]);
    set_field(me, "game_state", "accent_b", accent[2]);
    set_field(me, "game_state", "second_r", second[0]);
    set_field(me, "game_state", "second_g", second[1]);
    set_field(me, "game_state", "second_b", second[2]);
    if ev != "" {
        set_field(me, "game_state", "event", ev);
        set_field(me, "game_state", "event_time", now);
        set_field(me, "game_state", "event_value", ev_val);
    }
}
