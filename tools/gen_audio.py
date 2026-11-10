"""Kandinski audio: every sound in the game, synthesized from nothing.

    python tools/gen_audio.py                 regenerate everything in audio/
    python tools/gen_audio.py crash wind      regenerate a subset (file stems)
    python tools/gen_audio.py --verify        regenerate, then measure every file
    python tools/gen_audio.py --verify-only   measure what is already in audio/

Pure numpy DSP: no samples, no downloads, fixed seeds, so a run reproduces the
same PCM. Each sound is written as 24-bit WAV to snapshots/audio/wav/ (scratch)
and encoded to OGG Vorbis in audio/ with ffmpeg (libvorbis, bit-exact flags).

Flint preloads every *.ogg under audio/. One-shots are played by stem with
play_sound(name, volume, pitch); loops are audio_source components whose
volume/pitch a script sets every frame.

LOOPS are periodic by construction, never crossfaded: every note tail, delay
and reverb is wrapped modulo the loop length (circular convolution), and every
filter after that is an FFT filter over exactly one loop, which is circular
too. Sample N continues into sample 0 as smoothly as any two neighbours.

Loop OGGs are also cut to decode to exactly the loop's length even in a
decoder that ignores Vorbis end trimming, which Flint's does (see encode_loop).
Loop lengths in samples: engines 141120, wind 264576, skid and offroad 88192,
music_drive 6272000, music_title 2352000. The non-music loops are rotated to
start wherever in their cycle the cut works; they have no beginning anyway.

Engine loops (mono, 141120 samples = 3.2 s exactly):
    engine_low.ogg    firing fundamental 55 Hz   (176 firings, 88 half-orders)
    engine_high.ogg   firing fundamental 110 Hz  (352 firings, 176 half-orders)
  at pitch p the fundamental is 55*p / 110*p Hz.

music_drive.ogg (stereo): D minor, 108 BPM, 4/4, 64 bars.
    24500 samples per beat (0.555556 s), 98000 per bar (2.222222 s),
    6272000 samples = 142.222 s. Bar 1 beat 1 is sample 0 (t = 0).
    bars  1- 8  intro       0:00.000   arp + filtered bass, hats from bar 5
    bars  9-16  A           0:17.778   drums in, bass, chords
    bars 17-32  B (hook)    0:35.556   lead melody, twice
    bars 33-40  breakdown   1:11.111   no kick for four bars, then the build
    bars 41-56  A'          1:28.889   second melody, harmonised second time
    bars 57-64  turnaround  2:04.444   thins out back to the top

music_title.ogg (stereo): D minor, 54 BPM (half the drive tempo), 12 bars,
    49000 samples per beat, 2352000 samples = 53.333 s.
"""
import json
import os
import re
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
TAU = 2.0 * np.pi
ROOT = Path(__file__).resolve().parent.parent
AUDIO = ROOT / "audio"
SNAP = ROOT / "snapshots" / "audio"
WAVDIR = SNAP / "wav"


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
def rng(seed):
    return np.random.default_rng(seed)


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def undb(d):
    return 10.0 ** (d / 20.0)


def mtof(m):
    return 440.0 * 2.0 ** ((np.asarray(m, dtype=float) - 69.0) / 12.0)


def rms(x):
    return float(np.sqrt(np.mean(np.square(x))))


def active_rms(x, floor=1e-4):
    m = np.abs(x) > floor
    return float(np.sqrt(np.mean(np.square(x[m])))) if m.any() else 0.0


def peak(x):
    return float(np.max(np.abs(x)))


def norm_peak(x, p=1.0):
    return x * (p / max(peak(x), 1e-12))


# magnitude responses, used with fftfilt --------------------------------------
def H_lp(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def H_hp(f, fc, order=2):
    r = (f / fc) ** (2 * order)
    return np.sqrt(r / (1.0 + r))


def H_peak(f, f0, q):
    f = np.maximum(f, 1e-6)
    return 1.0 / np.sqrt(1.0 + (q * (f / f0 - f0 / f)) ** 2)


def H_res(f, fc, q):
    """Two-pole resonant low-pass magnitude."""
    r = f / fc
    return 1.0 / np.sqrt((1.0 - r * r) ** 2 + (r / q) ** 2)


def fftfilt(x, gain, circular=True, pad=4096):
    """Zero-phase filter by spectral gain(f). Circular over the array (what a
    loop wants) or zero-padded (what a one-shot wants)."""
    x = np.asarray(x, dtype=float)
    if not circular:
        x = np.pad(x, [(0, 0)] * (x.ndim - 1) + [(pad, pad)])
    n = x.shape[-1]
    X = np.fft.rfft(x, axis=-1)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    y = np.fft.irfft(X * gain(f), n, axis=-1)
    if not circular:
        y = y[..., pad:-pad]
    return y


def cconv(x, k):
    """Circular convolution of x (.., n) with kernel k (.., m<=n)."""
    n = x.shape[-1]
    return np.fft.irfft(np.fft.rfft(x, axis=-1) * np.fft.rfft(k, n, axis=-1), n, axis=-1)


def fconv(x, k):
    """Full linear convolution."""
    n = x.shape[-1] + k.shape[-1] - 1
    return np.fft.irfft(np.fft.rfft(x, n, axis=-1) * np.fft.rfft(k, n, axis=-1), n, axis=-1)


def periodic_noise(n, rs, max_cycles, min_cycles=1):
    """Smooth random curve, exactly periodic over n samples, unit peak."""
    X = np.zeros(n // 2 + 1, dtype=complex)
    k = np.arange(min_cycles, max_cycles + 1)
    X[k] = (rs.standard_normal(k.size) + 1j * rs.standard_normal(k.size)) / np.sqrt(k)
    y = np.fft.irfft(X, n)
    return y / max(peak(y), 1e-12)


def fade(y, fin=0.001, fout=0.01):
    y = np.array(y, dtype=float)
    a = max(int(fin * SR), 1)
    b = max(int(fout * SR), 1)
    y[..., :a] *= np.linspace(0.0, 1.0, a)
    y[..., -b:] *= 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, b))
    return y


def pan_gains(p):
    th = (np.clip(p, -1.0, 1.0) + 1.0) * np.pi / 4.0
    return np.cos(th), np.sin(th)


def put(buf, start, sig, gain=1.0, pan=0.0):
    """Mix sig into a loop buffer at start, wrapping past the end."""
    sig = np.asarray(sig)
    if buf.ndim == 1:
        s2 = sig[None, :] * gain
        tgt = buf[None, :]
    else:
        tgt = buf
        if sig.ndim == 1:
            gl, gr = pan_gains(pan)
            s2 = np.stack([sig * (gl * gain), sig * (gr * gain)])
        else:
            s2 = sig * gain
    N = tgt.shape[-1]
    n = s2.shape[-1]
    pos = int(start) % N
    off = 0
    while off < n:
        k = min(N - pos, n - off)
        tgt[:, pos:pos + k] += s2[:, off:off + k]
        off += k
        pos = 0


def saw_blep(freq, n, phase0=0.0):
    """Band-limited-enough sawtooth (polyBLEP), for sounds low-passed anyway."""
    dt = freq / SR
    ph = (phase0 + dt * np.arange(n)) % 1.0
    y = 2.0 * ph - 1.0
    m = ph < dt
    t = ph[m] / dt
    y[m] -= t + t - t * t - 1.0
    m = ph > 1.0 - dt
    t = (ph[m] - 1.0) / dt
    y[m] -= t * t + t + t + 1.0
    return y


def additive(phase, f, cutoff, q, shape="saw", pw=0.5, fmax=16000.0, kmax=160):
    """An oscillator through a resonant low-pass whose cutoff moves, done as a
    sum of harmonics each weighted by the filter's response where that harmonic
    is right now: band-limited, vectorised, no recursive filter."""
    out = np.zeros_like(phase)
    flo = float(np.min(f))
    cmax = float(np.max(cutoff))
    scalar_f = np.ndim(f) == 0
    K = int(min(kmax, fmax // flo))
    for k in range(1, K + 1):
        if shape == "saw":
            a = 1.0 / k
        elif shape == "square":
            if k % 2 == 0:
                continue
            a = 1.0 / k
        else:
            a = np.sin(np.pi * k * pw) / (k * np.sin(np.pi * pw))
        kf = k * f
        if k * flo > 7.0 * cmax:
            break
        h = H_res(kf, cutoff, q) * H_lp(kf, cutoff * 1.7, 1)
        if not scalar_f:
            h = np.where(kf < fmax, h, 0.0)
        out += (a * h) * np.sin(k * phase)
    return out


def swept_noise(n, fc, rs, width=0.45, lo=120.0, hi=14000.0, bands=18):
    """Noise through a band that follows fc(t): a bank of fixed bands, each
    faded by how near the moving centre is to it."""
    nz = rs.standard_normal(n)
    X = np.fft.rfft(nz)
    f = np.maximum(np.fft.rfftfreq(n, 1.0 / SR), 1.0)
    lf = np.log2(f)
    lc = np.log2(np.broadcast_to(fc, (n,)))
    centres = np.linspace(np.log2(lo), np.log2(hi), bands)
    bw = (centres[1] - centres[0])
    out = np.zeros(n)
    for c in centres:
        band = np.fft.irfft(X * np.exp(-0.5 * ((lf - c) / (bw * 0.6)) ** 2), n)
        out += band * np.exp(-0.5 * ((lc - c) / width) ** 2)
    return out


def chorus(x, rate_cycles, depth_ms=3.0, base_ms=11.0, mix=0.5):
    """Stereo chorus on a loop: a delay whose length breathes a whole number
    of times per loop, so the result is still periodic."""
    N = x.shape[-1]
    t = np.arange(N)
    out = np.empty_like(x)
    for c in range(x.shape[0]):
        d = (base_ms + depth_ms * np.sin(TAU * rate_cycles * t / N + c * 2.1)) * SR / 1000.0
        idx = t - d
        i0 = np.floor(idx).astype(np.int64)
        fr = idx - i0
        out[c] = x[c] + mix * (x[c][i0 % N] * (1.0 - fr) + x[c][(i0 + 1) % N] * fr)
    return out


def make_ir(seed, length=2.6, rt_low=2.3, rt_mid=1.9, rt_high=0.9, predelay=0.02):
    """A plate-ish stereo impulse response: decaying noise whose highs die
    first. Unit energy per channel."""
    n = int(length * SR)
    rs = rng(seed)
    t = np.arange(n) / SR
    nz = rs.standard_normal((2, n))
    lo = fftfilt(nz, lambda f: H_lp(f, 500.0, 2), False)
    hi = fftfilt(nz, lambda f: H_hp(f, 3500.0, 2), False)
    mid = nz - lo - hi
    ir = (lo * np.exp(-6.91 * t / rt_low) + mid * np.exp(-6.91 * t / rt_mid)
          + hi * np.exp(-6.91 * t / rt_high))
    ir *= 1.0 - np.exp(-t / 0.004)
    ir = fftfilt(ir, lambda f: H_hp(f, 240.0, 2) * H_lp(f, 9000.0, 1), False)
    ir = fade(ir, 0.0005, 0.2)
    ir = np.pad(ir, ((0, 0), (int(predelay * SR), 0)))
    return ir / np.sqrt(np.mean(np.sum(ir ** 2, axis=1)))


def soft_limit(x, ceiling, knee=0.72):
    """Memoryless soft knee: identity below knee*ceiling, tanh into the ceiling.
    Memoryless, so a periodic signal stays periodic."""
    T = ceiling * knee
    a = np.abs(x)
    over = a > T
    y = x.copy()
    y[over] = np.sign(x[over]) * (T + (ceiling - T) * np.tanh((a[over] - T) / (ceiling - T)))
    return y


# --------------------------------------------------------------------------
# files: WAV out, OGG out, loudness
# --------------------------------------------------------------------------
def write_wav24(path, x):
    x = np.asarray(x, dtype=float)
    if x.ndim == 1:
        x = x[None, :]
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.ascontiguousarray(np.clip(np.round(x.T * 8388607.0), -8388608, 8388607).astype("<i4"))
    raw = pcm.view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(x.shape[0])
        w.setsampwidth(3)
        w.setframerate(SR)
        w.writeframes(raw)


def read_wav24(path):
    with wave.open(str(path), "rb") as w:
        ch, n = w.getnchannels(), w.getnframes()
        raw = np.frombuffer(w.readframes(n), dtype=np.uint8).reshape(-1, 3)
    v = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8)
         | (raw[:, 2].astype(np.int8).astype(np.int32) << 16))
    return (v.reshape(-1, ch).T / 8388607.0)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")


