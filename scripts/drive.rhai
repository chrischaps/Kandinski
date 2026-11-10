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
// THE CAR is a road-relative single-track ("bicycle") model, so it fits the
// treadmill: forward speed `speed`, lateral offset `px`, heading `yaw` and
// travel angle `dir` (both measured from the road tangent, + = right), and
// an inertial yaw rate `yawr`. Slip = yaw - dir. Each sub-step
//
//     kappa = curve / SEG^2                      (the road's curvature, rad/m)
//     yaw  += (yawr            - kappa v cos dir) h
//     dir  += ((ay cos b + ax sin b) / v - kappa v cos dir) h
//     px   += v sin dir h ;  pos += v cos dir h
//
// the road turns under the car, so a bend has to be steered. ay comes from
// two axles, each a saturating tyre  F = D sat(C alpha / D)  on its own slip
// angle; D is the grip the axle has right now (speed, surface, crest load,
// weight transfer, handbrake, power). Front runs out first: understeer.
// Cut the rear: the tail steps out. Assists make that playable (see ASSISTS).
//
// Everything published for the HUD and audio goes through the game_state
// component on this entity. Globals are visible only in the callbacks
// (Rhai), which is why on_update is one long function.

import "pools" as pl;
import "tour" as tour;

// ── tuning: the world ───────────────────────────────────────────
let SEG = 8.0;               // tile length (tools/gen_tiles.py L)
let ROAD = 6.0;              // road half width
let BACK = 2;                // tiles kept behind the car
let VMAX = 83.3;             // m/s, 300 km/h: the unboosted top speed, and the unit of `sp`
let N_RIVAL = 5;
let RV_POWER = 385.0;        // rivals: thrust x speed, m^2/s^3 (a skill-1 rival tops out near 297 km/h)
let RV_GRIP = 1.0;            // rivals: corner speed^2 against the autopilot's plan at skill 1
let RV_BAND = 0.03;          // rivals: pace given or taken once 300 m from the player
let RV_LAUNCH = 9.6;         // rivals: the most they accelerate off the line, m/s^2
let HORIZON_ORDER = [0, 5, 1, 7, 2, 6, 3, 4];   // the themes HORIZON cycles through
let TYPE_NAMES = ["", "palm", "pine", "lamp", "sign", "tower_a", "tower_b", "tower_c", "circle", "triangle", "square"];

// ── tuning: the car (SI units; accelerations in m/s^2) ──────────
let G = 9.81;
// engine and gearbox
let GEAR_V = [0.0, 17.5, 28.5, 40.5, 54.0, 69.0, 98.0];   // redline speed of each gear, m/s
let ENG_A1 = 30.0;           // thrust at the torque peak in 1st (traction caps it: wheelspin)
let SHIFT_T = 0.13;          // power cut on an upshift, s
let TRAC_G = 1.12;           // launch traction limit, g
let DRAG = 0.000660;         // aero: a = DRAG v^2 (sets the 300 km/h top speed)
let ROLL_A = 0.25;           // rolling resistance
let ENG_BRAKE0 = 0.8;        // engine braking off the throttle: ENG_BRAKE0 + ENG_BRAKE1 * rpm
let ENG_BRAKE1 = 2.2;
let BRAKE_G = 1.65;          // brakes, g at low speed (downforce adds BRAKE_DF at VMAX)
let BRAKE_DF = 0.55;
let HB_DECEL = 3.5;          // what the handbrake itself slows the car by
let BOOST_MUL = 0.90;        // extra engine thrust while boosting (about +45 km/h)
let BOOST_DRAIN = 0.28;      // meter per second while held (a full meter: 3.6 s)
// tyres
let MU = 1.42;               // peak lateral grip of an axle, g at low speed
let MU_DF = 0.18;            // downforce: grip x (1 + MU_DF) at VMAX
let FRONT = 0.93;            // front axle's share of that: under 1 = terminal understeer
let CORNER = 300.0;          // cornering stiffness, m/s^2 per rad of slip
let WB_A = 1.32;             // CG to front axle, m (the hubs in tools/build_scene.py)
let WB_B = 1.28;             // CG to rear axle
let KYAW = 0.42;             // yaw acceleration per m/s^2 of front-rear imbalance
let OFF_GRIP = 0.45;         // grip lost off the road
let WT = 0.16;               // weight transfer: axle grip change per g of longitudinal accel
let HB_CUT = 0.62;           // rear grip the handbrake takes
let PWR_CUT = 0.32;          // rear grip full traction-limited power takes
let SPIN_CUT = 0.35;         // and what spinning the rear wheels up takes on top
let DRIFT_REAR = 0.14;       // rear grip the throttle keeps off while sliding (holds a drift)
let SCRUB = 0.7;             // how much of the tyres' drag a slide costs (1 = physical)
// steering
let STEER_ASK = 1.12;        // full lock asks for this x the front's grip
let STEER_MAX = 0.50;        // rad at the wheels, low speed
let LOCK_SLIP = 0.022;       // rad more at full lock (x steer^3), the slip the front needs to reach its peak
let KEY_IN = 4.0;            // keyboard: lock per second applying (full in 0.25 s)
let KEY_OUT = 8.0;           //           and releasing
// ASSISTS
let YAW_DAMP = 1.0;          // yaw damping, 1/s
let YAW_DAMP_SLIDE = 4.5;    // damping of the slip RATE per unit of slide (0-1); the handbrake lifts 60% of it
let CASTER = 1.45;           // front wheels follow the travel direction in a slide (>1: steer in to hold)
let SLIP_DEAD = 0.05;        // rad of slip the caster ignores (grip driving)
let DRIFT_LOCK = 0.11;       // rad of extra lock the driver has while sliding
let SLIP_SOFT = 0.50;        // rad: a soft wall pushes back past this
let SLIP_SPIN = 0.68;        // rad (39 deg): past this it is a spin-out
// body
let ROLL_K = 0.0032;         // rad of roll per m/s^2 (shown roll is capped at 3 deg)
let PITCH_K = 0.0017;        // rad of pitch per m/s^2 (shown pitch is capped at 2 deg)
let AIR_LOAD = 0.50;         // under this much load over a crest the car counts as flying
let HEAVE_K = 0.040;         // m per g of load
let ARCH = 0.10;             // m a wheel may travel in its arch: roll, pitch and heave share it
// scoring
let DRIFT_ON = 0.14;         // rad of slip that counts as a drift
let DRIFT_K = 0.35;          // points per degree x m/s x second

// ── palettes, one row a theme (scripts/lib/tour.rhai names them) ───────────────────────────────────
// Materials are linear colour (x3 ambient = radiance); sky values are
// display colours for styles/horizon.
let P_GRID = [[0.50, 0.03, 0.34], [0.03, 0.34, 0.62], [0.03, 0.50, 0.30], [0.62, 0.50, 0.06], [0.62, 0.26, 0.14], [0.10, 0.22, 0.50], [0.30, 0.10, 0.60], [0.42, 0.06, 0.62]];
let P_EDGE = [[1.00, 0.16, 0.62], [0.16, 0.86, 1.00], [0.50, 1.00, 0.50], [1.00, 0.10, 0.06], [1.00, 0.72, 0.40], [0.75, 0.90, 1.00], [0.30, 1.00, 0.60], [0.80, 0.40, 1.00]];
let P_LANE = [[0.85, 0.80, 1.00], [0.75, 0.90, 1.00], [0.90, 1.00, 0.85], [1.00, 0.95, 0.70], [1.00, 0.92, 0.80], [0.90, 0.95, 1.00], [0.85, 1.00, 0.95], [0.95, 0.85, 1.00]];
let P_SHOULDER = [[0.055, 0.006, 0.055], [0.006, 0.02, 0.07], [0.005, 0.035, 0.028], [0.008, 0.016, 0.10], [0.05, 0.02, 0.026], [0.012, 0.020, 0.050], [0.020, 0.008, 0.050], [0.030, 0.006, 0.070]];
let P_ROAD = [[0.006, 0.003, 0.012], [0.003, 0.004, 0.012], [0.003, 0.007, 0.009], [0.006, 0.006, 0.008], [0.012, 0.007, 0.012], [0.003, 0.004, 0.010], [0.004, 0.003, 0.010], [0.005, 0.003, 0.012]];
let P_GROUND = [[0.010, 0.001, 0.014], [0.001, 0.003, 0.014], [0.001, 0.008, 0.008], [0.004, 0.004, 0.006], [0.016, 0.006, 0.012], [0.002, 0.004, 0.012], [0.004, 0.002, 0.012], [0.008, 0.001, 0.018]];
let P_WIRE = [[0.60, 0.10, 0.70], [0.10, 0.30, 0.90], [0.10, 0.70, 0.50], [0.80, 0.80, 0.70], [0.90, 0.50, 0.40], [0.35, 0.50, 0.80], [0.30, 0.90, 0.60], [0.50, 0.20, 0.90]];
let P_FOG = [[0.30, 0.03, 0.17], [0.02, 0.05, 0.22], [0.02, 0.14, 0.14], [0.05, 0.05, 0.10], [0.50, 0.22, 0.20], [0.03, 0.06, 0.16], [0.05, 0.10, 0.14], [0.12, 0.03, 0.26]];
let S_TOP = [[0.07, 0.02, 0.20], [0.01, 0.01, 0.07], [0.01, 0.05, 0.10], [0.03, 0.03, 0.06], [0.10, 0.14, 0.40], [0.01, 0.015, 0.06], [0.05, 0.01, 0.14], [0.03, 0.00, 0.10]];
let S_LOW = [[0.50, 0.07, 0.40], [0.06, 0.12, 0.42], [0.06, 0.34, 0.36], [0.14, 0.14, 0.30], [0.98, 0.52, 0.42], [0.08, 0.16, 0.36], [0.05, 0.50, 0.32], [0.30, 0.06, 0.55]];
let S_GLOW = [[1.00, 0.36, 0.62], [0.24, 0.50, 1.00], [0.20, 1.00, 0.76], [0.40, 0.48, 1.00], [1.00, 0.80, 0.60], [0.55, 0.75, 1.00], [0.30, 1.00, 0.55], [0.75, 0.35, 1.00]];
let S_SUN_HI = [[1.00, 0.86, 0.28], [0.92, 0.97, 1.00], [1.00, 0.95, 0.64], [1.00, 0.84, 0.10], [1.00, 0.98, 0.86], [1.00, 1.00, 0.95], [0.90, 1.00, 0.95], [1.00, 0.75, 1.00]];
let S_SUN_LO = [[1.00, 0.17, 0.50], [0.34, 0.80, 1.00], [1.00, 0.46, 0.22], [0.92, 0.12, 0.10], [1.00, 0.62, 0.36], [0.75, 0.85, 1.00], [0.50, 1.00, 0.80], [0.55, 0.20, 1.00]];
let S_GROUND = [[0.05, 0.01, 0.07], [0.01, 0.02, 0.07], [0.01, 0.05, 0.05], [0.03, 0.03, 0.04], [0.09, 0.04, 0.07], [0.015, 0.025, 0.06], [0.02, 0.03, 0.05], [0.04, 0.01, 0.08]];
// sun_y, sun_size, sun_gain, stripes, rings, stars, glow_gain, haze
let S_NUM = [
    [0.150, 0.215, 1.15, 1.0, 0.0, 0.70, 1.10, 0.060],
    [0.300, 0.085, 1.20, 0.0, 0.0, 1.50, 0.90, 0.050],
    [0.110, 0.170, 1.00, 1.0, 0.0, 1.10, 1.00, 0.060],
    [0.200, 0.200, 1.15, 0.0, 1.0, 0.45, 0.80, 0.045],
    [0.050, 0.260, 1.10, 0.6, 0.0, 0.12, 1.30, 0.110],
    [0.255, 0.120, 0.92, 0.0, 0.0, 1.30, 0.80, 0.070],     // moonlit shore: a full pale moon, high
    [0.060, 0.050, 0.90, 0.0, 0.0, 1.80, 1.60, 0.100],     // aurora plain: a green band under violet, a cold star
    [0.200, 0.240, 1.10, 1.0, 0.0, 0.90, 1.20, 0.060],     // ultraviolet: the striped sun again, in violet
];
// the glyph ink of the towers, by theme (only the city and the boulevard have any)
let P_TOWER = [[0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.42, 0.62, 1.0], [0.80, 0.42, 1.0]];

