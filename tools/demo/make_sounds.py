#!/usr/bin/env python3
"""Makes the demo project's sound effects and music (examples/demo_project/assets/sfx/, music/).

The demo's music and its bees' buzz are synthesized here from code alone: the workspace's
GameSounds pack, where its other sound effects come from (tools/demo/pick_sounds.py), has no
music and no insect. The other effects below were the demo's first ones and stay as a
synthesizer example; they're written only with --all-sfx (pick_sounds.py's replace them). Every
run gives the same samples (fixed seeds, no clock):

    python3 -I tools/demo/make_sounds.py [--all-sfx] [<out folder>]

(default: examples/demo_project/assets beside this script's editor checkout; it writes
<out>/sfx/*.ogg and <out>/music/*.ogg). Python 3 standard library only; needs ffmpeg with
libvorbis to encode. The tracks render in parallel processes, in about a minute or two.

What it makes:
- sfx/: mono 44.1 kHz Ogg Vorbis (quality 4), each with faded edges and a -1 dBFS peak:
  jump, land, step, swing, slash_hit, enemy_hurt, enemy_defeat, stomp, hero_hurt, hero_death,
  coin, shard, heart, checkpoint, ui_move, ui_select, ui_back, ui_toggle, pause, dialogue_blip,
  boss_roar, boss_slam, boss_charge, boss_defeat, boss_stun, bee_buzz, platform, gate_open,
  splash, pot_break, saved, and the jingles level_complete, game_over and victory.
- music/: stereo 44.1 kHz Ogg Vorbis loops (quality 1, to keep everything under 3 MB) that loop without a click or a gap: note
  tails, echoes and reverb wrap around into the start. title; forest_base + forest_drums and
  caves_base + caves_drums, layer pairs of exactly the same sample count and tempo, made to play
  together sample-aligned (the drums layer fades in over the base during fights; the two are
  normalized together, so they don't clip when summed); boss; victory. The music is written out
  below as chord charts and melodies (note names, beats), each bar checked to add up.
- The synth: band-limited wavetable oscillators (sine, triangle, square, saw; harmonics capped
  well below Nyquist, which also keeps them soft), noise, ADSR and exponential envelopes, pitch
  glides, one-pole and state-variable filters, Karplus-Strong plucks (harp, lute), drums (kick,
  snare, hats, toms, taiko, crash, shaker, rim), a feedback echo and a Freeverb-style reverb
  (its combs and allpasses are computed a delay-length block at a time, so it is quick in pure
  Python).

At the end it decodes every file back with ffmpeg and prints a table: duration, channels, rate,
samples, size, peak, and for the loops the seam (the jump from the last sample to the first
against the signal's local slope); the layer pairs' sample counts are compared.
"""
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import wave
import zlib
from array import array
from concurrent.futures import ProcessPoolExecutor
from itertools import accumulate, islice, repeat
from operator import mul

EDITOR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_OUT = os.path.join(EDITOR, "examples", "demo_project", "assets")

SR = 44100
TAU = 2.0 * math.pi
PEAK = 10 ** (-1 / 20)          # -1 dBFS
SFX_QUALITY = 4
MUSIC_QUALITY = 1
PRIME = 10.0                    # seconds of a loop's end fed through echo/reverb before the loop
WORKERS = 3                     # parallel renders (each music job holds up to about 1 GB)
DEBUG = bool(os.environ.get("MAKE_SOUNDS_DEBUG"))   # prints every part's level


def sec(t):
    """Seconds to samples."""
    return int(round(t * SR))


def seed_of(*parts):
    """A seed from values (stable across runs, unlike hash() of strings)."""
    return zlib.crc32(repr(parts).encode())


_memo = {}


def memo(fn):
    """Caches a sound by its arguments (as float32 arrays: notes repeat a lot in music)."""
    def wrapper(*args):
        key = (fn.__name__,) + args
        r = _memo.get(key)
        if r is None:
            r = fn(*args)
            r = tuple(array("f", c) for c in r) if isinstance(r, tuple) else array("f", r)
            _memo[key] = r
        return r
    wrapper.__name__, wrapper.__doc__ = fn.__name__, fn.__doc__
    return wrapper


# --- Pitch ------------------------------------------------------------------------------------

_LETTER = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _pc(s):
    """A pitch class from the start of `s` ("F#", "Bb", "C"); returns (pc, rest)."""
    pc, i = _LETTER[s[0]], 1
    while i < len(s) and s[i] in "#b":
        pc += 1 if s[i] == "#" else -1
        i += 1
    return pc % 12, s[i:]


def note(name):
    """A note name to MIDI ("A4" = 69, "C4" = 60, "F#5", "Bb3")."""
    pc, i = _LETTER[name[0]], 1
    while name[i] in "#b":
        pc += 1 if name[i] == "#" else -1
        i += 1
    return 12 * (int(name[i:]) + 1) + pc


def hz(m):
    """Equal-tempered frequency of MIDI note `m` (A4 = 440 Hz)."""
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


# --- Vectors ----------------------------------------------------------------------------------

def scale(x, g):
    return [v * g for v in x]


def vmul(a, b):
    return [p * q for p, q in zip(a, b)]


def peak(x):
    return max(map(abs, x), default=0.0)


def norm(x, p=1.0):
    m = peak(x)
    return scale(x, p / m) if m > 0 else list(x)


def add_into(buf, x, start, gain=1.0, wrap=0):
    """Adds `x` * gain into `buf` from sample `start`; with `wrap` (the buffer's length) what
    runs past the end goes on from the start, else it is cut."""
    n, size, off = len(x), len(buf), 0
    pos = start % wrap if wrap else start
    if pos < 0:
        off, pos = -pos, 0
    is_arr = isinstance(buf, array)
    while off < n:
        if pos >= size:
            if not wrap:
                return
            pos = 0
        k = min(size - pos, n - off)
        seg = [a + b * gain for a, b in zip(buf[pos:pos + k], x[off:off + k])]
        buf[pos:pos + k] = array("f", seg) if is_arr else seg
        off += k
        pos += k


def mix(*parts):
    """Sums (gain, signal) or (gain, signal, start seconds) parts."""
    starts = [sec(p[2]) if len(p) > 2 else 0 for p in parts]
    out = [0.0] * max(len(p[1]) + s for p, s in zip(parts, starts))
    for p, s in zip(parts, starts):
        add_into(out, p[1], s, p[0])
    return out


def fade(x, tin=0.002, tout=0.012):
    """Fades the edges (no clicks)."""
    x = list(x)
    n = len(x)
    a, b = min(n, max(1, sec(tin))), min(n, max(1, sec(tout)))
    for i in range(a):
        x[i] *= i / a
    for i in range(b):
        x[n - 1 - i] *= i / b
    return x


def soft_clip(x, t=0.6, c=1.0):
    """Leaves |v| <= t alone and bends what is above smoothly toward c (never past it)."""
    s = c - t
    th = math.tanh
    return [v if -t <= v <= t else (t + s * th((v - t) / s) if v > 0 else -t - s * th((-v - t) / s)) for v in x]


# --- Oscillators ------------------------------------------------------------------------------

TN = 8192                       # wavetable size
TMASK = TN - 1
_HSTEPS = (1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64)
_tables = {}


