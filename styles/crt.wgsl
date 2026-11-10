// crt: scanlines, corner fringes, vignette, grain. Display stage.
fn style(p: StylePixel) -> vec4<f32> {
    let c = p.uv - vec2<f32>(0.5);
    let r2 = dot(c, c);
    let off = c * (0.25 + r2 * 3.0) * params.aberration * 0.006;
    let cr = flint_sample(p.uv + off).r;
    let cb = flint_sample(p.uv - off).b;
    var col = vec3<f32>(cr, p.color.g, cb);

    let y = p.pos.y / flint.pixels_per_point;
    let s = 0.5 + 0.5 * cos(y * 6.2831853 / params.pitch);
    // bright pixels bleed over the dark line, as phosphor does
    let luma = flint_luma(col);
    col *= 1.0 - params.scanlines * (1.0 - s) * (1.0 - 0.6 * luma);

    col *= 1.0 - params.vignette * smoothstep(0.12, 0.62, r2);

    let n = flint_hash(p.pos + vec2<f32>(flint.time * 61.0, flint.time * 37.0)) - 0.5;
    col += vec3<f32>(n) * params.grain * (1.0 - 0.7 * luma);
    return vec4<f32>(col, p.color.a);
}
