// tour.rhai — the GRAND TOUR's content, shared by drive.rhai and hud.rhai.
//
// An event is a road made from parameters plus a rule. To add one, add a map
// to `events()` (keep 3 a leg), then run `python tools/tour_check.py
// --calibrate`, which drives it with the autopilot and writes the clock and
// the medal targets into scripts/lib/tour_cal.rhai.
//
//   secs     the road, a section per entry: [theme, tiles (8 m each),
//            curve_max, hill_amp, curve_min, straight share]. A section
//            boundary is a gate: a checkpoint when the event has a clock.
//   traffic  [cars (0-12), slowest m/s, speed spread m/s, spawn spread m]
//   rivals   a skill per rival (race only): 1.0 is about the autopilot's pace
//   type     sprint | race | drift | rush | endurance
//
// Themes: 0 SUNSET COAST 1 NEON CITY 2 PINE RIDGE 3 COMPOSITION 4 DAYBREAK
//         5 MOONLIT SHORE 6 AURORA PLAIN 7 ULTRAVIOLET

import "tour_cal" as cal;

fn theme_names() {
    ["SUNSET COAST", "NEON CITY", "PINE RIDGE", "COMPOSITION", "DAYBREAK", "MOONLIT SHORE", "AURORA PLAIN", "ULTRAVIOLET"]
}

fn leg_names() { ["COASTLINE", "CITY LIMITS", "HIGH COUNTRY", "ABSTRACTION", "HORIZON"] }

fn rival_names() { ["GELB", "ROT", "BLAU", "GRUN", "WEISS"] }
// rival paint: one colour, as the hero's (body, x2 lit, x0.36 shade) but brighter, so the pack reads at speed
fn rival_paint() { [[0.20, 0.15, 0.01], [0.22, 0.02, 0.02], [0.02, 0.08, 0.26], [0.02, 0.18, 0.06], [0.16, 0.16, 0.18]] }
fn rival_ink() { [[1.0, 0.85, 0.2], [1.0, 0.3, 0.3], [0.35, 0.6, 1.0], [0.4, 1.0, 0.55], [0.95, 0.95, 1.0]] }

// hero paints: name, colour, medals needed
fn paints() {
    [
        #{ name: "CARMINE", c: [0.030, 0.003, 0.010], need: 0 },
        #{ name: "COBALT", c: [0.004, 0.012, 0.045], need: 4 },
        #{ name: "VIRIDIAN", c: [0.003, 0.030, 0.016], need: 8 },
        #{ name: "CHROME YELLOW", c: [0.045, 0.030, 0.002], need: 12 },
    ]
}

// the original five-stage run, exactly as it was
fn arcade() {
    #{ id: "arcade", name: "ARCADE", type: "arcade", seed: 20261109,
       secs: [[0, 500, 0.075, 9.0, 0.045, 0.28], [1, 500, 0.100, 5.0, 0.045, 0.28], [2, 500, 0.140, 26.0, 0.045, 0.28],
              [3, 500, 0.150, 14.0, 0.045, 0.28], [4, 500, 0.110, 18.0, 0.045, 0.28]],
       traffic: [8, 28.0, 20.0, 520.0], rivals: [], time0: 70.0, ext: [58.0, 56.0, 54.0, 52.0],
       targets: [0.0, 0.0, 0.0], max_crashes: 99, brief: [] }
}

// HORIZON: the first sections; drive.rhai keeps adding more, harder
fn endless() {
    #{ id: "endless", name: "HORIZON", type: "endless", seed: 7741,
       secs: [[0, 260, 0.070, 8.0, 0.045, 0.30], [5, 260, 0.080, 8.0, 0.045, 0.28]],
       traffic: [7, 28.0, 18.0, 520.0], rivals: [], time0: 0.0, ext: [],
       targets: [0.0, 0.0, 0.0], max_crashes: 3, brief: [] }
}