def _table(wave_, nh):
    """One cycle of `wave_` from its first `nh` harmonics (Lanczos-smoothed, peak 1)."""
    key = (wave_, nh)
    t = _tables.get(key)
    if t is None:
        if wave_ == "sine":
            parts = [(1, 1.0)]
        elif wave_ == "saw":
            parts = [(k, 1.0 / k) for k in range(1, nh + 1)]
        elif wave_ == "square":
            parts = [(k, 1.0 / k) for k in range(1, nh + 1, 2)]
        elif wave_ == "tri":
            parts = [(k, (-1) ** ((k - 1) // 2) / (k * k)) for k in range(1, nh + 1, 2)]
        else:
            raise ValueError(wave_)
        vals = [0.0] * TN
        for k, a in parts:
            if nh > 1:
                z = math.pi * k / (nh + 1)
                a *= math.sin(z) / z
            w = TAU * k / TN
            vals = [v + a * math.sin(w * i) for i, v in enumerate(vals)]
        pk = peak(vals)
        t = _tables[key] = [v / pk for v in vals]
    return t


def _nh(f, cut):
    """How many harmonics of `f` fit under `cut` Hz (from a few fixed steps)."""
    lim, best = cut / max(f, 1.0), 1
    for h in _HSTEPS:
        if h <= lim:
            best = h
    return best


def osc(wave_, freq, n, cut=8000.0, phase=0.0):
    """`n` samples of a band-limited oscillator: `freq` is Hz or a list of n Hz values;
    harmonics above `cut` are left out (band-limiting and a gentle low-pass in one)."""
    if isinstance(freq, (int, float)):
        tab = _table(wave_, 1 if wave_ == "sine" else _nh(freq, cut))
        inc, p0 = freq * TN / SR, phase * TN
        return [tab[int(p0 + i * inc) & TMASK] for i in range(n)]
    tab = _table(wave_, 1 if wave_ == "sine" else _nh(max(freq), cut))
    k = TN / SR
    ph = accumulate((f * k for f in freq), initial=phase * TN)
    return [tab[int(p) & TMASK] for p in islice(ph, n)]


def noise(n, seed):
    rnd = random.Random(seed).random
    return [2.0 * rnd() - 1.0 for _ in range(n)]


def vib_freqs(f, n, rate, depth, delay=0.0, ramp=0.25):
    """Frequencies with vibrato that fades in after `delay` seconds."""
    w, d0, nr = TAU * rate / SR, sec(delay), max(1, sec(ramp))
    sin = math.sin
    return [f * (1.0 + depth * min(1.0, max(0.0, (i - d0) / nr)) * sin(w * i)) for i in range(n)]


# --- Envelopes --------------------------------------------------------------------------------

def env_lin(n, pts):
    """Piecewise-linear through (seconds, level) points from t = 0; holds the last level."""
    out = []
    for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
        k = sec(t1) - sec(t0)
        if k > 0:
            st = (v1 - v0) / k
            out += [v0 + st * j for j in range(k)]
    if len(out) < n:
        out += [pts[-1][1]] * (n - len(out))
    return out[:n]


def glide(n, pts):
    """Frequencies through (seconds, Hz) points, exponential between them."""
    return [math.exp(v) for v in env_lin(n, [(t, math.log(f)) for t, f in pts])]


def env_exp(n, t60, attack=0.002):
    """A short attack, then an exponential decay reaching -60 dB at `t60`; ends at 0."""
    k = 0.001 ** (1.0 / (t60 * SR))
    e = list(accumulate(repeat(k, n - 1), mul, initial=1.0))
    na = min(n, max(1, sec(attack)))
    for i in range(na):
        e[i] *= i / na
    nb = min(n, sec(0.01))
    for i in range(nb):
        e[n - 1 - i] *= i / nb
    return e


def adsr(n, a, d, s, r, gate):
    """Attack (linear), decay (exponential, mostly done after `d`) to sustain `s`, held until
    `gate` seconds, then released to 0 over `r`; zeros after."""
    na, ng, nr = max(1, sec(a)), max(1, sec(gate)), max(1, sec(r))
    e = [j / na for j in range(min(na, ng))]
    m = ng - len(e)
    if m > 0:
        g = math.exp(-4.0 / (max(d, 1e-3) * SR))
        e += [s + (1.0 - s) * p for p in accumulate(repeat(g, m - 1), mul, initial=1.0)]
    lvl = e[-1]
    e += [lvl * (1.0 - j / nr) ** 2 for j in range(nr)]
    return e[:n] + [0.0] * (n - len(e))


# --- Filters ----------------------------------------------------------------------------------

def lowpass(x, fc):
    """One-pole low-pass (6 dB/octave)."""
    a = 1.0 - math.exp(-TAU * fc / SR)
    y, out = 0.0, []
    ap = out.append
    for v in x:
        y += a * (v - y)
        ap(y)
    return out


def highpass(x, fc):
    """One-pole high-pass."""
    return [v - w for v, w in zip(x, lowpass(x, fc))]


def svf(x, fc, q=0.707, mode="lp"):
    """State-variable (12 dB/octave) filter, Simper's TPT form: 'lp', 'bp' (unity peak) or
    'hp'. `fc` is Hz or a list of Hz per sample (for sweeps)."""
    k = 1.0 / q
    tan, lim = math.tan, 0.45 * SR
    if isinstance(fc, (int, float)):
        gs = repeat(tan(math.pi * min(fc, lim) / SR))
    else:
        gs = [tan(math.pi * min(f, lim) / SR) for f in fc]
    md = {"lp": 0, "bp": 1, "hp": 2}[mode]
    ic1 = ic2 = 0.0
    out = []
    ap = out.append
    for v0, g in zip(x, gs):
        a1 = 1.0 / (1.0 + g * (g + k))
        a2 = g * a1
        v3 = v0 - ic2
        v1 = a1 * ic1 + a2 * v3
        v2 = ic2 + a2 * ic1 + g * a2 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        ap(v2 if md == 0 else (k * v1 if md == 1 else v0 - k * v1 - v2))
    return out


# --- Karplus-Strong ---------------------------------------------------------------------------

def pluck(freq, dur, t60=2.0, bright=0.5, seed=0, tail=0.4):
    """A plucked string: a noise burst (low-passed by `bright`, 0..1) circulating in a delay line
    with an averaging filter; tuned exactly by a fractional-delay allpass. Rings for `dur`
    seconds, then fades out over `tail`."""
    n = sec(dur + tail)
    d = SR / freq
    L = int(d - 0.5)
    frac = d - 0.5 - L
    if frac < 0.2:
        L -= 1
        frac += 1.0
    c = (1.0 - frac) / (1.0 + frac)
    h = 0.5 * 0.001 ** (1.0 / (t60 * freq))
    exc = noise(L, seed)
    for _ in range(2):                     # soften the burst (circularly, so no edge)
        y = exc[-1]
        for i in range(L):
            y += bright * (exc[i] - y)
            exc[i] = y
    mean = sum(exc) / L
    buf = norm([v - mean for v in exc])
    out = [0.0] * n
    idx, prev, ax, ay = 0, 0.0, 0.0, 0.0
    for i in range(n):
        x = buf[idx]
        out[i] = x
        v = h * (x + prev)
        prev = x
        ay = c * (v - ay) + ax
        ax = v
        buf[idx] = ay
        idx += 1
        if idx == L:
            idx = 0
    ng, nt = sec(dur), n - sec(dur)
    for i in range(min(n, sec(0.001))):
        out[i] *= i / sec(0.001)
    for j in range(nt):
        out[ng + j] *= (1.0 - j / nt) ** 2
    return out


# --- Echo and reverb --------------------------------------------------------------------------

def comb(x, D, fb, damp=0.3):
    """A feedback comb, Freeverb's: w[i] = x[i] + fb * lowpass(w[i-D]); returns w delayed by D.
    The damping low-pass is a 2-tap average on the delayed signal, so a whole block of D samples
    depends only on earlier blocks and is computed in one comprehension."""
    n, P = len(x), D + 1
    w = [0.0] * (n + P)
    c1, c2 = fb * (1.0 - damp), fb * damp
    i = 0
    while i < n:
        k = min(D, n - i)
        j = i + P
        w[j:j + k] = [a + c1 * b + c2 * c for a, b, c in zip(x[i:i + k], w[j - D:j - D + k], w[j - D - 1:j - D - 1 + k])]
        i += k
    return w[1:n + 1]


def allpass(x, D, g=0.5):
    """Freeverb's allpass: v[i] = x[i] + g v[i-D], y[i] = v[i-D] - x[i] (blockwise too)."""
    n = len(x)
    v = [0.0] * (n + D)
    i = 0
    while i < n:
        k = min(D, n - i)
        j = i + D
        v[j:j + k] = [a + g * b for a, b in zip(x[i:i + k], v[j - D:j - D + k])]
        i += k
    return [b - a for a, b in zip(x, v)]


_COMBS = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)
_ALLPASSES = (556, 441, 341, 225)


def reverb(x, room=0.8, damp=0.4):
    """Freeverb (8 combs, 4 allpasses per side, the right side's delays 23 samples longer):
    mono in, (left, right) wet out."""
    fb, d = room * 0.28 + 0.7, damp * 0.4
    inp = [v * 0.1 for v in x]
    sides = []
    for spread in (0, 23):
        acc = None
        for D in _COMBS:
            c = comb(inp, D + spread, fb, d)
            acc = c if acc is None else [p + q for p, q in zip(acc, c)]
            del c
        for D in _ALLPASSES:
            acc = allpass(acc, D + spread)
        sides.append(array("f", acc))
        del acc
    return sides[0], sides[1]


def looped(fx, x, prime):
    """Applies an effect as if `x` repeated forever: runs it over the loop's last `prime`
    samples followed by the loop and keeps the loop part, so the tail wraps into the start."""
    x = list(x)
    reps = 1 + prime // len(x)
    y = fx((x * reps)[-prime:] + x)
    del x
    if isinstance(y, tuple):
        return tuple(c[prime:] for c in y)
    return y[prime:]


# --- Instruments (MIDI note, gate seconds) ----------------------------------------------------

@memo
def flute(m, dur):
    """A soft flute-like lead: triangle and a little square, delayed vibrato, breath."""
    f, rel = hz(m), 0.16
    n = sec(dur + rel)
    fr = vib_freqs(f, n, 5.2, 0.0045, 0.18)
    breath = svf(noise(n, seed_of("flute", m, dur)), 2.0 * f, 2.0, "bp")
    sig = mix((0.8, osc("tri", fr, n, 6000)), (0.2, osc("square", fr, n, 2400)), (0.12, breath))
    return vmul(lowpass(sig, 5500), adsr(n, 0.05, 0.25, 0.8, rel, dur))


@memo
def ocarina(m, dur):
    """A hollow ocarina: mostly sine, slow vibrato, breathy, slow attack."""
    f, rel = hz(m), 0.25
    n = sec(dur + rel)
    fr = vib_freqs(f, n, 4.6, 0.006, 0.3, 0.4)
    breath = svf(noise(n, seed_of("ocarina", m, dur)), f, 1.5, "bp")
    sig = mix((1.0, osc("sine", fr, n)), (0.22, osc("tri", fr, n, 3000)), (0.1, breath))
    return vmul(sig, adsr(n, 0.08, 0.35, 0.85, rel, dur))


@memo
def brass(m, dur):
    """A soft-brass lead: saw and square through a low-pass that opens on the attack."""
    f, rel = hz(m), 0.14
    n = sec(dur + rel)
    fr = vib_freqs(f, n, 5.5, 0.003, 0.25)
    src = mix((0.75, osc("saw", fr, n, 5000)), (0.3, osc("square", fr, n, 3000)))
    t1 = min(0.07, dur * 0.5)
    t2 = max(t1 + 0.01, min(0.3, dur))
    t3 = max(t2 + 0.01, dur + rel)
    fc = env_lin(n, [(0, 400.0), (t1, min(3000.0, f * 6)), (t2, min(2000.0, f * 4)), (t3, min(1500.0, f * 3))])
    return vmul(svf(src, fc, 0.9, "lp"), adsr(n, 0.025, 0.2, 0.78, rel, dur))


@memo
def harp(m, dur):
    """A harp: a Karplus-Strong pluck with a soft burst, long ring (shorter up high)."""
    f = hz(m)
    t60 = min(5.0, max(0.9, 3.5 * (196.0 / f) ** 0.5))
    return lowpass(pluck(f, dur, t60, 0.45, seed_of("harp", m, dur), 0.5), 5200)


@memo
def lute(m, dur):
    """A lute: a brighter, shorter pluck."""
    f = hz(m)
    t60 = min(2.5, max(0.6, 1.6 * (196.0 / f) ** 0.5))
    return lowpass(highpass(pluck(f, dur, t60, 0.65, seed_of("lute", m, dur), 0.25), 90), 6000)


@memo
def bell(m, dur):
    """A celesta-like bell: a few sine partials, the higher ones dying sooner."""
    f = hz(m)
    n = sec(dur + 1.2)
    parts = [(1.0, 1.0, 1.5), (2.0, 0.3, 0.7), (3.01, 0.1, 0.4), (4.07, 0.05, 0.25)]
    return mix(*[(a, vmul(osc("sine", f * r, n), env_exp(n, t))) for r, a, t in parts if f * r < 9000])


@memo
def chip(m, dur):
    """A plucky chiptune square (counter-lines and ostinatos), low-passed."""
    f = hz(m)
    n = sec(dur + 0.06)
    sig = mix((0.7, osc("square", f, n, 2800)), (0.4, osc("tri", f, n, 4000)))
    return vmul(lowpass(sig, 3200), adsr(n, 0.003, 0.12, 0.35, 0.05, dur))


@memo
def bass(m, dur):
    """A round plucked bass: triangle, sine and a touch of square."""
    f = hz(m)
    n = sec(dur + 0.08)
    sig = mix((0.6, osc("tri", f, n, 2000)), (0.5, osc("sine", f, n)), (0.12, osc("square", f, n, 1200)))
    return vmul(lowpass(sig, 1400), adsr(n, 0.004, 0.25, 0.55, 0.08, dur))


@memo
def bass_soft(m, dur):
    """A soft sustained bass (sine and triangle, slow attack)."""
    f = hz(m)
    n = sec(dur + 0.3)
    sig = mix((1.0, osc("sine", f, n)), (0.35, osc("tri", f, n, 1500)))
    return vmul(sig, adsr(n, 0.04, 0.5, 0.8, 0.3, dur))


@memo
def bass_saw(m, dur):
    """A driving saw bass with a sine sub, its low-pass closing after the attack."""
    f = hz(m)
    n = sec(dur + 0.05)
    fc = env_lin(n, [(0, 1500.0), (0.08, 650.0), (dur + 0.05, 500.0)])
    sig = mix((0.6, svf(osc("saw", f, n, 3000), fc, 1.1, "lp")), (0.5, osc("sine", f, n)))
    return soft_clip(vmul(sig, adsr(n, 0.004, 0.15, 0.6, 0.05, dur)), 0.6, 1.0)


@memo
def pad(ms, dur, wave_="saw", bright=1300.0):
    """A warm pad of notes `ms`: two detuned oscillators a note, spread left and right, through
    two low-passes; slow attack and release. Returns (left, right)."""
    rel = 0.9
    n = sec(dur + rel)
    att = min(0.6, dur * 0.4)
    left, right = [0.0] * n, [0.0] * n
    g = 1.0 / len(ms)
    for i, m in enumerate(ms):
        f = hz(m)
        a = osc(wave_, f * 2 ** (6 / 1200), n, 2500, (0.13 * i) % 1)
        b = osc(wave_, f * 2 ** (-6 / 1200), n, 2500, (0.41 + 0.29 * i) % 1)
        left = [p + g * (0.65 * u + 0.35 * v) for p, u, v in zip(left, a, b)]
        right = [p + g * (0.35 * u + 0.65 * v) for p, u, v in zip(right, a, b)]
    e = adsr(n, att, 0.5, 0.9, rel, dur)
    return (vmul(lowpass(lowpass(left, bright), bright), e), vmul(lowpass(lowpass(right, bright), bright), e))


# --- Drums ------------------------------------------------------------------------------------

@memo
def kick():
    n = sec(0.42)
    body = vmul(osc("sine", glide(n, [(0, 160), (0.05, 70), (0.3, 45)]), n), env_exp(n, 0.38))
    click = vmul(lowpass(noise(n, 101), 3000), env_exp(n, 0.012))
    return norm(soft_clip(norm(mix((1.0, body), (0.5, click)), 1.3), 0.7, 1.0))


@memo
def snare():
    n = sec(0.3)
    tone = vmul(mix((0.6, osc("sine", 190, n)), (0.3, osc("sine", 340, n))), env_exp(n, 0.1))
    nz = vmul(norm(lowpass(svf(noise(n, 102), 1800, 0.7, "hp"), 7000)), env_exp(n, 0.2))
    return norm(mix((0.7, tone), (0.8, nz)))


@memo
def hat(open_=False):
    n = sec(0.35 if open_ else 0.08)
    nz = norm(lowpass(svf(noise(n, 103), 7000, 0.7, "hp"), 9500))
    return vmul(nz, env_exp(n, 0.3 if open_ else 0.045, 0.001))


@memo
def tom(f):
    n = sec(0.5)
    body = vmul(osc("sine", glide(n, [(0, f * 1.5), (0.06, f), (0.5, f * 0.95)]), n), env_exp(n, 0.45))
    skin = vmul(norm(lowpass(noise(n, 104), 1500)), env_exp(n, 0.05))
    return norm(mix((1.0, body), (0.15, skin)))


@memo
def taiko():
    n = sec(0.9)
    body = vmul(osc("sine", glide(n, [(0, 95), (0.05, 62), (0.9, 58)]), n), env_exp(n, 0.8))
    skin = vmul(norm(lowpass(lowpass(noise(n, 105), 600), 600)), env_exp(n, 0.15))
    return norm(soft_clip(norm(mix((1.0, body), (0.4, skin)), 1.2), 0.7, 1.0))


@memo
def crash():
    n = sec(1.6)
    nz = norm(lowpass(lowpass(svf(noise(n, 106), 3500, 0.7, "hp"), 8000), 9000))
    return vmul(nz, env_exp(n, 1.4, 0.003))


@memo
def shaker():
    n = sec(0.09)
    nz = norm(svf(noise(n, 107), 6000, 0.8, "bp"))
    return vmul(nz, [v * v for v in env_lin(n, [(0, 0), (0.025, 1), (0.09, 0)])])


@memo
def rim():
    n = sec(0.08)
    sig = mix((0.6, osc("sine", 1700, n)), (0.7, norm(svf(noise(n, 108), 2500, 2.0, "bp"))))
    return norm(vmul(sig, env_exp(n, 0.03, 0.0005)))


# --- Music: chords, lines, songs --------------------------------------------------------------

QUAL = {"": (0, 4, 7), "m": (0, 3, 7), "7": (0, 4, 7, 10), "maj7": (0, 4, 7, 11),
        "m7": (0, 3, 7, 10), "sus4": (0, 5, 7), "sus2": (0, 2, 7), "dim": (0, 3, 6), "add9": (0, 4, 7, 14)}


class Chord:
    """A chord symbol ("D", "Bm", "A/C#", "Bbmaj7", "Asus4") placed at `start` for `dur` beats."""

    def __init__(self, sym, start, dur):
        self.sym, self.start, self.dur = sym, start, dur
        name, _, slash = sym.partition("/")
        self.root, q = _pc(name)
        self.ivs = QUAL[q]
        self.tones = {(self.root + i) % 12 for i in self.ivs}
        self.bass = _pc(slash)[0] if slash else self.root


def stack(c, lo):
    """The chord's tones upward from its root at or above MIDI `lo` (three octaves)."""
    r = lo + (c.root - lo) % 12
    return sorted({r + iv % 12 + 12 * o for iv in c.ivs for o in range(4)})


def voicing(c, lo, hi):
    """Every chord tone in [lo, hi]."""
    return [m for m in range(lo, hi + 1) if m % 12 in c.tones]


def bass_note(c, lo=36):
    """The chord's bass (the slash note, else the root) at or above `lo`."""
    return lo + (c.bass - lo) % 12


def chord_at(chords, beat):
    for c in chords:
        if c.start <= beat + 1e-6 < c.start + c.dur:
            return c
    return chords[-1]


def merged(chords):
    """Joins repeated chords (for pads and held basses)."""
    out = []
    for c in chords:
        if out and out[-1].sym == c.sym:
            out[-1] = Chord(c.sym, out[-1].start, out[-1].dur + c.dur)
        else:
            out.append(Chord(c.sym, c.start, c.dur))
    return out


def harmony(notes, chords):
    """A second voice: under each melody note, the nearest chord tone 3 to 9 semitones below."""
    out = []
    for t, m, d in notes:
        if m is None:
            continue
        c = chord_at(chords, t)
        for k in range(3, 10):
            if (m - k) % 12 in c.tones:
                out.append((t, m - k, d))
                break
    return out


def shift(notes, semis, since=0.0, until=1e9):
    """The notes in [since, until) beats, transposed."""
    return [(t, m + semis, d) for t, m, d in notes if m is not None and since <= t < until]


class Song:
    """A piece being rendered: a tempo, a length in bars and stereo buffers, plus the reverb
    and echo sends. With `loop`, everything that runs past the end wraps into the start."""

    def __init__(self, bpm, bpb, bars, seed, room=0.8, damp=0.45, wet=0.3, echo_beats=0.0,
                 echo_fb=0.4, loop=True, extra=0.0):
        self.bpm, self.bpb, self.loop = bpm, bpb, loop
        self.spb = SR * 60.0 / bpm
        self.n = int(round(bpb * bars * self.spb)) + (0 if loop else sec(extra))
        self.L, self.R, self.rev, self.echo = (array("f", bytes(4 * self.n)) for _ in range(4))
        self.rng = random.Random(seed)
        self.room, self.damp, self.wet = room, damp, wet
        self.echo_beats, self.echo_fb = echo_beats, echo_fb
        self.parts = {}

    def secs(self, beats):
        return beats * 60.0 / self.bpm

    def at(self, beat):
        return int(round(beat * self.spb))

    def put(self, x, beat, gain, pan=0.0, rev=0.0, echo=0.0, part="?"):
        """Mixes a sound (mono, or a (left, right) pair) in at `beat`."""
        xl, xr = x if isinstance(x, tuple) else (x, x)
        s, w = self.at(beat), self.n if self.loop else 0
        a = (pan + 1.0) * math.pi / 4
        add_into(self.L, xl, s, gain * math.cos(a) * math.sqrt(2), w)
        add_into(self.R, xr, s, gain * math.sin(a) * math.sqrt(2), w)
        if rev:
            add_into(self.rev, xl, s, gain * rev, w)
        if echo:
            add_into(self.echo, xl, s, gain * echo, w)
        if DEBUG:
            self.parts[part] = self.parts.get(part, 0.0) + gain * gain * sum(v * v for v in xl)

    def play(self, inst, notes, gain, pan=0.0, rev=0.2, echo=0.0, length=1.0, human=0.06, part="?"):
        """Plays (beat, midi, beats) notes on an instrument; `length` scales how long each
        sounds; `human` varies the loudness a little."""
        for t, m, d in notes:
            if m is not None:
                x = inst(m, round(self.secs(d * length), 3))
                self.put(x, t, gain * (1.0 + self.rng.uniform(-human, human)), pan, rev, echo, part)

    def hit(self, sound, beats, gain, pan=0.0, rev=0.1, human=0.08, part="drums"):
        for t in beats:
            self.put(sound, t, gain * (1.0 + self.rng.uniform(-human, human)), pan, rev, 0.0, part)

    def chords(self, text):
        """Parses a chord chart: bars split by '|', one symbol a bar or "sym:beats" each."""
        out, beat = [], 0.0
        for bar in text.split("|"):
            toks = bar.split()
            if len(toks) == 1 and ":" not in toks[0]:
                toks = [f"{toks[0]}:{self.bpb}"]
            total = 0.0
            for tok in toks:
                sym, _, d = tok.partition(":")
                out.append(Chord(sym, beat + total, float(d)))
                total += float(d)
            if abs(total - self.bpb) > 1e-6:
                raise ValueError(f"chord bar {bar!r} has {total} beats")
            beat += total
        return out

    def line(self, text, bar=0):
        """Parses a melody from `bar`: "NOTE:beats" tokens (the length carries over to the next
        tokens until changed; 'r' rests), bars split by '|' and checked to add up."""
        out, beat, dur = [], bar * self.bpb, 1.0
        for b in text.split("|"):
            total = 0.0
            for tok in b.split():
                name, _, d = tok.partition(":")
                if d:
                    dur = float(d)
                out.append((beat, None if name == "r" else note(name), dur))
                beat += dur
                total += dur
            if abs(total - self.bpb) > 1e-6:
                raise ValueError(f"melody bar {b!r} has {total} beats")
        return out

    def arp(self, inst, chords, pattern, step, lo, gain, pan=0.0, rev=0.2, echo=0.0, length=1.0, part="arp"):
        """Arpeggiates each chord: every `step` beats the stack(lo) tone that `pattern` gives
        for that position in the bar."""
        notes = []
        for c in chords:
            st, t = stack(c, lo), c.start
            while t < c.start + c.dur - 1e-6:
                i = int(round((t % self.bpb) / step)) % len(pattern)
                notes.append((t, st[pattern[i]], step))
                t += step
        self.play(inst, notes, gain, pan, rev, echo, length, part=part)

    def strum(self, inst, chords, offsets, lo, gain, count=4, pan=0.0, rev=0.2, length=1.0, part="strum"):
        """Strums each chord's lowest `count` stack tones at the bar `offsets` (15 ms apart)."""
        notes = []
        for c in chords:
            st = stack(c, lo)[:count]
            for off in offsets:
                if off < c.dur - 1e-6:
                    for i, m in enumerate(st):
                        notes.append((c.start + off + i * 0.015 / self.secs(1), m, 0.5))
        self.play(inst, notes, gain, pan, rev, 0.0, length, part=part)

    def bassline(self, inst, chords, pattern, gain, lo=36, pan=0.0, rev=0.05, length=0.95, part="bass"):
        """Plays (offset, beats, degree) per chord: 'R' the bass note, '8' its octave, '5' the
        chord's fifth (its root when the bass is the fifth), '3' the third."""
        notes = []
        for c in chords:
            r = bass_note(c, lo)
            for off, d, deg in pattern:
                if off >= c.dur - 1e-6:
                    continue
                if deg == "R":
                    m = r
                elif deg == "8":
                    m = r + 12
                elif deg == "5":
                    m = r + ((c.root + c.ivs[2] - c.bass) % 12 or (c.root - c.bass) % 12 or 7)
                else:
                    m = r + (c.root + c.ivs[1] - c.bass) % 12
                notes.append((c.start + off, m, min(d, c.dur - off)))
        self.play(inst, notes, gain, pan, rev, 0.0, length, part=part)

    def pads(self, chords, lo, hi, gain, wave_="saw", bright=1300.0, rev=0.4, part="pad"):
        for c in merged(chords):
            self.put(pad(tuple(voicing(c, lo, hi)), round(self.secs(c.dur), 3), wave_, bright),
                     c.start, gain * (1.0 + self.rng.uniform(-0.03, 0.03)), 0.0, rev, 0.0, part)

    def finish(self, name=""):
        """Runs the echo and the reverb (looped for a loop) and returns (left, right)."""
        L, R, rev = self.L, self.R, self.rev
        prime = sec(PRIME)
        if self.echo_beats:
            D = self.at(self.echo_beats)
            fx = lambda v: comb(v, D, self.echo_fb, 0.35)
            e = looped(fx, self.echo, prime) if self.loop else fx(self.echo.tolist())
            # The echo pans: left, then right half a delay later (wrapping round for a loop).
            h = self.at(self.echo_beats / 2)
            e2 = e[-h:] + e[:-h] if self.loop else [0.0] * h + e[:-h]
            L = array("f", [a + 0.8 * b for a, b in zip(L, e)])
            R = array("f", [a + 0.8 * b for a, b in zip(R, e2)])
            rev = array("f", [a + 0.4 * b for a, b in zip(rev, e)])
            del e, e2
        fx = lambda v: reverb(v, self.room, self.damp)
        wl, wr = looped(fx, rev, prime) if self.loop else fx(rev.tolist())
        del rev
        if DEBUG:
            n = self.n
            for k, v in sorted(self.parts.items()):
                print(f"  {name:14} {k:10} {10 * math.log10(v / n + 1e-12):7.1f} dB")
            dry = sum(a * a for a in L) / n
            wet = sum(a * a for a in wl) / n * self.wet ** 2
            print(f"  {name:14} dry {10 * math.log10(dry + 1e-12):6.1f} dB, wet {10 * math.log10(wet + 1e-12):6.1f} dB")
        g = self.wet
        return (array("f", [a + g * b for a, b in zip(L, wl)]), array("f", [a + g * b for a, b in zip(R, wr)]))


# --- Music: the tracks ------------------------------------------------------------------------

def track_title():
    """Title: D major, 3/4, 90 bpm, 24 bars (48 s). A (flute theme over harp arpeggios), A'
    (the theme rises, a second flute in harmony, bell sparkles), B (the tune on harp and bell
    over held chords), ending on A to lead back to D."""
    s = Song(90, 3, 24, seed=1, room=0.86, damp=0.45, wet=0.55)
    ch = s.chords("D | A/C# | Bm | G | D/F# | Em | G | A | D | A/C# | Bm | F#m | G | D/F# | Em7 | A7 | "
                  "Bm | G | D | A | Bm | G | Em | Asus4:1.5 A:1.5")
    a = s.line("A4 D5 F#5 | E5:2 C#5:1 | D5 F#5 B5 | A5:2 G5:0.5 F#5 | F#5:1.5 E5:0.5 D5:1 | E5 G5 B4 | "
               "D5 B4:0.5 D5 G5:1 | E5:3", 0)
    a2 = s.line("A4:1 D5 F#5 | E5:2 C#5:1 | D5 F#5 B5 | C#6:2 A5:1 | B5:1.5 A5:0.5 G5:1 | F#5 A5 D6 | "
                "E6 D6 B5 | C#6:1.5 B5:0.5 A5:1", 8)
    b = s.line("F#5:1.5 E5:0.5 D5:1 | D5 B4 G4 | A4:1.5 B4:0.5 D5:1 | C#5:2 E5:1 | F#5:1.5 A5:0.5 F#5:1 | "
               "G5 F#5 E5 | B4 E5 G5 | A5:1.5 G5:0.5 E5:1", 16)
    s.play(flute, a + a2, 0.30, 0.0, rev=0.35, length=0.97, part="lead")
    s.play(flute, harmony(a2, ch), 0.07, -0.35, rev=0.4, part="harmony")
    s.play(harp, b, 0.36, 0.1, rev=0.35, length=1.5, part="lead")
    s.play(bell, shift(b, 12), 0.06, 0.25, rev=0.5, part="bell")
    s.arp(harp, ch[:16], [0, 2, 3, 4, 5, 4], 0.5, 43, 0.24, -0.3, rev=0.35, length=3, part="arp")
    s.arp(harp, ch[16:], [0, 1, 2], 1.0, 43, 0.2, -0.3, rev=0.35, length=2.5, part="arp")
    s.bassline(bass_soft, ch, [(0, 2.5, "R")], 0.14, part="bass")
    s.pads(ch[:8], 54, 69, 0.14)
    s.pads(ch[8:], 54, 69, 0.2)
    s.play(bell, [(c.start + 1, voicing(c, 78, 90)[0], 1.0) for c in ch[8:16]], 0.05, 0.3, rev=0.5, part="bell")
    return [s.finish("title")]


FOREST_CHORDS = ("G | D | Em | C | G | D | C | D | G | D | Em | C | Am | Bm | C | D | "
                 "Em | C | G | D | Em | C | Am | Dsus4:2 D:2")
FOREST_A4 = ("G4:0.5 B4 D5:1 D5:0.5 E5 D5:1 | A4:0.5 D5 F#5:1 E5:0.5 D5 A4:1 | "
             "B4:0.5 E5 G5:1 F#5:0.5 E5 B4:1 | E5:0.5 G5 C6:1.5 B5:0.5 A5:1")


def track_forest():
    """Forest: G major, 4/4, 126 bpm, 24 bars (45.7 s), in two layers. Base: A (flute tune over
    lute arpeggios), A' (the tune climbs, a second flute in harmony, lute strums), B (a lyrical
    bridge doubled by a bell); bouncing bass, a soft pad. Drums: kick, snare, hats, tom fills
    every 8 bars, crashes, and a driving chiptune counter-line in eighths."""
    s = Song(126, 4, 24, seed=2, room=0.7, damp=0.45, wet=0.5)
    ch = s.chords(FOREST_CHORDS)
    a = s.line(FOREST_A4 + " | B5:1 G5:0.5 D5 G5:1 A5:0.5 B5 | A5:1.5 F#5:0.5 D5:1 F#5:0.5 A5 | "
               "G5:1 E5:0.5 C5 E5:1 G5 | F#5:1.5 E5:0.5 D5:2", 0)
    a2 = s.line(FOREST_A4 + " | C6:1 B5:0.5 A5 E5:1 A5 | D6:1 B5:0.5 F#5 B5:1 D6 | E6:1.5 D6:0.5 C6:1 G5 | "
                "A5:1 B5:0.5 A5 F#5:1 D5", 8)
    b = s.line("B5:2 G5:1 E5 | G5:1.5 A5:0.5 G5:1 E5 | D5:2 G5:1 B5 | A5:3 F#5:1 | "
               "E5:0.5 G5 B5:1 A5:0.5 G5 B5:1 | C6:1.5 B5:0.5 G5:1 E5 | A5:1 C6 E6 D6:0.5 C6 | A5:1 G5 F#5 D5", 16)
    s.play(flute, a + a2 + b, 0.30, 0.0, rev=0.25, length=0.95, part="lead")
    s.play(flute, harmony(a2, ch), 0.07, -0.35, rev=0.3, part="harmony")
    s.play(bell, b, 0.06, 0.25, rev=0.4, part="bell")
    s.arp(lute, ch[:8], [0, 2, 3, 2, 4, 2, 3, 2], 0.5, 43, 0.26, -0.25, rev=0.25, length=1.5)
    s.strum(lute, ch[8:], [0, 1.5, 2, 3], 50, 0.16, pan=-0.25, rev=0.25)
    s.bassline(bass, ch, [(0, 1, "R"), (1.5, 0.5, "R"), (2, 1, "5"), (3, 0.5, "8"), (3.5, 0.5, "5")], 0.19)
    s.pads(ch, 55, 69, 0.18)

    d = Song(126, 4, 24, seed=3, room=0.55, damp=0.5, wet=0.5)
    for bar in range(24):
        b0 = bar * 4.0
        fill = bar in (7, 15, 23)
        d.hit(kick(), [b0, b0 + 2], 0.42)
        d.hit(kick(), [b0 + 2.75], 0.24)
        if bar % 8 == 0:
            d.hit(crash(), [b0], 0.12, 0.3, rev=0.3)
        if not fill:
            d.hit(snare(), [b0 + 1, b0 + 3], 0.26, rev=0.15)
            d.hit(hat(), [b0 + k * 0.5 for k in range(0, 8, 2)], 0.05, 0.25)
            d.hit(hat(), [b0 + k * 0.5 for k in range(1, 8, 2)], 0.08, 0.25)
            if bar % 2 == 1:
                d.hit(hat(True), [b0 + 3.5], 0.05, 0.25)
        else:
            d.hit(snare(), [b0 + 1], 0.26, rev=0.15)
            d.hit(hat(), [b0 + 0.5, b0 + 1.5], 0.07, 0.25)
            for k, f in enumerate((220, 220, 175, 175, 140, 140, 110)):
                d.hit(tom(f), [b0 + 2 + k * 0.25], 0.22 + 0.02 * k, -0.4 + 0.12 * k, rev=0.2)
            d.hit(snare(), [b0 + 3.75], 0.3, rev=0.15)
    d.arp(chip, ch, [3, 2, 1, 2, 3, 4, 3, 2], 0.5, 55, 0.13, 0.3, rev=0.2, length=0.7, part="counter")
    return [s.finish("forest_base"), d.finish("forest_drums")]


def track_caves():
    """Caves: D minor, 4/4, 84 bpm, 16 bars (45.7 s), two layers. Base: an ocarina tune with a
    dotted-eighth echo over a tri-wave choir pad, a deep held bass, sparse harp arpeggios, the
    tune's second half doubled low on harp, and water-drip bells, in a long reverb. Drums: taiko
    in a 3-3-2 pulse, a soft snare, rim ticks and shaker, tom answers, rolls every 8 bars, and a
    low plucked pulse in eighths."""
    s = Song(84, 4, 16, seed=4, room=0.9, damp=0.5, wet=0.45, echo_beats=0.75, echo_fb=0.42)
    ch = s.chords("Dm | Dm | Bbmaj7 | Bbmaj7 | Gm | Gm | A | A7 | Dm | C | Bb | F | Gm | Gm | Asus4 | A")
    mel = s.line("A4:1.5 D5:0.5 F5:2 | E5:1 D5 A4:2 | F5:2 D5:1 Bb4 | A4:3 r:1 | G4:1.5 Bb4:0.5 D5:2 | "
                 "D5:1 C5 Bb4:2 | A4:1 C#5 E5:2 | G5:1.5 F5:0.5 E5:2 | D5:1.5 F5:0.5 A5:2 | G5:1 E5 C5:2 | "
                 "F5:1.5 D5:0.5 Bb4:2 | A4:1 C5 F5:2 | G5:2 F5:1 D5 | Bb4:3 G4:1 | D5:2 E5 | C#5:4", 0)
    s.play(ocarina, mel, 0.22, 0.0, rev=0.4, echo=0.3, length=0.95, part="lead")
    s.play(harp, shift(mel, -12, 32), 0.32, 0.2, rev=0.4, echo=0.2, length=1.2, part="lead2")
    notes = []
    for c in ch:
        st = stack(c, 50)
        notes += [(c.start + off, st[i], 1.5) for off, i in ((0, 0), (0.5, 2), (1.5, 4), (3, 3))]
    s.play(harp, notes, 0.3, -0.3, rev=0.4, echo=0.25, part="arp")
    s.pads(ch, 50, 65, 0.18, "tri", 900.0, rev=0.5)
    s.bassline(bass_soft, merged(ch), [(0, 8, "R")], 0.13, lo=38)
    rng = random.Random(44)
    drips = [(bar * 4 + rng.randrange(8) * 0.5, note(rng.choice(("D6", "F6", "G6", "A6", "C7"))), 0.5)
             for bar in range(16) if rng.random() < 0.6]
    s.play(bell, drips, 0.12, 0.0, rev=0.5, echo=0.5, part="drips")

    d = Song(84, 4, 16, seed=5, room=0.85, damp=0.5, wet=0.4)
    for bar in range(16):
        b0 = bar * 4.0
        d.hit(taiko(), [b0], 0.45, rev=0.3)
        d.hit(taiko(), [b0 + 1.5], 0.28, rev=0.3)
        d.hit(taiko(), [b0 + 3], 0.34, rev=0.3)
        d.hit(snare(), [b0 + 2], 0.10, 0.1, rev=0.5)
        d.hit(rim(), [b0 + 1, b0 + 3.5], 0.07, -0.3, rev=0.3)
        d.hit(shaker(), [b0 + k * 0.25 for k in range(16) if k % 2], 0.03, 0.35)
        d.hit(shaker(), [b0 + k * 0.5 for k in range(8)], 0.05, 0.35)
        if bar % 8 == 7:
            for k in range(8):
                d.hit(tom(85), [b0 + 2 + k * 0.25], 0.12 + 0.03 * k, -0.2, rev=0.3)
        elif bar % 2 == 1:
            d.hit(tom(110), [b0 + 2.5, b0 + 3.5], 0.16, 0.3, rev=0.3)
    pulse = []
    for c in ch:
        r = bass_note(c, 38)
        pulse += [(c.start + k * 0.5, r + (12 if k % 4 == 2 else 0), 0.5) for k in range(8)]
    d.play(lute, pulse, 0.26, 0.0, rev=0.2, length=0.6, part="pulse")
    return [s.finish("caves_base"), d.finish("caves_drums")]


def track_boss():
    """Boss: E minor (harmonic: B major chords), 4/4, 150 bpm, 24 bars (38.4 s). A (a brass
    theme), B (it climbs to F#6 over Am - Em - C - D - B), C (a pounding riff over Em - D - C - B,
    doubled by a chiptune an octave up the second time, a run back to the top); 8th-note saw
    bass, a chiptune ostinato, dark pad; kick on every beat, snare, hats, tom fills, crashes."""
    s = Song(150, 4, 24, seed=6, room=0.6, damp=0.4, wet=0.45)
    ch = s.chords("Em | Em | C | D | Em | Em | C | B | Am | Am | Em | Em | C | D | B | B | "
                  "Em | D | C | B | Em | D | C | B")
    a = s.line("E5:0.5 E5 G5 E5 B5:1 A5:0.5 G5 | F#5:1 G5:0.5 F#5 E5:1 B4 | E5:0.5 G5 C6:1 B5:0.5 A5 G5:1 | "
               "F#5:1 A5 D6:1.5 C6:0.5 | B5:1 G5:0.5 E5 B5:1 C6:0.5 B5 | A5:1 G5:0.5 F#5 G5:2 | "
               "E5:0.5 G5 C6:1 E6 C6 | D#6:1 B5 F#5 D#5", 0)
    b = s.line("A5:1.5 C6:0.5 E6:2 | D6:1 C6 B5 A5 | G5:1.5 B5:0.5 E6:2 | D6:1 B5 G5 E5 | "
               "C6:1 B5:0.5 C6 E6:1 C6 | D6:1 C6:0.5 D6 F#6:1 D6 | D#6:2 F#6:1 D#6 | B5:2 A5:1 F#5", 8)
    riff = ("E5:0.5 B4 E5 G5 F#5:1 E5 | D5:0.5 A4 D5 F#5 E5:1 D5 | C5:0.5 G4 C5 E5 D5:1 C5 | ")
    c = s.line(riff + "B4:0.5 F#4 B4 D#5 F#5:1 B5 | " + riff + "B4:0.5 F#4 B4 D#5 F#5 A5 B5 D#6", 16)
    s.play(brass, a + b + c, 0.27, 0.0, rev=0.15, length=0.92, part="lead")
    s.play(chip, shift(c, 12, 80), 0.13, 0.3, rev=0.2, length=0.8, part="lead2")
    s.bassline(bass_saw, ch, [(k * 0.5, 0.5, "8" if k in (2, 6) else ("5" if k == 7 else "R")) for k in range(8)],
               0.22, lo=36, length=0.85)
    s.arp(chip, ch, [0, 1, 2, 3, 2, 1, 2, 1], 0.5, 52, 0.11, -0.3, rev=0.2, length=0.6, part="ostinato")
    s.pads(ch, 52, 67, 0.17, bright=1000.0)
    for bar in range(24):
        b0 = bar * 4.0
        fill = bar in (7, 15, 23)
        s.hit(kick(), [b0, b0 + 1, b0 + 2, b0 + 3] if not fill else [b0, b0 + 1], 0.40)
        s.hit(kick(), [b0 + 2.75], 0.22)
        if bar % 8 == 0:
            s.hit(crash(), [b0], 0.12, 0.3, rev=0.3)
        if not fill:
            s.hit(snare(), [b0 + 1, b0 + 3], 0.28, rev=0.15)
            step = 0.25 if bar >= 16 else 0.5
            s.hit(hat(), [b0 + k * step for k in range(int(4 / step))], 0.045, 0.3)
        else:
            s.hit(snare(), [b0 + 1], 0.28, rev=0.15)
            for k, f in enumerate((240, 240, 200, 200, 160, 160, 120, 120)):
                s.hit(tom(f), [b0 + 2 + k * 0.25], 0.22 + 0.015 * k, -0.4 + 0.1 * k, rev=0.2)
    return [s.finish("boss")]


def track_victory():
    """Victory: C major, 4/4, 126 bpm, 16 bars (30.5 s). A fanfare tune on brass doubled by a
    flute, lute off-beat strums, a root-fifth bass in quarters, a brassy pad, a march beat with
    crashes and rolls."""
    s = Song(126, 4, 16, seed=7, room=0.75, damp=0.45, wet=0.5)
    ch = s.chords("C | G/B | Am | F | C/G | F | Dm | G | F | G | Em | Am | F | G | Am:2 F:2 | Gsus4:2 G:2")
    mel = s.line("G4:0.5 C5 E5 G5 C6:1.5 G5:0.5 | B5:1 A5:0.5 G5 D5:2 | C6:1 B5:0.5 A5 E5:1 A5 | "
                 "A5:1.5 G5:0.5 F5:1 C5 | E5:0.5 G5 C6:1 E6:1.5 D6:0.5 | C6:1 A5 F5 A5 | D6:1 C6:0.5 A5 F5:1 D5 | "
                 "B5:1 D6 G5:2 | A5:1.5 G5:0.5 F5:1 A5 | B5:1.5 A5:0.5 G5:1 D6 | G5:1 B5 E6:1.5 D6:0.5 | "
                 "C6:1 B5:0.5 A5 E5:2 | F5:0.5 A5 C6:1 A5 C6 | D6:1 B5 G5 B5 | C6:1 E6 C6 A5 | C6:1 D6 B5 G5", 0)
    s.play(brass, mel, 0.26, 0.0, rev=0.2, length=0.92, part="lead")
    s.play(flute, mel, 0.11, 0.15, rev=0.25, length=0.92, part="lead2")
    s.strum(lute, ch, [0.5, 1.5, 2.5, 3.5], 52, 0.15, pan=-0.3, rev=0.25)
    s.bassline(bass, ch, [(0, 1, "R"), (1, 1, "5"), (2, 1, "8"), (3, 1, "5")], 0.18)
    s.pads(ch, 55, 69, 0.17, bright=1500.0)
    for bar in range(16):
        b0 = bar * 4.0
        s.hit(kick(), [b0, b0 + 2], 0.5)
        s.hit(snare(), [b0 + 1, b0 + 3], 0.3, rev=0.15)
        s.hit(hat(), [b0 + k * 0.5 for k in range(8)], 0.07, 0.25)
        if bar % 8 == 0:
            s.hit(crash(), [b0], 0.12, 0.3, rev=0.3)
            s.hit(tom(90), [b0], 0.25, rev=0.3)
        if bar % 4 == 3:
            s.hit(snare(), [b0 + 3.5, b0 + 3.75], 0.16, rev=0.15)
    return [s.finish("victory")]


# --- Sound effects (each returns mono samples) ------------------------------------------------

def sfx_jump():
    n = sec(0.22)
    f = glide(n, [(0, 260), (0.16, 640), (0.22, 700)])
    x = mix((0.6, osc("square", f, n, 4000)), (0.5, osc("tri", [v * 0.5 for v in f], n, 4000)))
    return lowpass(vmul(x, adsr(n, 0.004, 0.12, 0.3, 0.06, 0.16)), 5000)


def sfx_land():
    n = sec(0.2)
    thud = vmul(osc("sine", glide(n, [(0, 140), (0.12, 50)]), n), env_exp(n, 0.16))
    dust = vmul(norm(lowpass(lowpass(noise(n, 1), 900), 900)), env_exp(n, 0.09))
    return mix((1.0, thud), (0.6, dust))


def sfx_step():
    n = sec(0.13)
    rng = random.Random(2)
    grains = [v * (1.0 if rng.random() < 0.3 else 0.25) for v in noise(n, 3)]
    crunch = norm(highpass(lowpass(grains, 2500), 300))
    thump = vmul(osc("sine", glide(n, [(0, 95), (0.06, 60)]), n), env_exp(n, 0.06))
    return mix((0.8, vmul(crunch, env_exp(n, 0.09, 0.004))), (0.4, thump))


def sfx_swing():
    n = sec(0.3)
    fc = glide(n, [(0, 450), (0.12, 3200), (0.3, 900)])
    x = norm(svf(noise(n, 4), fc, 1.4, "bp"))
    return vmul(x, [v * v for v in env_lin(n, [(0, 0), (0.1, 1), (0.3, 0)])])


def sfx_slash_hit():
    n = sec(0.32)
    body = vmul(osc("sine", glide(n, [(0, 210), (0.15, 70)]), n), env_exp(n, 0.2))
    thwack = vmul(norm(lowpass(lowpass(noise(n, 5), 1400), 1400)), env_exp(n, 0.1))
    crack = vmul(norm(lowpass(svf(noise(n, 6), 3500, 0.8, "hp"), 9000)), env_exp(n, 0.025, 0.0005))
    return soft_clip(norm(mix((1.0, body), (0.8, thwack), (0.45, crack)), 1.4), 0.7, 1.0)


def sfx_enemy_hurt():
    n = sec(0.24)
    f = [v * (1 + 0.03 * math.sin(TAU * 28 * i / SR)) for i, v in enumerate(glide(n, [(0, 620), (0.05, 1250), (0.24, 520)]))]
    x = mix((0.7, osc("square", f, n, 4000)), (0.5, osc("tri", f, n, 4000)))
    x = mix((1.0, svf(x, 1800, 1.2, "bp")), (0.3, x))
    return lowpass(vmul(x, adsr(n, 0.005, 0.08, 0.6, 0.06, 0.18)), 5000)


def sfx_enemy_defeat():
    n = sec(0.55)
    pop = vmul(osc("sine", glide(n, [(0, 700), (0.03, 300)]), n), env_exp(n, 0.05))
    poof = vmul(norm(svf(noise(n, 7), glide(n, [(0, 2500), (0.4, 250)]), 0.8, "lp")), env_exp(n, 0.35, 0.005))
    fall = vmul(osc("tri", glide(n, [(0, 900), (0.45, 140)]), n, 4000), adsr(n, 0.005, 0.1, 0.7, 0.1, 0.42))
    return mix((0.7, pop), (0.9, poof), (0.55, fall))


def sfx_stomp():
    n = sec(0.28)
    thud = vmul(osc("sine", glide(n, [(0, 180), (0.1, 55)]), n), env_exp(n, 0.18))
    squash = vmul(norm(lowpass(noise(n, 8), 1500)), env_exp(n, 0.06))
    m = sec(0.2)
    boing = vmul(osc("square", glide(m, [(0, 220), (0.12, 520)]), m, 3000), adsr(m, 0.005, 0.08, 0.5, 0.06, 0.12))
    return mix((1.0, thud), (0.6, squash), (0.35, lowpass(boing, 3500), 0.03))


def sfx_hero_hurt():
    n = sec(0.32)
    src = osc("saw", glide(n, [(0, 240), (0.2, 160)]), n, 5000)
    voice = mix((1.0, svf(src, 550, 4.0, "bp")), (0.6, svf(src, 950, 5.0, "bp")), (0.2, svf(src, 2400, 6.0, "bp")))
    voice = vmul(norm(voice), adsr(n, 0.01, 0.1, 0.7, 0.07, 0.17))
    impact = mix((1.0, vmul(norm(lowpass(noise(n, 9), 1000)), env_exp(n, 0.08))),
                 (0.8, vmul(osc("sine", glide(n, [(0, 120), (0.1, 60)]), n), env_exp(n, 0.12))))
    return mix((1.0, voice), (0.6, impact))


def _sad_voice(m, dur, bend=0.03):
    n = sec(dur + 0.12)
    f = hz(m)
    fr = [v * (1 - bend * min(1.0, i / max(1, sec(dur)))) for i, v in enumerate(vib_freqs(f, n, 6.0, 0.012, 0.1, 0.15))]
    x = mix((0.65, osc("tri", fr, n, 5000)), (0.35, osc("square", fr, n, 3000)))
    return vmul(lowpass(x, 4000), adsr(n, 0.01, 0.15, 0.75, 0.12, dur))


def _with_reverb(x, wet, room=0.7, extra=0.6):
    x = list(x) + [0.0] * sec(extra)
    wl, wr = reverb(x, room, 0.5)
    return [a + wet * 0.5 * (b + c) for a, b, c in zip(x, wl, wr)]


def sfx_hero_death():
    parts = [(1.0, _sad_voice(note(nm), d), t) for nm, t, d in (("G4", 0.0, 0.2), ("F#4", 0.24, 0.2), ("F4", 0.48, 0.2), ("E4", 0.72, 0.55))]
    return _with_reverb(mix(*parts), 0.3, extra=0.15)


def sfx_coin():
    n1, n2 = sec(0.08), sec(0.4)
    a = vmul(mix((0.5, osc("square", hz(note("B5")), n1, 6000)), (0.6, osc("sine", hz(note("B5")), n1))), adsr(n1, 0.002, 0.05, 0.8, 0.01, 0.07))
    b = vmul(mix((0.5, osc("square", hz(note("E6")), n2, 6000)), (0.6, osc("sine", hz(note("E6")), n2))), env_exp(n2, 0.38))
    return lowpass(mix((1.0, a), (1.0, b, 0.07)), 7000)


def sfx_shard():
    parts = [(1.0, bell(note(nm), 0.2), i * 0.055) for i, nm in enumerate(("A5", "C#6", "E6", "A6", "C#7", "E7"))]
    n = sec(0.8)
    rng = random.Random(10)
    trem = lowpass([rng.random() for _ in range(n)], 40)
    sparkle = vmul(vmul(norm(lowpass(svf(noise(n, 11), 6000, 0.7, "hp"), 11000)), trem), env_lin(n, [(0, 0), (0.15, 1), (0.8, 0)]))
    return _with_reverb(mix(*parts, (0.12, sparkle))[:sec(0.8)], 0.35, extra=0.1)


def sfx_heart():
    n = sec(0.7)
    parts = []
    for i, nm in enumerate(("C5", "E5", "G5", "C6")):
        m = sec(0.6 - i * 0.08)
        f = glide(m, [(0, hz(note(nm)) * 0.985), (0.1, hz(note(nm)))])
        parts.append((0.5, vmul(mix((0.7, osc("sine", f, m)), (0.4, osc("tri", f, m, 4000))), adsr(m, 0.02, 0.2, 0.6, 0.25, m / SR - 0.25)), i * 0.08))
    swell = vmul(mix((0.5, osc("sine", hz(note("C4")), n)), (0.3, osc("sine", hz(note("G4")), n))), env_lin(n, [(0, 0), (0.3, 1), (0.7, 0)]))
    return _with_reverb(mix(*parts, (0.6, swell)), 0.25, extra=0.15)


def sfx_checkpoint():
    p = pad(tuple(note(nm) for nm in ("C4", "G4", "B4", "D5", "E5")), 0.5, "tri", 2000.0)
    chord = [a + b for a, b in zip(*p)]
    harps = [(0.5, harp(note(nm), 0.6), 0.05 + i * 0.08) for i, nm in enumerate(("C4", "E4", "G4", "B4", "D5", "G5"))]
    x = _with_reverb(mix((1.0, chord), *harps, (0.25, bell(note("G6"), 0.3), 0.5)), 0.4, extra=0.0)
    return fade(x[:sec(1.3)], 0.002, 0.3)


def sfx_ui_move():
    n = sec(0.05)
    return lowpass(mix((1.0, vmul(osc("sine", 1500, n), env_exp(n, 0.03, 0.001))), (0.3, vmul(norm(lowpass(noise(n, 12), 4000)), env_exp(n, 0.005, 0.0005)))), 6000)


def _blip(notes, wave_="square"):
    parts = []
    for nm, t, d in notes:
        n = sec(d + 0.03)
        f = hz(note(nm))
        parts.append((1.0, vmul(mix((0.5, osc(wave_, f, n, 4000)), (0.6, osc("sine", f, n))), adsr(n, 0.003, 0.05, 0.7, 0.03, d)), t))
    return lowpass(mix(*parts), 5000)


def sfx_ui_select():
    return _blip((("A5", 0.0, 0.05), ("E6", 0.05, 0.09)))


def sfx_ui_back():
    return _blip((("E5", 0.0, 0.05), ("A4", 0.05, 0.09)))


def sfx_ui_toggle():
    def tick(f, s):
        n = sec(0.04)
        return vmul(mix((1.0, osc("tri", glide(n, [(0, f * 1.3), (0.01, f)]), n, 4000)), (0.4, norm(lowpass(noise(n, s), 3000)))), env_exp(n, 0.03, 0.0005))
    return lowpass(mix((0.8, tick(700, 13)), (1.0, tick(1050, 14), 0.04)), 6000)


def sfx_pause():
    return lowpass(mix((1.0, bell(note("E6"), 0.1)), (1.0, bell(note("B5"), 0.2), 0.12))[:sec(0.5)], 6000)


def sfx_dialogue_blip():
    n = sec(0.055)
    src = osc("saw", glide(n, [(0, 320), (0.055, 290)]), n, 4000)
    x = mix((1.0, svf(src, 800, 3.0, "bp")), (0.5, svf(src, 1400, 4.0, "bp")))
    return vmul(x, [math.sin(math.pi * i / n) ** 2 for i in range(n)])


def _roar(n, pts, vib=0.05, seed=20):
    f = [v * (1 + vib * math.sin(TAU * 7 * i / SR)) for i, v in enumerate(glide(n, pts))]
    src = osc("saw", f, n, 4000)
    rough = norm(lowpass(lowpass(noise(n, seed), 60), 60))
    src = [v * (0.65 + 0.35 * r) for v, r in zip(src, rough)]
    voice = mix((1.0, svf(src, 450, 3.0, "bp")), (0.7, svf(src, 800, 4.0, "bp")), (0.35, svf(src, 1300, 5.0, "bp")))
    breath = norm(svf(noise(n, seed + 1), 900, 1.0, "bp"))
    return mix((1.0, norm(voice)), (0.3, breath))


def sfx_boss_roar():
    n = sec(1.25)
    x = vmul(_roar(n, [(0, 85), (0.25, 105), (0.9, 90), (1.25, 70)]), env_lin(n, [(0, 0), (0.15, 1), (0.85, 0.85), (1.25, 0)]))
    return lowpass(soft_clip(norm(x, 1.5), 0.7, 1.0), 3500)


def _slam(n, seed=30):
    boom = vmul(osc("sine", glide(n, [(0, 90), (0.5, 32)]), n), env_exp(n, 0.9))
    rumble = vmul(norm(lowpass(lowpass(noise(n, seed), 250), 250)), env_exp(n, 1.0, 0.01))
    crack = vmul(norm(lowpass(noise(n, seed + 1), 3500)), env_exp(n, 0.05, 0.0005))
    return soft_clip(norm(mix((1.0, boom), (0.6, rumble), (0.5, crack)), 1.4), 0.7, 1.0)


def sfx_boss_slam():
    return _slam(sec(1.0))


def sfx_boss_charge():
    n = sec(0.6)
    env = env_lin(n, [(0, 0), (0.45, 1), (0.6, 0)])
    snort = norm(svf(noise(n, 40), glide(n, [(0, 400), (0.6, 2600)]), 1.2, "bp"))
    grunt = norm(svf(osc("saw", glide(n, [(0, 80), (0.6, 190)]), n, 3000), 700, 2.0, "bp"))
    return vmul(mix((1.0, snort), (0.6, grunt)), env)


def sfx_boss_defeat():
    n = sec(2.0)
    roar = vmul(_roar(n, [(0, 130), (1.9, 38)], 0.04, 50), env_lin(n, [(0, 0), (0.1, 1), (1.2, 0.7), (2.0, 0)]))
    x = mix((1.0, _slam(sec(1.0), 60)), (0.8, lowpass(roar, 3000), 0.1))
    return _with_reverb(x, 0.3, room=0.8, extra=0.2)


def sfx_bee_buzz():
    n = sec(0.4)
    rng = random.Random(70)
    jitter = lowpass([rng.uniform(-1, 1) for _ in range(n)], 30)
    f = [210 * (1 + 0.04 * math.sin(TAU * 9 * i / SR) + 0.1 * j) for i, j in enumerate(jitter)]
    src = osc("saw", f, n, 5000)
    x = mix((1.0, svf(src, 1200, 1.0, "bp")), (0.4, lowpass(src, 3000)))
    return vmul(x, env_lin(n, [(0, 0), (0.06, 1), (0.32, 1), (0.4, 0)]))


def _creak(n, pts, seed, bands=((1100, 6.0, 1.0),)):
    """Wood creak: a jittered click train at the rate glide `pts`, through wood resonances."""
    rng = random.Random(seed)
    rate = glide(n, pts)
    clicks, ph = [0.0] * n, 0.0
    for i in range(n):
        ph += rate[i] / SR
        if ph >= 1.0:
            ph -= 1.0 + rng.uniform(-0.15, 0.15)
            clicks[i] = rng.uniform(0.5, 1.0)
    return norm(mix(*[(g, svf(clicks, f, q, "bp")) for f, q, g in bands]))


def sfx_platform():
    n = sec(0.4)
    clunk = mix((1.0, pluck(110, 0.15, 0.15, 0.3, 80, 0.1)), (0.8, vmul(osc("sine", glide(n, [(0, 150), (0.1, 100)]), n), env_exp(n, 0.12))))
    m = sec(0.3)
    creak = vmul(_creak(m, [(0, 90), (0.3, 60)], 81), [math.sin(math.pi * i / m) for i in range(m)])
    return mix((1.0, norm(clunk)), (0.5, creak, 0.08))


def sfx_gate_open():
    chime = mix((1.0, bell(note("C6"), 0.2)), (0.8, bell(note("G6"), 0.3), 0.07))
    m = sec(0.75)
    creak = vmul(_creak(m, [(0, 50), (0.35, 110), (0.75, 70)], 90, ((900, 5.0, 1.0), (1700, 6.0, 0.5))),
                 env_lin(m, [(0, 0), (0.1, 1), (0.6, 0.9), (0.75, 0)]))
    n = sec(0.3)
    clunk = mix((1.0, pluck(90, 0.1, 0.2, 0.3, 91, 0.15)), (0.8, vmul(osc("sine", glide(n, [(0, 120), (0.1, 70)]), n), env_exp(n, 0.2))))
    x = mix((0.5, chime[:sec(0.9)]), (0.6, creak, 0.15), (0.8, norm(clunk), 0.88))
    return _with_reverb(x, 0.2, extra=0.1)


def _bubble(f0, f1, dur, seed=0):
    """A water bubble: a sine gliding up, quickly dying."""
    n = sec(dur)
    return vmul(osc("sine", glide(n, [(0, f0), (dur, f1)]), n), env_exp(n, dur * 0.9, 0.002))


def sfx_splash():
    n = sec(0.7)
    wash = vmul(norm(svf(noise(n, 200), glide(n, [(0, 4000), (0.6, 600)]), 0.7, "lp")),
                env_lin(n, [(0, 0), (0.02, 1), (0.15, 0.6), (0.7, 0)]))
    plop = _bubble(250, 700, 0.12)
    rng = random.Random(201)
    drops = [(0.25 * rng.uniform(0.5, 1.0), _bubble(f, f * 1.8, 0.06), rng.uniform(0.1, 0.55))
             for f in (rng.uniform(600, 1400) for _ in range(7))]
    return lowpass(mix((1.0, wash), (0.7, plop), *drops), 6000)


def sfx_pot_break():
    n = sec(0.55)
    thud = vmul(osc("sine", glide(n, [(0, 220), (0.08, 150)]), n), env_exp(n, 0.12))
    crack = vmul(norm(lowpass(noise(n, 210), 5000)), env_exp(n, 0.03, 0.0005))
    rng = random.Random(211)
    shards = []
    for k in range(9):
        m = sec(0.08)
        f = rng.uniform(1800, 4200)
        shards.append((rng.uniform(0.25, 0.6), vmul(norm(svf(noise(m, 212 + k), f, 8.0, "bp")), env_exp(m, 0.06, 0.0005)),
                       0.01 + rng.uniform(0, 0.35) * (k / 9 + 0.2)))
    return lowpass(mix((0.8, thud), (0.7, crack), *shards), 8000)


def sfx_boss_stun():
    n = sec(0.8)
    thud = mix((1.0, vmul(osc("sine", glide(n, [(0, 90), (0.2, 40)]), n), env_exp(n, 0.35))),
               (0.5, vmul(norm(lowpass(lowpass(noise(n, 220), 400), 400)), env_exp(n, 0.2, 0.003))))
    birds = []
    for k, (t, f) in enumerate(((0.12, 1900), (0.3, 2200), (0.46, 1800), (0.6, 2100))):
        m = sec(0.14)
        fr = [v * (1 + 0.04 * math.sin(TAU * 22 * i / SR)) for i, v in enumerate(glide(m, [(0, f), (0.06, f * 1.25), (0.14, f * 0.95)]))]
        tone = mix((0.8, osc("sine", fr, m)), (0.2, osc("tri", fr, m, 6000)))
        birds.append((0.22, vmul(tone, [math.sin(math.pi * i / m) ** 2 for i in range(m)]), t))
    return lowpass(mix((1.0, thud), *birds), 6000)


def sfx_saved():
    x = mix((1.0, bell(note("G5"), 0.1)), (0.9, bell(note("D6"), 0.2), 0.09))
    return fade(lowpass(x[:sec(0.55)], 6000), 0.002, 0.2)


def _jingle(bpm, beats, extra, build):
    s = Song(bpm, 1, beats, seed=bpm, room=0.75, damp=0.45, wet=0.35, loop=False, extra=extra)
    build(s)
    left, right = s.finish()
    return [0.5 * (a + b) for a, b in zip(left, right)]


def sfx_level_complete():
    def build(s):
        ch = [Chord("C", 0, 2), Chord("F", 2, 1), Chord("G", 3, 1), Chord("C", 4, 2)]
        mel = [(t * 0.5, note(nm), 0.5) for t, nm in enumerate(("C5", "E5", "G5", "E5", "F5", "A5", "G5", "B5"))] + [(4, note("C6"), 2)]
        s.play(brass, mel, 0.3, rev=0.2, length=0.9)
        s.play(flute, mel, 0.12, rev=0.2, length=0.9)
        s.pads(ch, 55, 69, 0.08, bright=1500.0)
        s.arp(harp, ch, [0, 1, 2, 3], 0.25, 48, 0.12, rev=0.3, length=3)
        s.bassline(bass, ch, [(0, 1, "R")], 0.3)
        s.hit(tom(140), [3, 3.5], 0.25)
        s.hit(kick(), [4], 0.4)
        s.hit(crash(), [4], 0.15, rev=0.3)
    return _jingle(150, 6, 0.4, build)


def sfx_game_over():
    def build(s):
        ch = [Chord("Am", 0, 0.8), Chord("Dm", 0.8, 0.4), Chord("E", 1.2, 0.6), Chord("Am", 1.8, 1.2)]
        mel = [(0, note("E5"), 0.4), (0.4, note("C5"), 0.4), (0.8, note("D5"), 0.4), (1.2, note("B4"), 0.6), (1.8, note("A4"), 1.0)]
        s.play(flute, mel, 0.3, rev=0.35, length=0.95)
        s.pads(ch, 52, 67, 0.08, "tri", 1100.0)
        s.play(harp, [(c.start, bass_note(c, 45), 1.0) for c in ch], 0.25, rev=0.3, length=1.5)
        s.play(bass_soft, [(c.start, bass_note(c, 33), c.dur) for c in ch], 0.25, rev=0.1)
    return _jingle(60, 3, 0.3, build)


def sfx_victory():
    def build(s):
        ch = [Chord("G", 0, 1), Chord("C", 1, 4), Chord("F", 5, 1), Chord("G", 6, 2), Chord("C", 8, 2)]
        mel = [(0, "G4", 1 / 3), (1 / 3, "G4", 1 / 3), (2 / 3, "G4", 1 / 3), (1, "C5", 1.5), (2.5, "E5", 0.5), (3, "G5", 1),
               (4, "E5", 0.5), (4.5, "G5", 0.5), (5, "A5", 0.5), (5.5, "G5", 0.5), (6, "F5", 0.5), (6.5, "D5", 0.5),
               (7, "G5", 0.5), (7.5, "B5", 0.5), (8, "C6", 2)]
        mel = [(t, note(nm), d) for t, nm, d in mel]
        s.play(brass, mel, 0.3, rev=0.2, length=0.92)
        s.play(flute, mel, 0.1, rev=0.2, length=0.92)
        s.play(brass, harmony(mel[3:], ch), 0.14, rev=0.2, length=0.92)
        s.pads(ch[1:], 55, 69, 0.08, bright=1500.0)
        s.strum(lute, ch[1:], [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], 52, 0.05, rev=0.25)
        s.bassline(bass, ch[1:], [(0, 1, "R"), (1, 1, "5"), (2, 1, "8"), (3, 1, "5")], 0.32)
        s.hit(snare(), [k / 3 for k in range(3)], 0.18)
        s.hit(kick(), [1, 3, 5, 7, 8], 0.35)
        s.hit(snare(), [2, 4, 6, 7.5, 7.75], 0.2)
        s.hit(crash(), [1, 8], 0.14, rev=0.3)
        s.hit(tom(90), [8], 0.3, rev=0.3)
    return _jingle(120, 10, 0.6, build)


SFX = [name[4:] for name in list(globals()) if name.startswith("sfx_")]
# What the demo ships of them (the others come from GameSounds: pick_sounds.py)
SHIPPED_SFX = ["bee_buzz"]
MUSIC = {"forest": track_forest, "caves": track_caves, "title": track_title, "boss": track_boss, "victory": track_victory}
LAYERS = {"forest": ("forest_base", "forest_drums"), "caves": ("caves_base", "caves_drums")}


# --- Files ------------------------------------------------------------------------------------

def write_wav(path, chans):
    """Writes 16-bit PCM (channels of floats in [-1, 1])."""
    def pcm(x):
        return array("h", [int(v * 32767.0 + (0.5 if v >= 0 else -0.5)) for v in (min(1.0, max(-1.0, u)) for u in x)])
    if len(chans) == 1:
        data = pcm(chans[0])
    else:
        data = array("h", bytes(2 * len(chans) * len(chans[0])))
        for i, c in enumerate(chans):
            data[i::len(chans)] = pcm(c)
    if sys.byteorder == "big":
        data.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(len(chans))
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def encode(wav_path, out_path, quality):
    """Encodes to Ogg Vorbis next to `out_path`, then renames it into place (bit-exact output:
    no random stream serial, no encoder tag)."""
    tmp = out_path + ".part"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav_path, "-map_metadata", "-1", "-c:a", "libvorbis",
                    "-q:a", str(quality), "-fflags", "+bitexact", "-flags:a", "+bitexact", "-f", "ogg", tmp], check=True)
    os.replace(tmp, out_path)