def loudness(path):
    """(integrated LUFS, true peak dBFS) from ffmpeg's EBU R128 meter."""
    r = run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path),
             "-af", "ebur128=peak=true", "-f", "null", "-"])
    tail = r.stderr[r.stderr.rfind("Summary:"):]
    i = re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", tail)
    p = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    f = lambda m: float(m.group(1)) if m and m.group(1) != "-inf" else float("-inf")
    return f(i), f(p)


def master(x, target_lufs, ceiling_db=-1.6, name="master"):
    """Gain to an integrated loudness, soft-limited under a ceiling."""
    tmp = WAVDIR / f"_{name}_tmp.wav"
    c = undb(ceiling_db)
    y = x
    for _ in range(4):
        write_wav24(tmp, np.clip(y, -1, 1))
        i, _tp = loudness(tmp)
        y = soft_limit(y * undb(target_lufs - i), c)
    write_wav24(tmp, y)
    i, tp = loudness(tmp)
    if tp > ceiling_db + 0.3:
        y = y * undb(ceiling_db + 0.3 - tp)
    tmp.unlink(missing_ok=True)
    return y


def encode(name, x, q):
    wav = WAVDIR / f"{name}.wav"
    write_wav24(wav, x)
    AUDIO.mkdir(parents=True, exist_ok=True)
    out = AUDIO / f"{name}.ogg"
    r = run(["ffmpeg", "-y", "-v", "error", "-i", str(wav), "-map_metadata", "-1",
             "-fflags", "+bitexact", "-flags:a", "+bitexact",
             "-c:a", "libvorbis", "-q:a", str(q), "-ar", str(SR), str(out)])
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return out


# --------------------------------------------------------------------------
# exact-length Vorbis for loops
# --------------------------------------------------------------------------
# A Vorbis stream ends on a whole block, and the encoder records the true
# length in the last page's granule position so a decoder can trim the excess.
# Flint's decoder (Symphonia with default FormatOptions, as Kira's own loader)
# does NOT trim: it plays every decoded sample, so a plain encode loops with up
# to a block of extrapolated fade-out stuck on its end (measured: +512 samples
# on engine_low, +832 on music_drive). So loops are encoded with their own
# beginning appended, and the stream is then cut after the packet whose block
# centre lands exactly on the loop length. Decoded with or without trimming,
# that stream is exactly N samples, and its last block was coded against the
# real continuation (the loop's own start) instead of padding.
def _ogg_crc_table():
    t = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if r & 0x80000000 else (r << 1) & 0xFFFFFFFF
        t.append(r)
    return t


_OGG_CRC = _ogg_crc_table()


def _ogg_crc(data):
    c = 0
    T = _OGG_CRC
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ T[(c >> 24) ^ b]
    return c


def ogg_read(data):
    """-> (serial, packets, the header pages' bytes, how many pages those are)."""
    pos = 0
    packets, cur, serial, header_pages, header_end, npage = [], b"", None, None, 0, 0
    while pos < len(data):
        assert data[pos:pos + 4] == b"OggS", "not an Ogg page"
        serial = int.from_bytes(data[pos + 14:pos + 18], "little")
        nseg = data[pos + 26]
        lacing = data[pos + 27:pos + 27 + nseg]
        body = pos + 27 + nseg
        for l in lacing:
            cur += data[body:body + l]
            body += l
            if l < 255:
                packets.append(cur)
                cur = b""
        npage += 1
        if header_pages is None and len(packets) >= 3:
            assert len(packets) == 3 and not cur, "audio shares a page with the headers"
            header_pages, header_end = npage, body
        pos = body
    return serial, packets, data[:header_end], header_pages


def vorbis_centres(packets):
    """Samples decoded after each audio packet (cumulative), from each packet's
    block size. libvorbis writes two modes, 0 = short block and 1 = long, and
    the mode number is the bit after the packet-type bit."""
    ident = packets[0]
    assert ident[:7] == b"\x01vorbis"
    bs = (1 << (ident[28] & 15), 1 << (ident[28] >> 4))
    cum, total, prev = [], 0, None
    for p in packets[3:]:
        assert p[0] & 1 == 0, "not an audio packet"
        cur = bs[(p[0] >> 1) & 1]
        if prev is not None:
            total += prev // 4 + cur // 4
        cum.append(total)
        prev = cur
    return cum