fn raw_events() {
    [
        // ── leg 1: COASTLINE ────────────────────────────────────
        #{ id: "l1e1", name: "FIRST LIGHT", type: "sprint", seed: 1101,
           secs: [[0, 300, 0.060, 7.0, 0.040, 0.32], [5, 300, 0.070, 8.0, 0.040, 0.30], [0, 300, 0.075, 9.0, 0.045, 0.28]],
           traffic: [6, 28.0, 16.0, 560.0], rivals: [] },
        #{ id: "l1e2", name: "SHORE RUN", type: "race", seed: 1202,
           secs: [[0, 450, 0.070, 8.0, 0.045, 0.30], [5, 450, 0.080, 9.0, 0.045, 0.28]],
           traffic: [0, 30.0, 12.0, 700.0], rivals: [0.86, 0.90, 0.94, 0.975, 1.00] },
        #{ id: "l1e3", name: "PALM SLALOM", type: "drift", seed: 1303, time0: 110.0,
           secs: [[5, 1200, 0.130, 5.0, 0.100, 0.10]],
           traffic: [0, 30.0, 10.0, 700.0], rivals: [] },
        // ── leg 2: CITY LIMITS ──────────────────────────────────
        #{ id: "l2e1", name: "RUSH HOUR", type: "rush", seed: 2101, max_crashes: 3,
           secs: [[1, 370, 0.060, 4.0, 0.040, 0.36], [7, 370, 0.065, 5.0, 0.040, 0.34], [1, 370, 0.070, 5.0, 0.040, 0.34]],
           traffic: [11, 26.0, 16.0, 330.0], rivals: [] },
        #{ id: "l2e2", name: "UNDERPASS", type: "sprint", seed: 2202,
           secs: [[1, 390, 0.095, 5.0, 0.045, 0.28], [7, 390, 0.105, 8.0, 0.045, 0.26], [1, 390, 0.110, 6.0, 0.050, 0.26]],
           traffic: [7, 28.0, 18.0, 520.0], rivals: [] },
        #{ id: "l2e3", name: "BOULEVARD CUP", type: "race", seed: 2303,
           secs: [[7, 580, 0.095, 6.0, 0.045, 0.28], [1, 580, 0.105, 6.0, 0.045, 0.26]],
           traffic: [0, 30.0, 14.0, 640.0], rivals: [0.87, 0.91, 0.95, 0.985, 1.01] },
        // ── leg 3: HIGH COUNTRY ─────────────────────────────────
        #{ id: "l3e1", name: "SWITCHBACK", type: "drift", seed: 3101, time0: 150.0,
           secs: [[2, 1650, 0.170, 16.0, 0.110, 0.08]],
           traffic: [3, 30.0, 10.0, 800.0], rivals: [] },
        #{ id: "l3e2", name: "RIDGE RACE", type: "race", seed: 3202,
           secs: [[2, 450, 0.130, 22.0, 0.050, 0.26], [6, 450, 0.110, 26.0, 0.045, 0.28], [2, 450, 0.140, 24.0, 0.050, 0.24]],
           traffic: [0, 32.0, 14.0, 900.0], rivals: [0.88, 0.92, 0.955, 0.99, 1.02] },
        #{ id: "l3e3", name: "NORTHERN LINE", type: "sprint", seed: 3303,
           secs: [[6, 360, 0.110, 30.0, 0.045, 0.28], [2, 360, 0.140, 26.0, 0.050, 0.24], [6, 360, 0.120, 34.0, 0.045, 0.26], [6, 360, 0.130, 30.0, 0.050, 0.24]],
           traffic: [8, 28.0, 20.0, 500.0], rivals: [] },
        // ── leg 4: ABSTRACTION ──────────────────────────────────
        #{ id: "l4e1", name: "POINT AND LINE", type: "rush", seed: 4101, max_crashes: 3,
           secs: [[3, 440, 0.080, 8.0, 0.040, 0.32], [7, 440, 0.085, 6.0, 0.040, 0.32], [3, 440, 0.090, 10.0, 0.045, 0.30], [7, 440, 0.090, 6.0, 0.045, 0.30]],
           traffic: [12, 26.0, 22.0, 280.0], rivals: [] },
        #{ id: "l4e2", name: "YELLOW RED BLUE", type: "drift", seed: 4202, time0: 200.0,
           secs: [[3, 1100, 0.190, 10.0, 0.120, 0.07], [7, 1100, 0.200, 8.0, 0.130, 0.06]],
           traffic: [5, 30.0, 12.0, 640.0], rivals: [] },
        #{ id: "l4e3", name: "SEVERAL CIRCLES", type: "race", seed: 4303,
           secs: [[3, 480, 0.150, 14.0, 0.050, 0.24], [6, 480, 0.130, 28.0, 0.050, 0.26], [7, 480, 0.140, 8.0, 0.050, 0.24], [3, 480, 0.150, 16.0, 0.055, 0.22]],
           traffic: [0, 32.0, 16.0, 800.0], rivals: [0.89, 0.93, 0.96, 0.99, 1.02] },
        // ── leg 5: HORIZON ──────────────────────────────────────
        #{ id: "l5e1", name: "LAST EXIT", type: "rush", seed: 5101, max_crashes: 2,
           secs: [[1, 440, 0.090, 6.0, 0.045, 0.30], [7, 440, 0.100, 8.0, 0.045, 0.28], [4, 440, 0.100, 14.0, 0.045, 0.28], [1, 440, 0.105, 6.0, 0.050, 0.28]],
           traffic: [12, 24.0, 28.0, 250.0], rivals: [] },
        #{ id: "l5e2", name: "GRAND FINAL", type: "race", seed: 5202,
           secs: [[0, 480, 0.130, 12.0, 0.050, 0.26], [1, 480, 0.140, 8.0, 0.050, 0.24], [2, 480, 0.155, 28.0, 0.055, 0.22], [4, 480, 0.140, 18.0, 0.050, 0.24]],
           traffic: [0, 32.0, 18.0, 760.0], rivals: [0.90, 0.94, 0.97, 0.995, 1.03] },
        #{ id: "l5e3", name: "POINT AND LINE TO HORIZON", type: "endurance", seed: 5303,
           secs: [[0, 480, 0.090, 10.0, 0.045, 0.28], [5, 480, 0.100, 10.0, 0.045, 0.28], [1, 480, 0.115, 6.0, 0.045, 0.26], [7, 480, 0.125, 8.0, 0.050, 0.26],
                  [2, 480, 0.150, 28.0, 0.050, 0.24], [6, 480, 0.130, 34.0, 0.050, 0.26], [3, 480, 0.155, 16.0, 0.055, 0.22], [4, 480, 0.130, 20.0, 0.050, 0.26]],
           traffic: [9, 28.0, 22.0, 460.0], rivals: [] },
    ]
}