def run_job(kind, names, tmp, out):
    """Renders and encodes music tracks or sound effects (in a worker process)."""
    _memo.clear()
    done = []
    for name in names:
        t0 = time.time()
        if kind == "sfx":
            x = fade(globals()["sfx_" + name]())
            files = [(name, [norm(x, PEAK)])]
        else:
            layers = MUSIC[name]()
            # One gain for every layer: the layers' sum peaks at -1 dBFS.
            total = [sum(v) for v in zip(*[l[0] for l in layers])] if len(layers) > 1 else layers[0][0]
            total_r = [sum(v) for v in zip(*[l[1] for l in layers])] if len(layers) > 1 else layers[0][1]
            g = PEAK / max(peak(total), peak(total_r))
            del total, total_r
            files = [(fname, [scale(l[0], g), scale(l[1], g)]) for fname, l in zip(LAYERS.get(name, (name,)), layers)]
        for fname, chans in files:
            wav = os.path.join(tmp, f"{kind}_{fname}.wav")
            write_wav(wav, chans)
            folder = os.path.join(out, "sfx" if kind == "sfx" else "music")
            encode(wav, os.path.join(folder, fname + ".ogg"), SFX_QUALITY if kind == "sfx" else MUSIC_QUALITY)
            done.append((kind, fname, time.time() - t0))
        _memo.clear()
    return done