def ogg_write(header_bytes, header_pages, serial, packets, cum):
    """Header pages as they were, then the audio packets re-paged: whole
    packets per page, granule = samples decoded by the page's last packet."""
    out = bytearray(header_bytes)
    seq = header_pages
    i = 0
    while i < len(packets):
        lacing = bytearray()
        body = bytearray()
        while i < len(packets):
            p = packets[i]
            segs = bytes([255] * (len(p) // 255) + [len(p) % 255])
            if lacing and (len(lacing) + len(segs) > 255 or len(body) + len(p) > 4096):
                break
            lacing += segs
            body += p
            i += 1
        last = i == len(packets)
        page = bytearray(b"OggS\x00")
        page.append(4 if last else 0)
        page += int(cum[i - 1]).to_bytes(8, "little") + serial.to_bytes(4, "little") + seq.to_bytes(4, "little")
        page += b"\x00\x00\x00\x00" + bytes([len(lacing)]) + lacing + body
        page[22:26] = _ogg_crc(page).to_bytes(4, "little")
        out += page
        seq += 1
    return bytes(out)


def encode_loop(name, x, q, free_phase):
    """Encode a loop so that it decodes to exactly its own length. Returns
    (path, rotation used or None if no exact cut was found, quality used).
    free_phase: the loop may start anywhere in its cycle (not the music), which
    gives more chances of a block centre landing on the loop length."""
    x = np.asarray(x, dtype=float)
    x2 = x[None, :] if x.ndim == 1 else x
    N = x2.shape[-1]
    tmp_wav = WAVDIR / f"_{name}_ext.wav"
    tmp_ogg = WAVDIR / f"_{name}_ext.ogg"
    rots = [0] + ([(N * k) // 37 for k in range(1, 37)] if free_phase else [])
    quals = [q] if free_phase else [q, q + 0.2, q - 0.2, q + 0.4, q - 0.4, q + 0.6, q - 0.6, q + 1, q - 1]
    try:
        for rot in rots:
            xr = np.roll(x2, -rot, axis=1)
            write_wav24(tmp_wav, np.concatenate([xr, xr[:, :min(N, 16384)]], axis=1))
            for qq in quals:
                r = run(["ffmpeg", "-y", "-v", "error", "-i", str(tmp_wav), "-map_metadata", "-1",
                         "-fflags", "+bitexact", "-flags:a", "+bitexact",
                         "-c:a", "libvorbis", "-q:a", f"{qq:g}", "-ar", str(SR), str(tmp_ogg)])
                if r.returncode != 0:
                    raise RuntimeError(r.stderr)
                serial, packets, header, hp = ogg_read(tmp_ogg.read_bytes())
                cum = vorbis_centres(packets)
                if N in cum:
                    k = cum.index(N) + 1
                    write_wav24(WAVDIR / f"{name}.wav", xr if x.ndim == 2 else xr[0])
                    AUDIO.mkdir(parents=True, exist_ok=True)
                    out = AUDIO / f"{name}.ogg"
                    out.write_bytes(ogg_write(header, hp, serial, packets[3:3 + k], cum[:k]))
                    return out, rot, qq
    finally:
        tmp_wav.unlink(missing_ok=True)
        tmp_ogg.unlink(missing_ok=True)
    # No centre on N. A plain encode can still end exactly on N by itself
    # (the encoder often closes a stream with short blocks); take one that does.
    for rot in rots:
        xr = np.roll(x2, -rot, axis=1)
        for qq in quals:
            out = encode(name, xr if x.ndim == 2 else xr[0], qq)
            if vorbis_centres(ogg_read(out.read_bytes())[1])[-1] == N:
                return out, rot, qq
    print(f"  !! {name}: could not make a stream of exactly {N} samples; Flint will loop over extra ones")
    return encode(name, x, q), None, q


# --------------------------------------------------------------------------
# engine loops
# --------------------------------------------------------------------------
ENGINE_N = 141120          # 3.2 s: 176 cycles of 55 Hz, 352 of 110 Hz, exactly


def gen_engine(high):
    """A train of exhaust pulses, one per firing, summed straight into the
    spectrum (so each can sit at a fractional sample), then shaped by a source
    roll-off and a few pipe resonances. Pulse strength and timing follow a
    four-firing pattern (the half-order lump of uneven banks) plus a slow
    drift; both are periodic over the loop, so the loop is too."""
    N = ENGINE_N
    T = N / SR
    f0 = 110.0 if high else 55.0
    ncyc = int(round(f0 * T))
    rs = rng(5502 if high else 5501)
    k = np.arange(ncyc)
    if high:
        pat = np.array([0.050, -0.035, 0.025, -0.040])
        tpat = np.array([0.006, -0.004, 0.003, -0.005])
        drift, tdrift, fmax = 0.030, 0.004, 9000.0
    else:
        pat = np.array([0.150, -0.100, 0.060, -0.110])
        tpat = np.array([0.014, -0.010, 0.006, -0.010])
        drift, tdrift, fmax = 0.050, 0.008, 6000.0
    amp = 1.0 + pat[k % 4] + drift * periodic_noise(ncyc, rs, 24)
    jit = tpat[k % 4] + tdrift * periodic_noise(ncyc, rs, 40)
    tk = (k + jit) * (N / ncyc)
    M = int(fmax * T)
    m = np.arange(M + 1)
    P = np.zeros(M + 1, dtype=complex)
    for s in range(0, ncyc, 64):
        P += (amp[None, s:s + 64] * np.exp(-2j * np.pi * np.outer(m, tk[s:s + 64]) / N)).sum(axis=1)
    f = m / T
    jf = 1j * f
    def reson(F, Q, g):
        return g / (1.0 - (f / F) ** 2 + jf / (F * Q))
    if high:
        src = (jf / 60.0) / (1.0 + jf / 60.0) / (1.0 + jf / 230.0) / (1.0 + jf / 2600.0)
        body = (0.55 + reson(118.0, 2.2, 0.85) + reson(480.0, 3.0, 0.95) + reson(1010.0, 4.0, 1.15)
                + reson(2150.0, 5.0, 0.85) + reson(3500.0, 6.0, 0.40))
    else:
        src = (jf / 30.0) / (1.0 + jf / 30.0) / (1.0 + jf / 105.0) / (1.0 + jf / 1500.0)
        body = (0.50 + reson(60.0, 2.0, 0.90) + reson(205.0, 2.6, 0.75) + reson(430.0, 3.5, 1.05)
                + reson(900.0, 4.5, 0.80) + reson(1700.0, 5.0, 0.30))
    X = np.zeros(N // 2 + 1, dtype=complex)
    X[:M + 1] = P * src * body
    X[0] = 0.0
    tone = np.fft.irfft(X, N)
    tone /= rms(tone)
    # combustion hiss, gated by the same pulses so it breathes with the cycle
    E = np.zeros(N // 2 + 1, dtype=complex)
    E[:M + 1] = P / (1.0 + jf / (0.6 * f0))
    env = np.fft.irfft(E, N)
    env = np.clip(env / peak(env), 0.0, None) ** 1.5
    lo, hi = (500.0, 4500.0) if high else (250.0, 2400.0)
    nz = fftfilt(rs.standard_normal(N), lambda fr: H_hp(fr, lo, 2) * H_lp(fr, hi, 2))
    nz = nz * (0.35 + env)
    nz /= rms(nz)
    y = tone + (0.085 if high else 0.11) * nz
    y = np.tanh(0.55 * y) / 0.55                      # a little compression of the pulse tops
    y = fftfilt(y, lambda fr: H_hp(fr, 22.0, 2) * H_lp(fr, 7000.0 if high else 3600.0, 2))
    y *= undb(-17.0) / rms(y)
    if peak(y) > undb(-3.0):
        y *= undb(-3.0) / peak(y)
    return y


# --------------------------------------------------------------------------
# ambience loops
# --------------------------------------------------------------------------
def gen_wind():
    N = 264576                 # 6 s less 24 samples: Vorbis blocks land on multiples of 64
    rs = rng(101)
    t = np.arange(N)
    common = rs.standard_normal(N)
    bands = [(110.0, 420.0, 1.0), (380.0, 1300.0, 0.8), (1100.0, 3600.0, 0.55), (3000.0, 8000.0, 0.22)]
    out = np.zeros((2, N))
    for c in range(2):
        nz = 0.5 * common + rs.standard_normal(N)
        for lo, hi, g in bands:
            b = fftfilt(nz, lambda f: H_hp(f, lo, 2) * H_lp(f, hi, 2) / np.sqrt(f + 30.0))
            b /= rms(b)
            lfo = 1.0 + 0.42 * periodic_noise(N, rs, 7)     # under 1.2 Hz, periodic
            out[c] += g * b * lfo
    out = fftfilt(out, lambda f: H_hp(f, 70.0, 2))
    out *= undb(-20.0) / rms(out)
    return out


def gen_skid():
    N = 88192                  # 2 s less 8 samples, a multiple of 64
    rs = rng(202)
    t = np.arange(N) / N
    nz = fftfilt(rs.standard_normal(N),
                 lambda f: (H_peak(f, 1250.0, 7.0) + 0.5 * H_peak(f, 2450.0, 6.0)
                            + 0.10 * H_hp(f, 700.0, 2) * H_lp(f, 6000.0, 2)))
    nz /= rms(nz)
    nz *= 1.0 + 0.4 * periodic_noise(N, rs, 50, 4)
    y = 0.55 * nz
    # squeal partials: a whole number of cycles, their pitch wandering by a
    # periodic random walk and their level never settling
    for cycles, beta, g in [(2080, 5.0, 1.00), (2970, 6.5, 0.70), (1830, 4.0, 0.45), (3170, 5.0, 0.30)]:
        wob = periodic_noise(N, rs, 14)
        a = (0.55 + 0.45 * periodic_noise(N, rs, 22)) ** 2
        ph = TAU * cycles * t + beta * wob
        y += g * a * (np.sin(ph) + 0.25 * np.sin(2.0 * ph) + 0.08 * np.sin(3.0 * ph))
    y = np.tanh(0.8 * y / rms(y) * 0.5)
    y = fftfilt(y, lambda f: H_hp(f, 500.0, 2) * H_lp(f, 7500.0, 2))
    y *= undb(-20.0) / rms(y)
    return y


def gen_offroad():
    N = 88192
    rs = rng(303)
    t = np.arange(N) / SR
    # low thumps: stones under the tyres
    imp = np.zeros(N)
    for pos in rs.integers(0, N, 17):
        imp[pos] += rs.uniform(0.4, 1.0)
    kt = np.arange(int(0.16 * SR)) / SR
    thump = np.sin(TAU * (48.0 * kt + 2.2 * (1.0 - np.exp(-kt / 0.02)))) * np.exp(-kt / 0.045)
    imp2 = np.zeros(N)
    for pos in rs.integers(0, N, 11):
        imp2[pos] += rs.uniform(0.4, 1.0)
    thump2 = np.sin(TAU * (82.0 * kt + 1.5 * (1.0 - np.exp(-kt / 0.015)))) * np.exp(-kt / 0.03)
    low = cconv(imp, thump) + 0.7 * cconv(imp2, thump2)
    rumble = fftfilt(rs.standard_normal(N), lambda f: H_hp(f, 35.0, 2) * H_lp(f, 160.0, 2))
    rumble = rumble / rms(rumble) * (1.0 + 0.5 * periodic_noise(N, rs, 22, 2))
    # grit: band noise torn by a fast random envelope
    grit = fftfilt(rs.standard_normal(N), lambda f: H_hp(f, 700.0, 2) * H_lp(f, 5200.0, 2))
    tear = np.abs(periodic_noise(N, rs, 140, 6)) ** 1.6
    grit = grit / rms(grit) * tear / rms(tear)
    # pebbles: tiny bright pings
    pimp = np.zeros(N)
    for pos in rs.integers(0, N, 70):
        pimp[pos] += rs.uniform(0.2, 1.0) * rs.choice([-1.0, 1.0])
    pt = np.arange(int(0.012 * SR)) / SR
    ping = np.sin(TAU * 2900.0 * pt) * np.exp(-pt / 0.002)
    peb = cconv(pimp, ping)
    y = 1.0 * low / rms(low) + 0.55 * rumble + 0.36 * grit + 0.30 * peb / rms(peb)
    y = np.tanh(0.5 * y) / 0.5
    y = fftfilt(y, lambda f: H_hp(f, 30.0, 2) * H_lp(f, 9000.0, 2))
    y *= undb(-19.0) / rms(y)
    if peak(y) > undb(-3.0):
        y *= undb(-3.0) / peak(y)
    return y


# --------------------------------------------------------------------------
# drum kit
# --------------------------------------------------------------------------
def make_kick(soft=False):
    n = int(0.42 * SR)
    t = np.arange(n) / SR
    f = 46.0 + 120.0 * np.exp(-t / 0.045) + (0.0 if soft else 300.0) * np.exp(-t / 0.006)
    body = np.sin(TAU * np.cumsum(f) / SR) * np.exp(-t / 0.17)
    y = body
    if not soft:
        click = fftfilt(rng(11).standard_normal(n) * np.exp(-t / 0.003),
                        lambda fr: H_hp(fr, 1500.0, 2) * H_lp(fr, 7000.0, 2), False)
        y = y + 0.9 * click
    y = np.tanh(1.8 * y)
    return norm_peak(fade(y, 0.0003, 0.03))


def make_snare():
    """Tone + noise, then the 80s move: a big bright room, cut dead by a gate."""
    rs = rng(12)
    n = int(0.34 * SR)
    t = np.arange(n) / SR
    tone = (np.sin(TAU * np.cumsum(185.0 + 70.0 * np.exp(-t / 0.02)) / SR)
            + 0.5 * np.sin(TAU * 331.0 * t)) * np.exp(-t / 0.07)
    nz = fftfilt(rs.standard_normal(n),
                 lambda f: H_hp(f, 900.0, 2) * H_lp(f, 9500.0, 2) * (1.0 + 1.5 * H_peak(f, 2300.0, 1.5)), False)
    nz = norm_peak(nz) * np.exp(-t / 0.10)
    dry = fade(0.7 * tone + 0.6 * nz, 0.0003, 0.02)
    m = int(0.6 * SR)
    ir = rs.standard_normal((2, m)) * np.exp(-np.arange(m) / SR / 0.30)
    ir = fftfilt(ir, lambda f: H_hp(f, 350.0, 2) * H_lp(f, 7500.0, 2), False)
    wet = fconv(np.stack([dry, dry]), ir)[:, :n]
    wet = wet / peak(wet)
    gate = np.ones(n)
    g0, g1 = int(0.25 * SR), int(0.30 * SR)
    gate[g0:g1] = 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, g1 - g0))
    gate[g1:] = 0.0
    out = np.stack([dry, dry]) * 0.75 + 0.62 * wet * gate
    return norm_peak(out)


def make_hat(decay, length, seed):
    n = int(length * SR)
    t = np.arange(n) / SR
    y = fftfilt(rng(seed).standard_normal(n), lambda f: H_hp(f, 7200.0, 3) * H_lp(f, 15000.0, 2), False)
    return norm_peak(fade(y * np.exp(-t / decay), 0.0003, 0.01))


def make_tom(f0, seed):
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = f0 * (1.0 + 0.7 * np.exp(-t / 0.035))
    body = np.sin(TAU * np.cumsum(f) / SR) * np.exp(-t / 0.16)
    nz = fftfilt(rng(seed).standard_normal(n), lambda fr: H_hp(fr, 300.0, 1) * H_lp(fr, 3500.0, 2), False)
    y = np.tanh(1.5 * (body + 0.25 * norm_peak(nz) * np.exp(-t / 0.03)))
    return norm_peak(fade(y, 0.0003, 0.05))


def make_crash(seed, length=2.8):
    n = int(length * SR)
    t = np.arange(n) / SR
    rs = rng(seed)
    y = fftfilt(rs.standard_normal((2, n)),
                lambda f: H_hp(f, 3200.0, 2) * (1.0 + 0.8 * H_peak(f, 5400.0, 3.0) + 0.6 * H_peak(f, 8200.0, 4.0)), False)
    y *= (0.7 * np.exp(-t / 0.65) + 0.3 * np.exp(-t / 0.12))
    return norm_peak(fade(y, 0.0005, 0.3))


# --------------------------------------------------------------------------
# pitched voices
# --------------------------------------------------------------------------
BASS_LV = [(130.0, 120.0), (170.0, 320.0), (220.0, 650.0), (280.0, 1050.0), (330.0, 1500.0), (380.0, 2000.0)]
_bass_cache = {}


def bass_note(m, gate, lvl):
    """Saw through a resonant low-pass with a plucked envelope, over a sine sub."""
    key = (m, gate, lvl)
    if key not in _bass_cache:
        base, amt = BASS_LV[lvl]
        rel = int(0.02 * SR)
        n = gate + rel
        t = np.arange(n) / SR
        f = float(mtof(m))
        cutoff = base + amt * np.exp(-t / 0.075)
        ph = TAU * f * t
        y = additive(ph, f, cutoff, 2.4, fmax=9000.0) + 0.55 * np.sin(ph)
        env = np.minimum(t / 0.003, 1.0) * (0.72 + 0.28 * np.exp(-t / 0.12))
        env[gate:] *= np.linspace(1.0, 0.0, rel)
        _bass_cache[key] = np.tanh(1.2 * y * env)
    return _bass_cache[key]

_pluck_cache = {}


def pluck(m, lvl, length=0.34):
    """The arpeggio voice: a saw/square whose filter snaps shut."""
    key = (m, lvl, length)
    if key not in _pluck_cache:
        n = int(length * SR)
        t = np.arange(n) / SR
        f = float(mtof(m))
        amt = [900.0, 1900.0, 3400.0, 5200.0][lvl]
        cutoff = 420.0 + 0.5 * f + amt * np.exp(-t / 0.055)
        ph = TAU * f * t
        y = additive(ph, f, cutoff, 1.5, fmax=14000.0) + 0.4 * additive(ph * 2.0, 2.0 * f, cutoff, 1.2, "square", fmax=14000.0)
        env = np.minimum(t / 0.002, 1.0) * (0.25 * np.exp(-t / 0.20) + 0.75 * np.exp(-t / 0.07))
        _pluck_cache[key] = fade(y * env, 0.0002, 0.03)
    return _pluck_cache[key]


def pad_chord(notes, dur_n, attack, release, seed):
    """Lush pad: five detuned saws per note, fanned across the stereo field."""
    n = dur_n + int(release * SR)
    rs = rng(seed)
    out = np.zeros((2, n))
    det = [-12.0, -6.0, 0.0, 5.0, 11.0]
    pans = [-0.85, 0.5, 0.0, -0.45, 0.85]
    for i, m in enumerate(notes):
        w = 0.8 if i == 0 else 1.0
        for d, p in zip(det, pans):
            f = float(mtof(m)) * 2.0 ** ((d + rs.uniform(-1.5, 1.5)) / 1200.0)
            s = saw_blep(f, n, rs.uniform())
            gl, gr = pan_gains(p * (1.0 if i % 2 == 0 else -1.0))
            out[0] += w * gl * s
            out[1] += w * gr * s
    a = int(attack * SR)
    r = n - dur_n
    env = np.ones(n)
    env[:a] = np.sin(np.linspace(0.0, np.pi / 2.0, a)) ** 2
    env[dur_n:] = np.cos(np.linspace(0.0, np.pi / 2.0, r)) ** 2
    out = fftfilt(out, lambda f: H_hp(f, 130.0, 1) * H_lp(f, 6500.0, 2), False)
    return out * env / np.sqrt(len(notes) * len(det))


def lead_phrase(notes, beat_len, bright=1.0, vib_depth=0.22, glide=0.028):
    """The singing lead: one continuous oscillator that glides between joined
    notes (portamento) and blooms into vibrato on the long ones.
    notes = [(beat, beats, midi)], in order. Returns stereo, two detuned takes."""
    end = max(b + d for b, d, _ in notes)
    rel = int(0.14 * SR)
    n = int(round(end * beat_len)) + rel + 8
    lf = np.full(n, notes[0][2] / 12.0)
    amp = np.zeros(n)
    vib = np.zeros(n)
    prev_e = prev_m = None
    for i, (b, d, m) in enumerate(notes):
        s = int(round(b * beat_len))
        e = int(round((b + d) * beat_len))
        nxt = int(round(notes[i + 1][0] * beat_len)) if i + 1 < len(notes) else None
        leg_in = prev_e is not None and abs(prev_e - s) <= 1
        leg_out = nxt is not None and abs(nxt - e) <= 1
        seg = e if leg_out else min(n, e + rel)
        L = seg - s
        tt = np.arange(L) / SR
        tgt = m / 12.0
        if leg_in:
            lfs = tgt + (prev_m / 12.0 - tgt) * np.exp(-tt / glide)
            a = 1.0 - 0.22 * np.exp(-tt / 0.03)
        else:
            lfs = tgt - (0.6 / 12.0) * np.exp(-tt / 0.018)       # a small scoop up into the note
            a = 1.0 - np.exp(-tt / 0.007)
        if not leg_out:
            r = np.arange(L - (e - s))
            a[e - s:] *= np.exp(-r / SR / 0.035) * np.linspace(1.0, 0.0, r.size)
        lf[s:seg] = lfs
        lf[seg:] = tgt
        amp[s:seg] = a
        if d >= 1.0:
            vib[s:seg] = np.clip((tt - 0.2) / 0.3, 0.0, 1.0)
        prev_e, prev_m = e, m
    t = np.arange(n) / SR
    lf = lf + vib * (vib_depth / 12.0) * np.sin(TAU * 5.6 * t)
    f = 440.0 * 2.0 ** (lf - 69.0 / 12.0)
    cutoff = bright * (1300.0 + 3.0 * f)
    out = np.zeros((2, n))
    for c, det in enumerate((1.0020, 0.9980)):
        ph = TAU * np.cumsum(f * det) / SR
        out[c] = additive(ph, f, cutoff, 0.95, fmax=13000.0)
        out[c] += 0.35 * additive(ph, f, cutoff, 0.9, "pulse", pw=0.31, fmax=13000.0)
    mid = 0.5 * (out[0] + out[1])
    out = 0.6 * out + 0.4 * mid
    return out * amp

SCALE_DM = [2, 4, 5, 7, 9, 10, 0]            # D natural minor pitch classes


def diatonic(m, steps):
    pc = m % 12
    if pc not in SCALE_DM:
        return m + (-3 if steps < 0 else 3)
    i = SCALE_DM.index(pc)
    j = i + steps
    oct_shift, j = divmod(j, 7)
    base = m - pc
    new = base + SCALE_DM[j] + 12 * oct_shift
    # SCALE_DM wraps past C (pc 0) into the next octave
    if SCALE_DM[j] < 2:
        new += 12
    if SCALE_DM[i] < 2:
        new -= 12
    return new

CH = {  # pad voicing, arp tones, bass root
    "Dm": dict(pad=[50, 57, 62, 65, 69], arp=[62, 65, 69, 74], bass=38),
    "Bb": dict(pad=[46, 53, 58, 62, 65], arp=[58, 62, 65, 70], bass=34),
    "F": dict(pad=[53, 57, 60, 65, 69], arp=[60, 65, 69, 72], bass=41),
    "C": dict(pad=[48, 55, 60, 64, 67], arp=[60, 64, 67, 72], bass=36),
    "Am": dict(pad=[45, 52, 57, 60, 64], arp=[57, 60, 64, 69], bass=33),
    "Gm": dict(pad=[43, 50, 55, 58, 62], arp=[58, 62, 67, 70], bass=31),
    "A": dict(pad=[45, 52, 57, 61, 64], arp=[57, 61, 64, 69], bass=33),
    "Asus": dict(pad=[45, 52, 57, 62, 64], arp=[57, 62, 64, 69], bass=33),
}


# The hook (bars 17-24), in (bar, beat, beats, midi). Over Bb C Am Dm Bb C F A.
HOOK = [
    (0, 0, 1.5, 74), (0, 1.5, 0.5, 77), (0, 2, 1, 76), (0, 3, 1, 72),
    (1, 0, 1.5, 76), (1, 1.5, 0.5, 79), (1, 2, 2, 76),
    (2, 0, 1.5, 72), (2, 1.5, 0.5, 76), (2, 2, 1, 74), (2, 3, 1, 72),
    (3, 0, 3, 74), (3, 3, 0.5, 69), (3, 3.5, 0.5, 72),
    (4, 0, 1.5, 74), (4, 1.5, 0.5, 77), (4, 2, 1, 76), (4, 3, 1, 72),
    (5, 0, 1.5, 76), (5, 1.5, 0.5, 79), (5, 2, 2, 81),
]
HOOK_END_A = [(6, 0, 1, 81), (6, 1, 0.5, 79), (6, 1.5, 0.5, 77), (6, 2, 1, 72), (6, 3, 1, 77),
              (7, 0, 2.5, 76), (7, 2.5, 0.5, 73), (7, 3, 1, 76)]


HOOK_END_B = [(6, 0, 1, 81), (6, 1, 0.5, 79), (6, 1.5, 0.5, 77), (6, 2, 1, 79), (6, 3, 1, 81),
              (7, 0, 2, 81), (7, 2, 1, 79), (7, 3, 1, 76)]


# The breakdown line (bars 33-40), over Gm Dm Bb C Gm Dm Bb A.
BREAK = [
    (0, 0, 2, 70), (0, 2, 2, 74), (1, 0, 3, 69), (1, 3, 1, 65), (2, 0, 2, 74), (2, 2, 2, 77), (3, 0, 4, 76),
    (4, 0, 2, 79), (4, 2, 2, 74), (5, 0, 3, 77), (5, 3, 1, 74), (6, 0, 2, 74), (6, 2, 2, 70),
    (7, 0, 2, 73), (7, 2, 1, 76), (7, 3, 1, 81),
]


# The second melody (bars 41-48), over Dm Bb F C twice.
MEL2 = [
    (0, 0, 1.5, 74), (0, 1.5, 0.5, 76), (0, 2, 1.5, 77), (0, 3.5, 0.5, 81),
    (1, 0, 1, 79), (1, 1, 1, 77), (1, 2, 2, 74),
    (2, 0, 1.5, 72), (2, 1.5, 0.5, 74), (2, 2, 1.5, 77), (2, 3.5, 0.5, 81),
    (3, 0, 2, 79), (3, 2, 1, 76), (3, 3, 0.5, 72), (3, 3.5, 0.5, 76),
    (4, 0, 1.5, 74), (4, 1.5, 0.5, 76), (4, 2, 1.5, 77), (4, 3.5, 0.5, 81),
    (5, 0, 1, 82), (5, 1, 1, 81), (5, 2, 2, 77),
    (6, 0, 1, 81), (6, 1, 1, 84), (6, 2, 1, 81), (6, 3, 1, 77),
]
MEL2_END_A = [(7, 0, 3, 79)]
MEL2_END_B = [(7, 0, 2, 79), (7, 2, 1, 76), (7, 3, 1, 72), (8, 0, 4, 74)]   # lands on D in the turnaround


def flat(notes):
    return [(bar * 4 + beat, d, m) for bar, beat, d, m in notes]


def curve(N, bar_len, pts):
    """Piecewise-linear automation through (bar, value) points."""
    x = np.arange(N) / bar_len
    return np.interp(x, [p[0] for p in pts], [p[1] for p in pts])


# --------------------------------------------------------------------------
# music_drive
# --------------------------------------------------------------------------
DRIVE_BEAT = 24500         # samples: 108 BPM exactly
DRIVE_BARS = 64
DRIVE_SECTIONS = [("intro", 1, 8), ("A", 9, 16), ("B (hook)", 17, 32), ("breakdown", 33, 40),
                  ("A' (second melody)", 41, 56), ("turnaround", 57, 64)]


def gen_music_drive(stems=None):
    BEAT = DRIVE_BEAT
    STEP = BEAT // 4
    BAR = BEAT * 4
    NB = DRIVE_BARS
    N = NB * BAR
    prog = (["Dm", "Bb", "F", "C"] * 4
            + ["Bb", "C", "Am", "Dm", "Bb", "C", "F", "A"] * 2
            + ["Gm", "Dm", "Bb", "C", "Gm", "Dm", "Bb", "A"]
            + ["Dm", "Bb", "F", "C"] * 4
            + ["Dm", "Bb", "F", "C", "Dm", "Bb", "Gm", "A"])
    assert len(prog) == NB
    def sec(b):
        return ("intro" if b < 8 else "A" if b < 16 else "B" if b < 32 else
                "break" if b < 40 else "A2" if b < 56 else "turn")
    kick, kick_soft = make_kick(), make_kick(soft=True)
    snare = make_snare()
    hat_c = [make_hat(0.022, 0.09, 21 + i) for i in range(3)]
    hat_o = make_hat(0.11, 0.32, 29)
    toms = [make_tom(f0, 31 + i) for i, f0 in enumerate((205.0, 155.0, 118.0, 88.0))]
    tom_pan = [-0.5, -0.15, 0.2, 0.55]
    crash = make_crash(41)
    drums = np.zeros((2, N))
    drum_send = np.zeros((2, N))
    kick_imp = np.zeros(N)
    fill_len = {7: 4, 15: 4, 23: 2, 31: 8, 39: 8, 47: 4, 55: 8, 63: 8}
    for b in range(NB):
        s = sec(b)
        t0 = b * BAR
        fl = fill_len.get(b, 0)
        fill_from = 16 - fl
        # kick
        if s == "intro":
            ks = [] if b < 4 else [0]
        elif s == "break":
            ks = [] if b < 36 else [0, 4, 8, 12]
        elif s == "turn" and b >= 60:
            ks = [0, 8] if b < 63 else [0, 4, 8, 12]
        else:
            ks = [0, 4, 8, 12]
        kv = 0.72 if s in ("intro", "break") else 1.0
        for st in ks:
            put(drums, t0 + st * STEP, kick_soft if s == "break" else kick, 0.95 * kv)
            kick_imp[(t0 + st * STEP) % N] += kv
        # snare
        if s in ("A", "B", "A2") or (s == "turn" and b < 60):
            sn = [4, 12]
        elif s == "turn":
            sn = [12]
        else:
            sn = []
        for st in sn:
            if st < fill_from:
                put(drums, t0 + st * STEP, snare, 0.62)
        if b == 39:                                       # the build: a snare roll that swells
            for st in range(16):
                put(drums, t0 + st * STEP, snare, 0.10 + 0.42 * (st / 15.0) ** 1.5)
                if st >= 12:
                    put(drums, t0 + st * STEP + STEP // 2, snare, 0.30 + 0.05 * (st - 12))
        # hats
        if s in ("B", "A2") or (s == "turn" and b < 60):
            hs = [(st, [1.0, 0.42, 0.72, 0.42][st % 4]) for st in range(16)]
        elif s == "A" or (s == "intro" and b >= 4) or (s == "break" and b >= 36) or s == "turn":
            hs = [(st, 0.6 if st % 4 == 0 else 1.0) for st in range(0, 16, 2)]
        else:
            hs = []
        hv = 0.6 if s in ("intro", "break") else 1.0
        open_step = 14 if (s in ("B", "A2") and b % 2 == 1) else (14 if (s == "A" and b % 4 == 3) else -1)
        for st, v in hs:
            if st >= fill_from:
                continue
            if st == open_step:
                put(drums, t0 + st * STEP, hat_o, 0.15, 0.25)
            else:
                put(drums, t0 + st * STEP, hat_c[(st + b) % 3], 0.125 * v * hv, 0.22)
        # tom fill
        if fl:
            seq = {2: [1, 3], 4: [0, 1, 2, 3], 8: [0, 0, 1, 1, 2, 2, 3, 3]}[fl]
            for i, ti in enumerate(seq):
                st = fill_from + i
                v = 0.42 + 0.14 * i / max(len(seq) - 1, 1)
                if fl == 8 and i in (1, 5):
                    v *= 0.7
                put(drums, t0 + st * STEP, toms[ti], v, tom_pan[ti])
                put(drum_send, t0 + st * STEP, toms[ti], v * 0.5, tom_pan[ti])
        # crash on the big downbeats
        if b in (0, 8, 16, 24, 40, 48, 56):
            put(drums, t0, crash, 0.24 if b else 0.15)
            put(drum_send, t0, crash, 0.10)
    # sidechain: every kick ducks the pads and bass, which pump back up
    kt = np.arange(int(0.6 * SR)) / SR
    duck = np.clip(cconv(kick_imp, np.minimum(kt / 0.004, 1.0) * np.exp(-kt / 0.13)), 0.0, 1.0)
    # bass ------------------------------------------------------------------
    bass = np.zeros(N)
    p8 = [0, 0, 12, 0, 0, 0, 12, 0]
    p16 = [0, 0, 12, 0, 0, 0, 12, 0, 0, 0, 12, 0, 0, 12, 0, 12]
    for b in range(NB):
        s = sec(b)
        root = CH[prog[b]]["bass"]
        t0 = b * BAR
        if s == "intro":
            mode, lvl, vel = 8, [0, 0, 1, 1, 1, 2, 2, 3][b], 0.85
        elif s == "A":
            mode, lvl, vel = 8, 3, 1.0
        elif s == "B":
            mode, lvl, vel = 16, 4, 1.0
        elif s == "break":
            if b < 36:
                mode, lvl, vel = 1, 0, 0.8
            else:
                mode, lvl, vel = 8, [1, 2, 3, 4][b - 36], 0.9
        elif s == "A2":
            mode, lvl, vel = 16, 5, 1.0
        else:
            mode, lvl, vel = (16, 4, 1.0) if b < 60 else (8, [3, 2, 1, 1][b - 60], 0.9)
        if mode == 1:
            put(bass, t0, bass_note(root, BAR - STEP, lvl), vel)
        elif mode == 8:
            for i in range(8):
                put(bass, t0 + i * 2 * STEP, bass_note(root + p8[i], int(STEP * 1.25), lvl),
                    vel * (1.0 if i % 2 == 0 else 0.85))
        else:
            for i in range(16):
                put(bass, t0 + i * STEP, bass_note(root + p16[i], int(STEP * 0.78), lvl),
                    vel * [1.0, 0.72, 0.9, 0.72][i % 4])
    bass = fftfilt(bass, lambda f: H_hp(f, 30.0, 2))
    # pads ------------------------------------------------------------------
    pad = np.zeros((2, N))
    pcache = {}
    for b in range(NB):
        name = prog[b]
        if name not in pcache:
            pcache[name] = pad_chord(CH[name]["pad"], BAR, 0.09, 0.55, 500 + len(pcache))
        put(pad, b * BAR, pcache[name])
    pad = chorus(pad, 37, 3.2, 12.0, 0.55)
    dark = fftfilt(pad, lambda f: H_lp(f, 620.0, 2))
    bright = fftfilt(pad, lambda f: H_lp(f, 5200.0, 2) * (1.0 + 0.5 * H_peak(f, 2400.0, 1.2)))
    tN = np.arange(N)
    morph = curve(N, BAR, [(0, 0.08), (8, 0.45), (16, 0.55), (16.01, 0.68), (32, 0.75), (32.01, 0.22),
                           (40, 0.85), (56, 0.9), (60, 0.55), (64, 0.08)])
    morph = np.clip(morph + 0.10 * np.sin(TAU * 8 * tN / N) + 0.05 * np.sin(TAU * 27 * tN / N + 1.0), 0.0, 1.0)
    pad = dark * (1.0 - morph) + bright * morph
    pad_vol = curve(N, BAR, [(0, 0.45), (6, 0.9), (8, 1.0), (32, 1.0), (32.01, 1.1), (40, 1.1), (40.01, 1.0),
                             (60, 1.0), (64, 0.6)])
    # arpeggio --------------------------------------------------------------
    arp = np.zeros((2, N))
    apat = [(0, 0), (2, 0), (1, 0), (3, 0), (2, 0), (1, 0), (3, 0), (2, 0),
            (0, 0), (2, 0), (1, 0), (3, 0), (2, 0), (3, 0), (1, 12), (3, 0)]
    for b in range(NB):
        s = sec(b)
        tones = CH[prog[b]]["arp"]
        if s == "intro":
            lvl = [0, 0, 1, 1, 1, 2, 2, 2][b]
        elif s == "break":
            lvl = [0, 0, 1, 1, 1, 2, 2, 3][b - 32]
        elif s == "A2":
            lvl = 3
        elif s == "turn":
            lvl = [3, 2, 2, 2, 1, 1, 1, 0][b - 56]
        else:
            lvl = 2
        for i in range(16):
            if s == "break" and b < 36 and i % 2 == 1:
                continue
            idx, o = apat[i]
            v = [1.0, 0.62, 0.8, 0.62][i % 4] * (0.82 if s == "B" else 1.0)
            put(arp, b * BAR + i * STEP, pluck(tones[idx] + o, lvl), v, 0.35 if i % 2 else -0.35)
    # ping-pong echo, dotted eighth
    d = 3 * STEP
    arp = (arp + 0.36 * np.roll(arp[::-1], d, axis=1) + 0.17 * np.roll(arp, 2 * d, axis=1)
           + 0.08 * np.roll(arp[::-1], 3 * d, axis=1))
    # lead ------------------------------------------------------------------
    lead = np.zeros((2, N))
    put(lead, 16 * BAR, lead_phrase(flat(HOOK + HOOK_END_A), BEAT), 1.0)
    h2 = flat(HOOK + HOOK_END_B)
    put(lead, 24 * BAR, lead_phrase(h2, BEAT, bright=1.12), 1.0)
    put(lead, 24 * BAR, lead_phrase([(b_, d_, m_ - 12) for b_, d_, m_ in h2], BEAT, bright=0.8), 0.30)
    put(lead, 32 * BAR, lead_phrase(flat(BREAK), BEAT, bright=0.62, vib_depth=0.16), 0.50)
    put(lead, 40 * BAR, lead_phrase(flat(MEL2 + MEL2_END_A), BEAT, bright=1.05), 1.0)
    m2 = flat(MEL2 + MEL2_END_B)
    put(lead, 48 * BAR, lead_phrase(m2, BEAT, bright=1.15), 1.0)
    harm = [(b_, d_, diatonic(m_, -2)) for b_, d_, m_ in m2[:-1]]
    put(lead, 48 * BAR, lead_phrase(harm, BEAT, bright=0.9), 0.42)
    lead = (lead + 0.30 * np.roll(lead[::-1], d, axis=1) + 0.14 * np.roll(lead, 2 * d, axis=1)
            + 0.06 * np.roll(lead[::-1], 3 * d, axis=1))
    # risers into the section changes ----------------------------------------
    fx = np.zeros((2, N))
    rs = rng(77)
    for start_bar, nbars, g in [(14, 2, 0.8), (38, 2, 1.0), (30, 2, 0.6), (7, 1, 0.5), (54, 2, 0.6)]:
        n = nbars * BAR
        x = np.linspace(0.0, 1.0, n)
        for c in range(2):
            r = swept_noise(n, 300.0 * (9000.0 / 300.0) ** x, rs, 0.5) * x ** 2.2
            put(fx[c], start_bar * BAR, fade(norm_peak(r), 0.01, 0.004), g)
    # a falling breath out of the last bar, into the top
    n = 2 * BAR
    x = np.linspace(0.0, 1.0, n)
    for c in range(2):
        r = swept_noise(n, 6000.0 * (350.0 / 6000.0) ** x, rs, 0.5) * np.sin(np.pi * x) ** 2
        put(fx[c], 62 * BAR, norm_peak(r), 0.55)
    # balance ---------------------------------------------------------------
    bass *= undb(-16.5) / active_rms(bass)
    pad *= undb(-22.0) / rms(pad[:, 8 * BAR:16 * BAR])
    arp *= undb(-23.5) / rms(arp[:, 8 * BAR:16 * BAR])
    lead *= undb(-17.5) / rms(lead[:, 16 * BAR:24 * BAR])
    fx *= 0.11
    bass = bass * (1.0 - 0.42 * duck)
    pad = pad * pad_vol * (1.0 - 0.58 * duck)
    arp = arp * (1.0 - 0.22 * duck)
    send = 0.34 * pad + 0.30 * arp + 0.42 * lead + 0.5 * fx + drum_send
    wet = cconv(send, make_ir(900))
    bass_st = np.stack([bass, bass]) * np.sqrt(0.5)
    parts = dict(drums=drums, bass=bass_st, pad=pad, arp=arp, lead=lead, fx=fx, reverb=0.62 * wet)
    if stems is not None:
        stems.update(parts)
    mix = sum(parts.values())
    mix = fftfilt(mix, lambda f: H_hp(f, 28.0, 2))
    mix *= 0.70 / np.percentile(np.abs(mix), 99.9)
    mix = np.tanh(1.15 * mix) / 1.15                          # tape-ish soft saturation
    return master(mix, -14.0, -1.6, "music_drive")


# --------------------------------------------------------------------------
# music_title
# --------------------------------------------------------------------------
TITLE_BEAT = 49000         # samples: 54 BPM exactly, half the drive tempo
TITLE_BARS = 12


def gen_music_title():
    BEAT = TITLE_BEAT
    BAR = BEAT * 4
    NB = TITLE_BARS
    N = NB * BAR
    EIGHTH = BEAT // 2
    prog = ["Dm", "Bb", "F", "C", "Gm", "Dm", "Bb", "C", "Dm", "Bb", "Gm", "Asus"]
    tN = np.arange(N)
    # pad swells: each chord rises for most of its bar and hangs over the next
    pad = np.zeros((2, N))
    for b, name in enumerate(prog):
        if name == "Asus":
            put(pad, b * BAR, pad_chord(CH["Asus"]["pad"], BAR // 2, 1.4, 1.6, 640))
            put(pad, b * BAR + BAR // 2, pad_chord(CH["A"]["pad"], BAR // 2, 1.0, 2.6, 641))
        else:
            put(pad, b * BAR, pad_chord(CH[name]["pad"], BAR, 2.4, 2.8, 600 + b))
    pad = chorus(pad, 9, 3.5, 13.0, 0.6)
    dark = fftfilt(pad, lambda f: H_lp(f, 480.0, 2))
    bright = fftfilt(pad, lambda f: H_lp(f, 3800.0, 2))
    morph = np.clip(0.33 + 0.20 * np.sin(TAU * 3 * tN / N - 1.2) + 0.10 * np.sin(TAU * 12 * tN / N), 0.0, 1.0)
    pad = dark * (1.0 - morph) + bright * morph
    # a low drone under each chord
    drone = np.zeros(N)
    for b, name in enumerate(prog):
        root = CH[name]["bass"]
        n = BAR + int(1.5 * SR)
        t = np.arange(n) / SR
        f = float(mtof(root))
        y = additive(TAU * f * t, f, 190.0 + 60.0 * np.sin(np.pi * t / t[-1]), 1.2) + 0.5 * np.sin(TAU * f * t)
        env = np.sin(np.pi * np.arange(n) / n) ** 1.2
        put(drone, b * BAR, y * env)
    # sparse arpeggio: a few plucks a bar, an octave up, long echoes
    arp = np.zeros((2, N))
    pats = [[(0, 0), (3, 1), (5, 2), (6, 3)], [(1, 1), (3, 2), (6, 0), (7, 3)],
            [(0, 2), (2, 3), (5, 1), (7, 2)], [(1, 0), (4, 3), (5, 2)]]
    for b, name in enumerate(prog):
        tones = CH[name]["arp"]
        for j, (st, idx) in enumerate(pats[b % 4]):
            lvl = 1 if b < 8 else 2
            put(arp, b * BAR + st * EIGHTH, pluck(tones[idx] + 12, lvl, 0.5), 0.75 + 0.25 * (j == 0),
                -0.45 if (st + b) % 2 else 0.45)
    dly = 3 * EIGHTH // 2
    arp = (arp + 0.45 * np.roll(arp[::-1], dly, axis=1) + 0.24 * np.roll(arp, 2 * dly, axis=1)
           + 0.12 * np.roll(arp[::-1], 3 * dly, axis=1) + 0.06 * np.roll(arp, 4 * dly, axis=1))
    # a soft heartbeat: lub-dub on beats 1 and 3
    heart = np.zeros(N)
    k = fade(fftfilt(make_kick(soft=True), lambda f: H_lp(f, 140.0, 2), False), 0.006, 0.05)
    for b in range(NB):
        for beat in (0, 2):
            p = b * BAR + beat * BEAT
            put(heart, p, k, 1.0)
            put(heart, p + int(0.30 * SR), k, 0.55)
    # the drive track's hook, heard from far off, at half speed (bars 9-10)
    lead = np.zeros((2, N))
    far = [(0, 1.5, 74), (1.5, 0.5, 77), (2, 1, 76), (3, 1, 72), (4, 3, 74)]
    put(lead, 8 * BAR, lead_phrase(far, BEAT, bright=0.5, vib_depth=0.14, glide=0.05), 1.0)
    lead = lead + 0.4 * np.roll(lead[::-1], dly, axis=1) + 0.2 * np.roll(lead, 2 * dly, axis=1)
    # a breath of noise rising through the last bar into the loop point
    fx = np.zeros((2, N))
    rs = rng(88)
    n = 2 * BAR
    x = np.linspace(0.0, 1.0, n)
    for c in range(2):
        r = swept_noise(n, 400.0 * (5000.0 / 400.0) ** x, rs, 0.6) * np.sin(np.pi * x ** 1.6) ** 2
        put(fx[c], 10 * BAR + BAR // 2, norm_peak(r), 1.0)
    pad *= undb(-21.0) / rms(pad)
    arp *= undb(-28.0) / rms(arp)
    drone *= undb(-25.0) / rms(drone)
    heart *= 0.20 / peak(heart)
    lead *= undb(-24.0) / rms(lead[:, 8 * BAR:10 * BAR])
    fx *= 0.035
    send = 0.55 * pad + 0.6 * arp + 0.8 * lead + 0.6 * fx
    wet = cconv(send, make_ir(901, 3.4, 3.2, 2.8, 1.3, 0.03))
    mono = (drone + heart) * np.sqrt(0.5)
    mix = pad + arp + lead + fx + 0.8 * wet + np.stack([mono, mono])
    mix = fftfilt(mix, lambda f: H_hp(f, 28.0, 2))
    mix *= 0.5 / np.percentile(np.abs(mix), 99.9)
    mix = np.tanh(1.1 * mix) / 1.1
    return master(mix, -18.0, -1.6, "music_title")


# --------------------------------------------------------------------------
# one-shots (mono, peak -3 dBFS)
# --------------------------------------------------------------------------
def oneshot(y, fin=0.001, fout=0.012, peak_db=-3.0):
    return norm_peak(fade(y, fin, fout), undb(peak_db))


def beep(freq, dur, decay=None):
    n = int(dur * SR)
    t = np.arange(n) / SR
    ph = TAU * freq * t
    y = additive(ph, freq, 5200.0, 0.8, "square") + 0.25 * additive(ph, freq, 5200.0, 0.8, "saw")
    env = np.minimum(t / 0.002, 1.0)
    if decay:
        env = env * (0.45 + 0.55 * np.exp(-t / decay))
    return y * env


def gen_count_beep():
    return oneshot(beep(float(mtof(74)), 0.15), 0.001, 0.02)          # D5


def gen_count_go():
    y = beep(float(mtof(86)), 0.5, 0.16) + 0.35 * beep(float(mtof(93)), 0.5, 0.10)   # D6, with the fifth above
    return oneshot(y, 0.001, 0.12)


def bell(freq, dur, tau=0.28):
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for ratio, a in [(1.0, 1.0), (2.0, 0.45), (3.0, 0.22), (4.2, 0.18), (5.4, 0.08)]:
        if freq * ratio < 16000.0:
            y += a * np.sin(TAU * freq * ratio * t) * np.exp(-t / (tau / (1.0 + 0.7 * (ratio - 1.0))))
    return y * np.minimum(t / 0.0015, 1.0)


def gen_checkpoint():
    n = int(0.9 * SR)
    y = np.zeros(n)
    for i, m in enumerate([77, 81, 84, 89]):                # F A C F: bright, and inside D minor
        s = int(i * 0.068 * SR)
        b = bell(float(mtof(m)), 0.9 - i * 0.068, 0.20 + 0.05 * i)
        y[s:s + b.size] += b * (0.8 + 0.07 * i)
    return oneshot(y, 0.001, 0.15)


def brass(m, dur, seed=0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = float(mtof(m))
    cutoff = 500.0 + 1.2 * f + 3600.0 * (1.0 - np.exp(-t / 0.02)) * (0.45 + 0.55 * np.exp(-t / 0.25))
    y = np.zeros(n)
    for det in (0.996, 1.0, 1.005):
        y += additive(TAU * f * det * t + seed * det, f, cutoff, 1.1, fmax=14000.0)
    env = np.minimum(t / 0.012, 1.0) * (0.8 + 0.2 * np.exp(-t / 0.2))
    return fade(y * env, 0.0005, min(0.06, dur * 0.3))


def stab(y, start, notes, dur, gain=1.0):
    s = int(start * SR)
    for i, m in enumerate(notes):
        b = brass(m, dur, i * 1.7)
        e = min(y.size, s + b.size)
        y[s:e] += gain * b[:e - s] / np.sqrt(len(notes))


def gen_stage():
    n = int(1.5 * SR)
    y = np.zeros(n)
    stab(y, 0.0, [48, 60, 64, 67, 72], 0.15, 0.8)                     # C
    stab(y, 0.19, [41, 53, 60, 65, 69, 72, 77], 1.25, 1.0)            # F, held
    t = np.arange(n) / SR
    y *= np.where(t > 0.5, np.exp(-(t - 0.5) / 0.55), 1.0)
    for i, m in enumerate([84, 89]):
        s = int((0.19 + 0.09 * i) * SR)
        b = bell(float(mtof(m)), 1.0, 0.3)
        y[s:s + b.size] += 0.5 * b[:n - s]
    k = make_kick()
    y[int(0.19 * SR):int(0.19 * SR) + k.size] += 1.2 * k
    return oneshot(np.tanh(0.9 * y / peak(y)), 0.001, 0.25)


def gen_finish():
    n = int(3.0 * SR)
    y = np.zeros(n)
    Bb, C, D = [46, 58, 62, 65, 70], [48, 60, 64, 67, 72], [38, 50, 62, 66, 69, 74, 78]
    stab(y, 0.00, Bb, 0.20, 0.85)
    stab(y, 0.24, Bb, 0.10, 0.70)
    stab(y, 0.38, C, 0.20, 0.90)
    stab(y, 0.62, C, 0.10, 0.75)
    stab(y, 0.78, D, 2.2, 1.10)                                       # the Picardy third: D major
    t = np.arange(n) / SR
    y *= np.where(t > 1.3, np.exp(-(t - 1.3) / 0.75), 1.0)
    for i, m in enumerate([74, 78, 81, 86, 90, 93]):                  # a rising D major sparkle on top
        s = int((0.78 + 0.085 * i) * SR)
        b = bell(float(mtof(m)), 1.8, 0.45)
        y[s:s + b.size] += 0.42 * b[:n - s]
    k = make_kick()
    for at, g in [(0.0, 0.9), (0.38, 0.9), (0.78, 1.3)]:
        y[int(at * SR):int(at * SR) + k.size] += g * k
    cr = make_crash(43, 2.2)[0]
    s = int(0.78 * SR)
    y[s:s + cr.size] += 0.5 * cr[:n - s]
    return oneshot(np.tanh(0.9 * y / peak(y)), 0.001, 0.5)


def gen_game_over():
    """Four falling steps, and then the last one loses its nerve and slides away."""
    n = int(2.5 * SR)
    t = np.arange(n) / SR
    steps = [(0.0, 74), (0.34, 72), (0.68, 70), (1.02, 69)]
    lf = np.full(n, 74.0)
    amp = np.zeros(n)
    for i, (at, m) in enumerate(steps):
        s = int(at * SR)
        e = int(steps[i + 1][0] * SR) if i + 1 < len(steps) else n
        tt = np.arange(e - s) / SR
        lf[s:e] = m - 0.5 * np.exp(-tt / 0.02)
        amp[s:e] = (1.0 - np.exp(-tt / 0.006)) * (0.75 + 0.25 * np.exp(-tt / 0.15))
    s = int(1.35 * SR)
    x = np.linspace(0.0, 1.0, n - s)
    lf[s:] = 69.0 - 19.0 * x ** 1.7 + 0.5 * x * np.sin(TAU * 6.5 * x * (n - s) / SR)   # down to D3, wobbling
    amp[s:] *= (1.0 - x) ** 1.3
    f = mtof(lf)
    ph = TAU * np.cumsum(f) / SR
    cutoff = (900.0 + 2.5 * f) * np.where(t > 1.35, np.exp(-(t - 1.35) / 0.9), 1.0)
    y = additive(ph, f, cutoff, 1.2, fmax=12000.0) + 0.5 * additive(ph * 0.5, f * 0.5, cutoff, 1.0, "square", fmax=12000.0)
    return oneshot(y * amp, 0.001, 0.2)


def gen_crash():
    n = int(0.8 * SR)
    t = np.arange(n) / SR
    rs = rng(404)
    thud = np.sin(TAU * np.cumsum(38.0 + 90.0 * np.exp(-t / 0.035)) / SR) * np.exp(-t / 0.14)
    metal = np.zeros(n)
    for f0 in [317.0, 523.0, 791.0, 1163.0, 1489.0, 2212.0, 2947.0, 3811.0]:
        metal += (rs.uniform(0.5, 1.0) * np.sin(TAU * f0 * t + rs.uniform(0, TAU))
                  * np.exp(-t / rs.uniform(0.035, 0.13)))
    crunch = fftfilt(rs.standard_normal(n), lambda f: H_hp(f, 500.0, 2) * H_lp(f, 6500.0, 2), False)
    grain = np.abs(fftfilt(rs.standard_normal(n), lambda f: H_lp(f, 90.0, 2), False))
    crunch = crunch * (grain / peak(grain)) ** 0.8 * np.exp(-t / 0.16)
    burst = fftfilt(rs.standard_normal(n), lambda f: H_hp(f, 1800.0, 2), False) * np.exp(-t / 0.035)
    y = 1.5 * thud + 0.30 * metal * (1.0 + norm_peak(crunch)) + 1.1 * norm_peak(crunch) + 0.6 * norm_peak(burst)
    y = np.tanh(1.6 * y / peak(y) * 1.5)
    return oneshot(y, 0.0003, 0.12)


def gen_bump():
    n = int(0.25 * SR)
    t = np.arange(n) / SR
    rs = rng(405)
    thud = np.sin(TAU * np.cumsum(62.0 + 110.0 * np.exp(-t / 0.02)) / SR) * np.exp(-t / 0.05)
    knock = fftfilt(rs.standard_normal(n), lambda f: H_hp(f, 250.0, 2) * H_lp(f, 2600.0, 2), False) * np.exp(-t / 0.012)
    ring = 0.2 * np.sin(TAU * 640.0 * t) * np.exp(-t / 0.03)
    return oneshot(np.tanh(1.4 * (thud + 0.7 * norm_peak(knock) + ring)), 0.0003, 0.05)


def gen_whoosh():
    n = int(0.5 * SR)
    x = np.linspace(0.0, 1.0, n)
    rs = rng(406)
    fc = 350.0 * 2.0 ** (3.3 * np.exp(-((x - 0.45) / 0.22) ** 2))      # up to ~3.4 kHz at the pass, then away
    y = swept_noise(n, fc, rs, 0.55)
    env = np.exp(-((x - 0.45) / 0.20) ** 2)
    return oneshot(y * env, 0.02, 0.08)


def gen_shift():
    n = int(0.12 * SR)
    t = np.arange(n) / SR
    rs = rng(407)
    thunk = np.sin(TAU * np.cumsum(95.0 + 80.0 * np.exp(-t / 0.012)) / SR) * np.exp(-t / 0.028)
    click = fftfilt(rs.standard_normal(n), lambda f: H_hp(f, 900.0, 2) * H_lp(f, 2800.0, 2), False) * np.exp(-t / 0.006)
    blip = 0.25 * np.sin(TAU * 420.0 * t) * np.exp(-t / 0.02)
    return oneshot(thunk + 0.45 * norm_peak(click) + blip, 0.0005, 0.03)


def gen_tick():
    n = int(0.1 * SR)
    t = np.arange(n) / SR
    f = float(mtof(93))                                               # A6: cuts through, fifth of the key
    y = additive(TAU * f * t, f, 7000.0, 0.8, "square") * np.exp(-t / 0.018)
    y += 0.5 * np.sin(TAU * 2.0 * f * t) * np.exp(-t / 0.006)
    return oneshot(y, 0.0004, 0.03)


def gen_ui_select():
    n = int(0.15 * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for at, m, g in [(0.0, 81, 0.8), (0.055, 86, 1.0)]:               # A5 up a fourth to D6
        s = int(at * SR)
        tt = t[:n - s]
        f = float(mtof(m))
        y[s:] += g * (np.sin(TAU * f * tt) + 0.22 * np.sin(TAU * 3 * f * tt) * np.exp(-tt / 0.02)) \
            * np.minimum(tt / 0.002, 1.0) * np.exp(-tt / 0.045)
    return oneshot(y, 0.0005, 0.03)


def gen_near_miss():
    n = int(0.4 * SR)
    t = np.arange(n) / SR
    x = t / t[-1]
    rs = rng(408)
    f = 1100.0 * (3700.0 / 1100.0) ** (x ** 0.7)
    ph = TAU * np.cumsum(f) / SR
    y = (np.sin(ph) + 0.35 * np.sin(2.0 * ph) + 0.15 * np.sin(3.0 * ph)) * np.sin(np.pi * x) ** 0.6 * np.exp(-x * 1.2)
    for i in range(14):                                               # sparkles climbing after it
        at = 0.02 + 0.30 * (i / 13.0) ** 0.9 + rs.uniform(-0.006, 0.006)
        fs = 3000.0 + 5500.0 * (i / 13.0) + rs.uniform(-300.0, 300.0)
        s = int(at * SR)
        tt = t[:n - s]
        y[s:] += rs.uniform(0.25, 0.5) * np.sin(TAU * fs * tt) * np.exp(-tt / 0.022) * np.minimum(tt / 0.001, 1.0)
    return oneshot(y, 0.001, 0.06)


# --------------------------------------------------------------------------
# registry
# --------------------------------------------------------------------------
# name: (generator, kind, vorbis quality)
SOUNDS = {
    "engine_low": (lambda: gen_engine(False), "loop", 7),
    "engine_high": (lambda: gen_engine(True), "loop", 7),
    "wind": (gen_wind, "loop", 6),
    "skid": (gen_skid, "loop", 6),
    "offroad": (gen_offroad, "loop", 6),
    "music_drive": (gen_music_drive, "loop", 6),
    "music_title": (gen_music_title, "loop", 6),
    "count_beep": (gen_count_beep, "shot", 6),
    "count_go": (gen_count_go, "shot", 6),
    "checkpoint": (gen_checkpoint, "shot", 6),
    "stage": (gen_stage, "shot", 6),
    "finish": (gen_finish, "shot", 6),
    "game_over": (gen_game_over, "shot", 6),
    "crash": (gen_crash, "shot", 6),
    "bump": (gen_bump, "shot", 6),
    "whoosh": (gen_whoosh, "shot", 6),
    "shift": (gen_shift, "shot", 6),
    "tick": (gen_tick, "shot", 6),
    "ui_select": (gen_ui_select, "shot", 6),
    "near_miss": (gen_near_miss, "shot", 6),
}
SPECTROGRAMS = {"music_drive": "s=1800x720:legend=1:scale=log", "music_title": "s=1800x600:legend=1:scale=log",
                "engine_low": "s=1200x600:legend=1:scale=log:stop=2500",
                "engine_high": "s=1200x600:legend=1:scale=log:stop=5000"}


# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------
def decode(path):
    info = json.loads(run(["ffprobe", "-v", "error", "-show_entries",
                           "stream=channels,sample_rate,codec_name:format=duration",
                           "-of", "json", str(path)]).stdout)
    ch = int(info["streams"][0]["channels"])
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                       capture_output=True)
    x = np.frombuffer(r.stdout, dtype="<f4").reshape(-1, ch).T.astype(float)
    return x, info


def wrap_report(x):
    """How the last sample meets the first, against how neighbours meet
    everywhere else in the file. Worst channel."""
    worst = None
    for c in x:
        d1 = np.abs(np.diff(c))
        d2 = np.abs(np.diff(c, 2))
        jump = abs(c[0] - c[-1])
        kink = max(abs(c[0] - 2 * c[-1] + c[-2]), abs(c[1] - 2 * c[0] + c[-1]))
        # click energy: > 6 kHz content of 512 samples straddling the wrap, vs everywhere else
        hop = 512
        seam = np.concatenate([c[-hop // 2:], c[:hop // 2]])
        w = np.hanning(hop)
        fb = int(6000 * hop / SR)
        frames = c[:(c.size // hop) * hop].reshape(-1, hop)
        body = np.sqrt((np.abs(np.fft.rfft(frames * w, axis=1))[:, fb:] ** 2).sum(axis=1))
        se = np.sqrt((np.abs(np.fft.rfft(seam * w))[fb:] ** 2).sum())
        rep = dict(jump=float(jump), step_rms=float(np.sqrt(np.mean(d1 ** 2))), step_p999=float(np.percentile(d1, 99.9)),
                   step_max=float(d1.max()), kink=float(kink), kink_rms=float(np.sqrt(np.mean(d2 ** 2))),
                   kink_p999=float(np.percentile(d2, 99.9)),
                   seam_hf_pct=float((body < se).mean() * 100.0),
                   seam_hf_over_median=float(se / max(np.median(body), 1e-12)))
        rep["ok"] = bool(rep["jump"] <= rep["step_p999"] and rep["kink"] <= rep["kink_p999"])
        if worst is None or rep["jump"] / max(rep["step_rms"], 1e-12) > worst["jump"] / max(worst["step_rms"], 1e-12):
            worst = rep
    return worst


def fft_peaks(x, count=6, fmax=3000.0):
    c = x[0] * np.hanning(x.shape[1])
    X = np.abs(np.fft.rfft(c))
    f = np.fft.rfftfreq(c.size, 1.0 / SR)
    X[f > fmax] = 0.0
    out = []
    Y = X.copy()
    for _ in range(count):
        i = int(np.argmax(Y))
        a, b, cc = np.log(X[i - 1] + 1e-20), np.log(X[i] + 1e-20), np.log(X[i + 1] + 1e-20)
        off = 0.5 * (a - cc) / (a - 2 * b + cc)
        out.append((float((i + off) * SR / c.size), float(20 * np.log10(X[i] / X.max()))))
        Y[max(i - 40, 0):i + 40] = 0.0
    return out


def verify(names):
    SNAP.mkdir(parents=True, exist_ok=True)
    report = {}
    for name in names:
        kind = SOUNDS[name][1]
        ogg = AUDIO / f"{name}.ogg"
        x, info = decode(ogg)
        src = read_wav24(WAVDIR / f"{name}.wav")
        lufs, tp = loudness(ogg)
        r = dict(kind=kind, channels=x.shape[0], sample_rate=int(info["streams"][0]["sample_rate"]),
                 codec=info["streams"][0]["codec_name"], duration=x.shape[1] / SR,
                 container_duration=float(info["format"]["duration"]), samples=x.shape[1],
                 source_samples=src.shape[1], bytes=ogg.stat().st_size,
                 peak_db=db(peak(x)), rms_db=db(rms(x)), true_peak_db=tp,
                 lufs=lufs if x.shape[1] >= SR * 0.5 and lufs > -69 else None)
        if kind == "loop":
            r["wrap_pcm"] = wrap_report(src)
            r["wrap_ogg"] = wrap_report(x)
            if x.shape[1] == src.shape[1]:
                r["codec_snr_db"] = db(rms(src) / max(rms(x - src), 1e-12))
        if name.startswith("engine"):
            r["fft_peaks"] = fft_peaks(x)
            r["fft_peaks_pcm"] = fft_peaks(src)
        if name in SPECTROGRAMS:
            png = SNAP / f"{name}_spectrogram.png"
            run(["ffmpeg", "-y", "-v", "error", "-i", str(ogg), "-lavfi",
                 f"showspectrumpic={SPECTROGRAMS[name]}", str(png)])
            r["spectrogram"] = str(png)
        report[name] = r
    (SNAP / "report.json").write_text(json.dumps(report, indent=1))
    print(f"\n{'file':<16}{'dur s':>9}{'ch':>3}{'rate':>7}{'peak dB':>9}{'TP dB':>7}{'RMS dB':>8}{'LUFS':>7}{'kB':>7}")
    for name, r in report.items():
        l = f"{r['lufs']:.1f}" if r["lufs"] is not None else "-"
        print(f"{name + '.ogg':<16}{r['duration']:>9.3f}{r['channels']:>3}{r['sample_rate']:>7}{r['peak_db']:>9.2f}"
              f"{r['true_peak_db']:>7.1f}{r['rms_db']:>8.2f}{l:>7}{r['bytes'] / 1024:>7.0f}")
    print("\nloop wrap (last sample -> first sample), worst channel.  jump = |x[0]-x[N-1]|, kink = second difference;")
    print("each against the same measure between ordinary neighbours (rms / 99.9th percentile).")
    for name, r in report.items():
        if r["kind"] != "loop":
            continue
        for tag in ("wrap_pcm", "wrap_ogg"):
            w = r[tag]
            print(f"  {name:<12}{tag[5:]:>4}  jump {w['jump']:.5f} (steps rms {w['step_rms']:.5f}, p99.9 {w['step_p999']:.5f})"
                  f"  kink {w['kink']:.5f} (rms {w['kink_rms']:.5f}, p99.9 {w['kink_p999']:.5f})"
                  f"  seam HF {w['seam_hf_over_median']:.2f}x median, pct {w['seam_hf_pct']:.0f}  {'OK' if w['ok'] else 'CHECK'}")
        d = r["samples"] - r["source_samples"]
        print(f"  {name:<12}      decoded {r['samples']} vs source {r['source_samples']} samples ({d:+d})"
              + (f", codec SNR {r['codec_snr_db']:.1f} dB" if "codec_snr_db" in r else ""))
    for name, r in report.items():
        if "fft_peaks" in r:
            print(f"  {name} strongest partials (Hz, dB rel): " + ", ".join(f"{f:.2f} ({a:.1f})" for f, a in r["fft_peaks"]))
    return report


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    names = [a[:-4] if a.endswith(".ogg") else a for a in argv if not a.startswith("--")]
    bad = [n for n in names if n not in SOUNDS]
    if bad:
        sys.exit(f"unknown sound(s): {', '.join(bad)}\nknown: {', '.join(SOUNDS)}")
    names = names or list(SOUNDS)
    if "--verify-only" not in flags:
        for name in names:
            gen, kind, q = SOUNDS[name]
            x = np.asarray(gen(), dtype=float)
            n = x.shape[-1]
            if kind == "loop":
                out, rot, qq = encode_loop(name, x, q, free_phase=not name.startswith("music"))
                note = "  NOT exact-length" if rot is None else f"  exact length (rotated {rot}, q {qq:g})"
            else:
                out, note = encode(name, x, q), ""
            print(f"{name + '.ogg':<18}{kind:<5}{n / SR:8.3f} s  {'stereo' if x.ndim == 2 else 'mono  '}"
                  f"  peak {db(peak(x)):6.2f} dBFS  rms {db(rms(x)):6.2f} dBFS  {out.stat().st_size / 1024:7.0f} kB{note}", flush=True)
    if "--verify" in flags or "--verify-only" in flags:
        verify(names)

if __name__ == "__main__":
    main(sys.argv[1:])