// the events with their calibrated clocks and targets filled in
fn events() {
    let out = [];
    let c = cal::cal();
    let i = 0;
    for e in raw_events() {
        e.idx = i;
        e.leg = i / 3;
        if !("max_crashes" in e) { e.max_crashes = 99; }
        if !("time0" in e) { e.time0 = 0.0; }
        e.ext = [];
        e.targets = if e.type == "race" { [3.0, 2.0, 1.0] } else { [0.0, 0.0, 0.0] };
        if e.id in c {
            let k = c[e.id];
            if "time0" in k { e.time0 = k.time0; }
            if "ext" in k { e.ext = k.ext; }
            if "targets" in k { e.targets = k.targets; }
        }
        // an uncalibrated clock is a long one
        if e.type != "race" && e.type != "drift" && e.time0 <= 0.0 { e.time0 = 900.0; }
        while e.ext.len() < e.secs.len() - 1 { e.ext.push(if e.type == "drift" || e.type == "race" { 0.0 } else { 60.0 }); }
        let n = 0;
        for s in e.secs { n += s[1]; }
        e.km = n.to_float() * 0.008;
        out.push(e);
        i += 1;
    }
    out
}

// 0 none, 1 bronze, 2 silver, 3 gold. `value` is what the type is scored by:
// sprint seconds left, race position, drift points, rush close passes,
// endurance score. `ok` is false when the run failed (clock, crashes).
fn medal_for(e, value, ok) {
    if !ok { return 0; }
    let t = e.targets;
    if e.type == "race" {
        return if value <= t[2] { 3 } else if value <= t[1] { 2 } else if value <= t[0] { 1 } else { 0 };
    }
    if value >= t[2] { 3 } else if value >= t[1] { 2 } else if value >= t[0] { 1 } else { 0 }
}