# --- Checks -----------------------------------------------------------------------------------

def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=channels,sample_rate,codec_name:format=duration", "-of", "default=nw=1", path],
                       capture_output=True, text=True, check=True)
    return dict(line.split("=", 1) for line in r.stdout.split())


def decode(path, channels):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                       capture_output=True, check=True)
    a = array("f")
    a.frombytes(r.stdout)
    if sys.byteorder == "big":
        a.byteswap()
    return [a[c::channels] for c in range(channels)]


def seam(chans):
    """How big the jump from the last sample to the first is against the local slope (the mean
    |difference| of the 64 samples each side): about 1 is seamless, a click is much more."""
    worst = 0.0
    for x in chans:
        local = [abs(x[i + 1] - x[i]) for i in range(-65, -1)] + [abs(x[i + 1] - x[i]) for i in range(64)]
        slope = sum(local) / len(local)
        worst = max(worst, abs(x[0] - x[-1]) / max(slope, 1e-4))
    return worst


def check(out):
    """Decodes every file back and prints the summary table; returns False on a problem."""
    ok = True
    rows, counts = [], {}
    print(f"\n{'file':26} {'codec':7} {'ch':>2} {'rate':>6} {'seconds':>8} {'samples':>9} {'KB':>6} {'peak dB':>8} {'seam':>6}")
    for kind, names in (("sfx", SFX), ("music", [f for k in MUSIC for f in LAYERS.get(k, (k,))])):
        for name in names:
            path = os.path.join(out, kind, name + ".ogg")
            info = probe(path)
            chs = int(info["channels"])
            chans = decode(path, chs)
            n = len(chans[0])
            counts[name] = n
            pk = max(peak(c) for c in chans)
            pk_db = 20 * math.log10(pk) if pk > 0 else -120.0
            sm = seam(chans) if kind == "music" else None
            bad = (int(info["sample_rate"]) != SR or chs != (1 if kind == "sfx" else 2) or pk >= 1.0
                   or (sm is not None and sm > 4.0))
            ok &= not bad
            print(f"{kind + '/' + name + '.ogg':26} {info['codec_name']:7} {chs:>2} {info['sample_rate']:>6} "
                  f"{float(info['duration']):8.3f} {n:>9} {os.path.getsize(path) / 1024:6.0f} {pk_db:8.2f} "
                  f"{'' if sm is None else f'{sm:6.2f}'}{'  <-- check' if bad else ''}")
    for a, b in LAYERS.values():
        same = counts[a] == counts[b]
        ok &= same
        pa, pb = (decode(os.path.join(out, "music", f + ".ogg"), 2) for f in (a, b))
        both = max(peak([u + v for u, v in zip(x, y)]) for x, y in zip(pa, pb)) if same else 0.0
        ok &= both < 1.0
        print(f"layers {a} / {b}: {counts[a]} / {counts[b]} samples {'(identical)' if same else '<-- DIFFER'}, "
              f"together peak {20 * math.log10(max(both, 1e-9)):.2f} dB")
    size = sum(os.path.getsize(os.path.join(out, k, f)) for k in ("sfx", "music") for f in os.listdir(os.path.join(out, k)) if f.endswith(".ogg"))
    print(f"total: {size / 1024 / 1024:.2f} MB")
    return ok


