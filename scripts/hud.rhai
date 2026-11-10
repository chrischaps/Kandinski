// hud.rhai — everything drawn over the road: the dash, the clock, the
// title card and the words that mark a run (GO, CHECKPOINT, GAME OVER).
//
// Reads the game_state component scripts/drive.rhai publishes; draws with
// the immediate-mode API in logical points, scaled from a 720-point-high
// layout. It also owns pause, because on_draw_ui is the one callback that
// still runs while the game state is "paused".

let game = -1;
let seen_event_time = -100.0;
let msg = "";
let msg_sub = "";
let msg_t = -100.0;
let msg_kind = "";
let flash_t = -100.0;
let ui_t = 0.0;

fn pad_int(n, width) {
    let s = `${n}`;
    while s.len() < width { s = "0" + s; }
    s
}

// a display colour from a material colour: lifted so dark hues still read
fn lift(c) { sqrt(clamp(c, 0.0, 1.0)) * 0.85 + 0.15 }

fn glow_text(x, y, s, size, font, r, g, b, a, align, spacing) {
    // a thin halo of the hue under a near-white face. (Wide strokes are
    // stamped copies of the glyph and read as blocks, so the halo stays thin.)
    draw_text_opts(x, y, s, size, #{ font: font, align: align, spacing: spacing, layer: 6,
        color: [0.55 + 0.45 * r, 0.55 + 0.45 * g, 0.55 + 0.45 * b, a],
        stroke: [r * 0.9, g * 0.9, b * 0.9, 0.28 * a, 1.0],
        shadow: [0.0, size * 0.05, 0.0, 0.0, 0.0, 0.55 * a] });
}

fn label(x, y, s, size, r, g, b, a, align) {
    draw_text_opts(x, y, s, size, #{ font: "hud", align: align, spacing: size * 0.12, layer: 6,
        color: [r, g, b, a], shadow: [0.0, size * 0.08, 0.0, 0.0, 0.0, 0.6 * a] });
}

