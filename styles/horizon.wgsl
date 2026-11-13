// horizon: the sky of Kandinski. Runs at the hdr stage and feeds bloom.
// Only pixels nothing was drawn on (depth at the far plane) are painted.

fn disp(c: vec3<f32>) -> vec3<f32> {
    // params are display colours; the hdr stage is linear light
    return pow(max(c, vec3<f32>(0.0)), vec3<f32>(2.2));
}

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let a = flint_hash(p);
    let b = flint_hash(p + vec2<f32>(17.3, 91.7));
    return vec2<f32>(a, b);
}

fn view_dir(uv: vec2<f32>) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 1.0, 1.0);
    let w = flint.inv_view_proj * ndc;
    return normalize(w.xyz / w.w - flint.camera_pos);
}

fn style(p: StylePixel) -> vec4<f32> {
    let depth = flint_depth(p.uv);
    let dir = view_dir(p.uv);
    // one pixel, as an angle
    let px = length(view_dir(p.uv + vec2<f32>(0.0, flint.texel.y)) - dir);

    let el = asin(clamp(dir.y, -1.0, 1.0));
    let az = atan2(dir.x, -dir.z);

    let sky_top = disp(vec3<f32>(params.sky_top_r, params.sky_top_g, params.sky_top_b));
    let sky_low = disp(vec3<f32>(params.sky_low_r, params.sky_low_g, params.sky_low_b));
    let glow = disp(vec3<f32>(params.glow_r, params.glow_g, params.glow_b));
    let sun_hi = disp(vec3<f32>(params.sun_hi_r, params.sun_hi_g, params.sun_hi_b));
    let sun_lo = disp(vec3<f32>(params.sun_lo_r, params.sun_lo_g, params.sun_lo_b));
    let ground = disp(vec3<f32>(params.ground_r, params.ground_g, params.ground_b));

    // ---- gradient -------------------------------------------------
    let up = clamp(el / 0.62, 0.0, 1.0);
    var col = mix(sky_low, sky_top, pow(up, 0.6));

    // ---- stars ----------------------------------------------------
    let sgrid = vec2<f32>(az, el) * 46.0;
    let cell = floor(sgrid);
    let h = hash2(cell);
    let centre = (cell + 0.15 + 0.7 * hash2(cell + 7.0)) / 46.0;
    let sd = length((vec2<f32>(az, el) - centre) * vec2<f32>(cos(el), 1.0));
    let twinkle = 0.65 + 0.35 * sin(flint.time * (1.5 + 4.0 * h.y) + h.x * 40.0);
    let mag = pow(h.x, 9.0) * 5.0 + step(0.82, h.y) * 0.25;
    let star = mag * twinkle * (1.0 - smoothstep(0.0, px * 1.6, sd));
    let star_fade = smoothstep(0.03, 0.35, el);
    col += vec3<f32>(0.85, 0.9, 1.0) * star * star_fade * params.stars;

    // ---- sun ------------------------------------------------------
    let sp = vec2<f32>((az - params.sun_x) * cos(el), el - params.sun_y) / params.sun_size;
    let r = length(sp);
    let aa = px / params.sun_size;
    let disc = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
    // gradient: bottom to top
    let v = clamp(sp.y * 0.5 + 0.5, 0.0, 1.0);
    var sun = mix(sun_lo, sun_hi, smoothstep(0.22, 0.85, v));
    // concentric rings (the "Composition" stage's sun)
    let ring = floor(r * 5.0);
    let rk = ring - 3.0 * floor(ring / 3.0);
    var ring_col = sun_hi;
    if rk > 0.5 { ring_col = sun_lo; }
    if rk > 1.5 { ring_col = glow; }
    let ring_gap = smoothstep(0.80, 0.80 + aa * 10.0, abs(fract(r * 5.0) - 0.5) * 2.0);
    sun = mix(sun, ring_col * (1.0 - ring_gap), params.rings);
    // bands cut out of the lower half, widening toward the bottom
    let k = clamp((0.18 - sp.y) / 1.18, 0.0, 1.0);
    let band = fract(k * 7.0 - params.stripe_phase);
    let gap = (0.12 + 0.62 * k) * params.stripes;
    let baa = aa * 7.0 / 1.18;
    let cut = (1.0 - smoothstep(gap - baa, gap + baa, band)) * step(0.0001, k);
    let sun_mask = disc * (1.0 - cut * (1.0 - params.rings));
    // halo: a soft bed of light the disc sits in
    let halo = sun_lo * exp(-r * r * 0.9) * 0.28 + sun_lo * exp(-r * 0.9) * 0.10;
    col += halo * params.halo;
    // echoes: thin rings that leave the sun's rim on each beat and fade as
    // they widen (drive.rhai's pulse block gives the beat's phase)
    var echo = 0.0;
    for (var n = 0; n < 3; n = n + 1) {
        let age = params.echo_phase + f32(n);
        let rr = 1.0 + age * 0.5;
        let line = 1.0 - smoothstep(0.0, aa * 2.0 + 0.012, abs(r - rr));
        let fade = 1.0 - age / 3.0;
        echo += line * fade * fade;
    }
    col += mix(sun_lo, sun_hi, 0.35) * echo * params.echo;
    col = mix(col, sun * params.sun_gain, sun_mask);

    // ---- horizon --------------------------------------------------
    let band_up = exp(-max(el, 0.0) / params.haze);
    col += glow * band_up * 0.55 * params.glow_gain;
    // under the horizon: the ground runs on, dark, lit along its far edge
    let under = smoothstep(0.0, -px * 1.5, el);
    let floor_col = ground + glow * exp(el / (params.haze * 0.25)) * 0.5 * params.glow_gain;
    col = mix(col, floor_col, under);
    // the line itself
    col += glow * (1.0 - smoothstep(0.0, px * 1.8, abs(el))) * 1.6 * params.glow_gain;

    let is_sky = step(0.9999995, depth);
    return vec4<f32>(mix(p.color.rgb, col, is_sky), p.color.a);
}
