// audio.rhai — the car's voice, the air, and the radio.
//
// Loops are audio_source entities that autoplay at volume 0; this script
// only moves their volume and pitch (Flint's components have no play/stop).
// One-shots answer the events scripts/drive.rhai publishes in game_state.
//
// Engine: two loops recorded at exact fundamentals (tools/gen_audio.py:
// engine_low 55 Hz, engine_high 110 Hz). Both are played at the same target
// frequency f(rpm, gear), so the crossfade never sounds like two engines.

let game = -1;
let id_low = -1;
let id_high = -1;
let id_wind = -1;
let id_skid = -1;
let id_off = -1;
let id_drive = -1;
let id_title = -1;
let seen_event_time = -100.0;
let seen_shift = 0.0;
let v_drive = 0.0;
let v_title = 0.0;
let rpm_s = 0.2;
let last_tick = 100;

fn on_init() {
    game = get_entity("game");
    id_low = get_entity("snd_engine_low");
    id_high = get_entity("snd_engine_high");
    id_wind = get_entity("snd_wind");
    id_skid = get_entity("snd_skid");
    id_off = get_entity("snd_offroad");
    id_drive = get_entity("snd_music_drive");
    id_title = get_entity("snd_music_title");
}

fn on_update() {
    if game < 0 { return; }
    let gs = get_component(game, "game_state");
    if gs == () { return; }
    let dt = min(delta_time(), 0.05);
    let mode = gs.mode;
    let sp = clamp(gs.speed / 83.0, 0.0, 1.0);
    let title = mode == "title";

    // ── engine ──────────────────────────────────────────────────
    rpm_s += (gs.rpm - rpm_s) * min(1.0, dt * 9.0);
    // 50 Hz at idle to 190 Hz at the limiter, a little higher in each gear
    let hz = 50.0 + 140.0 * rpm_s * rpm_s + 4.0 * gs.gear.to_float();
    let mix = clamp((rpm_s - 0.30) / 0.45, 0.0, 1.0);
    let load = 0.55 + 0.45 * gs.throttle;
    let master = if title { 0.22 } else if mode == "over" || mode == "finish" { 0.45 } else { 0.80 };
    set_field(id_low, "audio_source", "pitch", clamp(hz / 55.0, 0.3, 3.9));
    set_field(id_high, "audio_source", "pitch", clamp(hz / 110.0, 0.3, 3.9));
    set_field(id_low, "audio_source", "volume", (1.0 - mix * 0.75) * load * master * 0.62);
    set_field(id_high, "audio_source", "volume", mix * load * master * 0.50);

    // ── air, tyres, shoulder ────────────────────────────────────
    set_field(id_wind, "audio_source", "volume", sp * sp * (if title { 0.25 } else { 0.55 }));
    set_field(id_wind, "audio_source", "pitch", 0.7 + 0.6 * sp);
    let spin = if gs.crash > 0.0 { 1.0 } else { 0.0 };
    set_field(id_skid, "audio_source", "volume", clamp(max(gs.skid * 0.55, spin * 0.8), 0.0, 1.0) * (if title { 0.0 } else { 1.0 }));
    set_field(id_skid, "audio_source", "pitch", 0.85 + 0.3 * sp);
    set_field(id_off, "audio_source", "volume", gs.offroad * (0.25 + 0.6 * sp));
    set_field(id_off, "audio_source", "pitch", 0.7 + 0.7 * sp);
    // the world goes dull for a moment after a crash
    set_audio_lowpass(if gs.crash > 0.0 { 900.0 + 3000.0 * (1.6 - gs.crash) } else { 20000.0 });

    // ── the radio ───────────────────────────────────────────────
    let want_drive = if mode == "drive" || mode == "countdown" { 0.80 } else if mode == "finish" { 0.55 } else if mode == "over" { 0.18 } else { 0.0 };
    let want_title = if title { 0.75 } else { 0.0 };
    v_drive += (want_drive - v_drive) * min(1.0, dt * 1.6);
    v_title += (want_title - v_title) * min(1.0, dt * 1.6);
    set_field(id_drive, "audio_source", "volume", v_drive);
    set_field(id_title, "audio_source", "volume", v_title);

    // ── one-shots ───────────────────────────────────────────────
    if gs.event_time != seen_event_time {
        seen_event_time = gs.event_time;
        let e = gs.event;
        if e == "count" { play_sound("audio/count_beep.ogg", 0.8); }
        else if e == "go" { play_sound("audio/count_go.ogg", 0.9); }
        else if e == "start" { play_sound("audio/ui_select.ogg", 0.8); }
        else if e == "checkpoint" { play_sound("audio/checkpoint.ogg", 0.9); play_sound("audio/stage.ogg", 0.7); }
        else if e == "finish" { play_sound("audio/finish.ogg", 1.0); }
        else if e == "over" { play_sound("audio/game_over.ogg", 0.9); }
        else if e == "crash" { play_sound("audio/crash.ogg", 1.0); }
        else if e == "bump" { play_sound("audio/bump.ogg", 0.9, 0.9 + random() * 0.2); }
        else if e == "near_miss" { play_sound("audio/near_miss.ogg", 0.7); play_sound("audio/whoosh.ogg", 0.8, 0.9 + random() * 0.3); }
        else if e == "pass" { play_sound("audio/whoosh.ogg", 0.45, 0.85 + random() * 0.3); }
    }
    if gs.shifted != seen_shift {
        seen_shift = gs.shifted;
        if !title { play_sound("audio/shift.ogg", 0.5); }
    }
    // the last ten seconds tick
    let secs = (gs.time_left + 0.999).to_int();
    if mode == "drive" && secs < last_tick && secs <= 10 && secs > 0 { play_sound("audio/tick.ogg", 0.8); }
    last_tick = secs;
}
