// hud.rhai — everything drawn over the road: the title menu, the GRAND TOUR
// screen, the briefing card, the dash and each event's readout, the results
// and the pause menu.
//
// Reads the game_state component scripts/drive.rhai publishes and the event
// table in scripts/lib/tour.rhai; draws with the immediate-mode API in
// logical points, scaled from a 720-point-high layout. drive.rhai owns the
// menus' cursors (it reads the menu actions in on_update); this script only
// draws them. The one exception is pause: on_draw_ui is the one callback
// that still runs while the game state is "paused", so the pause menu's
// cursor lives here and its choice goes to drive.rhai as game_state.cmd.
//
// Touch: the engine's stick and buttons (config/input.toml [touch_controls])
// are out only in the countdown and the drive; every other screen is tapped.
// A tap is tested against the rectangle its row was just drawn from, and what
// it chose goes to drive.rhai as game_state.cmd too (title:n | ev:n | paint:n
// | res:n | ok | back), since drive.rhai owns the cursors. Rows and buttons
// are at least TOUCH_MIN points tall on any device (so nothing moves under the
// first finger); while a finger was the last device (`touch`) the BACK and
// START buttons appear and the hint lines speak of thumbs and taps.

import "tour" as tour;

let game = -1;
let seen_event_time = -100.0;
let seen_pulse = -1.0;       // the pulse setting last drawn, and when it changed
let pulse_toast = -10.0;
let msg = "";
let msg_sub = "";
let msg_t = -100.0;
let msg_kind = "";
let flash_t = -100.0;
let ui_t = 0.0;
let p_sel = 0;                // pause menu cursor
// the settings (this script owns them; see "settings" in on_draw_ui)
let s_loaded = false;
let s_music = 1.0;            // 0-1: music volume
let s_sfx = 1.0;              // 0-1: everything that is not music
let s_pulse = 1.0;            // 0-1: how strongly the world moves with the music
let s_fx = 1.0;               // 0-1: the CRT glass
let s_shake = 1.0;            // 0-1: camera shake
let s_quality = 2;            // 0 low, 1 medium, 2 high
let s_units = 0;              // 0 km/h, 1 mph
let s_sel = 0;                // the Settings screen's cursor
let s_open = false;           // Settings is open over the pause menu
let s_was = false;            // Settings was showing last frame
let s_reset_t = -10.0;        // when RESET PROGRESS was first pressed (a second press within 3 s erases)
let s_erase = false;
let on_web = false;
let touch_mode = false;       // the last deliberate input was a finger (a mouse leaves it as it was)
let tc_out = -1;              // the last set_touch_controls(): -1 not yet, 0 away, 1 out
let TOUCH_MIN = 44.0;         // points: the least height of anything meant for a thumb
let EVENTS = [];
let LEGS = [];
let PAINTS = [];
let THEMES = [];
let medals = [];
let bests = [];
let save_key = "";

fn pad_int(n, width) {
    let s = `${n}`;
    while s.len() < width { s = "0" + s; }
    s
}

// m:ss.t
fn fmt_time(t) {
    let whole = t.to_int();
    let m = whole / 60;
    let s = whole % 60;
    let d = ((t - whole.to_float()) * 10.0).to_int();
    `${m}:${pad_int(s, 2)}.${d}`
}

// a display colour from a material colour: lifted so dark hues still read
fn lift(c) { sqrt(clamp(c, 0.0, 1.0)) * 0.85 + 0.15 }

fn medal_rgb(m) {
    if m == 3 { [1.0, 0.84, 0.25] } else if m == 2 { [0.80, 0.88, 1.0] } else if m == 1 { [0.95, 0.55, 0.28] } else { [0.45, 0.42, 0.6] }
}
fn medal_name(m) { if m == 3 { "GOLD" } else if m == 2 { "SILVER" } else if m == 1 { "BRONZE" } else { "NO MEDAL" } }

fn type_rgb(t) {
    if t == "sprint" { [0.40, 0.95, 1.0] } else if t == "race" { [1.0, 0.36, 0.52] } else if t == "drift" { [1.0, 0.85, 0.30] }
    else if t == "rush" { [0.50, 1.0, 0.62] } else { [0.86, 0.74, 1.0] }
}

fn glow_text(x, y, s, size, font, r, g, b, a, align, spacing) {
    // a thin halo of the hue under a near-white face. (Wide strokes are
    // stamped copies of the glyph and read as blocks, so the halo stays thin.)
    draw_text(x, y, s, size, #{ font: font, align: align, spacing: spacing, layer: 6,
        color: [0.55 + 0.45 * r, 0.55 + 0.45 * g, 0.55 + 0.45 * b, a],
        stroke: [r * 0.9, g * 0.9, b * 0.9, 0.28 * a, 1.0],
        shadow: [0.0, size * 0.05, 0.0, 0.0, 0.0, 0.55 * a] });
}

// Lettering as a lit tube: a soft halo of the hue under a near-white face
// (Flint #626 draws a glow as one cached picture). The picture is rebuilt
// when the text, its size or the glow changes, about a millisecond each,
// so this is for words and slow counters, not for figures that tick every
// frame, and the halo's own alpha stays fixed while the face fades.
fn neon_text(x, y, s, size, font, r, g, b, a, align, spacing) {
    draw_text(x, y, s, size, #{ font: font, align: align, spacing: spacing, layer: 6,
        color: [0.55 + 0.45 * r, 0.55 + 0.45 * g, 0.55 + 0.45 * b, a],
        glow: [r, g, b, 0.55, size * 0.22],
        shadow: [0.0, size * 0.05, 0.0, 0.0, 0.0, 0.55 * a] });
}

fn label(x, y, s, size, r, g, b, a, align) {
    draw_text(x, y, s, size, #{ font: "hud", align: align, spacing: size * 0.12, layer: 6,
        color: [r, g, b, a], shadow: [0.0, size * 0.08, 0.0, 0.0, 0.0, 0.6 * a] });
}

// text on a menu layer (above the overlays that dim the road)
fn mtext(x, y, s, size, font, c, a, align) {
    draw_text(x, y, s, size, #{ font: font, align: align, spacing: if font == "mono" { 0.0 } else { size * 0.10 }, layer: 13,
        color: [c[0], c[1], c[2], a] });
}