// ── state ───────────────────────────────────────────────────────
let ready = false;
let mode = "title";
let mode_t = 0.0;
let auto = false;
let manual = false;
let telemetry = false;
let traffic_on = true;
let cruise = 0.0;            // handling tests: hold this speed while no pedal is pressed
let wide = false;            // handling tests: no shoulder, no edge
let tm_hz = 10.0;
let ap_skill = 1.0;
let pos = 0.0;
let time_left = 0.0;
let score = 0.0;
let hi_score = 0.0;
let stage = 0;
let count_n = 4;
let near_count = 0;
let start_pos = 0.0;
let last_sky_key = -1;
let pan = 0.0;
let sun_lean = 0.0;
// the car
let speed = 0.0;
let px = 0.0;
let yaw = 0.0;
let dir = 0.0;
let yawr = 0.0;
let steer_s = 0.0;           // -1..1 after the keyboard ramp / stick curve
let wheel_a = 0.0;           // front wheel angle, rad (what the tyres see and the model shows)
let gear = 1;
let shift_t = 0.0;
let rpm = 0.0;
let ax_s = 0.0;              // smoothed longitudinal accel (weight transfer)
let ax_now = 0.0;
let ay_now = 0.0;
let nload = 1.0;             // vertical load, 1 = level road
let air = false;
let air_t = 0.0;
let slide = 0.0;             // 0-1, rises fast with slip, falls slowly
let wspin = 0.0;             // 0-1 rear wheelspin
let offroad = 0.0;
let skid = 0.0;
let boost = 0.0;
let boosting = false;
let boost_s = 0.0;
let draft = 0.0;
let brake_lit = false;
// body springs
let roll = 0.0; let roll_v = 0.0;
let pitch = 0.0; let pitch_v = 0.0;
let heave = 0.0; let heave_v = 0.0;
let spin_f = 0.0; let spin_r = 0.0;
// crash / spin-out
let crash_t = 0.0;
let crash_len = 1.5;
let crash_dir = 1.0;
let crash_turns = 2.0;
let crash_yaw0 = 0.0;
let bump_cd = 0.0;
// scoring hooks
let drift_score = 0.0;
let drift_gap = 0.0;
let drift_last = 0.0;
let drift_total = 0.0;
let drift_count = 0;
let air_total = 0.0;
let draft_total = 0.0;
// camera
let shake = 0.0;
let cam_a = 0.0;
let cam_kick = 0.0;
// autopilot
let ap_lane = 0.0;
let ap_x = 0.0;
let tm_crashes = 0;
let tm_off = 0.0;

// ── the game: what is loaded, what is being played ──────────────
let EVENTS = [];
let THEMES = [];
let PAINTS = [];
let RIVAL_NAMES = [];
let cur = #{};               // the event whose road is laid (scripts/lib/tour.rhai)
let road_id = "";
let g_kind = "arcade";       // arcade | event | endless
let rules = true;            // false: rolling captures and handling tests (no clock, no results)
let no_clock = false;        // calibration: the clock shows but never runs down
let do_persist = true;
let assist = false;          // the autopilot drives the events, the menus stay the player's (menu tests)
let ghost = false;           // calibration: rivals run their own race, unbanded, and nobody touches them
let ap_style = 0;            // 0 clean | 1 drifts the bends | 2 shaves the traffic | 3 burns the boost it earns
let boot = true;
let boot_event = -1;
let boot_stage = 0;
let boot_speed = 0.0;
let req_load = false;
let req_reset = false;
let n_sec = 5;
let sec_theme = [];
let gen_seed = 0;
let gen_y = 0.0;
let test_track = false;
let test_curve = 0.0;
// menus (hud.rhai draws them from game_state)
let m_title = 0;
let m_leg = 0;
let m_row = 0;
let m_res = 0;
let paint = 0;
let medals = [];
let bests = [];
let endless_best = 0.0;
let save_rev = 0;
let dirty = true;
let frame_n = 0;
// the run's record
let elapsed = 0.0;
let n_crash = 0;
let top_speed = 0.0;
let was_crash = false;
let splits = [];
let res_medal = 0;
let res_value = 0.0;
let res_best = false;
let res_fail = "";
let res_ok = false;
// rivals (race events): the last N_RIVAL slots of the traffic arrays
let rv_skill = [];
let rv_lane = [];
let rv_block = [];
let rv_fin = [];
let rv_turn = 0;
let race_pos = 1;
let gap_a = 0.0;
let gap_b = 0.0;
let name_a = "";
let name_b = "";
let tr_seed = 1;
let tr_shown = [];
// the autopilot's party tricks (ap_style)
let ap_goal = 0.0;
let db_t = -1.0;
let db_dir = 0.0;
let db_cd = 0.0;
let tower_ink = [0.42, 0.62, 1.0];
let towers_styled = false;   // the towers carry an ascii_style (tools/build_scene.py ASCII): only then is there an ink to set

// ── track ───────────────────────────────────────────────────────
let t_curve = [];
let t_y = [];
let t_left = [];
let t_right = [];
let t_lo = [];
let t_ro = [];
let t_v2 = [];               // rivals: the speed^2 the road allows at each tile, braking included
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
let id_rival_body = [];
let id_mount = [];
let id_car = -1;
let id_body = -1;
let id_wheel = [];
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
// a tyre: linear to start with, flat at |u| >= 2 (the peak), nothing lost past it
fn sat2(u) { let a = abs(u); if a >= 2.0 { if u > 0.0 { 1.0 } else { -1.0 } } else { u - u * a * 0.25 } }
// 1 - exp(-k h), near enough, for filters that must not care about frame rate
fn ease(k, h) { let x = k * h; 1.0 - 1.0 / (1.0 + x + 0.5 * x * x) }
fn sgn(x) { if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 } }
// quaternions as [x, y, z, w]
fn q_x(a) { [sin(a * 0.5), 0.0, 0.0, cos(a * 0.5)] }
fn q_y(a) { [0.0, sin(a * 0.5), 0.0, cos(a * 0.5)] }
fn q_z(a) { [0.0, 0.0, sin(a * 0.5), cos(a * 0.5)] }
fn q_mul(a, b) {
    [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
     a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
     a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
     a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]]
}
fn mix3(a, b, t) { [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t] }

// THE ROAD GENERATOR. A road is sections of eased bends and hills made from
// a seed; `secs` rows are [theme, tiles, curve_max, hill_amp, curve_min,
// straight share]. Returns the track arrays (curve, y, scenery), the section
// starts (the last entry is the goal), and the seed and height it ended on
// so HORIZON can keep adding sections. `i0` is the tile index the first
// tile will have (scenery is hashed by absolute index). Pure: the caller
// assigns what it returns.
fn gen_road(secs, seed, y, i0, lead, runout, tt, tc, want_v2) {
    let curve = []; let ys = [];
    let starts = []; let themes = [];
    for i in 0..lead { curve.push(0.0); ys.push(y); }
    for sec in secs {
        starts.push(i0 + curve.len());
        themes.push(sec[0]);
        let n0 = curve.len();
        let last_sign = 1.0;
        let n_want = sec[1]; let cmax = sec[2]; let hill = sec[3]; let cmin = sec[4]; let straight = sec[5];
        while curve.len() - n0 < n_want {
            seed = lcg(seed); let r_kind = unit(seed);
            seed = lcg(seed); let r_len = unit(seed);
            seed = lcg(seed); let r_mag = unit(seed);
            seed = lcg(seed); let r_sign = unit(seed);
            seed = lcg(seed); let r_hill = unit(seed);
            let enter = 10 + (r_len * 10.0).to_int();
            let hold = 6 + (r_mag * 12.0).to_int();
            let c = 0.0;
            if r_kind > straight {
                let sign = if r_sign > 0.62 { last_sign } else { -last_sign };
                last_sign = sign;
                c = (cmin + r_mag * cmax) * sign;
                hold = 8 + (r_len * 30.0).to_int();
            }
            let dy = (r_hill - 0.5) * 2.0 * hill;
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
                curve.push(c * k);
                ys.push(y0 + dy * (0.5 - 0.5 * cos(PI() * t)));
            }
            y = y0 + dy;
        }
    }
    starts.push(i0 + curve.len());
    // the run-out past the goal: straight, settling flat
    for i in 0..runout { curve.push(0.0); ys.push(y); }
    let n = curve.len();

    // handling tests: a flat road, straight or one long bend
    if tt {
        for i in 0..n {
            ys[i] = 0.0;
            curve[i] = if i < 30 { 0.0 } else { tc * smooth01((i - 30).to_float() / 12.0) };
        }
    }

    // ---- scenery, by theme (a gate's tiles are kept clear) --------
    let left = []; let right = []; let lo_a = []; let ro_a = [];
    let nsec = themes.len();
    let s = 0;
    for i in 0..n {
        let gi = i0 + i;
        let l = 0; let r = 0; let lo = 10.0; let ro = 10.0;
        while s < nsec - 1 && gi >= starts[s + 1] { s += 1; }
        let th = themes[s];
        let past_goal = gi >= starts[nsec];
        let h1 = hash01(gi, 1); let h2 = hash01(gi, 2); let h3 = hash01(gi, 3);
        let near_gate = (gi > starts[s] - 3 && gi < starts[s] + 3) || (gi > starts[s + 1] - 3 && gi < starts[s + 1] + 3);
        if !near_gate && gi > 6 && !tt {
            if th == 0 {
                // sunset coast: an avenue of palms, signs
                if !past_goal {
                    if gi % 4 == 0 { l = 1; r = 1; lo = 9.4 + h1 * 2.6; ro = 9.4 + h2 * 2.6; }
                    if gi % 44 == 22 { r = 4; ro = 11.5; }
                    if gi % 44 == 0 { l = 4; lo = 11.5; }
                }
            } else if th == 1 {
                // neon city: a skyline, street lamps
                if gi % 2 == 0 { l = 5 + (h1 * 2.99).to_int(); lo = 38.0 + h2 * 80.0; }
                else { r = 5 + (h2 * 2.99).to_int(); ro = 38.0 + h1 * 80.0; }
                if gi % 10 == 0 { l = 3; lo = 8.6; }
                if gi % 10 == 5 { r = 3; ro = 8.6; }
            } else if th == 2 {
                // pine ridge: forest to the road's edge
                if gi % 2 == 0 { l = 2; lo = 9.5 + h1 * h1 * 46.0; }
                else { r = 2; ro = 9.5 + h2 * h2 * 46.0; }
            } else if th == 3 {
                // composition: circle, triangle, square
                if gi % 4 == 0 { l = 8 + (h1 * 2.99).to_int(); lo = 10.5 + h2 * 18.0; }
                if gi % 4 == 2 { r = 8 + (h3 * 2.99).to_int(); ro = 10.5 + h1 * 18.0; }
            } else if th == 5 {
                // moonlit shore: palms along the land side, the sea side open but for a far palm and a sign
                if gi % 3 == 0 { l = 1; lo = 9.4 + h1 * 3.2; }
                if gi % 16 == 8 { r = 1; ro = 20.0 + h2 * 34.0; }
                if gi % 48 == 24 { r = 4; ro = 11.5; }
            } else if th == 6 {
                // aurora plain: a few pines a long way off, the sky does the rest
                if gi % 5 == 0 { l = 2; lo = 16.0 + h1 * 64.0; }
                if gi % 5 == 2 { r = 2; ro = 16.0 + h2 * 64.0; }
            } else if th == 7 {
                // ultraviolet: towers behind a boulevard of palms and lamps
                if gi % 3 == 0 { l = 5 + (h1 * 2.99).to_int(); lo = 46.0 + h2 * 70.0; }
                else if gi % 3 == 1 { r = 5 + (h2 * 2.99).to_int(); ro = 46.0 + h1 * 70.0; }
                if gi % 8 == 0 { l = 1; lo = 10.2; }
                if gi % 8 == 4 { r = 1; ro = 10.2; }
                if gi % 16 == 2 { l = 3; lo = 8.6; }
                if gi % 16 == 10 { r = 3; ro = 8.6; }
            } else {
                // daybreak: thinning palms, a shape now and then
                if gi % 6 == 0 { l = 1; lo = 9.6 + h1 * 12.0; }
                if gi % 6 == 3 { r = 1; ro = 9.6 + h2 * 12.0; }
                if gi % 30 == 15 { r = 8 + (h3 * 2.99).to_int(); ro = 22.0 + h1 * 20.0; }
            }
        }
        left.push(l); right.push(r); lo_a.push(lo); ro_a.push(ro);
    }

    // ---- rivals: the speed each tile allows --------------------------
    // The autopilot's own plan (0.78 of the front axle's grip, downforce,
    // light crests), then a backward pass so a bend's speed is braked to
    // at 9 m/s^2. A rival drives sqrt(v2 x its skill).
    let v2 = [];
    if want_v2 {
        let g0 = 0.78 * 0.93 * 1.42 * 9.81;
        let kdf = 0.18 / (83.3 * 83.3);
        for i in 0..n {
            let kap = abs(curve[i]) / 64.0;
            let c2 = 1000000.0;
            if kap > 0.00004 {
                c2 = g0 / max(kap - g0 * kdf, 0.00002);
                if i > 0 && i < n - 1 {
                    let ypp = (ys[i + 1] - 2.0 * ys[i] + ys[i - 1]) / 64.0;
                    c2 *= clamp(1.0 + min(c2, 6500.0) * ypp / 9.81, 0.30, 1.0);
                }
            }
            v2.push(c2);
        }
        let i = n - 2;
        while i >= 0 {
            if v2[i + 1] + 144.0 < v2[i] { v2[i] = v2[i + 1] + 144.0; }
            i -= 1;
        }
    }
    #{ curve: curve, y: ys, left: left, right: right, lo: lo_a, ro: ro_a, starts: starts, themes: themes,
       seed: seed, y_end: y, v2: v2 }
}