fn on_init() {
    game = get_entity("game");
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

    // stage colours
    let ar = lift(gs.accent_r); let ag = lift(gs.accent_g); let ab = lift(gs.accent_b);
    let br = lift(gs.second_r); let bg = lift(gs.second_g); let bb = lift(gs.second_b);

    // ── pause ───────────────────────────────────────────────────
    let paused = current_state() == "paused";
    if is_action_just_pressed("pause") {
        if paused { pop_state(); paused = false; }
        else if mode == "drive" { push_state("paused"); paused = true; }
    }

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
        else if e == "near_miss" { msg = "CLOSE PASS"; msg_sub = `+${gs.event_value.to_int()}`; msg_t = now; msg_kind = "small"; }
        else if e == "crash" { flash_t = now; }
    }

    // ── title ───────────────────────────────────────────────────
    if mode == "title" {
        let a = clamp(mt / 1.2, 0.0, 1.0);
        draw_rect_gradient(0.0, 0.0, sw, sh * 0.52, 0.02, 0.0, 0.06, 0.72 * a, 0.02, 0.0, 0.06, 0.0, true, 0);
        draw_rect_gradient(0.0, sh * 0.70, sw, sh * 0.30, 0.02, 0.0, 0.06, 0.0, 0.02, 0.0, 0.06, 0.80 * a, true, 0);
        // the wordmark, two tubes offset: magenta under cyan
        let ty = sh * 0.17;
        let ts = 104.0 * u;
        draw_text_opts(cx + 4.0 * u, ty + 4.0 * u, "KANDINSKI", ts, #{ font: "title", align: "center", layer: 3,
            color: [1.0, 0.15, 0.6, 0.85 * a] });
        draw_text_opts(cx, ty, "KANDINSKI", ts, #{ font: "title", align: "center", layer: 5,
            color: [0.55, 0.97, 1.0, a] });
        label(cx, ty + 142.0 * u, "POINT  AND  LINE  TO  HORIZON", 17.0 * u, 1.0, 0.85, 0.45, 0.95 * a, "center");
        // three figures: the game's whole vocabulary
        let fy = ty + 196.0 * u;
        draw_circle_outline_ex(cx - 64.0 * u, fy, 13.0 * u, 0.25, 0.55, 1.0, a, 2.5 * u, 5);
        draw_polygon_outline([[cx, fy - 15.0 * u], [cx + 15.0 * u, fy + 12.0 * u], [cx - 15.0 * u, fy + 12.0 * u]],
            1.0, 0.86, 0.2, a, 2.5 * u, true, 5);
        draw_rect_outline_ex(cx + 51.0 * u, fy - 13.0 * u, 26.0 * u, 26.0 * u, 1.0, 0.2, 0.25, a, 2.5 * u, 0.0, 5);

        let blink = if (ui_t * 1.6).to_int() % 2 == 0 { 1.0 } else { 0.25 };
        let prompt = if last_input_device() == "gamepad" { "PRESS  START" } else { "PRESS  ENTER" };
        glow_text(cx, sh * 0.76, prompt, 30.0 * u, "hud", 1.0, 0.9, 0.5, blink * a, "center", 3.0 * u);
        draw_text_opts(cx, sh * 0.86, "W/UP  ACCELERATE     S/DOWN  BRAKE     A D / LEFT RIGHT  STEER     P  PAUSE", 14.0 * u,
            #{ font: "mono", align: "center", color: [0.75, 0.8, 1.0, 0.75 * a], layer: 5 });
        if gs.hi_score > 0.0 {
            label(cx, sh * 0.92, `BEST  ${pad_int(gs.hi_score.to_int(), 8)}`, 15.0 * u, 0.6, 0.95, 1.0, 0.9 * a, "center");
        }
        return;
    }

    // ── top row: score, time, stage ─────────────────────────────
    let top = 22.0 * u;
    label(34.0 * u, top, "SCORE", 14.0 * u, ar, ag, ab, 0.95, "left");
    glow_text(34.0 * u, top + 18.0 * u, pad_int(gs.score.to_int(), 8), 30.0 * u, "hud", 1.0, 0.95, 0.85, 1.0, "left", 1.5 * u);
    draw_text_opts(34.0 * u, top + 56.0 * u, `BEST ${pad_int(gs.hi_score.to_int(), 8)}`, 13.0 * u,
        #{ font: "mono", color: [0.7, 0.75, 0.95, 0.7], layer: 6 });

    let tl = gs.time_left;
    let low = tl < 10.0 && mode == "drive";
    let tr = 1.0; let tg = 0.92; let tb = 0.35;
    if low { let p = 0.5 + 0.5 * sin(now * 12.0); tr = 1.0; tg = 0.15 + 0.2 * p; tb = 0.2; }
    label(cx, top, "TIME", 14.0 * u, ar, ag, ab, 0.95, "center");
    let secs = if tl > 0.0 { (tl + 0.999).to_int() } else { 0 };
    glow_text(cx, top + 14.0 * u, pad_int(secs, 2), (if low { 62.0 + 6.0 * sin(now * 12.0) } else { 58.0 }) * u, "hud", tr, tg, tb, 1.0, "center", 2.0 * u);

    label(sw - 34.0 * u, top, `STAGE ${gs.stage + 1} / 5`, 14.0 * u, ar, ag, ab, 0.95, "right");
    glow_text(sw - 34.0 * u, top + 20.0 * u, gs.stage_name, 22.0 * u, "hud", br, bg, bb, 1.0, "right", 2.0 * u);

    // ── the dash ────────────────────────────────────────────────
    let dh = 104.0 * u;                 // height
    let dw = 300.0 * u;                 // half width at the top
    let sl = 46.0 * u;                  // slant
    let y0 = sh - dh;
    draw_polygon([[cx - dw - sl, sh], [cx - dw, y0], [cx + dw, y0], [cx + dw + sl, sh]], 0.035, 0.012, 0.085, 0.86, 2);
    draw_polygon_outline([[cx - dw - sl, sh], [cx - dw, y0], [cx + dw, y0], [cx + dw + sl, sh]], ar, ag, ab, 0.95, 2.0 * u, false, 3);
    draw_line_ex(cx - dw + 10.0 * u, y0 + 5.0 * u, cx + dw - 10.0 * u, y0 + 5.0 * u, br, bg, bb, 0.5, 1.0 * u, 3);

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
    let kmh = gs.speed_kmh.to_int();
    glow_text(cx + 62.0 * u, y0 + 30.0 * u, pad_int(kmh, 3), 56.0 * u, "hud", 1.0, 0.97, 0.9, 1.0, "right", 2.0 * u);
    label(cx + 72.0 * u, y0 + 66.0 * u, "KM/H", 15.0 * u, ar, ag, ab, 0.95, "left");

    // gear
    let gx = cx - 232.0 * u; let gy = y0 + 22.0 * u;
    draw_rect_outline_ex(gx, gy, 54.0 * u, 62.0 * u, br, bg, bb, 0.8, 1.5 * u, 4.0 * u, 4);
    label(gx + 27.0 * u, gy + 4.0 * u, "GEAR", 9.0 * u, br, bg, bb, 0.9, "center");
    let shift_age = now - gs.shifted;
    let gs_size = (38.0 + 10.0 * clamp(1.0 - shift_age * 4.0, 0.0, 1.0)) * u;
    glow_text(gx + 27.0 * u, gy + 16.0 * u, `${gs.gear}`, gs_size, "hud", 1.0, 0.92, 0.5, 1.0, "center", 0.0);

    // the road so far: S ▸▸▸▸▸ G
    let px0 = cx + 150.0 * u; let pw = 128.0 * u; let pyy = y0 + 40.0 * u;
    label(px0 - 14.0 * u, pyy - 9.0 * u, "S", 13.0 * u, br, bg, bb, 0.95, "center");
    label(px0 + pw + 14.0 * u, pyy - 9.0 * u, "G", 13.0 * u, 1.0, 0.9, 0.4, 0.95, "center");
    draw_line_ex(px0, pyy, px0 + pw, pyy, br, bg, bb, 0.35, 2.0 * u, 4);
    draw_line_ex(px0, pyy, px0 + pw * gs.run_progress, pyy, ar, ag, ab, 1.0, 3.0 * u, 5);
    for i in 0..6 {
        let x = px0 + pw * i.to_float() / 5.0;
        let done = gs.run_progress >= i.to_float() / 5.0 - 0.001;
        draw_line_ex(x, pyy - 5.0 * u, x, pyy + 5.0 * u, if done { ar } else { br }, if done { ag } else { bg }, if done { ab } else { bb }, if done { 1.0 } else { 0.5 }, 2.0 * u, 5);
    }
    let mx = px0 + pw * gs.run_progress;
    draw_polygon([[mx, pyy - 7.0 * u], [mx + 6.0 * u, pyy - 16.0 * u], [mx - 6.0 * u, pyy - 16.0 * u]], 1.0, 0.95, 0.6, 1.0, 6);
    draw_text_opts(px0 + pw * 0.5, pyy + 14.0 * u, `${gs.near_count} CLOSE PASSES`, 11.0 * u,
        #{ font: "mono", align: "center", color: [0.75, 0.8, 1.0, 0.7], layer: 5 });

    // ── words in the middle of the road ─────────────────────────
    let age = now - msg_t;
    if msg_kind == "count" && age < 0.9 {
        let k = age / 0.9;
        glow_text(cx, sh * 0.27 - 30.0 * u * k, msg, (150.0 - 50.0 * k) * u, "hud", 1.0, 0.85, 0.3, 1.0 - k * k, "center", 0.0);
    } else if msg_kind == "go" && age < 1.3 {
        let k = age / 1.3;
        glow_text(cx, sh * 0.25, msg, (140.0 + 60.0 * k) * u, "hud", 0.4, 1.0, 0.7, 1.0 - k * k, "center", 8.0 * u);
    } else if msg_kind == "big" && age < 3.2 {
        let a = clamp(age * 5.0, 0.0, 1.0) * clamp((3.2 - age) * 2.0, 0.0, 1.0);
        let blink = if (age * 7.0).to_int() % 2 == 0 || age > 1.4 { 1.0 } else { 0.35 };
        glow_text(cx, sh * 0.27, msg, 64.0 * u, "hud", 1.0, 0.9, 0.35, a * blink, "center", 6.0 * u);
        label(cx, sh * 0.27 + 78.0 * u, msg_sub, 20.0 * u, 0.5, 1.0, 0.85, a, "center");
    } else if msg_kind == "small" && age < 1.4 {
        let a = clamp((1.4 - age) * 2.0, 0.0, 1.0);
        glow_text(cx, sh * 0.36 - 30.0 * u * age, `${msg}  ${msg_sub}`, 24.0 * u, "hud", 0.5, 1.0, 0.9, a, "center", 2.0 * u);
    }

    if mode == "over" {
        let a = clamp(mt / 0.6, 0.0, 1.0);
        draw_rect_ex(0.0, 0.0, sw, sh, 0.02, 0.0, 0.05, 0.45 * a, 0.0, 1);
        glow_text(cx, sh * 0.30, "GAME OVER", 84.0 * u, "hud", 1.0, 0.2, 0.45, a, "center", 8.0 * u);
        label(cx, sh * 0.30 + 104.0 * u, `STAGE ${gs.stage + 1}  ${gs.stage_name}`, 20.0 * u, 0.7, 0.85, 1.0, a, "center");
        if mt > 1.5 { label(cx, sh * 0.30 + 150.0 * u, "ENTER  TO  CONTINUE", 16.0 * u, 1.0, 0.9, 0.5, 0.5 + 0.5 * sin(now * 5.0), "center"); }
    } else if mode == "finish" {
        let a = clamp(mt / 0.6, 0.0, 1.0);
        glow_text(cx, sh * 0.22, "GOAL", 120.0 * u, "hud", 1.0, 0.9, 0.4, a, "center", 14.0 * u);
        label(cx, sh * 0.22 + 138.0 * u, "YOU  REACHED  THE  HORIZON", 20.0 * u, 0.6, 1.0, 0.9, a, "center");
        if mt > 1.2 {
            label(cx, sh * 0.22 + 178.0 * u, `TIME BONUS  +${gs.event_value.to_int()}`, 18.0 * u, 1.0, 0.85, 0.5, clamp(mt - 1.2, 0.0, 1.0), "center");
        }
    }

    // a flash on the frame a checkpoint or a crash lands
    let fa = clamp(1.0 - (now - flash_t) * 4.0, 0.0, 1.0);
    if fa > 0.0 { draw_rect_ex(0.0, 0.0, sw, sh, 1.0, 0.9, 0.95, 0.28 * fa, 0.0, 8); }

    // fade up from the title
    if mode == "countdown" && mt < 0.5 { draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, 1.0 - mt * 2.0, 0.0, 9); }

    if paused {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.02, 0.0, 0.05, 0.6, 0.0, 10);
        draw_text_opts(cx, sh * 0.40, "PAUSED", 72.0 * u, #{ font: "hud", align: "center", layer: 11, spacing: 8.0 * u,
            color: [0.5, 0.95, 1.0, 1.0], stroke: [0.2, 0.8, 1.0, 0.3, 2.0 * u] });
        draw_text_opts(cx, sh * 0.40 + 96.0 * u, "P  TO  RESUME", 18.0 * u, #{ font: "hud", align: "center", layer: 11,
            color: [1.0, 0.9, 0.5, 0.9] });
    }
}