def main():
    global SFX
    args = [a for a in sys.argv[1:] if a != "--all-sfx"]
    if "--all-sfx" not in sys.argv[1:]:
        SFX = SHIPPED_SFX
    out = os.path.abspath(args[0]) if args else DEFAULT_OUT
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"make_sounds: {tool} is needed (install ffmpeg, with libvorbis)")
    enc = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    if "libvorbis" not in enc:
        sys.exit("make_sounds: this ffmpeg has no libvorbis encoder (needed for Ogg Vorbis)")
    for k in ("sfx", "music"):
        os.makedirs(os.path.join(out, k), exist_ok=True)
    t0 = time.time()
    tmp = tempfile.mkdtemp(prefix="make_sounds_")
    try:
        jobs = [("music", [name]) for name in MUSIC] + [("sfx", SFX[i::3]) for i in range(3)]
        with ProcessPoolExecutor(max_workers=min(WORKERS, os.cpu_count() or 1)) as ex:
            futures = [ex.submit(run_job, kind, names, tmp, out) for kind, names in jobs]
            for f in futures:
                for kind, name, t in f.result():
                    print(f"made {kind}/{name}.ogg ({t:.1f} s)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"rendered in {time.time() - t0:.0f} s")
    if not check(out):
        sys.exit("make_sounds: some files failed the checks (marked above)")


if __name__ == "__main__":
    main()