fn on_init() {
    let me = self_entity();
    let NT = pl::N_TILES;
    EVENTS = tour::events();
    THEMES = tour::theme_names();
    PAINTS = tour::paints();
    RIVAL_NAMES = tour::rival_names();

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
    // traffic, then the rivals in the same arrays: one loop places, drafts and collides with both
    for i in 0..pl::N_TRAFFIC { id_traffic.push(get_entity(`traffic_${i}`)); }
    let rp = tour::rival_paint();
    for i in 0..N_RIVAL {
        id_traffic.push(get_entity(`rival_${i}`));
        let b = get_entity(`rival_body_${i}`);
        id_rival_body.push(b);
        let c = rp[i];
        set_material_override(b, "body", c[0], c[1], c[2], 1.0);
        set_material_override(b, "body_hi", c[0] * 2.0, c[1] * 2.0, c[2] * 2.0, 1.0);
        set_material_override(b, "body_shade", c[0] * 0.36, c[1] * 0.36, c[2] * 0.36, 1.0);
        set_material_override(b, "trim", min(c[0] * 5.0, 1.0), min(c[1] * 5.0, 1.0), min(c[2] * 5.0, 1.0), 1.0);
        set_material_override(b, "under", c[0] * 0.2, c[1] * 0.2, c[2] * 0.2, 1.0);
        set_material_override(b, "tail", 0.75, 0.02, 0.04, 1.0);
        rv_skill.push(1.0); rv_lane.push(0.0); rv_block.push(-1); rv_fin.push(-1.0);
    }
    for i in 0..id_traffic.len() {
        tr_pos.push(0.0); tr_x.push(0.0); tr_v.push(40.0); tr_side.push(1.0); tr_shown.push(true);
    }
    for i in 0..pl::N_MOUNT { id_mount.push(get_entity(`mount_${i}`)); }
    towers_styled = has_component(id_pool[5][0], "ascii_style");
    id_car = get_entity("car");
    id_body = get_entity("car_body");
    for n in ["wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr"] { id_wheel.push(get_entity(n)); }
    // nothing here casts a shadow, and thin neon lines want every sample
    set_quality(#{ shadows: false, msaa: 4 });
    set_material_override(id_body, "tail", 0.55, 0.012, 0.03, 1.0);
    for i in 0..pl::N_TRAFFIC { set_material_override(id_traffic[i], "tail", 0.50, 0.01, 0.02, 1.0); }

    // ---- what the scene asks for -----------------------------------
    start_pos = 8.0 * SEG + 2.0;
    pos = start_pos;
    auto = get_field(me, "game_state", "autopilot");
    manual = get_field(me, "game_state", "manual");
    telemetry = get_field(me, "game_state", "telemetry");
    traffic_on = get_field(me, "game_state", "traffic");
    ap_skill = get_field(me, "game_state", "ap_skill");
    ap_style = get_field(me, "game_state", "ap_style");
    assist = get_field(me, "game_state", "ap_assist");
    ghost = get_field(me, "game_state", "ghost_rivals");
    cruise = get_field(me, "game_state", "cruise");
    wide = get_field(me, "game_state", "test_wide");
    tm_hz = get_field(me, "game_state", "telemetry_hz");
    boost = clamp(get_field(me, "game_state", "start_boost"), 0.0, 1.0);
    test_track = get_field(me, "game_state", "test_track");
    test_curve = get_field(me, "game_state", "test_curve");
    boot_event = get_field(me, "game_state", "start_event");
    boot_stage = get_field(me, "game_state", "start_stage");
    boot_speed = get_field(me, "game_state", "start_speed");
    no_clock = get_field(me, "game_state", "no_clock");
    do_persist = get_field(me, "game_state", "persist");

    // ---- the save: version 2, every key optional ------------------
    //   save_version, hi_score (arcade), endless_best, paint,
    //   m_<event id> = 0..3 (medal), b_<event id> = best result
    for e in EVENTS {
        let m = 0; let b = -1.0;
        if do_persist {
            let pm = persist_get(`m_${e.id}`);
            if type_of(pm) == "i64" { m = if pm < 0 { 0 } else if pm > 3 { 3 } else { pm }; }
            let pb = persist_get(`b_${e.id}`);
            if type_of(pb) == "f64" { b = pb; } else if type_of(pb) == "i64" { b = pb.to_float(); }
        }
        medals.push(m); bests.push(b);
    }
    if do_persist {
        let hs = persist_get("hi_score");
        if type_of(hs) == "f64" { hi_score = hs; }
        let eb = persist_get("endless_best");
        if type_of(eb) == "f64" { endless_best = eb; }
        let pp = persist_get("paint");
        if type_of(pp) == "i64" && pp >= 0 && pp < PAINTS.len() {
            if tour::medal_count(medals) >= PAINTS[pp].need { paint = pp; }
        }
    }
    // paint is one colour in three materials: lit x 2, shade x 0.36 (never touch `glass`)
    let pc = PAINTS[paint].c;
    set_material_override(id_body, "body", pc[0], pc[1], pc[2], 1.0);
    set_material_override(id_body, "body_hi", pc[0] * 2.0, pc[1] * 2.0, pc[2] * 2.0, 1.0);
    set_material_override(id_body, "body_shade", pc[0] * 0.36, pc[1] * 0.36, pc[2] * 0.36, 1.0);

    // ---- the first road: laid on the first update ------------------
    if boot_event >= 0 && boot_event < EVENTS.len() { g_kind = "event"; cur = EVENTS[boot_event]; m_leg = boot_event / 3; m_row = boot_event % 3; }
    else if boot_event == 100 { g_kind = "endless"; cur = tour::endless(); }
    else { g_kind = "arcade"; cur = tour::arcade(); boot_event = -1; }
    req_load = true;
    ready = true;
}

fn on_update() {
    if !ready { return; }
    let me = self_entity();
    let dt = min(delta_time(), 0.05);
    let now = total_time();
    let NT = pl::N_TILES;
    let NTF = pl::N_TRAFFIC;
    let NTR = tr_pos.len();
    mode_t += dt;
    frame_n += 1;
    let ev = "";
    let ev_val = 0.0;
    let end_why = "";            // goal | time | crash | late: the run ended this frame

    // ═══ mode ═══════════════════════════════════════════════════
    // title -> (tour -> brief ->) countdown -> drive -> results | over | finish
    let confirm = is_action_just_pressed("confirm");
    let back = is_action_just_pressed("back");
    let nav_x = 0; let nav_y = 0;
    if is_action_just_pressed("menu_left") { nav_x = -1; } else if is_action_just_pressed("menu_right") { nav_x = 1; }
    if is_action_just_pressed("menu_up") { nav_y = -1; } else if is_action_just_pressed("menu_down") { nav_y = 1; }
    // the pause menu's orders (hud.rhai writes them: it is the one script awake while paused)
    // and a tap's: hud.rhai tests each tap against the row it drew and sends
    // what was chosen (title:n | ev:n | paint:n | res:n | ok | back). A tapped
    // row is chosen and confirmed in the one touch.
    let cmd = get_field(me, "game_state", "cmd");
    if cmd != "" { set_field(me, "game_state", "cmd", ""); }
    let tap_k = ""; let tap_n = -1;
    if cmd == "ok" { confirm = true; }
    else if cmd == "back" { back = true; }
    else if cmd.contains(":") { let parts = cmd.split(":"); tap_k = parts[0]; tap_n = parts[1].parse_int(); }
    let was_mode = mode;
    if mode == "title" {
        if mode_t > 0.4 {
            if nav_y != 0 { m_title = (m_title + nav_y + 3) % 3; ev = "ui_move"; dirty = true; }
            if tap_k == "title" && tap_n >= 0 && tap_n < 3 { m_title = tap_n; confirm = true; dirty = true; }
            if confirm {
                if m_title == 0 {
                    g_kind = "arcade"; rules = true;
                    if road_id != "arcade" { cur = tour::arcade(); req_load = true; } else { req_reset = true; }
                    mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start";
                } else if m_title == 1 {
                    mode = "tour"; mode_t = 0.0; ev = "ui_ok";
                } else if tour::endless_unlocked(medals) {
                    g_kind = "endless"; rules = true; cur = tour::endless(); req_load = true;
                    mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start";
                } else { ev = "ui_no"; }
            }
        }
    } else if mode == "tour" {
        if nav_y != 0 {
            m_row += nav_y;
            if m_row < 0 { m_row = 0; } else if m_row > 3 { m_row = 3; }
            ev = "ui_move"; dirty = true;
        }
        if tap_k == "ev" && tap_n >= 0 && tap_n < EVENTS.len() { m_leg = tap_n / 3; m_row = tap_n % 3; confirm = true; dirty = true; }
        let tap_paint = tap_k == "paint" && tap_n >= 0 && tap_n < PAINTS.len();
        if nav_x != 0 || tap_paint {
            if m_row < 3 && !tap_paint { m_leg = (m_leg + nav_x + 5) % 5; }
            else {
                let have = tour::medal_count(medals);
                let np = PAINTS.len();
                if tap_paint {
                    // a tapped paint: worn if it is earned
                    m_row = 3;
                    if have >= PAINTS[tap_n].need { paint = tap_n; }
                } else {
                    // the paint row: step to the next paint that is earned
                    for k in 1..np {
                        let c = (paint + nav_x * k + np * k) % np;
                        if have >= PAINTS[c].need { paint = c; break; }
                    }
                }
                let pc = PAINTS[paint].c;
                set_material_override(id_body, "body", pc[0], pc[1], pc[2], 1.0);
                set_material_override(id_body, "body_hi", pc[0] * 2.0, pc[1] * 2.0, pc[2] * 2.0, 1.0);
                set_material_override(id_body, "body_shade", pc[0] * 0.36, pc[1] * 0.36, pc[2] * 0.36, 1.0);
                if do_persist { persist_set("paint", paint); persist_set("save_version", 2); }
            }
            ev = if tap_paint && paint != tap_n { "ui_no" } else { "ui_move" }; dirty = true;
        }
        if confirm && mode_t > 0.2 && m_row < 3 {
            let i = m_leg * 3 + m_row;
            if tour::unlocked(i, medals) {
                g_kind = "event"; rules = true; cur = EVENTS[i]; req_load = true;
                mode = "brief"; mode_t = 0.0; ev = "ui_ok";
            } else { ev = "ui_no"; }
        }
        if back { mode = "title"; mode_t = 0.0; ev = "ui_move"; }
    } else if mode == "brief" {
        if confirm && mode_t > 0.3 { mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start"; }
        else if back { mode = "tour"; mode_t = 0.0; ev = "ui_move"; }
    } else if mode == "countdown" {
        let n = 3 - (mode_t / 0.9).to_int();
        if n < count_n {
            count_n = n;
            if n > 0 { ev = "count"; ev_val = n.to_float(); }
            else { ev = "go"; mode = "drive"; mode_t = 0.0; }
        }
    } else if mode == "drive" {
        if rules {
            elapsed += dt;
            let ty = cur.type;
            if ty != "race" && ty != "endless" {
                if !no_clock { time_left -= dt; }
                if time_left <= 0.0 { time_left = 0.0; end_why = "time"; }
            }
            if (ty == "rush" && n_crash > cur.max_crashes) || (ty == "endless" && n_crash >= cur.max_crashes) { end_why = "crash"; }
            if ty == "race" {
                // every rival home and the player still out: the flag falls 15 s after the last
                let all = true; let last = 0.0;
                for r in 0..cur.rivals.len() { if rv_fin[r] < 0.0 { all = false; } else if rv_fin[r] > last { last = rv_fin[r]; } }
                if all && elapsed > last + 15.0 { end_why = "late"; }
            }
            if is_action_just_pressed("restart") && !auto {
                // R: the arcade run goes back to the title, an event restarts
                if g_kind == "arcade" { mode = "title"; mode_t = 0.0; }
                else {
                    if g_kind == "endless" { cur = tour::endless(); req_load = true; } else { req_reset = true; }
                    mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start"; end_why = "";
                }
            }
        }
    } else if mode == "results" {
        // RETRY | NEXT (an event whose successor is open) | TOUR, or RETRY | TITLE
        let n_opt = if g_kind == "event" { 3 } else { 2 };
        let has_next = false;
        if g_kind == "event" && cur.idx < EVENTS.len() - 1 { has_next = tour::unlocked(cur.idx + 1, medals); }
        if mode_t > 1.2 {
            if nav_x != 0 {
                m_res = (m_res + nav_x + n_opt) % n_opt;
                if n_opt == 3 && m_res == 1 && !has_next { m_res = (m_res + nav_x + 3) % 3; }
                ev = "ui_move"; dirty = true;
            }
            if tap_k == "res" && tap_n >= 0 && tap_n < n_opt {
                if n_opt == 3 && tap_n == 1 && !has_next { ev = "ui_no"; }
                else { m_res = tap_n; confirm = true; dirty = true; }
            }
            if confirm {
                if m_res == 0 {
                    if g_kind == "endless" { cur = tour::endless(); req_load = true; } else { req_reset = true; }
                    mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start";
                } else if n_opt == 3 && m_res == 1 {
                    cur = EVENTS[cur.idx + 1]; m_leg = cur.idx / 3; m_row = cur.idx % 3; req_load = true;
                    mode = "brief"; mode_t = 0.0; ev = "ui_ok";
                } else {
                    mode = if g_kind == "event" { "tour" } else { "title" }; mode_t = 0.0; ev = "ui_ok";
                }
            } else if back {
                mode = if g_kind == "event" { "tour" } else { "title" }; mode_t = 0.0; ev = "ui_move";
            }
        }
    } else {
        // over | finish (the arcade run): coast, then back to the title
        if (confirm && mode_t > 1.5) || mode_t > 14.0 { mode = "title"; mode_t = 0.0; }
    }
    if cmd == "restart" && (mode == "drive" || mode == "countdown") {
        if g_kind == "endless" { cur = tour::endless(); req_load = true; } else { req_reset = true; }
        mode = "countdown"; mode_t = 0.0; count_n = 4; ev = "start"; end_why = "";
    } else if cmd == "quit" && (mode == "drive" || mode == "countdown") {
        mode = if g_kind == "event" { "tour" } else { "title" }; mode_t = 0.0; end_why = "";
    }

    // ═══ a new road, a new run ══════════════════════════════════
    // (behind the briefing card or the countdown's fade from black)
    if req_load {
        req_load = false;
        let r = gen_road(cur.secs, cur.seed, 0.0, 0, 30, NT + 140, test_track, test_curve, cur.rivals.len() > 0);
        t_curve = r.remove("curve"); t_y = r.remove("y");
        t_left = r.remove("left"); t_right = r.remove("right");
        t_lo = r.remove("lo"); t_ro = r.remove("ro"); t_v2 = r.remove("v2");
        stage_start = r.starts; sec_theme = r.themes;
        gen_seed = r.seed; gen_y = r.y_end;
        n_sec = sec_theme.len();
        n_seg = t_curve.len() - 1;
        gates = [];
        for g in stage_start { gates.push(g); }
        // every tile takes its colours again; the sky's slow things too
        for j in 0..NT { tile_seg[j] = -1; }
        last_sky_key = -1;
        road_id = cur.id;
        req_reset = true;
    }
    if req_reset {
        req_reset = false;
        pos = start_pos; stage = 0;
        time_left = cur.time0; score = 0.0; near_count = 0; pan = 0.0;
        // the car, at rest on the line
        speed = 0.0; px = 0.0; yaw = 0.0; dir = 0.0; yawr = 0.0; steer_s = 0.0; wheel_a = 0.0;
        gear = 1; shift_t = 0.0; ax_s = 0.0; nload = 1.0; air = false; air_t = 0.0;
        slide = 0.0; wspin = 0.0; crash_t = 0.0; bump_cd = 0.0;
        if !boot { boost = 0.0; }
        boosting = false; draft = 0.0;
        roll = 0.0; roll_v = 0.0; pitch = 0.0; pitch_v = 0.0; heave = 0.0; heave_v = 0.0;
        drift_score = 0.0; drift_last = 0.0; drift_total = 0.0; drift_count = 0;
        air_total = 0.0; draft_total = 0.0; cam_a = 0.0; ap_x = 0.0; ap_lane = 0.0; ap_goal = 0.0;
        elapsed = 0.0; n_crash = 0; top_speed = 0.0; was_crash = false; splits = [];
        res_medal = 0; res_fail = ""; res_best = false; res_ok = false;
        db_t = -1.0; db_cd = 0.0;
        tr_seed = cur.seed % 100000 + 17;
        let tf = cur.traffic;
        for i in 0..NTF {
            tr_pos[i] = pos + 160.0 + i.to_float() * tf[3] * 0.21154 + hash01(i, 9) * tf[3] * 0.13462;
            tr_x[i] = ((hash01(i, 5) * 2.99).to_int() - 1).to_float() * 4.0;
            tr_v[i] = tf[1] + 2.0 + hash01(i, 7) * (tf[2] - 2.0);
            tr_side[i] = 1.0;
        }
        // the grid: five rivals ahead, the quickest at the front, the player last
        let grid_x = [-4.0, 4.0, 0.0, -4.0, 4.0];
        for r in 0..N_RIVAL {
            let t = NTF + r;
            rv_skill[r] = if r < cur.rivals.len() { cur.rivals[r] } else { 1.0 };
            tr_pos[t] = pos + 9.0 * (r + 1).to_float();
            tr_x[t] = grid_x[r]; rv_lane[r] = grid_x[r];
            tr_v[t] = 0.0; tr_side[t] = 1.0; rv_block[r] = -1; rv_fin[r] = -1.0;
        }
        race_pos = cur.rivals.len() + 1; gap_a = 0.0; gap_b = 0.0; name_a = ""; name_b = "";
        dirty = true;
    }
    if boot {
        boot = false;
        if (auto || telemetry) && boot_event >= 0 {
            // what this event is, for tools/tour_check.py
            let th = ""; for q in sec_theme { th += THEMES[q] + ","; }
            let rv = ""; for q in cur.rivals { rv += `${q},`; }
            let tg = ""; for q in cur.targets { tg += `${q},`; }
            let ex = ""; for q in cur.ext { ex += `${q},`; }
            let nm = cur.name; nm.replace(" ", "_"); th.replace(" ", "_");
            log(`EVI id=${cur.id} name=${nm} type=${cur.type} km=${(stage_start[n_sec] - stage_start[0]).to_float() * SEG * 0.001} secs=${n_sec} themes=${th} cars=${cur.traffic[0]} v0=${cur.traffic[1]} dv=${cur.traffic[2]} rivals=${rv} targets=${tg} time0=${cur.time0} ext=${ex} max_crashes=${cur.max_crashes}`);
        }
        if auto || manual || boot_event >= 0 {
            if boot_event >= 0 && boot_speed <= 0.0 && !manual {
                // an event, by its rules, from the countdown (tools/tour_check.py)
                rules = true; mode = "countdown"; mode_t = 0.0; count_n = 4;
            } else {
                // rolling: captures and handling tests, no clock and no results
                rules = false;
                stage = if boot_stage < n_sec { boot_stage } else { n_sec - 1 };
                if auto || boot_stage > 0 { pos = (stage_start[stage] + 60).to_float() * SEG; }
                speed = boot_speed;
                for g in 1..6 { if speed > GEAR_V[g] * 0.965 { gear = g + 1; } }
                mode = "drive"; time_left = 60.0;
                for i in 0..NTF { tr_pos[i] = pos + 120.0 + i.to_float() * 95.0 + hash01(i, 9) * 60.0; }
            }
        }
    }
    // HORIZON: the road is never allowed to run out. Each new section is the
    // next theme in the cycle, a little harder than the last.
    if g_kind == "endless" && (pos / SEG).to_int() > stage_start[n_sec] - 200 {
        let kf = n_sec.to_float();
        let sec = [HORIZON_ORDER[n_sec % 8], 260, min(0.070 + 0.010 * kf, 0.170), min(8.0 + 2.5 * kf, 30.0), 0.045, max(0.30 - 0.01 * kf, 0.20)];
        let i0 = stage_start[n_sec];
        let r = gen_road([sec], gen_seed, gen_y, i0, 0, NT + 140, false, 0.0, false);
        t_curve.truncate(i0); t_curve.append(r.remove("curve"));
        t_y.truncate(i0); t_y.append(r.remove("y"));
        t_left.truncate(i0); t_left.append(r.remove("left"));
        t_right.truncate(i0); t_right.append(r.remove("right"));
        t_lo.truncate(i0); t_lo.append(r.remove("lo"));
        t_ro.truncate(i0); t_ro.append(r.remove("ro"));
        stage_start.push(r.starts[1]); gates.push(r.starts[1]); sec_theme.push(sec[0]);
        gen_seed = r.seed; gen_y = r.y_end;
        n_sec += 1;
        n_seg = t_curve.len() - 1;
    }
    if mode != was_mode { dirty = true; }
    let driving = mode == "drive";
    let attract = mode == "title" || mode == "tour";
    let self_drive = auto || attract || assist;
    let stage_c = if stage < n_sec { stage } else { n_sec - 1 };   // the section the car is in

    // ═══ where on the road ══════════════════════════════════════
    let basef = pos / SEG;
    let base = basef.to_int();
    let f = basef - base.to_float();
    let c0 = t_curve[base] + (t_curve[base + 1] - t_curve[base]) * f;
    let sp = min(speed / VMAX, 1.25);
    let sp1 = min(sp, 1.0);
    let wheelbase = WB_A + WB_B;
    // the lateral acceleration full lock asks for here, and the lock that asks it
    let steer_acc = STEER_ASK * FRONT * MU * G * (1.0 + MU_DF * sp * sp);
    let v3 = max(speed, 3.0);
    let lock = min(STEER_MAX, wheelbase * steer_acc / (v3 * v3));

    // ═══ input ══════════════════════════════════════════════════
    let in_steer = 0.0; let in_gas = 0.0; let in_brake = 0.0; let in_hb = 0.0; let in_boost = false;
    let analog = true;
    if self_drive {
        // THE AUTOPILOT: the title's attract loop, every capture, later the rivals.
        // 1. the lane with the clearest road ahead
        let NAP = if ghost { NTF } else { NTR };
        let best = ap_lane; let best_cost = 1000000.0;
        for li in 0..3 {
            let lx = (li - 1).to_float() * 4.0;
            let cost = abs(lx - px) * 0.12;
            if abs(lx - ap_lane) > 1.0 { cost += 1.6; }
            for t in 0..NAP {
                let rel = tr_pos[t] - pos;
                if rel > -8.0 && rel < 190.0 && abs(tr_x[t] - lx) < 2.6 && (speed > tr_v[t] - 4.0 || rel < 30.0) { cost += 6.0 + (190.0 - rel) * 0.08; }
            }
            if cost < best_cost { best_cost = cost; best = lx; }
        }
        ap_lane = best;
        ap_goal = ap_lane;
        if ap_style == 2 {
            // style 2: shave the next car it will pass in another lane (a close pass is under 3.3 m)
            let near_rel = 80.0;
            for t in 0..NTF {
                let rel = tr_pos[t] - pos;
                if rel > -4.0 && rel < near_rel && abs(tr_x[t] - ap_lane) > 2.0 && speed - tr_v[t] > 12.0 {
                    near_rel = rel;
                    ap_goal = clamp(tr_x[t] + sgn(ap_lane - tr_x[t]) * 2.7, ap_lane - 1.3, ap_lane + 1.3);
                }
            }
        }
        ap_x += clamp(ap_goal - ap_x, -3.0 * dt, 3.0 * dt);
        // 2. the speed the road ahead allows: each tile's bend against the grip
        //    it will have there (crests lighten the car), and room to brake to it
        let skill = if attract { 0.8 } else { ap_skill };
        let grip_plan = 0.78 * skill * FRONT * MU * G * (1.0 + MU_DF * sp * sp);
        let v2_allow = 1000000.0;
        for k in 0..46 {
            let sg = base + k;
            let kap = abs(t_curve[sg]) / (SEG * SEG);
            if kap > 0.00004 {
                let ypp = (t_y[sg + 1] - 2.0 * t_y[sg] + t_y[sg - 1]) / (SEG * SEG);
                let load = clamp(1.0 + speed * speed * ypp / G, 0.30, 1.0);
                let v2 = grip_plan * load / kap + 18.0 * max((k - 1).to_float() * SEG, 0.0);
                if v2 < v2_allow { v2_allow = v2; }
            }
        }
        let v_allow = min(sqrt(v2_allow), if attract { 52.0 } else { 120.0 });
        if speed > v_allow + 0.5 { in_brake = clamp((speed - v_allow) * 0.22, 0.0, 1.0); }
        else { in_gas = clamp((v_allow - speed) * 0.6, 0.0, 1.0); }
        for t in 0..NAP {
            let rel = tr_pos[t] - pos;
            let closing = speed - tr_v[t];
            if rel > 0.0 && closing > 0.0 && rel < 16.0 + closing * closing / 18.0 && abs(tr_x[t] - px) < 2.5 { in_gas = 0.0; in_brake = 1.0; }
        }
        // 3. steering: the lateral acceleration that holds the bend a little way
        //    ahead and closes on the lane (a PD on px), turned into lock
        let la = base + 1 + (speed * 0.30 / SEG).to_int();
        let kap_la = 0.5 * (c0 + t_curve[la]) / (SEG * SEG);
        let slip_now = yaw - dir;
        let a_want = kap_la * speed * speed + 1.20 * (ap_x - px) - 2.40 * speed * sin(dir)
            - 0.35 * (ay_now - c0 / (SEG * SEG) * speed * speed);
        // sliding: ease the wheel to centre and let the caster bring the tail back
        a_want *= 1.0 - clamp((abs(slip_now) - 0.09) / 0.15, 0.0, 1.0);
        in_steer = clamp(wheelbase * a_want / (v3 * v3) / lock, -1.0, 1.0);
        // a capture can take the controls back, one at a time (scripted
        // manoeuvres on a road the autopilot is otherwise driving)
        if ap_style == 1 && (auto || assist) && driving {
            // style 1: a handbrake entry into every real bend, held with the
            // wheel into it and eased as the car nears the inside edge. A
            // stand-in for a player who drifts, to calibrate the DRIFT events.
            db_cd = max(db_cd - dt, 0.0);
            let bend = sgn(c0);
            if db_t < 0.0 {
                if db_cd <= 0.0 && abs(c0) > 0.07 && t_curve[base + 14] * bend > 0.07 && speed > 42.0 && abs(px) < 3.0
                    && abs(slip_now) < 0.05 && crash_t <= 0.0 { db_t = 0.0; db_dir = bend; }
            } else {
                db_t += dt;
                if c0 * db_dir < 0.035 || db_t > 5.0 || crash_t > 0.0 || abs(px) > 5.2 { db_t = -1.0; db_cd = 1.0; }
                else {
                    in_steer = db_dir * clamp(1.0 - (px * db_dir + 1.0) * 0.22, 0.15, 1.0);
                    in_gas = 1.0; in_brake = 0.0;
                    if db_t < 0.40 { in_hb = 1.0; in_steer = db_dir; }
                }
            }
        }
        // style 3: burn the boost where the road is straight enough to use it
        if ap_style == 3 && (auto || assist) && driving && (boost > 0.5 || boosting) && in_gas > 0.95 && abs(c0) < 0.04 { in_boost = true; }
        if auto || (assist && driving) {
            let s_in = clamp(action_value("steer"), -1.0, 1.0);
            let g_in = clamp(action_value("accelerate"), 0.0, 1.0);
            let b_in = clamp(action_value("brake"), 0.0, 1.0);
            if s_in != 0.0 { in_steer = s_in; }
            if b_in > 0.0 { in_brake = b_in; in_gas = 0.0; } else if g_in > 0.0 { in_gas = g_in; in_brake = 0.0; }
            if is_action_pressed("handbrake") { in_hb = 1.0; }
            if is_action_pressed("boost") { in_boost = true; }
        }
    } else if driving {
        in_steer = clamp(action_value("steer"), -1.0, 1.0);
        in_gas = clamp(action_value("accelerate"), 0.0, 1.0);
        in_brake = clamp(action_value("brake"), 0.0, 1.0);
        if is_action_pressed("handbrake") { in_hb = 1.0; }
        in_boost = is_action_pressed("boost");
        // touch (the on-screen stick and buttons are up): the stick is a stick
        // even at full lock, and the gas is automatic, since a finger holds one
        // control at a time and the right thumb has BRAKE, DRIFT and BOOST to
        // press. Lift nothing: BRAKE is the only way to slow.
        let touch = touch_controls_visible();
        if touch && in_brake == 0.0 { in_gas = 1.0; }
        analog = last_input_device() == "gamepad" || touch || (abs(in_steer) > 0.02 && abs(in_steer) < 0.98);
        if cruise > 0.0 && in_gas == 0.0 && in_brake == 0.0 { in_gas = clamp((cruise - speed) * 0.8 + 0.3, 0.0, 1.0); }
    }
    if crash_t > 0.0 { in_steer = 0.0; in_gas = 0.0; in_brake = 0.0; in_hb = 0.0; in_boost = false; }
    if mode == "over" || mode == "finish" || mode == "results" { in_steer = 0.0; in_gas = 0.0; in_brake = 0.55; in_hb = 0.0; in_boost = false; }
    // a stick is curved to be precise near the centre; a key ramps, so a tap
    // is a small correction and a hold is full lock in 0.25 s
    if self_drive { steer_s += (in_steer - steer_s) * ease(14.0, dt); }
    else if analog { steer_s += (in_steer * (0.55 + 0.45 * abs(in_steer)) - steer_s) * ease(18.0, dt); }
    else {
        let rate = if in_steer == 0.0 || in_steer * steer_s < 0.0 { KEY_OUT } else { KEY_IN };
        steer_s += clamp(in_steer - steer_s, -rate * dt, rate * dt);
    }
    // boost: held, while there is any (a little is needed to light it)
    let was_boosting = boosting;
    boosting = in_boost && driving && boost > (if boosting { 0.0 } else { 0.06 });
    if boosting {
        boost = max(boost - BOOST_DRAIN * dt, 0.0);
        in_gas = 1.0;
        if !was_boosting { ev = "boost"; shake = max(shake, 0.25); }
    }

    // ═══ car ════════════════════════════════════════════════════
    let was_gear = gear;
    let was_air = air;
    let offk = 0.0;
    let lost = 0.0;
    if mode == "countdown" || mode == "brief" {
        // revving on the line
        rpm = 0.30 + 0.25 * (0.5 + 0.5 * sin(now * 9.0)) * clamp(action_value("accelerate") + 0.4, 0.0, 1.0);
        speed = 0.0; ax_now = 0.0; ay_now = 0.0;
    } else {
        let nsub = clamp(ceil(dt / 0.006), 2.0, 9.0).to_int();
        let h = dt / nsub.to_float();
        let ax_sum = 0.0; let ay_sum = 0.0;
        let boost_k = if boosting { 1.0 + BOOST_MUL } else { 1.0 };
        for step in 0..nsub {
            // the road under the car: curvature, and how fast it rises or falls away
            let bf = pos / SEG;
            let bi = bf.to_int();
            let ff = bf - bi.to_float();
            let kap = (t_curve[bi] + (t_curve[bi + 1] - t_curve[bi]) * ff) / (SEG * SEG);
            let ypp_a = t_y[bi + 1] - 2.0 * t_y[bi] + t_y[bi - 1];
            let ypp_b = t_y[bi + 2] - 2.0 * t_y[bi + 1] + t_y[bi];
            let ypp = (ypp_a + (ypp_b - ypp_a) * ff) / (SEG * SEG);
            let spn = min(speed / VMAX, 1.25);
            let aero = 1.0 + MU_DF * spn * spn;
            // load: a crest lightens the car (flying under AIR_LOAD), a dip presses it down
            let n_tgt = clamp(1.0 + speed * speed * ypp / G, 0.0, 1.7);
            nload += (n_tgt - nload) * ease(if n_tgt > nload { 7.0 } else { 14.0 }, h);
            air = nload < AIR_LOAD && speed > 30.0;
            let gl = if nload < 1.0 { 0.12 + 0.88 * nload } else { 1.0 + 0.45 * (nload - 1.0) };
            // surface: road, shoulder, grass
            offk = if wide { 0.0 } else { smooth01((abs(px) - (ROAD + 0.3)) / 1.5) };
            let surf = 1.0 - OFF_GRIP * offk;
            let amax = MU * G * aero * surf * gl;
            let ax_i = 0.0; let ay_i = 0.0;

            if crash_t > 0.0 {
                // a spin-out: the car turns `crash_turns` times about its
                // heading while it slides on down the road and slows
                crash_t -= h;
                let s = smooth01(1.0 - max(crash_t, 0.0) / crash_len);
                yaw = crash_yaw0 * (1.0 - s) + crash_dir * crash_turns * TAU() * s;
                yawr = 0.0;
                dir -= dir * ease(2.5, h);
                ax_i = -(speed * (0.6 + 0.8 * crash_turns) + 5.0);
                speed = max(speed + ax_i * h, 0.0);
                let home = clamp(px, -4.0, 4.0);
                px += (home - px) * ease(1.6, h) + speed * sin(dir) * h;
                pos += speed * cos(dir) * h;
                wspin = 0.0;
                slide = 1.0;
                for g in 2..7 { if gear == g && speed < GEAR_V[g - 1] * 0.80 { gear = g - 1; } }
                if crash_t <= 0.0 { crash_t = 0.0; yaw = 0.0; dir = 0.0; slide = 0.0; }
            } else {
                // ── engine, gearbox, brakes ─────────────────────
                shift_t = max(shift_t - h, 0.0);
                if shift_t <= 0.0 {
                    if gear < 6 && speed > GEAR_V[gear] * 0.965 { gear += 1; shift_t = SHIFT_T; }
                    else if gear > 1 && speed < GEAR_V[gear - 1] * 0.80 { gear -= 1; }
                }
                let rn = speed / GEAR_V[gear];
                let gas = if shift_t > 0.0 { 0.0 } else { in_gas };
                let rev = if gear == 1 { max(rn, 0.16 + 0.34 * gas) } else { rn };   // the clutch slips off the line
                let tq = max(1.0 - 1.1 * (rev - 0.55) * (rev - 0.55), 0.4);
                if rn > 1.0 { tq *= max(1.0 - (rn - 1.0) * 30.0, 0.0); }
                let a_eng = gas * ENG_A1 * GEAR_V[1] / GEAR_V[gear] * tq * boost_k;
                let a_trac = TRAC_G * G * surf * gl * (1.0 + 0.1 * spn * spn);
                let a_drive = min(a_eng, a_trac);
                let used = a_drive / a_trac;
                wspin += (clamp((a_eng - a_trac) / a_trac, 0.0, 1.0) - wspin) * ease(10.0, h);
                let moving = min(speed / 0.3, 1.0);
                let a_stop = in_brake * G * (BRAKE_G + BRAKE_DF * spn * spn) * surf * gl + in_hb * HB_DECEL * surf;
                if shift_t <= 0.0 { a_stop += (1.0 - gas) * (ENG_BRAKE0 + ENG_BRAKE1 * rn); }
                let ax = a_drive - a_stop * moving;
                let resist = (DRAG * speed * speed * (1.0 - 0.38 * draft) + ROLL_A + offk * (3.0 + 0.12 * speed)) * moving;

                // ── tyres ───────────────────────────────────────
                let beta = yaw - dir;
                let cb = cos(beta); let sb = sin(beta);
                let bex = beta - clamp(beta, -SLIP_DEAD, SLIP_DEAD);
                let slide_t = clamp(abs(bex) / 0.16, 0.0, 1.0);
                slide += (slide_t - slide) * ease(if slide_t > slide { 20.0 } else { 2.5 }, h);
                // what each axle can give right now
                let wt = clamp(ax_s / G, -1.3, 1.0) * WT;
                let d_f = max(FRONT * amax * (1.0 - wt) * (1.0 - 0.10 * in_brake), 0.5);
                let d_r = max(amax * (1.0 + wt) * (1.0 - HB_CUT * in_hb) * (1.0 - PWR_CUT * used * used) * (1.0 - SPIN_CUT * wspin) * (1.0 - DRIFT_REAR * slide * in_gas), 0.5);
                // the front wheels: the driver's lock, less the caster that
                // lets them follow the travel direction in a slide
                let vv = max(speed, 3.0);
                let lock_now = min(STEER_MAX, wheelbase * STEER_ASK * FRONT * MU * G * aero / (vv * vv));
                let delta = clamp(steer_s * (lock_now + DRIFT_LOCK * slide) + LOCK_SLIP * steer_s * steer_s * steer_s - CASTER * bex, -0.62, 0.62);
                wheel_a = delta;
                let den = max(abs(speed * cb), 6.0);
                let slip_f = delta + atan2(speed * sb - WB_A * yawr, den);
                let slip_r = atan2(speed * sb + WB_B * yawr, den);
                let stiff = CORNER * aero;
                let f_f = d_f * sat2(stiff * slip_f / d_f);
                let f_r = d_r * sat2(stiff * slip_r / d_r);
                let ay = 0.5 * (f_f * cos(delta) + f_r);
                // how fast the tyres are turning the travel direction
                let turn = (ay * cb + ax * sb) / max(speed, 4.0);
                let yacc = KYAW * (f_f - f_r) - YAW_DAMP * yawr - YAW_DAMP_SLIDE * slide * (1.0 - 0.6 * in_hb) * (yawr - turn);
                if abs(beta) > SLIP_SOFT { yacc -= 30.0 * (abs(beta) - SLIP_SOFT) * sgn(beta); }
                yawr += yacc * h;
                // parking speeds: the wheels just roll where they point
                let lowk = 1.0 - smooth01((speed - 2.0) / 6.0);
                if lowk > 0.0 {
                    yawr += (speed * delta / wheelbase - yawr) * lowk * ease(20.0, h);
                    dir += (yaw - dir) * lowk * ease(10.0, h);
                    yaw -= yaw * lowk * ease(1.5, h);
                }
                // ── integrate, road-relative ────────────────────
                let vdot = ax * cb - SCRUB * ay * sb - resist;
                let road_turn = kap * speed * cos(dir);
                dir += (turn - road_turn) * h;
                yaw += (yawr - road_turn) * h;
                speed = max(speed + vdot * h, 0.0);
                px += speed * sin(dir) * h;
                pos += speed * cos(dir) * h;
                ax_s += (vdot - ax_s) * ease(7.0, h);
                ax_i = vdot; ay_i = ay;
                // the soft edge of the world
                if abs(px) > 23.0 && !wide {
                    px = 23.0 * sgn(px);
                    if dir * px > 0.0 { dir = 0.0; }
                    yaw -= yaw * ease(4.0, h);
                    speed -= speed * ease(0.8, h);
                }
                // past the slip cap the slide is a spin-out
                if (abs(yaw - dir) > SLIP_SPIN && speed > 12.0) || (abs(yaw) > 1.35 && !wide) {
                    crash_len = 1.15; crash_t = crash_len; crash_turns = 1.0;
                    crash_dir = sgn(yaw - dir); crash_yaw0 = yaw;
                    ev = "spin"; shake = max(shake, 0.6);
                    lost = drift_score; drift_score = 0.0;
                }
            }
            // ── the body on its springs: roll, pitch (squat, dive), heave ──
            roll_v += (169.0 * (ROLL_K * ay_i - roll) - 14.3 * roll_v) * h;
            roll += roll_v * h;
            pitch_v += (144.0 * (clamp(PITCH_K * ax_i, -0.032, 0.022) - pitch) - 13.2 * pitch_v) * h;
            pitch += pitch_v * h;
            heave_v += (121.0 * (-HEAVE_K * (nload - 1.0) - heave) - 9.9 * heave_v) * h;
            heave += heave_v * h;
            ax_sum += ax_i; ay_sum += ay_i;
        }
        ax_now = ax_sum / nsub.to_float();
        ay_now = ay_sum / nsub.to_float();
        let slip = yaw - dir;
        rpm = clamp(if gear == 1 { max(speed / GEAR_V[1], 0.16 + 0.34 * in_gas) } else { speed / GEAR_V[gear] }, 0.12, 1.0);
        offroad += ((if offk > 0.5 && speed > 3.0 { 1.0 } else { 0.0 }) - offroad) * ease(8.0, dt);
        let skid_t = if air || speed < 4.0 { 0.0 } else {
            max(max(clamp((abs(slip) - 0.055) / 0.22, 0.0, 1.0), wspin * 0.8), in_hb * min(speed / 15.0, 1.0) * 0.7)
        };
        skid += (skid_t - skid) * ease(9.0, dt);

        // air over a crest: time it, land it
        if air { air_t += dt; if !boosting { boost = min(boost + 0.30 * dt, 1.0); } }
        if was_air && !air {
            heave_v -= 0.5 + 1.2 * min(air_t, 1.0);
            shake = max(shake, 0.22 + 0.3 * min(air_t, 1.0));
            if driving && air_t > 0.25 {
                air_total += air_t;
                if ev == "" { ev = "air"; ev_val = floor(air_t * 10.0) * 100.0; score += ev_val; }
            }
            air_t = 0.0;
        }

        // the drift score: angle x speed x time, banked when the slide ends
        // cleanly, lost in a spin or a crash
        if driving && crash_t <= 0.0 && abs(slip) > DRIFT_ON && speed > 18.0 && offroad < 0.5 {
            drift_score += rad_to_deg(abs(slip)) * speed * dt * DRIFT_K;
            drift_gap = 0.0;
            if !boosting { boost = min(boost + 0.16 * min(abs(slip) / 0.35, 1.0) * dt, 1.0); }
        } else if drift_score > 0.0 {
            drift_gap += dt;
            if crash_t > 0.0 { lost = max(lost, drift_score); drift_score = 0.0; }
            else if drift_gap > 0.45 {
                if drift_score >= 100.0 {
                    drift_last = floor(drift_score / 10.0) * 10.0;
                    drift_total += drift_last; drift_count += 1; score += drift_last;
                    if ev == "" { ev = "drift"; ev_val = drift_last; }
                }
                drift_score = 0.0;
            }
        }
        if ev == "spin" { ev_val = lost; }
        if driving { score += speed * dt * (1.0 + sp1) * 6.0; }
    }
    if gear != was_gear && mode != "countdown" {
        set_field(me, "game_state", "shifted", now);
        if gear > was_gear && crash_t <= 0.0 { cam_kick += 0.16; }
    }
    bump_cd = max(bump_cd - dt, 0.0);

    // the road ends: the attract loop goes round, a run stops on the run-out
    if attract && pos > (stage_start[n_sec] - 20).to_float() * SEG { pos = start_pos; stage = 0; }
    if pos > (n_seg - NT - 6).to_float() * SEG { pos = (n_seg - NT - 6).to_float() * SEG; speed = 0.0; dir = 0.0; yawr = 0.0; }
    if driving && speed > top_speed { top_speed = speed; }
    // crashes and spin-outs, counted as they begin
    if crash_t > 0.0 && !was_crash && driving { n_crash += 1; }
    was_crash = crash_t > 0.0;

    // gates: a section ends, the clock is extended, the last one is the goal
    basef = pos / SEG;
    base = basef.to_int();
    f = basef - base.to_float();
    if stage < n_sec && base >= stage_start[stage + 1] {
        stage += 1;
        if rules && driving { splits.push(elapsed); }
        if stage >= n_sec {
            if driving && rules {
                if g_kind == "arcade" {
                    mode = "finish"; mode_t = 0.0; ev = "finish";
                    ev_val = floor(time_left * 10.0) * 1000.0;
                    score += ev_val;
                } else { end_why = "goal"; }
            }
            stage = n_sec;
        } else if driving && rules {
            if cur.ext.len() >= stage && cur.ext[stage - 1] > 0.0 {
                time_left += cur.ext[stage - 1];
                ev = "checkpoint"; ev_val = cur.ext[stage - 1];
            } else { ev = "stage"; }
            if g_kind == "endless" {
                // more cars, a wider spread of speeds, closer together
                let sf = stage.to_float();
                let nc = 7 + stage / 2;
                cur.traffic = [if nc > NTF { NTF } else { nc }, max(28.0 - 0.5 * sf, 24.0), min(18.0 + 1.5 * sf, 30.0), max(520.0 - 30.0 * sf, 260.0)];
            }
        }
    }
    if attract && stage >= n_sec { stage = 0; }
    stage_c = if stage < n_sec { stage } else { n_sec - 1 };

    // the run is over: what it was worth
    if end_why != "" && mode == "drive" {
        if g_kind == "arcade" { mode = "over"; mode_t = 0.0; ev = "over"; }
        else {
            mode = "results"; mode_t = 0.0;
            let ty = cur.type;
            let base_score = score;
            res_ok = true; res_fail = "";
            if ty == "sprint" { res_ok = end_why == "goal"; res_value = time_left; }
            else if ty == "rush" { res_ok = end_why == "goal"; res_value = near_count.to_float(); }
            else if ty == "drift" { res_value = drift_total; }
            else if ty == "race" { res_value = (if end_why == "goal" { race_pos } else { cur.rivals.len() + 1 }).to_float(); }
            else if ty == "endurance" {
                res_ok = end_why == "goal";
                if res_ok { score += floor(time_left * 10.0) * 1000.0; }
                res_value = score;
            } else { res_value = score; }
            if !res_ok { res_fail = if end_why == "crash" { "TOO MANY CRASHES" } else { "OUT OF TIME" }; }
            res_medal = 0; res_best = false; m_res = 0;
            if g_kind == "event" {
                res_medal = tour::medal_for(cur, res_value, res_ok);
                let i = cur.idx;
                if res_ok && (bests[i] < 0.0 || tour::better(cur, bests[i], res_value)) {
                    bests[i] = res_value; res_best = true;
                    if do_persist { persist_set(`b_${cur.id}`, res_value); }
                }
                if res_medal > medals[i] {
                    medals[i] = res_medal;
                    if do_persist { persist_set(`m_${cur.id}`, res_medal); }
                }
                if res_medal > 0 && i < EVENTS.len() - 1 { if tour::unlocked(i + 1, medals) { m_res = 1; } }
            } else if score > endless_best {
                endless_best = score; res_best = true;
                if do_persist { persist_set("endless_best", endless_best); }
            }
            if do_persist { persist_set("save_version", 2); persist_save(); }
            save_rev += 1;
            ev = if res_ok && (g_kind != "event" || res_medal > 0) { "finish" } else { "over" };
            ev_val = res_value;
            if auto || telemetry || assist {
                let sp_s = ""; for x in splits { sp_s += `${x},`; }
                let rv_s = "";
                let goal_pos = stage_start[n_sec].to_float() * SEG;
                for r in 0..cur.rivals.len() {
                    let tt = if rv_fin[r] >= 0.0 { rv_fin[r] } else { elapsed + (goal_pos - tr_pos[NTF + r]) / max(tr_v[NTF + r], 20.0) };
                    rv_s += `${tt},`;
                }
                log(`EVR id=${cur.id} type=${ty} why=${end_why} t=${elapsed} value=${res_value} medal=${res_medal} ok=${res_ok} left=${time_left} score=${score} base=${base_score} crashes=${n_crash} near=${near_count} drift=${drift_total} drifts=${drift_count} air=${air_total} draft=${draft_total} top=${top_speed} dist=${pos - start_pos} splits=${sp_s} rivals=${rv_s}`);
            }
        }
    }
    if (mode == "over" || mode == "finish") && mode_t < 0.02 && score > hi_score {
        hi_score = score;
        if do_persist { persist_set("hi_score", hi_score); }
    }
    let stage_i = stage_c;
    // the height under the car: a Catmull-Rom curve through the tile joints
    // (C1, so the climb rate has no kink at a joint)
    let ya = t_y[base - 1]; let yb = t_y[base]; let yc = t_y[base + 1]; let yd = t_y[base + 2];
    let py = yb + 0.5 * f * ((yc - ya) + f * ((2.0 * ya - 5.0 * yb + 4.0 * yc - yd) + f * (3.0 * (yb - yc) + yd - ya)));
    let slope0 = 0.5 * ((yc - ya) + f * (2.0 * (2.0 * ya - 5.0 * yb + 4.0 * yc - yd) + 3.0 * f * (3.0 * (yb - yc) + yd - ya))) / SEG;

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
            // (a tile is at most one section away from the car's)
            let q0 = stage_c;
            if q0 < n_sec - 1 && sg >= stage_start[q0 + 1] { q0 += 1; } else if q0 > 0 && sg < stage_start[q0] { q0 -= 1; }
            let t = 0.0;
            let s0 = sec_theme[q0]; let s1 = s0;
            if q0 < n_sec - 1 {
                s1 = sec_theme[q0 + 1];
                t = smooth01((sg - (stage_start[q0 + 1] - 56)).to_float() / 56.0);
            }
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

    // ═══ rivals ═════════════════════════════════════════════════
    // Five cars on a cheap kinematic model: the speed the road allows
    // (t_v2, scaled by skill), an engine that runs out near 295 km/h, a
    // lane picked like the autopilot picks its own, and the car in front
    // as a ceiling. A light band keeps the pack in play: 3% either way
    // once a rival is 300 m from the player.
    let race_on = g_kind == "event" && cur.rivals.len() > 0 && !attract;
    let v_along = speed * cos(dir);
    let n_act = if traffic_on { cur.traffic[0] } else { 0 };
    if race_on {
        let racing = mode == "drive" || mode == "results";
        let goal_pos = stage_start[n_sec].to_float() * SEG;
        let end_pos = (n_seg - NT - 14).to_float() * SEG;
        rv_turn = (rv_turn + 1) % N_RIVAL;
        let ahead_n = 0; let d_a = 100000.0; let d_b = -100000.0;
        for r in 0..N_RIVAL {
            let t = NTF + r;
            let myp = tr_pos[t]; let myx = tr_x[t]; let myv = tr_v[t];
            let rel_p = myp - pos;
            if rel_p > 0.0 { ahead_n += 1; if rel_p < d_a { d_a = rel_p; name_a = RIVAL_NAMES[r]; } }
            else if rel_p > d_b { d_b = rel_p; name_b = RIVAL_NAMES[r]; }
            if !racing { tr_v[t] = 0.0; continue; }
            if rv_fin[r] < 0.0 && myp >= goal_pos { rv_fin[r] = elapsed; }
            let sk = rv_skill[r] * (1.0 - (if ghost { 0.0 } else { RV_BAND }) * clamp(rel_p / 300.0, -1.0, 1.0));
            let sgi = (myp / SEG).to_int();
            let vt = sqrt(min(t_v2[sgi], t_v2[sgi + 1]) * sk * RV_GRIP);
            if rv_fin[r] >= 0.0 { vt = min(vt, 45.0); }
            if myp > end_pos { vt = 0.0; }
            if r == rv_turn {
                // its turn to look around: the best lane, and who is in the way
                let best = rv_lane[r]; let best_cost = 1000000.0;
                for li in 0..3 {
                    let lx = (li - 1).to_float() * 4.0;
                    let cost = abs(lx - myx) * 0.15;
                    if abs(lx - rv_lane[r]) > 1.0 { cost += 1.2; }
                    for o in 0..NTR {
                        if o == t || (o < NTF && o >= n_act) { continue; }
                        if abs(tr_x[o] - lx) < 2.6 {
                            let rel = tr_pos[o] - myp;
                            if rel > -9.0 && rel < 12.0 { cost += 30.0; }
                            else if rel >= 12.0 && rel < 110.0 && tr_v[o] < myv - 2.0 { cost += 5.0 + (110.0 - rel) * 0.08; }
                        }
                    }
                    if abs(px - lx) < 2.6 && !ghost {
                        let rel = -rel_p;
                        if rel > -9.0 && rel < 12.0 { cost += 30.0; }
                        else if rel >= 12.0 && rel < 110.0 && v_along < myv - 2.0 { cost += 5.0 + (110.0 - rel) * 0.08; }
                    }
                    if cost < best_cost { best_cost = cost; best = lx; }
                }
                rv_lane[r] = best;
                let blk = -1; let bd = 60.0;
                for o in 0..NTR {
                    if o == t || (o < NTF && o >= n_act) { continue; }
                    let rel = tr_pos[o] - myp;
                    if rel > 2.0 && rel < bd && abs(tr_x[o] - myx) < 2.1 { bd = rel; blk = o; }
                }
                if -rel_p > 2.0 && -rel_p < bd && abs(px - myx) < 2.1 && !ghost { blk = -2; }
                rv_block[r] = blk;
            }
            let b = rv_block[r];
            if b != -1 {
                let bp = pos; let bv = v_along; let bx = px;
                if b >= 0 { bp = tr_pos[b]; bv = tr_v[b]; bx = tr_x[b]; }
                let gap = bp - myp;
                if gap > 0.0 && gap < 60.0 && abs(bx - myx) < 2.1 { vt = min(vt, max(bv + (gap - 7.0) * 0.9, 0.0)); }
            }
            if myv < vt {
                let a = min(RV_LAUNCH, RV_POWER * (0.72 + 0.28 * sk) / max(myv, 8.0)) - DRAG * myv * myv - ROLL_A;
                tr_v[t] = min(myv + max(a, 0.0) * dt, vt);
            } else { tr_v[t] = max(myv - 14.0 * dt, vt); }
            tr_x[t] = myx + clamp(rv_lane[r] - myx, -3.2 * dt, 3.2 * dt);
        }
        if driving {
            race_pos = ahead_n + 1;
            let vv = max(speed, 15.0);
            gap_a = if d_a < 99999.0 { d_a / vv } else { 0.0 };
            gap_b = if d_b > -99999.0 { -d_b / vv } else { 0.0 };
            if d_a >= 99999.0 { name_a = ""; }
            if d_b <= -99999.0 { name_b = ""; }
            if frame_n % 6 == 0 { dirty = true; }
        }
    }

    // ═══ traffic (and the rivals, which are placed and hit the same way) ═══
    let reach = (NT - BACK - 3).to_float() * SEG;
    let draft_t = 0.0;
    let tf = cur.traffic;
    for t in 0..NTR {
        let id = id_traffic[t];
        let rival = t >= NTF;
        let solid = !(rival && ghost);
        if (rival && !race_on) || (!rival && t >= n_act) {
            tr_pos[t] = pos + 5000.0;
            if tr_shown[t] { tr_shown[t] = false; set_position(id, 0.0, -1000.0, 0.0); }
            continue;
        }
        tr_pos[t] += tr_v[t] * dt;
        let rel = tr_pos[t] - pos;
        if !rival && (rel < -40.0 || rel > 1400.0) {
            // come back in over the horizon
            tr_seed = lcg(tr_seed); let r1 = unit(tr_seed);
            tr_seed = lcg(tr_seed); let r2 = unit(tr_seed);
            tr_seed = lcg(tr_seed); let r3 = unit(tr_seed);
            tr_pos[t] = pos + reach + 40.0 + r1 * tf[3];
            tr_x[t] = ((r2 * 2.99).to_int() - 1).to_float() * 4.0;
            tr_v[t] = tf[1] + r3 * tf[2];
            tr_side[t] = 1.0;
            rel = tr_pos[t] - pos;
        }
        // overtaken: a close pass is worth something
        let side_now = if rel >= 0.0 { 1.0 } else { -1.0 };
        if side_now < 0.0 && tr_side[t] > 0.0 && driving && crash_t <= 0.0 && solid {
            let gap = abs(px - tr_x[t]);
            if gap < 3.3 && speed - tr_v[t] > 12.0 {
                near_count += 1;
                ev = "near_miss"; ev_val = 500.0 + floor(sp1 * 10.0) * 100.0;
                score += ev_val;
                if !boosting { boost = min(boost + 0.15, 1.0); }
            } else if gap < 6.5 { if ev == "" { ev = "pass"; } }
        }
        tr_side[t] = side_now;
        // the slipstream: close behind, in its lane, at speed
        if rel > 3.0 && rel < 42.0 && abs(px - tr_x[t]) < 1.5 && speed > 25.0 && crash_t <= 0.0 && solid {
            draft_t = max(draft_t, 1.0 - (rel - 3.0) / 39.0);
        }
        if rel > -(BACK.to_float() - 0.2) * SEG && rel < reach {
            let kf = rel / SEG + f;
            let k = floor(kf).to_int();
            let fr = kf - k.to_float();
            let kk = k + BACK;
            let wx = vis_x[kk] + vis_dx[kk] * fr + tr_x[t];
            let wy = vis_y[kk] + (vis_y[kk + 1] - vis_y[kk]) * fr;
            tr_shown[t] = true;
            set_position(id, wx, wy, -rel);
            // heading and pitch are blended toward the next tile's, not stepped at the joint
            let tdx = vis_dx[kk] + (vis_dx[kk + 1] - vis_dx[kk]) * fr;
            let tdy = (vis_y[kk + 1] - vis_y[kk]) + (vis_y[kk + 2] - 2.0 * vis_y[kk + 1] + vis_y[kk]) * fr;
            set_rotation(id, rad_to_deg(atan2(tdy, SEG)), -rad_to_deg(atan2(tdx, SEG)), 0.0);
            // contact: an impact is a kick to the car's state (speed, travel
            // direction, yaw rate), and the tyres deal with it from there.
            // Traffic is shoved along; a rival holds its line.
            let gap = abs(px - wx);
            if abs(rel) < 4.3 && gap < 1.85 && crash_t <= 0.0 && mode != "countdown" && mode != "brief" && solid {
                let side = if px > wx { 1.0 } else { -1.0 };
                let closing = v_along - tr_v[t];
                if closing > 24.0 && rel > 0.0 {
                    // far too fast: a spin-out, thrown off to the side it hit from
                    crash_len = 1.5; crash_t = crash_len; crash_turns = 2.0;
                    crash_dir = side; crash_yaw0 = yaw;
                    dir = clamp(dir + side * 3.5 / max(speed, 10.0), -0.4, 0.4);
                    lost = max(lost, drift_score); drift_score = 0.0;
                    ev = "crash"; ev_val = lost; shake = 1.0;
                    if !rival { tr_v[t] = min(tr_v[t] + 14.0, 60.0); }
                } else if gap < 1.25 && rel > 2.0 {
                    // nose to tail: the speed goes into the car ahead, and
                    // the nose glances off to the side
                    if closing > -2.0 {
                        speed = max(tr_v[t] - 3.0, 0.0);
                        if !rival {
                            tr_v[t] = min(tr_v[t] + max(closing, 0.0) * 0.3, 60.0);
                            tr_pos[t] += 2.5;
                        }
                        dir += side * 1.6 / max(speed, 10.0);
                        yawr += side * 0.30;
                        if ev == "" { ev = "bump"; }
                        shake = max(shake, 0.5);
                    }
                } else if gap < 1.25 && rel < -2.0 {
                    // it has run up behind: it lifts
                    tr_v[t] = min(tr_v[t], max(v_along - 1.0, 0.0));
                } else {
                    // door to door: pushed apart, a little speed scrubbed off;
                    // scraping along slower traffic is survivable
                    px += side * (1.85 - gap) * 0.6;
                    if speed * sin(dir) * side < 1.0 { dir = side * 1.0 / max(speed, 10.0); }
                    speed = max(speed - 5.0 * dt, 0.0);
                    if bump_cd <= 0.0 {
                        yawr += side * 0.14;
                        if ev == "" { ev = "bump"; }
                        shake = max(shake, 0.3);
                    }
                    bump_cd = 0.45;
                }
            }
        } else if tr_shown[t] {
            tr_shown[t] = false;
            set_position(id, 0.0, -1000.0, 0.0);
        }
    }
    draft += (draft_t - draft) * ease(if draft_t > draft { 3.0 } else { 5.0 }, dt);
    if driving && draft > 0.3 {
        draft_total += dt;
        if !boosting { boost = min(boost + 0.10 * draft * dt, 1.0); }
    }
    if hit_prop && crash_t <= 0.0 && speed > 8.0 && !attract {
        crash_len = 1.7; crash_t = crash_len; crash_turns = 2.0;
        crash_dir = if px > 0.0 { -1.0 } else { 1.0 }; crash_yaw0 = yaw;
        dir = clamp(dir + crash_dir * 2.5 / max(speed, 10.0), -0.4, 0.4);
        lost = max(lost, drift_score); drift_score = 0.0;
        ev = "crash"; ev_val = lost; shake = 1.0;
    }

    // ═══ the car ════════════════════════════════════════════════
    // root: on the road, pitched with it, yawed by the heading. Positive
    // euler yaw turns left, the car's `yaw` is positive to the right.
    let q = q_mul(q_x(atan2(slope0, 1.0)), q_y(-yaw));
    set_position(id_car, px, 0.0, 0.0);
    set_rotation_quat(id_car, q[0], q[1], q[2], q[3]);
    // body: what the springs say, and the shoulder's rumble
    let rumble = offroad * sp1 * 0.03 * sin(now * 61.0);
    // The wheels stay put, so the body's movement is wheel travel in the
    // arches: roll and pitch are capped, and heave gets what room they leave.
    let roll_d = clamp(roll, -0.052, 0.052);
    let pitch_d = clamp(pitch, -0.035, 0.035);
    let room = max(ARCH - abs(roll_d) * 0.80 - abs(pitch_d) * 1.30, 0.012);
    q = q_mul(q_x(pitch_d), q_z(roll_d));
    set_position(id_body, 0.0, clamp(heave + rumble, -room, room), 0.0);
    set_rotation_quat(id_body, q[0], q[1], q[2], q[3]);
    // wheels: stay on the road, fronts steer, all spin; the rears spin up
    // with wheelspin and lock under the handbrake
    spin_f += speed / 0.33 * dt;
    spin_r += (speed + wspin * 22.0) * (1.0 - in_hb) / 0.33 * dt;
    if spin_f > TAU() { spin_f -= TAU() * floor(spin_f / TAU()); }
    if spin_r > TAU() { spin_r -= TAU() * floor(spin_r / TAU()); }
    let show = clamp(wheel_a, -0.49, 0.49);
    for i in 0..4 {
        let st = if i < 2 { show } else { 0.0 };
        let sn = if i < 2 { spin_f } else { spin_r };
        // left wheels are the right wheel's model turned round
        q = if i % 2 == 0 { q_mul(q_y(PI() - st), q_x(sn)) } else { q_mul(q_y(-st), q_x(-sn)) };
        set_rotation_quat(id_wheel[i], q[0], q[1], q[2], q[3]);
    }
    let lit = in_brake > 0.05 || in_hb > 0.0;
    if lit != brake_lit {
        brake_lit = lit;
        if lit { set_material_override(id_body, "tail", 1.0, 0.05, 0.08, 1.0); }
        else { set_material_override(id_body, "tail", 0.55, 0.012, 0.03, 1.0); }
    }

    // ═══ mountains, sun, sky ════════════════════════════════════
    pan += c0 * speed * dt * 0.6;
    let ring = pl::N_MOUNT.to_float() * 315.0;
    for i in 0..id_mount.len() {
        let mx = i.to_float() * 315.0 - pan;
        mx = mx - floor(mx / ring) * ring - ring * 0.5;
        set_position(id_mount[i], mx, -6.0 - py * 0.15, -640.0);
        set_field(id_mount[i], "transform", "scale", [0.45, 0.45 + 0.1 * hash01(i, 3), 0.45]);
    }
    sun_lean += (-c0 * 1.5 * sp1 - sun_lean) * ease(1.6, dt);

    // the sky runs a little ahead of the tiles under the car
    let sgs = base + 26;
    let q0 = stage_c;
    if q0 < n_sec - 1 && sgs >= stage_start[q0 + 1] { q0 += 1; }
    let k0 = sec_theme[q0]; let k1 = k0;
    let kt = 0.0;
    if q0 < n_sec - 1 {
        k1 = sec_theme[q0 + 1];
        kt = smooth01((sgs - (stage_start[q0 + 1] - 70)).to_float() / 70.0);
    }
    set_post_style_param("horizon", "sky_top", mix3(S_TOP[k0], S_TOP[k1], kt));
    set_post_style_param("horizon", "sky_low", mix3(S_LOW[k0], S_LOW[k1], kt));
    set_post_style_param("horizon", "glow", mix3(S_GLOW[k0], S_GLOW[k1], kt));
    set_post_style_param("horizon", "sun_hi", mix3(S_SUN_HI[k0], S_SUN_HI[k1], kt));
    set_post_style_param("horizon", "sun_lo", mix3(S_SUN_LO[k0], S_SUN_LO[k1], kt));
    set_post_style_param("horizon", "ground", mix3(S_GROUND[k0], S_GROUND[k1], kt));
    let na = S_NUM[k0]; let nb = S_NUM[k1];
    // the last stage's sun climbs as the goal comes up
    let rise = 0.0;
    if k0 == 4 && q0 == n_sec - 1 && g_kind != "endless" {
        rise = 0.12 * clamp((base - stage_start[q0]).to_float() / (stage_start[q0 + 1] - stage_start[q0]).to_float(), 0.0, 1.0);
    }
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
    let sky_key = q0 * 100 + (kt * 40.0).to_int();
    let accent = mix3(P_EDGE[k0], P_EDGE[k1], kt);
    let second = mix3(P_GRID[k0], P_GRID[k1], kt);
    if sky_key != last_sky_key {
        last_sky_key = sky_key;
        let w = mix3(P_WIRE[k0], P_WIRE[k1], kt);
        for id in id_mount { set_material_override(id, "wire", w[0], w[1], w[2], 1.0); }
        for id in id_pool[1] { set_material_override(id, "trim", accent[0] * 0.7, accent[1] * 0.7, accent[2] * 0.7, 1.0); }
        set_material_override(id_body, "under", accent[0] * 0.035, accent[1] * 0.035, accent[2] * 0.035, 1.0);
        set_material_override(id_body, "trim", accent[0] * 0.6, accent[1] * 0.6, accent[2] * 0.6, 1.0);
        for id in id_gate { set_material_override(id, "neon", accent[0], accent[1], accent[2], 1.0); }
        // the towers' glyph ink follows the theme (blue in the city, violet on the boulevard)
        let tw = mix3(P_TOWER[k0], P_TOWER[k1], kt);
        if towers_styled && abs(tw[0] - tower_ink[0]) + abs(tw[1] - tower_ink[1]) > 0.004 {
            tower_ink = tw;
            for ty in 5..8 { for id in id_pool[ty] { set_style_param(id, "tint", tw); } }
        }
    }

    // ═══ camera ═════════════════════════════════════════════════
    // It follows where the car is GOING (with lag), not where it points, so
    // a slide shows the car turned on screen. It looks into the bend, pulls
    // back and widens with speed and boost, and takes small knocks.
    shake = max(0.0, shake - dt * 1.8);
    cam_kick -= cam_kick * ease(8.0, dt);
    boost_s += ((if boosting { 1.0 } else { 0.0 }) - boost_s) * ease(4.5, dt);
    cam_a += (clamp(dir * 0.85, -0.30, 0.30) - cam_a) * ease(3.2, dt);
    let jx = (shake * 0.30 + offroad * sp1 * 0.07) * sin(now * 47.0);
    let jy = (shake * 0.24 + offroad * sp1 * 0.09) * sin(now * 59.0 + 1.3);
    // The road ahead is read at FIXED DISTANCES, interpolated between tile
    // starts. Reading it at a tile index makes the sample slide 8 m toward
    // the car and snap back at every joint: the picture pumps on any slope
    // or bend, eight to ten times a second at speed.
    let akf = 40.0 / SEG + f; let ak = akf.to_int(); let afr = akf - ak.to_float();
    let ahead = vis_x[BACK + ak] + (vis_x[BACK + ak + 1] - vis_x[BACK + ak]) * afr;
    let rkf = 48.0 / SEG + f; let rk = rkf.to_int(); let rfr = rkf - rk.to_float();
    let rise5 = vis_y[BACK + rk] + (vis_y[BACK + rk + 1] - vis_y[BACK + rk]) * rfr;
    if attract || mode == "brief" {
        let a = now * 0.16;
        set_camera_position(px + 6.4 * sin(a), 1.25 + 0.75 * (1.0 + sin(now * 0.11)), 4.0 + 5.2 * cos(a) + 3.0);
        set_camera_target(px + ahead * 0.3, 0.9 + rise5 * 0.3, -14.0);
        set_camera_fov(58.0);
        set_camera_roll(0.0);
    } else {
        let back = 7.1 + 0.7 * sp1 + 0.9 * boost_s - cam_kick;
        set_camera_position(px * 0.80 - back * sin(cam_a) * 0.8 + jx, 2.30 + 0.12 * sp1 + jy + rise5 * 0.06, back * cos(cam_a));
        set_camera_target(px * 0.56 + ahead * (0.55 + 0.10 * sp1) + 15.0 * sin(cam_a) + jx, 1.05 + rise5 * 0.55 + jy, -30.0);
        set_camera_fov(60.0 + 13.0 * sp1 * sp1 + 9.0 * boost_s);
        // never more than 2 degrees
        set_camera_roll(clamp(-roll * 0.30 - c0 * 0.10 * sp1, -0.035, 0.035));
    }
    set_radial_blur(clamp((sp1 - 0.6) * 0.3 + boost_s * 0.07, 0.0, 0.18));
    set_post_style_param("crt", "aberration", 0.5 + 1.6 * sp1 * sp1 + shake * 3.0 + boost_s * 2.0);

    // ═══ telemetry ══════════════════════════════════════════════
    if telemetry {
        if ev == "crash" || ev == "spin" { tm_crashes += 1; }
        if offroad > 0.5 { tm_off += dt; }
        if (now * tm_hz).to_int() != ((now - dt) * tm_hz).to_int() {
            log(`TM t=${now} v=${speed} px=${px} yaw=${yaw} dir=${dir} slip=${yaw - dir} r=${yawr} ay=${ay_now} ax=${ax_now} gear=${gear} rpm=${rpm} boost=${boost} drift=${drift_score} banked=${drift_total} steer=${steer_s} wheel=${wheel_a} roll=${roll} pitch=${pitch} heave=${heave} load=${nload} air=${air_total} off=${tm_off} crashes=${tm_crashes} crash=${crash_t} pos=${pos} stage=${stage} c0=${c0} wspin=${wspin} draft=${draft_total} near=${near_count}`);
        }
    }

    // ═══ publish ════════════════════════════════════════════════
    set_field(me, "game_state", "mode", mode);
    set_field(me, "game_state", "mode_time", mode_t);
    set_field(me, "game_state", "speed", speed);
    set_field(me, "game_state", "speed_kmh", speed * 3.6);
    set_field(me, "game_state", "rpm", rpm);
    set_field(me, "game_state", "gear", gear);
    set_field(me, "game_state", "throttle", if shift_t > 0.0 { 0.0 } else { in_gas });
    set_field(me, "game_state", "shift_cut", shift_t / SHIFT_T);
    set_field(me, "game_state", "brake", in_brake);
    set_field(me, "game_state", "handbrake", in_hb > 0.0);
    set_field(me, "game_state", "steer", steer_s);
    set_field(me, "game_state", "wheel_angle", wheel_a);
    set_field(me, "game_state", "px", px);
    set_field(me, "game_state", "yaw", yaw);
    set_field(me, "game_state", "travel", dir);
    set_field(me, "game_state", "slip", yaw - dir);
    set_field(me, "game_state", "yaw_rate", yawr);
    set_field(me, "game_state", "lat_g", ay_now / G);
    set_field(me, "game_state", "long_g", ax_now / G);
    set_field(me, "game_state", "load", nload);
    set_field(me, "game_state", "wheelspin", wspin);
    set_field(me, "game_state", "boost", boost);
    set_field(me, "game_state", "boosting", boosting);
    set_field(me, "game_state", "draft", draft);
    set_field(me, "game_state", "draft_time", draft_total);
    set_field(me, "game_state", "drift_score", drift_score);
    set_field(me, "game_state", "drift_banked", drift_last);
    set_field(me, "game_state", "drift_total", drift_total);
    set_field(me, "game_state", "drift_count", drift_count);
    set_field(me, "game_state", "airborne", air);
    set_field(me, "game_state", "air_time", air_t);
    set_field(me, "game_state", "air_total", air_total);
    set_field(me, "game_state", "time_left", time_left);
    set_field(me, "game_state", "score", score);
    set_field(me, "game_state", "hi_score", hi_score);
    set_field(me, "game_state", "stage", stage_i);
    set_field(me, "game_state", "stage_name", THEMES[sec_theme[stage_i]]);
    let s_lo = stage_start[stage_i]; let s_hi = stage_start[stage_i + 1];
    set_field(me, "game_state", "stage_progress", clamp((basef - s_lo.to_float()) / (s_hi - s_lo).to_float(), 0.0, 1.0));
    set_field(me, "game_state", "run_progress", clamp((basef - stage_start[0].to_float()) / (stage_start[n_sec] - stage_start[0]).to_float(), 0.0, 1.0));
    // the event's own numbers
    set_field(me, "game_state", "elapsed", elapsed);
    set_field(me, "game_state", "dist_km", (pos - start_pos) * 0.001);
    set_field(me, "game_state", "crashes", n_crash);
    if race_on {
        set_field(me, "game_state", "race_pos", race_pos);
        set_field(me, "game_state", "gap_ahead", gap_a);
        set_field(me, "game_state", "gap_behind", gap_b);
    }
    // the slow things: menus, results, the save. Written when they change
    // (and now and then anyway, so a reader that started late catches up).
    if dirty || frame_n % 30 == 0 {
        dirty = false;
        set_field(me, "game_state", "kind", g_kind);
        set_field(me, "game_state", "ev_idx", if g_kind == "event" { cur.idx } else { -1 });
        set_field(me, "game_state", "ev_type", cur.type);
        set_field(me, "game_state", "n_stages", n_sec);
        set_field(me, "game_state", "rules", rules);
        set_field(me, "game_state", "menu_title", m_title);
        set_field(me, "game_state", "menu_leg", m_leg);
        set_field(me, "game_state", "menu_row", m_row);
        set_field(me, "game_state", "menu_res", m_res);
        set_field(me, "game_state", "paint", paint);
        set_field(me, "game_state", "name_ahead", name_a);
        set_field(me, "game_state", "name_behind", name_b);
        set_field(me, "game_state", "top_speed", top_speed);
        set_field(me, "game_state", "res_medal", res_medal);
        set_field(me, "game_state", "res_value", res_value);
        set_field(me, "game_state", "res_best", res_best);
        set_field(me, "game_state", "res_fail", res_fail);
        set_field(me, "game_state", "endless_best", endless_best);
        let ms = ""; for m in medals { ms += `${m}`; }
        let bs = ""; for b in bests { bs += `${b};`; }
        set_field(me, "game_state", "save_medals", ms);
        set_field(me, "game_state", "save_bests", bs);
        set_field(me, "game_state", "save_rev", save_rev);
    }
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