// the size at which `s` fits in `maxw`
fn fit(s, size, font, maxw) {
    let w = measure_text(s, size, #{ font: font, spacing: size * 0.10 }).width;
    if w > maxw { size * maxw / w } else { size }
}

// a medal: a filled disc with a ring, or an empty ring for none
fn medal(x, y, r, m, a) {
    let c = medal_rgb(m);
    if m > 0 {
        draw_circle(x, y, r, #{ color: [c[0] * 0.55, c[1] * 0.55, c[2] * 0.55, a], layer: 13 });
        draw_circle_outline(x, y, r, #{ color: [c[0], c[1], c[2], a], thickness: max(r * 0.16, 1.0), layer: 14 });
        draw_circle_outline(x, y, r * 0.55, #{ color: [c[0], c[1], c[2], 0.7 * a], thickness: max(r * 0.10, 1.0), layer: 14 });
    } else {
        draw_circle_outline(x, y, r, #{ color: [c[0], c[1], c[2], 0.6 * a], thickness: max(r * 0.12, 1.0), layer: 13 });
    }
}

fn panel(x, y, w, h, c, fill_a, line_a, u) {
    draw_rect(x, y, w, h, #{ color: [0.035, 0.012, 0.085, fill_a], rounding: 6.0 * u, layer: 11 });
    draw_rect_outline(x, y, w, h, #{ color: [c[0], c[1], c[2], line_a], thickness: 1.5 * u, rounding: 6.0 * u, layer: 12 });
}

// whether a tap landed in the rectangle r = [x, y, w, h] (points)
fn hit(taps, r) {
    for t in taps { if t[0] >= r[0] && t[0] < r[0] + r[2] && t[1] >= r[1] && t[1] < r[1] + r[3] { return true; } }
    false
}

// a menu button: the rectangle r, its word centred in it
fn button(r, s, size, c, line_a, text_a, sel, u) {
    draw_rect(r[0], r[1], r[2], r[3], #{ color: [0.035, 0.012, 0.085, 0.92], rounding: 5.0 * u, layer: 11 });
    draw_rect_outline(r[0], r[1], r[2], r[3], #{ color: [c[0], c[1], c[2], line_a], thickness: (if sel { 2.0 } else { 1.0 }) * u, rounding: 5.0 * u, layer: 12 });
    mtext(r[0] + r[2] * 0.5, r[1] + (r[3] - size * 1.2) * 0.5, s, size, "hud", c, text_a, "center");
}

fn ordinal(p) { if p == 1 { "1ST" } else if p == 2 { "2ND" } else if p == 3 { "3RD" } else { `${p}TH` } }

fn traffic_word(n) { if n <= 0 { "NONE" } else if n <= 5 { "LIGHT" } else if n <= 8 { "MEDIUM" } else { "HEAVY" } }

fn theme_line(e, themes) {
    let s = "";
    let last = -1;
    for sec in e.secs {
        if sec[0] != last {
            if s != "" { s += "  >  "; }
            s += themes[sec[0]];
            last = sec[0];
        }
    }
    s
}

// the next medal a value has not reached yet: [medal, target] or [0, 0]
fn next_target(e, v) {
    for k in 0..3 { if v < e.targets[k] { return [k + 1, e.targets[k]]; } }
    [0, 0.0]
}

fn on_init() {
    game = get_entity("game");
    EVENTS = tour::events();
    LEGS = tour::leg_names();
    PAINTS = tour::paints();
    THEMES = tour::theme_names();
    for e in EVENTS { medals.push(0); bests.push(-1.0); }
    set_touch_controls(false);          // the game opens on a menu
    on_web = gpu_info().platform == "web";
}

fn on_draw_ui() {
    if game < 0 { return; }
    let gs = get_component(game, "game_state");
    if gs == () { return; }
    let sw = screen_width();
    let sh = screen_height();
    let u = sh / 720.0;
    let cx = sw * 0.5;
    let now = total_time();
    ui_t += 1.0 / 60.0;
    let mode = gs.mode;
    let mt = gs.mode_time;
    let kind = gs.kind;
    let dev = last_input_device();
    let pad = dev == "gamepad";
    if dev == "touch" { touch_mode = true; } else if dev == "keyboard" || pad { touch_mode = false; }
    let touch = touch_mode || touch_controls_visible();
    let tmin = TOUCH_MIN;         // on a small screen rows are a thumb high whatever the device, so nothing moves under the first finger
    let taps = [];
    for i in 0..tap_count() { taps.push([tap_x(i) * sw, tap_y(i) * sh]); }
    let tap_cmd = "";

    // the save, as drive.rhai last published it
    let key = gs.save_medals + gs.save_bests;
    if key != save_key && gs.save_medals.len() >= EVENTS.len() {
        save_key = key;
        let parts = gs.save_bests.split(";");
        for i in 0..EVENTS.len() {
            medals[i] = gs.save_medals.sub_string(i, 1).parse_int();
            if i < parts.len() && parts[i] != "" { bests[i] = parts[i].parse_float(); }
        }
    }
    let ei = gs.ev_idx;
    let has_ev = kind == "event" && ei >= 0 && ei < EVENTS.len();
    let E = if has_ev { EVENTS[ei] } else { #{ type: gs.ev_type, name: if kind == "endless" { "HORIZON" } else { "ARCADE" }, targets: [0.0, 0.0, 0.0], max_crashes: 3 } };
    let ty = E.type;

    // stage colours
    let ar = lift(gs.accent_r); let ag = lift(gs.accent_g); let ab = lift(gs.accent_b);
    let br = lift(gs.second_r); let bg = lift(gs.second_g); let bb = lift(gs.second_b);
    let AC = [ar, ag, ab];
    let GOLD = [1.0, 0.9, 0.5];
    let PALE = [0.75, 0.8, 1.0];
    let WHITE = [1.0, 0.97, 0.92];

    // ── pause ───────────────────────────────────────────────────
    let paused = get_current_state() == "paused";
    if is_action_just_pressed("pause") {
        if paused { pop_state(); paused = false; }
        else if mode == "drive" { push_state("paused"); paused = true; p_sel = 0; }
    } else if paused && !s_open {
        if is_action_just_pressed("menu_up") { p_sel = (p_sel + 3) % 4; }
        if is_action_just_pressed("menu_down") { p_sel = (p_sel + 1) % 4; }
        if is_action_just_pressed("back") { pop_state(); paused = false; }
        else if is_action_just_pressed("confirm") {
            if p_sel == 2 { s_open = true; }
            else {
                if p_sel == 1 { set_field(game, "game_state", "cmd", "restart"); }
                else if p_sel == 3 { set_field(game, "game_state", "cmd", "quit"); }
                pop_state(); paused = false;
            }
        }
    }
    // the stick and buttons are out only while there is a car to drive
    let want_tc = if (mode == "drive" || mode == "countdown") && !paused { 1 } else { 0 };
    if want_tc != tc_out { set_touch_controls(want_tc == 1); tc_out = want_tc; }

    // ── events become words ─────────────────────────────────────
    if gs.event_time != seen_event_time {
        seen_event_time = gs.event_time;
        let e = gs.event;
        if e == "count" { msg = `${gs.event_value.to_int()}`; msg_sub = ""; msg_t = now; msg_kind = "count"; }
        else if e == "go" { msg = "GO"; msg_sub = ""; msg_t = now; msg_kind = "go"; }
        else if e == "checkpoint" {
            msg = "CHECKPOINT"; msg_sub = `EXTENDED PLAY  +${gs.event_value.to_int()} SEC`;
            msg_t = now; msg_kind = "big"; flash_t = now;
        }
        else if e == "stage" { msg = "GATE"; msg_sub = ""; msg_t = now; msg_kind = "small"; }
        else if e == "near_miss" { msg = "CLOSE PASS"; msg_sub = `+${gs.event_value.to_int()}`; msg_t = now; msg_kind = "small"; }
        else if e == "drift" { msg = `+${gs.event_value.to_int()}`; msg_sub = "DRIFT"; msg_t = now; msg_kind = "small"; }
        else if e == "air" { msg = "AIR"; msg_sub = `+${gs.event_value.to_int()}`; msg_t = now; msg_kind = "small"; }
        else if e == "crash" || e == "spin" {
            if e == "crash" { flash_t = now; }
            if gs.event_value > 0.0 { msg = "DRIFT LOST"; msg_sub = `${gs.event_value.to_int()}`; msg_t = now; msg_kind = "lost"; }
        }
    }

    // ── settings ────────────────────────────────────────────────
    // This script owns the settings: it is the one awake while paused. They
    // are loaded once, kept in the save, and published in game_state for
    // drive.rhai (pulse, shake_amt, fx_amt) and audio.rhai (vol_music, vol_sfx).
    let s_changed = false;
    let s_store = true;          // a change is saved; the first load is not
    if !s_loaded {
        s_loaded = true;
        s_pulse = gs.pulse;                    // the scene's value, unless the save has one
        if gs.persist {
            let keys = ["set_music", "set_sfx", "pulse", "set_fx", "set_shake"];
            let got = [s_music, s_sfx, s_pulse, s_fx, s_shake];
            for i in 0..5 {
                let v = persist_get(keys[i]);
                if type_of(v) == "f64" { got[i] = clamp(v, 0.0, 1.0); } else if type_of(v) == "i64" { got[i] = clamp(v.to_float(), 0.0, 1.0); }
            }
            s_music = got[0]; s_sfx = got[1]; s_pulse = got[2]; s_fx = got[3]; s_shake = got[4];
            let q = persist_get("set_quality");
            if type_of(q) == "i64" && q >= 0 && q <= 2 { s_quality = q; }
            let un = persist_get("set_units");
            if type_of(un) == "i64" && un >= 0 && un <= 1 { s_units = un; }
        }
        s_changed = true; s_store = false;
    }
    // M, anywhere: the pulse off, half, full
    if is_action_just_pressed("pulse") && mode != "settings" && !s_open {
        s_pulse = if s_pulse > 0.75 { 0.0 } else if s_pulse > 0.25 { 1.0 } else { 0.5 };
        s_changed = true;
    }
    if !paused { s_open = false; }
    if mode != "settings" && !s_open { s_was = false; }
    if mode == "settings" || s_open {
        let from_title = mode == "settings";
        let names = ["MUSIC", "EFFECTS", "PULSE", "SCREEN GLASS", "CAMERA SHAKE", "QUALITY", "SPEED IN"];
        let helps = [
            "THE RADIO",
            "ENGINE, TYRES, WIND AND EVERY CHIME",
            if on_web { "HOW STRONGLY THE WORLD MOVES WITH THE MUSIC     NOT ON THE WEB BUILD YET" } else if touch { "HOW STRONGLY THE WORLD MOVES WITH THE MUSIC" } else { "HOW STRONGLY THE WORLD MOVES WITH THE MUSIC     M STEPS IT WHILE YOU DRIVE" },
            "COLOUR FRINGING, SCAN LINES AND GRAIN",
            "HOW HARD THE CAMERA IS THROWN BY A CRASH, A LANDING, THE SHOULDER",
            "HIGH: SMOOTH EDGES     MEDIUM: PLAIN EDGES     LOW: PLAIN EDGES, FEWER PIXELS, NO CONTACT SHADE",
            "THE SPEEDOMETER'S UNIT",
        ];
        let i_reset = -1;
        if from_title && gs.persist { i_reset = names.len(); names.push("RESET PROGRESS"); helps.push("ERASES EVERY MEDAL, BEST AND PAINT. THESE SETTINGS STAY."); }
        let i_back = names.len();
        names.push(if from_title { "BACK" } else { "BACK TO PAUSE" }); helps.push("");
        let nr = names.len();
        let steps = [0.1, 0.1, 0.05, 0.1, 0.1];
        let vals = [s_music, s_sfx, s_pulse, s_fx, s_shake];
        let dir = 0; let ok = false; let leave = false;
        if !s_was { s_was = true; s_sel = 0; s_reset_t = -10.0; }      // just opened: this frame's press opened it
        else {
            if is_action_just_pressed("menu_up") { s_sel = (s_sel + nr - 1) % nr; }
            if is_action_just_pressed("menu_down") { s_sel = (s_sel + 1) % nr; }
            if is_action_just_pressed("menu_left") { dir = -1; } else if is_action_just_pressed("menu_right") { dir = 1; }
            if is_action_just_pressed("confirm") { ok = true; }
            if is_action_just_pressed("back") { leave = true; }
        }

        // ---- the sheet ----
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, if from_title { 0.60 } else { 0.78 }], rounding: 0.0, layer: 10 });
        draw_text(cx, sh * 0.055, "SETTINGS", 46.0 * u, #{ font: "hud", align: "center", layer: 13, spacing: 7.0 * u,
            color: [0.5, 0.95, 1.0, 1.0], stroke: [0.2, 0.8, 1.0, 0.3, 1.0] });
        let top = sh * 0.19;
        let pitch = min(max(48.0 * u, tmin), sh * 0.66 / nr.to_float());
        let rh = pitch - 5.0 * u;
        let W = min(max(760.0 * u, 9.0 * tmin), sw - 32.0);
        let x0 = cx - W * 0.5;
        let fs = min(max(17.0 * u, 12.0), rh * 0.42);
        let bx = x0 + W * 0.40; let bw = W * 0.40;
        for i in 0..nr {
            let y = top + i.to_float() * pitch;
            let r = [x0, y, W, rh];
            let ym = y + rh * 0.5;
            let tapped = hit(taps, r);
            if tapped { s_sel = i; }
            let sel = s_sel == i;
            let c = if sel { GOLD } else { PALE };
            draw_rect(x0, y, W, rh, #{ color: [0.035, 0.012, 0.085, if sel { 0.92 } else { 0.55 }], rounding: 5.0 * u, layer: 11 });
            draw_rect_outline(x0, y, W, rh, #{ color: [c[0], c[1], c[2], if sel { 0.75 + 0.25 * sin(ui_t * 6.0) } else { 0.18 }], thickness: (if sel { 2.0 } else { 1.0 }) * u, rounding: 5.0 * u, layer: 12 });
            let ty = ym - fs * 0.6;
            if i == i_back {
                mtext(cx, ty, names[i], fs, "hud", c, 1.0, "center");
                if tapped || (sel && ok) { leave = true; }
            } else if i == i_reset {
                let armed = ui_t - s_reset_t < 3.0;
                let rc = if armed { [1.0, 0.3, 0.42] } else { c };
                mtext(x0 + 18.0 * u, ty, names[i], fs, "hud", rc, 1.0, "left");
                mtext(x0 + W - 18.0 * u, ym - fs * 0.45, if armed { "AGAIN TO ERASE" } else { "" }, fs * 0.75, "mono", rc, 1.0, "right");
                if tapped || (sel && ok) {
                    if armed { s_erase = true; } else { s_reset_t = ui_t; }
                }
            } else {
                mtext(x0 + 18.0 * u, ty, names[i], fs, "hud", c, 1.0, "left");
                if i < 5 {
                    // a slider: the track, what is filled, the knob, and a tick at every tenth
                    let v = vals[i];
                    for t in taps {
                        if t[1] >= y && t[1] < y + rh && t[0] >= bx - 14.0 * u && t[0] <= bx + bw + 14.0 * u {
                            v = clamp((t[0] - bx) / bw, 0.0, 1.0);
                        }
                    }
                    if sel && dir != 0 { v = v + dir.to_float() * steps[i]; }
                    v = clamp(floor(floor(v / steps[i] + 0.5) * steps[i] * 100.0 + 0.5) / 100.0, 0.0, 1.0);
                    if v != vals[i] { vals[i] = v; s_changed = true; }
                    draw_rect(bx, ym - 1.5 * u, bw, 3.0 * u, #{ color: [c[0], c[1], c[2], 0.28], rounding: 1.5 * u, layer: 12 });
                    for k in 0..11 { draw_rect(bx + bw * k.to_float() * 0.1 - 0.5 * u, ym + 6.0 * u, 1.0 * u, 4.0 * u, #{ color: [c[0], c[1], c[2], 0.35], rounding: 0.0, layer: 12 }); }
                    draw_rect(bx, ym - 2.5 * u, bw * v, 5.0 * u, #{ color: [c[0], c[1], c[2], 0.95], rounding: 2.5 * u, layer: 13 });
                    draw_rect(bx + bw * v - 4.0 * u, ym - 10.0 * u, 8.0 * u, 20.0 * u, #{ color: [1.0, 1.0, 1.0, 1.0], rounding: 2.0 * u, layer: 14 });
                    let pct = (v * 100.0 + 0.5).to_int();
                    let word = if i == 2 && on_web { "WEB: OFF" } else if pct == 0 { "OFF" } else { `${pct}%` };
                    mtext(x0 + W - 18.0 * u, ym - fs * 0.45, word, fs * 0.8, "mono", c, 1.0, "right");
                } else {
                    // a choice: sideways, Enter or a tap steps it
                    let step = if sel && dir != 0 { dir } else if tapped || (sel && ok) { 1 } else { 0 };
                    if i == 5 {
                        if step != 0 { s_quality = (s_quality + step + 3) % 3; s_changed = true; }
                        mtext(bx + bw * 0.5, ty, `<   ${["LOW", "MEDIUM", "HIGH"][s_quality]}   >`, fs, "hud", c, 1.0, "center");
                    } else {
                        if step != 0 { s_units = (s_units + step + 2) % 2; s_changed = true; }
                        mtext(bx + bw * 0.5, ty, `<   ${["KM/H", "MPH"][s_units]}   >`, fs, "hud", c, 1.0, "center");
                    }
                }
            }
        }
        s_music = vals[0]; s_sfx = vals[1]; s_pulse = vals[2]; s_fx = vals[3]; s_shake = vals[4];
        mtext(cx, top + nr.to_float() * pitch + 8.0 * u, helps[s_sel], max(12.0 * u, tmin * 0.21), "mono", GOLD, 0.85, "center");
        let hint = if touch { "TAP A ROW     TAP ALONG A BAR TO SET IT" } else if pad { "D-PAD  CHOOSE AND CHANGE     B  BACK" } else { "UP DOWN  CHOOSE     LEFT RIGHT  CHANGE     BACKSPACE  BACK" };
        mtext(cx, sh * 0.955, hint, max(12.0 * u, tmin * 0.21), "mono", PALE, 0.6, "center");
        if leave {
            s_was = false;
            if from_title { tap_cmd = "back"; } else { s_open = false; p_sel = 2; }
        }
    }
    if s_changed {
        set_field(game, "game_state", "pulse", s_pulse);
        set_field(game, "game_state", "vol_music", s_music);
        set_field(game, "game_state", "vol_sfx", s_sfx);
        set_field(game, "game_state", "shake_amt", s_shake);
        set_field(game, "game_state", "fx_amt", s_fx);
        // the glass: scan lines and grain here, the colour fringing in drive.rhai
        set_post_style_param("crt", "scanlines", 0.14 * s_fx);
        set_post_style_param("crt", "grain", 0.035 * s_fx);
        if s_quality == 2 { set_quality(#{ msaa: 4, render_scale: 1.0, ssao: true }); }
        else if s_quality == 1 { set_quality(#{ msaa: 1, render_scale: 1.0, ssao: true }); }
        else { set_quality(#{ msaa: 1, render_scale: 0.7, ssao: false }); }
        if gs.persist && s_store {
            persist_set("set_music", s_music); persist_set("set_sfx", s_sfx); persist_set("pulse", s_pulse);
            persist_set("set_fx", s_fx); persist_set("set_shake", s_shake);
            persist_set("set_quality", s_quality); persist_set("set_units", s_units);
            persist_set("save_version", 2);
            persist_save();
        }
    }
    if s_erase {
        // medals, bests and paint go; the settings were just written back
        s_erase = false;
        persist_clear();
        persist_set("set_music", s_music); persist_set("set_sfx", s_sfx); persist_set("pulse", s_pulse);
        persist_set("set_fx", s_fx); persist_set("set_shake", s_shake);
        persist_set("set_quality", s_quality); persist_set("set_units", s_units);
        persist_set("save_version", 2);
        persist_save();
        // drive.rhai holds the medals in memory: it forgets them and shows the title
        s_was = false;
        set_field(game, "game_state", "cmd", "erase");
        return;
    }
    if mode == "settings" || s_open {
        if tap_cmd != "" { set_field(game, "game_state", "cmd", tap_cmd); }
        return;
    }

    // ── title ───────────────────────────────────────────────────
    if mode == "title" {
        let a = clamp(mt / 1.2, 0.0, 1.0);
        draw_rect_gradient(0.0, 0.0, sw, sh * 0.52, #{ from: [0.02, 0.0, 0.06, 0.72 * a], to: [0.02, 0.0, 0.06, 0.0], vertical: true, layer: 0 });
        draw_rect_gradient(0.0, sh * 0.52, sw, sh * 0.48, #{ from: [0.02, 0.0, 0.06, 0.0], to: [0.02, 0.0, 0.06, 0.86 * a], vertical: true, layer: 0 });
        // the wordmark, two tubes offset: magenta under cyan
        let ty0 = sh * 0.12;
        let ts = 104.0 * u;
        draw_text(cx + 4.0 * u, ty0 + 4.0 * u, "AFTERGLOW", ts, #{ font: "title", align: "center", layer: 3,
            color: [1.0, 0.15, 0.6, 0.85 * a] });
        draw_text(cx, ty0, "AFTERGLOW", ts, #{ font: "title", align: "center", layer: 5,
            color: [0.55, 0.97, 1.0, a] });
        label(cx, ty0 + 142.0 * u, "OUTRUN  THE  DARK", 17.0 * u, 1.0, 0.85, 0.45, 0.95 * a, "center");
        // the menu
        let open = tour::endless_unlocked(medals);
        let n_med = tour::medal_count(medals);
        let names = ["ARCADE", "GRAND TOUR", "HORIZON", "SETTINGS"];
        let subs = [
            if gs.hi_score > 0.0 { `FIVE STAGES, ONE CLOCK      BEST ${pad_int(gs.hi_score.to_int(), 8)}` } else { "FIVE STAGES, ONE CLOCK" },
            `FIFTEEN EVENTS IN FIVE LEGS      ${n_med} / 15 MEDALS`,
            if !open { "LOCKED: WIN A MEDAL IN EVERY EVENT OF LEG 1" } else if gs.endless_best > 0.0 { `THE ROAD THAT DOES NOT END      BEST ${pad_int(gs.endless_best.to_int(), 8)}` } else { "THE ROAD THAT DOES NOT END" },
            "SOUND, THE PULSE, THE PICTURE",
        ];
        let pitch = max(59.0 * u, tmin + 2.0);
        let my = min(sh * 0.50, sh * 0.905 - 4.0 * pitch);     // four rows clear of the hints on a short screen
        // three figures: the game's whole vocabulary (left out where a short screen needs the room for rows)
        let fy = ty0 + 192.0 * u;
        if my > fy + 34.0 * u {
            draw_circle_outline(cx - 64.0 * u, fy, 13.0 * u, #{ color: [0.25, 0.55, 1.0, a], thickness: 2.5 * u, layer: 5 });
            draw_polygon_outline([[cx, fy - 15.0 * u], [cx + 15.0 * u, fy + 12.0 * u], [cx - 15.0 * u, fy + 12.0 * u]],
                1.0, 0.86, 0.2, a, 2.5 * u, true, 5);
            draw_rect_outline(cx + 51.0 * u, fy - 13.0 * u, 26.0 * u, 26.0 * u, #{ color: [1.0, 0.2, 0.25, a], thickness: 2.5 * u, rounding: 0.0, layer: 5 });
        }
        let rw = max(600.0 * u, 6.5 * tmin);
        for i in 0..4 {
            let sel = gs.menu_title == i;
            let locked = i == 2 && !open;
            // the row: what a tap is tested against, and where its words sit
            let row = [cx - rw * 0.5, my + i.to_float() * pitch - 4.0 * u, rw, pitch - 2.0];
            let yy = my + i.to_float() * pitch + (pitch - 59.0 * u) * 0.5;
            if touch { draw_rect_outline(row[0], row[1], row[2], row[3], #{ color: [0.7, 0.8, 1.0, (if sel { 0.34 } else { 0.16 }) * a], thickness: 1.0, rounding: 5.0 * u, layer: 4 }); }
            if a > 0.3 && hit(taps, row) { tap_cmd = `title:${i}`; }
            let c = if locked { [0.5, 0.45, 0.65] } else if sel { [1.0, 0.9, 0.5] } else { [0.7, 0.8, 1.0] };
            let pulse = if sel { 0.85 + 0.15 * sin(ui_t * 6.0) } else { 0.62 };
            if sel {
                neon_text(cx, yy, names[i], 34.0 * u, "hud", c[0], c[1], c[2], pulse * a, "center", 4.0 * u);
                let hw = measure_text(names[i], 34.0 * u, #{ font: "hud", spacing: 4.0 * u }).width * 0.5 + 26.0 * u;
                let ym = yy + 21.0 * u;
                draw_polygon([[cx - hw, ym - 8.0 * u], [cx - hw + 12.0 * u, ym], [cx - hw, ym + 8.0 * u]], c[0], c[1], c[2], a, 6);
                draw_polygon([[cx + hw, ym - 8.0 * u], [cx + hw - 12.0 * u, ym], [cx + hw, ym + 8.0 * u]], c[0], c[1], c[2], a, 6);
            } else {
                label(cx, yy + 4.0 * u, names[i], 26.0 * u, c[0], c[1], c[2], pulse * a, "center");
            }
            draw_text(cx, yy + (if sel { 42.0 } else { 36.0 }) * u, subs[i], 12.0 * u,
                #{ font: "mono", align: "center", color: [c[0], c[1], c[2], (if sel { 0.85 } else { 0.45 }) * a], layer: 5 });
        }
        let hint1 = if touch { "TAP  A  ROAD" } else if pad { "STICK / D-PAD  CHOOSE     A / START  GO" } else { "UP DOWN  CHOOSE     ENTER  GO     OR  TAP  A  ROAD" };
        let hint2 = if touch { "LEFT THUMB  STEER     THE GAS IS AUTOMATIC     RIGHT THUMB  BRAKE  DRIFT  BOOST" } else if pad { "RT  ACCELERATE   LT  BRAKE   STICK  STEER   A  HANDBRAKE   X / RB  BOOST   BACK  PAUSE" }
            else { "W/UP  ACCELERATE   S/DOWN  BRAKE   A D  STEER   SPACE  HANDBRAKE   SHIFT  BOOST   P  PAUSE" };
        let hs = max(12.0 * u, tmin * 0.21);
        draw_text(cx, sh * 0.925, hint1, max(13.0 * u, hs), #{ font: "mono", align: "center", color: [1.0, 0.85, 0.55, 0.8 * a], layer: 5 });
        draw_text(cx, sh * 0.955, hint2, hs, #{ font: "mono", align: "center", color: [0.75, 0.8, 1.0, 0.6 * a], layer: 5 });
        if tap_cmd != "" { set_field(game, "game_state", "cmd", tap_cmd); }
        return;
    }

    // ── the tour screen ─────────────────────────────────────────
    if mode == "tour" {
        let a = clamp(mt / 0.35, 0.0, 1.0);
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, 0.80 * a], rounding: 0.0, layer: 10 });
        let x0 = 40.0 * u;
        let W = sw - 80.0 * u;
        // a phone has no back gesture a game can hear: BACK is a button, beside the title
        let back_w = 0.0;
        if touch {
            let bh = max(44.0 * u, tmin);
            let rb = [x0, 54.0 * u - bh * 0.5, max(104.0 * u, 2.0 * tmin), bh];
            button(rb, "BACK", max(14.0 * u, 11.0), PALE, 0.5 * a, a, false, u);
            let bm = rb[1] + bh * 0.5;
            draw_polygon([[rb[0] + 10.0 * u, bm], [rb[0] + 19.0 * u, bm - 6.0 * u], [rb[0] + 19.0 * u, bm + 6.0 * u]], PALE[0], PALE[1], PALE[2], a, 13);
            if hit(taps, rb) { tap_cmd = "back"; }
            back_w = rb[2] + 18.0 * u;
        }
        draw_text(x0 + back_w, 20.0 * u, "GRAND TOUR", 46.0 * u, #{ font: "title", layer: 13, color: [0.55, 0.97, 1.0, a] });
        // medal tally
        let cnt = [0, 0, 0, 0];
        for m in medals { cnt[m] += 1; }
        let tx = sw - 40.0 * u;
        mtext(tx, 30.0 * u, `${cnt[1] + cnt[2] + cnt[3]} / 15 MEDALS`, 16.0 * u, "hud", GOLD, a, "right");
        for k in 0..3 {
            let m = 3 - k;
            let mx = tx - 250.0 * u + k.to_float() * 86.0 * u;
            medal(mx, 68.0 * u, 9.0 * u, m, a);
            mtext(mx + 16.0 * u, 59.0 * u, `${cnt[m]}`, 16.0 * u, "hud", medal_rgb(m), a, "left");
        }
        // five legs, three events each
        let gap = 10.0 * u;
        let cw = (W - 4.0 * gap) / 5.0;
        let top = 104.0 * u;
        let ch = 78.0 * u;
        let sel_i = gs.menu_leg * 3 + (if gs.menu_row < 3 { gs.menu_row } else { 2 });
        // a card's tap target: the card and, for a thumb, up to half the gap either side
        let cg = clamp((tmin - ch) * 0.5, 0.0, 4.0 * u);
        for leg in 0..5 {
            let x = x0 + leg.to_float() * (cw + gap);
            let leg_open = tour::unlocked(leg * 3, medals);
            let lc = if leg_open { [0.6, 0.95, 1.0] } else { [0.45, 0.42, 0.6] };
            mtext(x + 2.0 * u, top, `LEG ${leg + 1}`, 11.0 * u, "hud", lc, 0.8 * a, "left");
            mtext(x + 2.0 * u, top + 14.0 * u, LEGS[leg], 15.0 * u, "hud", lc, a, "left");
            draw_line(x, top + 38.0 * u, x + cw, top + 38.0 * u, #{ color: [lc[0], lc[1], lc[2], 0.5 * a], thickness: 1.0 * u, layer: 12 });
            for row in 0..3 {
                let i = leg * 3 + row;
                let e = EVENTS[i];
                let y = top + 48.0 * u + row.to_float() * (ch + 8.0 * u);
                let open = tour::unlocked(i, medals);
                let sel = gs.menu_leg == leg && gs.menu_row == row;
                let tc = type_rgb(e.type);
                let dim = if open { 1.0 } else { 0.38 };
                let line = if sel { [1.0, 0.9, 0.5] } else { tc };
                if hit(taps, [x, y - cg, cw, ch + 2.0 * cg]) { tap_cmd = `ev:${i}`; }
                draw_rect(x, y, cw, ch, #{ color: [if sel { 0.10 } else { 0.035 }, if sel { 0.05 } else { 0.012 }, if sel { 0.16 } else { 0.085 }, 0.92 * a], rounding: 5.0 * u, layer: 11 });
                draw_rect_outline(x, y, cw, ch, #{ color: [line[0], line[1], line[2], (if sel { 0.75 + 0.25 * sin(ui_t * 6.0) } else { 0.35 * dim }) * a], thickness: (if sel { 2.0 } else { 1.0 }) * u, rounding: 5.0 * u, layer: 12 });
                draw_rect(x + 8.0 * u, y + 10.0 * u, 3.0 * u, ch - 20.0 * u, #{ color: [tc[0], tc[1], tc[2], 0.9 * dim * a], rounding: 0.0, layer: 12 });
                mtext(x + 18.0 * u, y + 8.0 * u, tour::type_label(e.type), 10.0 * u, "hud", tc, dim * a, "left");
                let ns = fit(e.name, 14.0 * u, "hud", cw - 80.0 * u);
                mtext(x + 18.0 * u, y + 25.0 * u, e.name, ns, "hud", WHITE, dim * a, "left");
                if open {
                    let bt = if bests[i] >= 0.0 { tour::value_text(e, bests[i]) } else { `${(e.km * 10.0).to_int().to_float() / 10.0} KM` };
                    mtext(x + 18.0 * u, y + 52.0 * u, bt, 11.0 * u, "mono", PALE, 0.8 * a, "left");
                    medal(x + cw - 22.0 * u, y + ch * 0.5, 11.0 * u, medals[i], a);
                } else {
                    mtext(x + 18.0 * u, y + 52.0 * u, "LOCKED", 11.0 * u, "mono", [0.6, 0.55, 0.75], 0.7 * a, "left");
                }
            }
        }
        // the event under the cursor
        let e = EVENTS[sel_i];
        let open = tour::unlocked(sel_i, medals);
        let dy = top + 48.0 * u + 3.0 * (ch + 8.0 * u) + 4.0 * u;
        let dh = 150.0 * u;
        let tc = type_rgb(e.type);
        panel(x0, dy, W, dh, tc, 0.92 * a, 0.5 * a, u);
        mtext(x0 + 20.0 * u, dy + 14.0 * u, `LEG ${e.leg + 1}  EVENT ${sel_i % 3 + 1}     ${tour::type_label(e.type)}`, 11.0 * u, "hud", tc, a, "left");
        mtext(x0 + 20.0 * u, dy + 32.0 * u, e.name, fit(e.name, 26.0 * u, "hud", W * 0.52), "hud", WHITE, a, "left");
        let bl = tour::brief_lines(e);
        mtext(x0 + 20.0 * u, dy + 72.0 * u, bl[0], 12.0 * u, "mono", PALE, 0.9 * a, "left");
        mtext(x0 + 20.0 * u, dy + 90.0 * u, bl[1], 12.0 * u, "mono", PALE, 0.9 * a, "left");
        let info = `${(e.km * 10.0).to_int().to_float() / 10.0} KM     TRAFFIC ${traffic_word(e.traffic[0])}` + (if e.rivals.len() > 0 { `     ${e.rivals.len()} RIVALS` } else { "" });
        mtext(x0 + 20.0 * u, dy + 114.0 * u, theme_line(e, THEMES), 11.0 * u, "hud", [1.0, 0.75, 0.9], 0.9 * a, "left");
        mtext(x0 + 20.0 * u, dy + 130.0 * u, info, 11.0 * u, "mono", GOLD, 0.85 * a, "left");
        let rx = x0 + W - 300.0 * u;
        if open {
            for k in 0..3 {
                let m = 3 - k;
                let yy = dy + 22.0 * u + k.to_float() * 28.0 * u;
                medal(rx, yy + 8.0 * u, 8.0 * u, m, a);
                mtext(rx + 20.0 * u, yy, medal_name(m), 12.0 * u, "hud", medal_rgb(m), a, "left");
                mtext(rx + 280.0 * u, yy, tour::target_text(e, m - 1), 12.0 * u, "hud", WHITE, a, "right");
            }
            let bt = if bests[sel_i] >= 0.0 { tour::value_text(e, bests[sel_i]) } else { "NOT YET DRIVEN" };
            mtext(rx - 10.0 * u, dy + 116.0 * u, "YOUR BEST", 11.0 * u, "hud", PALE, 0.8 * a, "left");
            mtext(rx + 280.0 * u, dy + 114.0 * u, bt, 14.0 * u, "hud", GOLD, a, "right");
        } else {
            let why = if sel_i % 3 == 2 && tour::unlocked(sel_i - 1, medals) { "WIN A MEDAL IN BOTH EVENTS OF THIS LEG" } else { `WIN A MEDAL IN LEG ${e.leg}'S FINALE` };
            mtext(rx + 280.0 * u, dy + 40.0 * u, "LOCKED", 22.0 * u, "hud", [0.75, 0.6, 0.9], a, "right");
            mtext(rx + 280.0 * u, dy + 74.0 * u, why, 12.0 * u, "mono", PALE, 0.9 * a, "right");
        }
        // paint
        let py = dy + dh + 14.0 * u;
        let pfocus = gs.menu_row == 3;
        let have = cnt[1] + cnt[2] + cnt[3];
        let ph = max(34.0 * u, tmin);
        mtext(x0 + 2.0 * u, py + (ph - 18.0 * u) * 0.5, "PAINT", 13.0 * u, "hud", if pfocus { GOLD } else { PALE }, a, "left");
        let pw = 210.0 * u;
        for k in 0..PAINTS.len() {
            let P = PAINTS[k];
            let x = x0 + 90.0 * u + k.to_float() * (pw + 10.0 * u);
            let got = have >= P.need;
            let cur = gs.paint == k;
            let c = P.c;
            let mxc = max(max(c[0], c[1]), c[2]);
            let sc = [0.25 + 0.75 * c[0] / mxc, 0.25 + 0.75 * c[1] / mxc, 0.25 + 0.75 * c[2] / mxc];
            if hit(taps, [x, py, pw, ph]) { tap_cmd = `paint:${k}`; }
            draw_rect(x, py, pw, ph, #{ color: [0.035, 0.012, 0.085, 0.92 * a], rounding: 5.0 * u, layer: 11 });
            draw_rect_outline(x, py, pw, ph, #{ color: [if cur && pfocus { 1.0 } else { sc[0] }, if cur && pfocus { 0.9 } else { sc[1] }, if cur && pfocus { 0.5 } else { sc[2] }, (if cur { if pfocus { 0.75 + 0.25 * sin(ui_t * 6.0) } else { 0.8 } } else { 0.25 }) * a], thickness: (if cur { 2.0 } else { 1.0 }) * u, rounding: 5.0 * u, layer: 12 });
            draw_rect(x + 8.0 * u, py + (ph - 18.0 * u) * 0.5, 18.0 * u, 18.0 * u, #{ color: [sc[0], sc[1], sc[2], (if got { 1.0 } else { 0.3 }) * a], rounding: 3.0 * u, layer: 12 });
            mtext(x + 34.0 * u, py + (ph - 14.0 * u) * 0.5, if got { P.name } else { `${P.need} MEDALS` }, 11.0 * u, "hud", if got { WHITE } else { [0.6, 0.55, 0.75] }, (if got { 1.0 } else { 0.7 }) * a, "left");
        }
        let hint = if touch { "TAP AN EVENT FOR ITS BRIEFING     TAP A PAINT TO WEAR IT" } else if pad { "STICK / D-PAD  CHOOSE     A  DRIVE     B  TITLE" } else { "ARROWS / WASD  CHOOSE     ENTER  DRIVE     BACKSPACE  TITLE" };
        mtext(cx, max(sh - 26.0 * u, py + ph + 5.0 * u), hint, max(12.0 * u, tmin * 0.21), "mono", GOLD, 0.75 * a, "center");
        if tap_cmd != "" { set_field(game, "game_state", "cmd", tap_cmd); }
        return;
    }

    // ── the briefing card ───────────────────────────────────────
    if mode == "brief" && has_ev {
        let a = clamp(mt / 0.3, 0.0, 1.0);
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, 0.50 * a], rounding: 0.0, layer: 10 });
        let w = 760.0 * u; let h = 400.0 * u;
        let x = cx - w * 0.5; let y = sh * 0.5 - h * 0.5 - 20.0 * u;
        let tc = type_rgb(ty);
        panel(x, y, w, h, tc, 0.93 * a, 0.7 * a, u);
        mtext(cx, y + 20.0 * u, `LEG ${E.leg + 1}  ${LEGS[E.leg]}     EVENT ${ei % 3 + 1} OF 3`, 12.0 * u, "hud", PALE, 0.85 * a, "center");
        mtext(cx, y + 46.0 * u, tour::type_label(ty), 16.0 * u, "hud", tc, a, "center");
        mtext(cx, y + 70.0 * u, E.name, fit(E.name, 40.0 * u, "hud", w - 60.0 * u), "hud", WHITE, a, "center");
        let bl = tour::brief_lines(E);
        mtext(cx, y + 132.0 * u, bl[0], 14.0 * u, "mono", WHITE, 0.95 * a, "center");
        mtext(cx, y + 154.0 * u, bl[1], 14.0 * u, "mono", PALE, 0.95 * a, "center");
        mtext(cx, y + 186.0 * u, theme_line(E, THEMES), 12.0 * u, "hud", [1.0, 0.75, 0.9], 0.9 * a, "center");
        let info = `${(E.km * 10.0).to_int().to_float() / 10.0} KM     TRAFFIC ${traffic_word(E.traffic[0])}` + (if E.rivals.len() > 0 { `     ${E.rivals.len()} RIVALS` } else { "" });
        mtext(cx, y + 206.0 * u, info, 12.0 * u, "mono", GOLD, 0.85 * a, "center");
        draw_line(x + 40.0 * u, y + 234.0 * u, x + w - 40.0 * u, y + 234.0 * u, #{ color: [tc[0], tc[1], tc[2], 0.35 * a], thickness: 1.0 * u, layer: 12 });
        for k in 0..3 {
            let m = k + 1;
            let mx = cx + (k.to_float() - 1.0) * 230.0 * u;
            medal(mx, y + 268.0 * u, 16.0 * u, m, a);
            mtext(mx, y + 292.0 * u, medal_name(m), 11.0 * u, "hud", medal_rgb(m), a, "center");
            mtext(mx, y + 308.0 * u, tour::target_text(E, k), 15.0 * u, "hud", WHITE, a, "center");
        }
        let bt = if bests[ei] >= 0.0 { `YOUR BEST   ${tour::value_text(E, bests[ei])}` } else { "YOUR BEST   NOT YET DRIVEN" };
        mtext(cx, y + 346.0 * u, bt, 13.0 * u, "hud", if medals[ei] > 0 { medal_rgb(medals[ei]) } else { PALE }, 0.95 * a, "center");
        let blink = if (ui_t * 1.6).to_int() % 2 == 0 { 1.0 } else { 0.35 };
        if touch {
            // two buttons under the card: BACK on the left, START under the right thumb
            let bh = max(44.0 * u, tmin);
            let bw = max(220.0 * u, 3.0 * tmin);
            let bs = max(16.0 * u, 12.0);
            let rb = [cx - bw - 14.0 * u, y + h + 12.0 * u, bw, bh];
            let rs = [cx + 14.0 * u, y + h + 12.0 * u, bw, bh];
            button(rb, "BACK", bs, PALE, 0.5 * a, a, false, u);
            button(rs, "START", bs, GOLD, (0.75 + 0.25 * sin(ui_t * 6.0)) * a, a, true, u);
            if hit(taps, rs) { tap_cmd = "ok"; } else if hit(taps, rb) { tap_cmd = "back"; }
            if tap_cmd != "" { set_field(game, "game_state", "cmd", tap_cmd); }
        } else {
            let pr = if pad { "A  START          B  BACK" } else { "ENTER  START          BACKSPACE  BACK" };
            mtext(cx, y + h + 18.0 * u, pr, 16.0 * u, "hud", GOLD, blink * a, "center");
        }
        return;
    }

    // ── top row: the event's readout, the clock, the section ────
    let top = 22.0 * u;
    let playing = mode == "drive" || mode == "countdown";
    if ty == "race" {
        label(34.0 * u, top, "POSITION", 14.0 * u, ar, ag, ab, 0.95, "left");
        let n_cars = E.rivals.len() + 1;
        neon_text(34.0 * u, top + 16.0 * u, ordinal(gs.race_pos), 40.0 * u, "hud", 1.0, 0.95, 0.85, 1.0, "left", 1.5 * u);
        label(172.0 * u, top + 38.0 * u, `OF ${n_cars}`, 14.0 * u, br, bg, bb, 0.9, "left");
        if gs.name_ahead != "" && gs.gap_ahead > 0.0 {
            draw_text(34.0 * u, top + 66.0 * u, `AHEAD   ${gs.name_ahead}  +${(gs.gap_ahead * 10.0).to_int().to_float() / 10.0}`, 13.0 * u,
                #{ font: "mono", color: [1.0, 0.8, 0.5, 0.9], layer: 6 });
        }
        if gs.name_behind != "" && gs.gap_behind > 0.0 {
            draw_text(34.0 * u, top + 83.0 * u, `BEHIND  ${gs.name_behind}  -${(gs.gap_behind * 10.0).to_int().to_float() / 10.0}`, 13.0 * u,
                #{ font: "mono", color: [0.7, 0.8, 1.0, 0.8], layer: 6 });
        }
    } else if ty == "drift" || ty == "rush" {
        let v = if ty == "drift" { gs.drift_total } else { gs.near_count.to_float() };
        label(34.0 * u, top, if ty == "drift" { "DRIFT POINTS" } else { "CLOSE PASSES" }, 14.0 * u, ar, ag, ab, 0.95, "left");
        glow_text(34.0 * u, top + 18.0 * u, if ty == "drift" { pad_int(v.to_int(), 6) } else { pad_int(v.to_int(), 2) }, 34.0 * u, "hud", 1.0, 0.95, 0.85, 1.0, "left", 1.5 * u);
        let nt = next_target(E, v);
        let have_m = 0;
        for k in 0..3 { if v >= E.targets[k] { have_m = k + 1; } }
        let mc = medal_rgb(if nt[0] > 0 { nt[0] } else { 3 });
        let line = if nt[0] > 0 { `NEXT  ${medal_name(nt[0])}  ${nt[1].to_int()}` } else { "GOLD PACE" };
        draw_text(34.0 * u, top + 60.0 * u, line, 13.0 * u, #{ font: "mono", color: [mc[0], mc[1], mc[2], 0.95], layer: 6 });
        // a bar toward the next target
        let lo = if have_m > 0 { E.targets[have_m - 1] } else { 0.0 };
        let hi = if nt[0] > 0 { nt[1] } else { lo + 1.0 };
        let k = if nt[0] > 0 { clamp((v - lo) / max(hi - lo, 1.0), 0.0, 1.0) } else { 1.0 };
        draw_rect(34.0 * u, top + 80.0 * u, 180.0 * u, 4.0 * u, #{ color: [br, bg, bb, 0.25], rounding: 0.0, layer: 5 });
        draw_rect(34.0 * u, top + 80.0 * u, 180.0 * u * k, 4.0 * u, #{ color: [mc[0], mc[1], mc[2], 0.95], rounding: 0.0, layer: 6 });
        if ty == "rush" {
            let cc = gs.crashes;
            let hot = cc >= E.max_crashes;
            draw_text(34.0 * u, top + 92.0 * u, `CRASHES  ${cc} / ${E.max_crashes}`, 13.0 * u,
                #{ font: "mono", color: [1.0, if hot { 0.35 } else { 0.8 }, if hot { 0.4 } else { 0.8 }, 0.9], layer: 6 });
        }
    } else {
        label(34.0 * u, top, "SCORE", 14.0 * u, ar, ag, ab, 0.95, "left");
        glow_text(34.0 * u, top + 18.0 * u, pad_int(gs.score.to_int(), 8), 30.0 * u, "hud", 1.0, 0.95, 0.85, 1.0, "left", 1.5 * u);
        if kind == "arcade" {
            draw_text(34.0 * u, top + 56.0 * u, `BEST ${pad_int(gs.hi_score.to_int(), 8)}`, 13.0 * u,
                #{ font: "mono", color: [0.7, 0.75, 0.95, 0.7], layer: 6 });
        } else if kind == "endless" {
            let cc = gs.crashes;
            draw_text(34.0 * u, top + 56.0 * u, `BEST ${pad_int(gs.endless_best.to_int(), 8)}`, 13.0 * u,
                #{ font: "mono", color: [0.7, 0.75, 0.95, 0.7], layer: 6 });
            for k in 0..3 {
                let lost = k < cc;
                let x = 42.0 * u + k.to_float() * 22.0 * u;
                if lost { draw_circle_outline(x, top + 86.0 * u, 7.0 * u, #{ color: [1.0, 0.3, 0.4, 0.6], thickness: 1.5 * u, layer: 6 }); }
                else { draw_circle(x, top + 86.0 * u, 7.0 * u, #{ color: [ar, ag, ab, 0.95], layer: 6 }); }
            }
        } else if ty == "endurance" {
            let nt = next_target(E, gs.score);
            let mc = medal_rgb(if nt[0] > 0 { nt[0] } else { 3 });
            draw_text(34.0 * u, top + 56.0 * u, if nt[0] > 0 { `NEXT  ${medal_name(nt[0])}  ${nt[1].to_int()}` } else { "GOLD PACE" }, 13.0 * u,
                #{ font: "mono", color: [mc[0], mc[1], mc[2], 0.95], layer: 6 });
        } else if ty == "sprint" {
            draw_text(34.0 * u, top + 56.0 * u, `GOLD ${E.targets[2].to_int()}+ SEC LEFT   SILVER ${E.targets[1].to_int()}+`, 13.0 * u,
                #{ font: "mono", color: [1.0, 0.85, 0.5, 0.85], layer: 6 });
        }
    }

    let tl = gs.time_left;
    if ty == "race" || kind == "endless" {
        label(cx, top, "TIME", 14.0 * u, ar, ag, ab, 0.95, "center");
        glow_text(cx, top + 18.0 * u, fmt_time(gs.elapsed), 40.0 * u, "hud", 1.0, 0.95, 0.85, 1.0, "center", 2.0 * u);
    } else {
        let low = tl < 10.0 && mode == "drive" && gs.rules;
        let tr = 1.0; let tg = 0.92; let tb = 0.35;
        if low { let p = 0.5 + 0.5 * sin(now * 12.0); tr = 1.0; tg = 0.15 + 0.2 * p; tb = 0.2; }
        label(cx, top, "TIME", 14.0 * u, ar, ag, ab, 0.95, "center");
        let secs = if tl > 0.0 { (tl + 0.999).to_int() } else { 0 };
        glow_text(cx, top + 14.0 * u, pad_int(secs, 2), (if low { 62.0 + 6.0 * sin(now * 12.0) } else { 58.0 }) * u, "hud", tr, tg, tb, 1.0, "center", 2.0 * u);
    }

    let ns = gs.n_stages;
    let head = if kind == "arcade" { `STAGE ${gs.stage + 1} / ${ns}` } else if kind == "endless" { `SECTION ${gs.stage + 1}` } else { `${tour::type_label(ty)}   ${gs.stage + 1} / ${ns}` };
    label(sw - 34.0 * u, top, head, 14.0 * u, ar, ag, ab, 0.95, "right");
    neon_text(sw - 34.0 * u, top + 20.0 * u, gs.stage_name, 22.0 * u, "hud", br, bg, bb, 1.0, "right", 2.0 * u);
    if has_ev {
        draw_text(sw - 34.0 * u, top + 52.0 * u, E.name, 12.0 * u, #{ font: "mono", align: "right", color: [0.75, 0.8, 1.0, 0.7], layer: 6 });
    }

    // ── the dash ────────────────────────────────────────────────
    let dh = 104.0 * u;                 // height
    let dw = 300.0 * u;                 // half width at the top
    let sl = 46.0 * u;                  // slant
    let y0 = sh - dh;
    draw_polygon([[cx - dw - sl, sh], [cx - dw, y0], [cx + dw, y0], [cx + dw + sl, sh]], 0.035, 0.012, 0.085, 0.86, 2);
    draw_polygon_outline([[cx - dw - sl, sh], [cx - dw, y0], [cx + dw, y0], [cx + dw + sl, sh]], ar, ag, ab, 0.95, 2.0 * u, false, 3);
    draw_line(cx - dw + 10.0 * u, y0 + 5.0 * u, cx + dw - 10.0 * u, y0 + 5.0 * u, #{ color: [br, bg, bb, 0.5], thickness: 1.0 * u, layer: 3 });

    // tachometer: slanted bars, the last five run hot
    let bars = 26;
    let lit = (gs.rpm * bars.to_float() + 0.5).to_int();
    let tx0 = cx - 150.0 * u; let tw = 300.0 * u;
    let bw = tw / bars.to_float();
    let ty0 = y0 + 14.0 * u; let th = 15.0 * u;
    for i in 0..bars {
        let x = tx0 + i.to_float() * bw;
        let hot = i >= bars - 5;
        let on = i < lit;
        let r = if hot { 1.0 } else { br }; let g = if hot { 0.2 } else { bg }; let b = if hot { 0.25 } else { bb };
        let a = if on { 1.0 } else { 0.16 };
        draw_polygon([[x + 3.0 * u, ty0], [x + bw + 1.0 * u, ty0], [x + bw - 2.0 * u, ty0 + th], [x, ty0 + th]], r, g, b, a, 4);
    }

    // speed
    let kmh = (gs.speed_kmh * (if s_units == 1 { 0.621371 } else { 1.0 })).to_int();
    glow_text(cx + 62.0 * u, y0 + 30.0 * u, pad_int(kmh, 3), 56.0 * u, "hud", 1.0, 0.97, 0.9, 1.0, "right", 2.0 * u);
    label(cx + 72.0 * u, y0 + 66.0 * u, if s_units == 1 { "MPH" } else { "KM/H" }, 15.0 * u, ar, ag, ab, 0.95, "left");

    // boost: a slanted meter along the foot of the dash. It fills from
    // drifting, drafting, close passes and air; it burns white while held.
    let bx0 = cx - 150.0 * u; let bw2 = 300.0 * u; let by0 = y0 + 91.0 * u; let bh = 7.0 * u;
    let bv = clamp(gs.boost, 0.0, 1.0);
    let burn = gs.boosting;
    let full = bv > 0.995;
    label(bx0 - 10.0 * u, by0 - 2.0 * u, "BOOST", 9.0 * u, if burn { 1.0 } else { ar }, if burn { 1.0 } else { ag }, if burn { 0.8 } else { ab }, 0.95, "right");
    draw_polygon([[bx0 + 3.0 * u, by0], [bx0 + bw2 + 3.0 * u, by0], [bx0 + bw2, by0 + bh], [bx0, by0 + bh]], br, bg, bb, 0.16, 4);
    if bv > 0.005 {
        let fw = bw2 * bv;
        let pulse = if burn { 0.75 + 0.25 * sin(now * 30.0) } else if full { 0.8 + 0.2 * sin(now * 6.0) } else { 1.0 };
        let fr = if burn { 1.0 } else { ar }; let fg = if burn { 0.97 } else { ag }; let fb = if burn { 0.75 } else { ab };
        draw_polygon([[bx0 + 3.0 * u, by0], [bx0 + fw + 3.0 * u, by0], [bx0 + fw, by0 + bh], [bx0, by0 + bh]], fr, fg, fb, pulse, 5);
    }
    if !burn && bv > 0.06 && !touch {
        let key = if pad { "X" } else { "SHIFT" };
        draw_text(bx0 + bw2 + 12.0 * u, by0 - 2.0 * u, key, 9.0 * u, #{ font: "mono", color: [1.0, 0.9, 0.55, if full { 1.0 } else { 0.6 }], layer: 5 });
    }

    // touch: nobody holds a pedal, and the dash says so. The countdown spells the thumbs out.
    if touch_controls_visible() {
        let hs = max(11.0 * u, 9.0);
        draw_text(cx + dw - 6.0 * u, y0 - hs - 5.0 * u, "AUTO GAS", hs, #{ font: "mono", align: "right", color: [1.0, 0.9, 0.55, 0.75], layer: 5 });
        if mode == "countdown" {
            let ha = clamp(mt * 2.0 - 1.0, 0.0, 1.0);
            let hy = sh * 0.50;
            let ts = max(15.0 * u, 11.0);
            draw_text(cx, hy, "LEFT THUMB STEERS     THE GAS IS AUTOMATIC", ts, #{ font: "mono", align: "center", color: [1.0, 0.9, 0.55, 0.95 * ha], layer: 6,
                shadow: [0.0, 1.0, 0.0, 0.0, 0.0, 0.7 * ha] });
            draw_text(cx, hy + ts * 1.5, "RIGHT THUMB     BRAKE     DRIFT     BOOST", ts, #{ font: "mono", align: "center", color: [0.75, 0.9, 1.0, 0.95 * ha], layer: 6,
                shadow: [0.0, 1.0, 0.0, 0.0, 0.0, 0.7 * ha] });
        }
    }

    // sliding: the score building, live, over the dash, and the angle on a
    // bar that runs out at the spin-out
    if gs.drift_score > 1.0 && mode == "drive" {
        let ds = gs.drift_score;
        let k = clamp(ds / 2500.0, 0.0, 1.0);
        glow_text(cx, y0 - 58.0 * u, `DRIFT  ${ds.to_int()}`, (24.0 + 10.0 * k) * u, "hud", 1.0, 0.75 - 0.35 * k, 0.25 + 0.5 * k, 1.0, "center", 2.0 * u);
        let deg = abs(gs.slip) * 57.3;
        let aw = 120.0 * u;
        draw_line(cx - aw, y0 - 18.0 * u, cx + aw, y0 - 18.0 * u, #{ color: [br, bg, bb, 0.35], thickness: 2.0 * u, layer: 4 });
        let ax = clamp(gs.slip * 57.3 / 39.0, -1.0, 1.0) * aw;
        draw_line(cx, y0 - 18.0 * u, cx + ax, y0 - 18.0 * u, #{ color: [1.0, if deg > 30.0 { 0.3 } else { 0.85 }, 0.4, 1.0], thickness: 4.0 * u, layer: 5 });
        draw_line(cx, y0 - 24.0 * u, cx, y0 - 12.0 * u, #{ color: [1.0, 1.0, 1.0, 0.7], thickness: 1.5 * u, layer: 5 });
    }
    // in a slipstream: chevrons that fill as the tow builds
    if gs.draft > 0.12 && mode == "drive" {
        let da = clamp(gs.draft * 1.6, 0.0, 1.0);
        label(cx, sh * 0.17, "SLIPSTREAM", 13.0 * u, 0.6, 1.0, 0.95, da, "center");
        for i in 0..3 {
            let on = gs.draft > 0.25 + 0.22 * i.to_float();
            let yy = sh * 0.17 + (24.0 + 9.0 * i.to_float()) * u;
            let w = (16.0 - 3.0 * i.to_float()) * u;
            draw_line(cx - w, yy, cx, yy + 6.0 * u, #{ color: [0.6, 1.0, 0.95, if on { da } else { 0.2 * da }], thickness: 2.0 * u, layer: 5 });
            draw_line(cx + w, yy, cx, yy + 6.0 * u, #{ color: [0.6, 1.0, 0.95, if on { da } else { 0.2 * da }], thickness: 2.0 * u, layer: 5 });
        }
    }

    // gear
    let gx = cx - 232.0 * u; let gy = y0 + 22.0 * u;
    draw_rect_outline(gx, gy, 54.0 * u, 62.0 * u, #{ color: [br, bg, bb, 0.8], thickness: 1.5 * u, rounding: 4.0 * u, layer: 4 });
    label(gx + 27.0 * u, gy + 4.0 * u, "GEAR", 9.0 * u, br, bg, bb, 0.9, "center");
    let shift_age = now - gs.shifted;
    let gs_size = (38.0 + 10.0 * clamp(1.0 - shift_age * 4.0, 0.0, 1.0)) * u;
    neon_text(gx + 27.0 * u, gy + 16.0 * u, `${gs.gear}`, gs_size, "hud", 1.0, 0.92, 0.5, 1.0, "center", 0.0);

    // the road so far: S ▸▸▸ G, a tick a gate (HORIZON has no G: kilometres instead)
    let px0 = cx + 150.0 * u; let pw = 128.0 * u; let pyy = y0 + 40.0 * u;
    if kind == "endless" {
        glow_text(px0 + pw * 0.5, pyy - 16.0 * u, `${(gs.dist_km * 10.0).to_int().to_float() / 10.0} KM`, 20.0 * u, "hud", ar, ag, ab, 1.0, "center", 1.0 * u);
    } else {
        label(px0 - 14.0 * u, pyy - 9.0 * u, "S", 13.0 * u, br, bg, bb, 0.95, "center");
        label(px0 + pw + 14.0 * u, pyy - 9.0 * u, "G", 13.0 * u, 1.0, 0.9, 0.4, 0.95, "center");
        draw_line(px0, pyy, px0 + pw, pyy, #{ color: [br, bg, bb, 0.35], thickness: 2.0 * u, layer: 4 });
        draw_line(px0, pyy, px0 + pw * gs.run_progress, pyy, #{ color: [ar, ag, ab, 1.0], thickness: 3.0 * u, layer: 5 });
        for i in 0..(ns + 1) {
            let fr = i.to_float() / ns.to_float();
            let x = px0 + pw * fr;
            let done = gs.run_progress >= fr - 0.001;
            draw_line(x, pyy - 5.0 * u, x, pyy + 5.0 * u, #{ color: [if done { ar } else { br }, if done { ag } else { bg }, if done { ab } else { bb }, if done { 1.0 } else { 0.5 }], thickness: 2.0 * u, layer: 5 });
        }
        let mx = px0 + pw * gs.run_progress;
        draw_polygon([[mx, pyy - 7.0 * u], [mx + 6.0 * u, pyy - 16.0 * u], [mx - 6.0 * u, pyy - 16.0 * u]], 1.0, 0.95, 0.6, 1.0, 6);
    }
    draw_text(px0 + pw * 0.5, pyy + 14.0 * u, `${gs.near_count} CLOSE PASSES`, 11.0 * u,
        #{ font: "mono", align: "center", color: [0.75, 0.8, 1.0, 0.7], layer: 5 });

    // ── words in the middle of the road ─────────────────────────
    let age = now - msg_t;
    if msg_kind == "count" && age < 0.9 {
        let k = age / 0.9;
        glow_text(cx, sh * 0.27 - 30.0 * u * k, msg, (150.0 - 50.0 * k) * u, "hud", 1.0, 0.85, 0.3, 1.0 - k * k, "center", 0.0);
    } else if msg_kind == "go" && age < 1.3 {
        let k = age / 1.3;
        glow_text(cx, sh * 0.25, msg, (140.0 + 60.0 * k) * u, "hud", 0.4, 1.0, 0.7, 1.0 - k * k, "center", 8.0 * u);
    } else if msg_kind == "big" && age < 3.2 && mode == "drive" {
        let a = clamp(age * 5.0, 0.0, 1.0) * clamp((3.2 - age) * 2.0, 0.0, 1.0);
        let blink = if (age * 7.0).to_int() % 2 == 0 || age > 1.4 { 1.0 } else { 0.35 };
        glow_text(cx, sh * 0.27, msg, 64.0 * u, "hud", 1.0, 0.9, 0.35, a * blink, "center", 6.0 * u);
        label(cx, sh * 0.27 + 78.0 * u, msg_sub, 20.0 * u, 0.5, 1.0, 0.85, a, "center");
    } else if msg_kind == "lost" && age < 1.6 && mode == "drive" {
        let a = clamp((1.6 - age) * 2.0, 0.0, 1.0);
        glow_text(cx, sh * 0.36 + 20.0 * u * age, `${msg}  ${msg_sub}`, 24.0 * u, "hud", 1.0, 0.25, 0.4, a, "center", 2.0 * u);
    } else if msg_kind == "small" && age < 1.4 && mode == "drive" {
        let a = clamp((1.4 - age) * 2.0, 0.0, 1.0);
        glow_text(cx, sh * 0.36 - 30.0 * u * age, `${msg}  ${msg_sub}`, 24.0 * u, "hud", 0.5, 1.0, 0.9, a, "center", 2.0 * u);
    }

    if mode == "over" {
        let a = clamp(mt / 0.6, 0.0, 1.0);
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, 0.45 * a], rounding: 0.0, layer: 1 });
        glow_text(cx, sh * 0.30, "GAME OVER", 84.0 * u, "hud", 1.0, 0.2, 0.45, a, "center", 8.0 * u);
        label(cx, sh * 0.30 + 104.0 * u, `STAGE ${gs.stage + 1}  ${gs.stage_name}`, 20.0 * u, 0.7, 0.85, 1.0, a, "center");
        if mt > 1.5 { label(cx, sh * 0.30 + 150.0 * u, if touch { "TAP  TO  CONTINUE" } else { "ENTER  TO  CONTINUE" }, max(16.0 * u, tmin * 0.27), 1.0, 0.9, 0.5, 0.5 + 0.5 * sin(now * 5.0), "center"); }
        if mt > 1.5 && taps.len() > 0 { tap_cmd = "ok"; }           // anywhere
    } else if mode == "finish" {
        let a = clamp(mt / 0.6, 0.0, 1.0);
        glow_text(cx, sh * 0.22, "GOAL", 120.0 * u, "hud", 1.0, 0.9, 0.4, a, "center", 14.0 * u);
        label(cx, sh * 0.22 + 138.0 * u, "YOU  REACHED  THE  HORIZON", 20.0 * u, 0.6, 1.0, 0.9, a, "center");
        if mt > 1.2 {
            label(cx, sh * 0.22 + 178.0 * u, `TIME BONUS  +${gs.event_value.to_int()}`, 18.0 * u, 1.0, 0.85, 0.5, clamp(mt - 1.2, 0.0, 1.0), "center");
        }
        if mt > 1.5 && touch { label(cx, sh * 0.22 + 216.0 * u, "TAP  TO  CONTINUE", max(16.0 * u, tmin * 0.27), 1.0, 0.9, 0.5, 0.5 + 0.5 * sin(now * 5.0), "center"); }
        if mt > 1.5 && taps.len() > 0 { tap_cmd = "ok"; }
    }

    // ── results ─────────────────────────────────────────────────
    if mode == "results" {
        let a = clamp((mt - 0.5) / 0.5, 0.0, 1.0);
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, 0.62 * a], rounding: 0.0, layer: 10 });
        let w = 820.0 * u; let h = 470.0 * u;
        let x = cx - w * 0.5; let y = sh * 0.5 - h * 0.5 - 28.0 * u;
        let rm = gs.res_medal;
        let rv = gs.res_value;
        let failed = gs.res_fail != "";
        let mc = if failed { [1.0, 0.3, 0.42] } else if kind == "endless" { [0.55, 0.97, 1.0] } else { medal_rgb(rm) };
        panel(x, y, w, h, mc, 0.94 * a, 0.75 * a, u);
        let tcol = type_rgb(ty);
        mtext(x + 30.0 * u, y + 20.0 * u, if has_ev { `${tour::type_label(ty)}     LEG ${E.leg + 1}  EVENT ${ei % 3 + 1}` } else { "HORIZON" }, 12.0 * u, "hud", tcol, a, "left");
        mtext(x + 30.0 * u, y + 40.0 * u, E.name, fit(E.name, 28.0 * u, "hud", w * 0.55), "hud", WHITE, a, "left");
        // the verdict, left
        let lx = x + 150.0 * u;
        if kind == "endless" {
            mtext(lx, y + 112.0 * u, "THREE CRASHES", 20.0 * u, "hud", mc, a, "center");
            mtext(lx, y + 150.0 * u, pad_int(rv.to_int(), 8), 30.0 * u, "hud", WHITE, a, "center");
            mtext(lx, y + 192.0 * u, `${(gs.dist_km * 10.0).to_int().to_float() / 10.0} KM     ${gs.stage + 1} SECTIONS`, 13.0 * u, "mono", PALE, a, "center");
            mtext(lx, y + 222.0 * u, if gs.res_best { "NEW BEST" } else { `BEST  ${pad_int(gs.endless_best.to_int(), 8)}` }, 14.0 * u, "hud", GOLD,
                (if gs.res_best { 0.6 + 0.4 * sin(ui_t * 8.0) } else { 0.8 }) * a, "center");
        } else {
            let pop = 1.0 + 0.25 * clamp(1.0 - (mt - 0.5) * 2.0, 0.0, 1.0);
            medal(lx, y + 150.0 * u, 46.0 * u * pop, if failed { 0 } else { rm }, a);
            mtext(lx, y + 212.0 * u, if failed { gs.res_fail } else { medal_name(rm) }, if failed { 18.0 * u } else { 26.0 * u }, "hud", mc, a, "center");
            mtext(lx, y + 250.0 * u, tour::value_text(E, rv), 18.0 * u, "hud", WHITE, a, "center");
            let bt = if gs.res_best { "NEW BEST" } else if bests[ei] >= 0.0 { `BEST  ${tour::value_text(E, bests[ei])}` } else { "" };
            mtext(lx, y + 280.0 * u, bt, 13.0 * u, "hud", GOLD, (if gs.res_best { 0.6 + 0.4 * sin(ui_t * 8.0) } else { 0.8 }) * a, "center");
            // the three targets, and which were reached
            for k in 0..3 {
                let m = 3 - k;
                let yy = y + 316.0 * u + k.to_float() * 24.0 * u;
                let got = !failed && rm >= m;
                medal(x + 44.0 * u, yy + 7.0 * u, 7.0 * u, if got { m } else { 0 }, a);
                mtext(x + 62.0 * u, yy, medal_name(m), 11.0 * u, "hud", medal_rgb(m), (if got { 1.0 } else { 0.6 }) * a, "left");
                mtext(x + 270.0 * u, yy, tour::target_text(E, m - 1), 11.0 * u, "hud", WHITE, (if got { 1.0 } else { 0.6 }) * a, "right");
            }
        }
        // the run in numbers, right
        draw_line(x + 310.0 * u, y + 96.0 * u, x + 310.0 * u, y + h - 96.0 * u, #{ color: [mc[0], mc[1], mc[2], 0.3 * a], thickness: 1.0 * u, layer: 12 });
        let stats = [
            ["TIME", fmt_time(gs.elapsed)],
            ["TOP SPEED", if s_units == 1 { `${(gs.top_speed * 2.236936).to_int()} MPH` } else { `${(gs.top_speed * 3.6).to_int()} KM/H` }],
            ["DRIFTS", `${gs.drift_count}   ${gs.drift_total.to_int()} PTS`],
            ["CLOSE PASSES", `${gs.near_count}`],
            ["AIR", `${(gs.air_total * 10.0).to_int().to_float() / 10.0} S`],
            ["SLIPSTREAM", `${(gs.draft_time * 10.0).to_int().to_float() / 10.0} S`],
            ["CRASHES", `${gs.crashes}`],
            ["SCORE", pad_int(gs.score.to_int(), 8)],
        ];
        for k in 0..stats.len() {
            let yy = y + 104.0 * u + k.to_float() * 31.0 * u;
            mtext(x + 344.0 * u, yy, stats[k][0], 12.0 * u, "hud", PALE, 0.85 * a, "left");
            mtext(x + w - 36.0 * u, yy - 2.0 * u, stats[k][1], 15.0 * u, "hud", WHITE, a, "right");
            draw_line(x + 344.0 * u, yy + 22.0 * u, x + w - 36.0 * u, yy + 22.0 * u, #{ color: [PALE[0], PALE[1], PALE[2], 0.12 * a], thickness: 1.0 * u, layer: 12 });
        }
        // what next
        if mt > 1.2 {
            let has_next = false;
            if has_ev && ei < EVENTS.len() - 1 { has_next = tour::unlocked(ei + 1, medals); }
            let opts = if kind == "event" { ["RETRY", "NEXT EVENT", "TOUR"] } else { ["RETRY", "TITLE"] };
            let n = opts.len();
            let oy = y + h + 16.0 * u;
            let rh = max(40.0 * u, tmin);
            for k in 0..n {
                let ox = cx + (k.to_float() - (n - 1).to_float() * 0.5) * 230.0 * u;
                let sel = gs.menu_res == k;
                let dead = n == 3 && k == 1 && !has_next;
                let c = if dead { [0.45, 0.42, 0.6] } else if sel { GOLD } else { PALE };
                let r = [ox - 100.0 * u, oy, 200.0 * u, rh];
                button(r, opts[k], max(15.0 * u, tmin * 0.25), c, if sel { 0.75 + 0.25 * sin(ui_t * 6.0) } else { 0.3 }, if dead { 0.6 } else { 1.0 }, sel, u);
                if hit(taps, r) { tap_cmd = `res:${k}`; }
            }
            if kind == "event" && rm == 0 && !has_next {
                mtext(cx, oy + rh + 10.0 * u, "A MEDAL OPENS THE NEXT EVENT", 11.0 * u, "mono", PALE, 0.7, "center");
            }
        }
    }

    // a flash on the frame a checkpoint or a crash lands
    let fa = clamp(1.0 - (now - flash_t) * 4.0, 0.0, 1.0);
    if fa > 0.0 { draw_rect(0.0, 0.0, sw, sh, #{ color: [1.0, 0.9, 0.95, 0.28 * fa], rounding: 0.0, layer: 8 }); }

    // fade up from the title
    if mode == "countdown" && mt < 0.5 { draw_rect(0.0, 0.0, sw, sh, #{ color: [0.0, 0.0, 0.0, 1.0 - mt * 2.0], rounding: 0.0, layer: 9 }); }

    // ── the pause menu ──────────────────────────────────────────
    if paused {
        draw_rect(0.0, 0.0, sw, sh, #{ color: [0.02, 0.0, 0.05, 0.66], rounding: 0.0, layer: 10 });
        draw_text(cx, sh * 0.21 - 20.0 * u, "PAUSED", 72.0 * u, #{ font: "hud", align: "center", layer: 13, spacing: 8.0 * u,
            color: [0.5, 0.95, 1.0, 1.0], stroke: [0.2, 0.8, 1.0, 0.3, 1.0] });
        let opts = ["RESUME", "RESTART", "SETTINGS", if kind == "event" { "QUIT TO TOUR" } else { "QUIT TO TITLE" }];
        let rh = max(44.0 * u, tmin);
        let pitch = rh + 12.0 * u;
        let pick = -1;
        for k in 0..4 {
            let sel = p_sel == k;
            let r = [cx - max(150.0 * u, 2.4 * tmin), sh * 0.21 + 110.0 * u + k.to_float() * pitch, max(300.0 * u, 4.8 * tmin), rh];
            button(r, opts[k], max(17.0 * u, tmin * 0.27), if sel { GOLD } else { PALE }, if sel { 0.75 + 0.25 * sin(ui_t * 6.0) } else { 0.3 }, 1.0, sel, u);
            if hit(taps, r) { pick = k; }
        }
        let hint = if touch { "TAP  A  ROW" } else if pad { "D-PAD  CHOOSE     A  SELECT     B / BACK  RESUME" } else { "UP DOWN  CHOOSE     ENTER  SELECT     P  RESUME" };
        mtext(cx, sh * 0.21 + 110.0 * u + 4.0 * pitch + 8.0 * u, hint, max(12.0 * u, tmin * 0.21), "mono", PALE, 0.7, "center");
        // a tapped row is chosen and done in the one touch (this callback is the only one awake)
        if pick >= 0 {
            p_sel = pick;
            if pick == 2 { s_open = true; }
            else {
                if pick == 1 { tap_cmd = "restart"; } else if pick == 3 { tap_cmd = "quit"; }
                pop_state();
            }
        }
    }
    // M changed how much the world moves with the music: say what it is now
    if seen_pulse >= 0.0 && gs.pulse != seen_pulse { pulse_toast = ui_t; }
    seen_pulse = gs.pulse;
    let pa = ui_t - pulse_toast;
    if pa < 1.8 {
        let word = if on_web { "NOT ON THE WEB YET" } else if gs.pulse <= 0.0 { "OFF" } else { `${(gs.pulse * 100.0 + 0.5).to_int()}%` };
        let fa = clamp(pa / 0.12, 0.0, 1.0) * clamp((1.8 - pa) / 0.4, 0.0, 1.0);
        neon_text(cx, sh * 0.33, `PULSE  ${word}`, 26.0 * u, "hud", 0.45, 0.95, 1.0, fa, "center", 3.0 * u);
    }
    if tap_cmd != "" { set_field(game, "game_state", "cmd", tap_cmd); }
}