// is `b` a better result than `a` for this type?
fn better(e, a, b) { if e.type == "race" { b < a } else { b > a } }

// A leg opens when the leg before it has a medal in its finale. A leg's
// first two events open with the leg; its finale needs a medal in both.
fn unlocked(i, medals) {
    let leg = i / 3;
    let k = i % 3;
    let open = leg == 0 || medals[(leg - 1) * 3 + 2] > 0;
    if k < 2 { open } else { open && medals[leg * 3] > 0 && medals[leg * 3 + 1] > 0 }
}
// HORIZON opens when leg 1 is cleared
fn endless_unlocked(medals) { medals[0] > 0 && medals[1] > 0 && medals[2] > 0 }

fn medal_count(medals) { let n = 0; for m in medals { if m > 0 { n += 1; } } n }

fn type_label(t) {
    if t == "sprint" { "SPRINT" } else if t == "race" { "RACE" } else if t == "drift" { "DRIFT" }
    else if t == "rush" { "RUSH" } else if t == "endurance" { "ENDURANCE" } else { "" }
}

// a target, in the words of its type
fn target_text(e, k) {
    let v = e.targets[k];
    if e.type == "sprint" { if v <= 0.0 { "REACH THE GOAL" } else { `${v.to_int()} SEC LEFT` } }
    else if e.type == "race" { if v <= 1.0 { "1ST" } else if v <= 2.0 { "2ND" } else { "3RD" } }
    else if e.type == "drift" { `${v.to_int()} PTS` }
    else if e.type == "rush" { `${v.to_int()} PASSES` }
    else { `${v.to_int()} PTS` }
}

fn value_text(e, v) {
    if e.type == "sprint" { `${(v * 10.0).to_int().to_float() / 10.0} SEC LEFT` }
    else if e.type == "race" { let p = v.to_int(); if p == 1 { "1ST" } else if p == 2 { "2ND" } else if p == 3 { "3RD" } else { `${p}TH` } }
    else if e.type == "drift" { `${v.to_int()} PTS` }
    else if e.type == "rush" { `${v.to_int()} PASSES` }
    else { `${v.to_int()} PTS` }
}

fn brief_lines(e) {
    if e.type == "sprint" { ["BEAT THE CLOCK TO THE GOAL.", "EVERY GATE ADDS TIME. THE MEDAL IS THE TIME YOU HAVE LEFT."] }
    else if e.type == "race" { ["STANDING START, FIVE RIVALS, FIRST TO THE GOAL.", "TUCK IN BEHIND A RIVAL TO FILL THE BOOST, THEN PULL OUT AND USE IT."] }
    else if e.type == "drift" { [`${e.time0.to_int()} SECONDS OF BENDS. THE MEDAL IS DRIFT POINTS BANKED.`, "HANDBRAKE IN, HOLD THE WHEEL INTO THE BEND. A SPIN LOSES THE SLIDE."] }
    else if e.type == "rush" { ["HEAVY TRAFFIC. THE MEDAL IS CLOSE PASSES BEFORE THE GOAL.", `CRASH OR SPIN MORE THAN ${e.max_crashes} TIMES, OR RUN OUT OF CLOCK: NO MEDAL.`] }
    else { ["EIGHT LANDS, ONE ROAD. EVERY GATE ADDS TIME.", "THE MEDAL IS THE SCORE AT THE GOAL: PACE, DRIFTS, PASSES, AIR."] }
}
