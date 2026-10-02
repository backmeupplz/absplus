#!/usr/bin/env python3
"""Soundtrack for the ABS+ promo, synthesized from scratch (no samples) and seeded, so every run
writes the same out/music.wav. 120 BPM, so a bar is 2 s; the scenes in index.html start on these bars.

Bars (0-based): 0-1 intro build · 2-13 groove (drop at 4 s) · 14-15 stop-time hits (4 MB, privacy)
· 16 build · 17-18 final groove · 19 last chord.
"""
import os
import wave

import numpy as np
from scipy import signal
from scipy.ndimage import minimum_filter1d

SR = 48000
BEAT = 0.5
BAR = 4 * BEAT
BARS = 20
N = int(BARS * BAR * SR)
rng = np.random.default_rng(7)

# one chord per bar, "Bb|C" splits the bar in half
CHORDS = "Bb C F C Dm Bb F C Dm Bb F C Dm Bb F Dm Bb|C F Bb|C F".split()
PAD = {"F": [57, 60, 65, 69], "C": [55, 60, 64, 67], "Dm": [57, 62, 65, 69], "Bb": [58, 62, 65, 70]}
ROOT = {"F": 41, "C": 36, "Dm": 38, "Bb": 34}
# pluck arpeggio on the 3-3-3-3-2-2 sixteenth rhythm; B is the brighter second half
ARP_STEPS = [0, 3, 6, 9, 12, 14]
ARP_A = {"F": [72, 69, 72, 77, 76, 72], "C": [72, 67, 72, 76, 74, 72], "Dm": [74, 69, 74, 77, 76, 74], "Bb": [74, 70, 74, 77, 74, 72]}
ARP_B = {"F": [77, 72, 77, 81, 79, 77], "C": [76, 72, 76, 79, 77, 76], "Dm": [77, 74, 77, 81, 79, 77], "Bb": [77, 74, 77, 82, 81, 79]}
# lead: (beat, length in beats, note)
LEAD = {
    "F": [(0, 1, 81), (1.5, .5, 79), (2, 1.5, 77), (3.5, .5, 79)],
    "C": [(0, 1.5, 76), (1.5, .5, 74), (2, 2, 72)],
    "Dm": [(0, 1, 74), (1, .5, 76), (1.5, .5, 77), (2, 1.5, 81), (3.5, .5, 79)],
    "Bb": [(0, 1.5, 77), (1.5, .5, 74), (2, 2, 77)],
    "Bb|C": [(0, 1, 77), (1, 1, 74), (2, 1, 76), (3, 1, 79)],
    "end": [(0, 4, 81)],
}

GROOVE = list(range(2, 14)) + [17, 18]
STABS = [14, 15]
ARP = {b: ARP_A for b in [0, 1, *range(2, 10), 16]} | {b: ARP_B for b in [*range(10, 14), 17, 18]}
LEAD_BARS = [*range(10, 14), 17, 18, 19]
DROPS = [4.0, 28.0, 34.0]
CRASHES = [4.0, 12.0, 20.0, 28.0, 34.0, 38.0]
WHOOSHES = [8.0, 12.0, 16.0, 20.0, 24.0, 30.0]  # scene changes that aren't drops
RISERS = [(2.0, 3.875), (26.0, 28.0), (32.0, 33.875)]
ROLLS = [(3.0, 3.875), (27.0, 28.0), (32.0, 33.875)]


def at(t):
    return int(round(t * SR))


def hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def tt(dur):
    return np.arange(at(dur)) / SR


def sos(kind, f, order=2):
    return signal.butter(order, f, kind, fs=SR, output="sos")


def filt(x, kind, f, order=2):
    return signal.sosfilt(sos(kind, f, order), x, axis=-1)


def sweep(x, kind, f0, f1, order=2, block=256):
    """Filter with a cutoff gliding exponentially from f0 to f1 over the length of x."""
    x = np.atleast_2d(x)
    out, zi = np.zeros_like(x), None
    for s in range(0, x.shape[1], block):
        fc = f0 * (f1 / f0) ** (s / x.shape[1])
        c = sos(kind, fc if kind != "bandpass" else [fc / 1.6, fc * 1.6], order)
        if zi is None:
            zi = np.zeros((c.shape[0], x.shape[0], 2))
        out[:, s:s + block], zi = signal.sosfilt(c, x[:, s:s + block], axis=-1, zi=zi)
    return out


def saw(f, n, ph0):
    dt = np.broadcast_to(np.asarray(f, float) / SR, (n,))
    ph = (ph0 + np.cumsum(dt)) % 1.0
    y = 2 * ph - 1
    m = ph < dt  # polyBLEP: round off the reset so the saw doesn't alias
    k = ph[m] / dt[m]
    y[m] -= 2 * k - k * k - 1
    m = ph > 1 - dt
    k = (ph[m] - 1) / dt[m]
    y[m] -= k * k + 2 * k + 1
    return y


def fade(x, ms=12):
    """Short fade at the end of a one-shot, so a cut-off tail can't click."""
    n = min(x.shape[-1], int(SR * ms / 1000))
    x[..., -n:] *= np.linspace(1, 0, n)
    return x


def pan(x, p):
    a = (p + 1) * np.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)])


def add(busx, x, t, g=1.0):
    x = np.atleast_2d(x)
    if x.shape[0] == 1:
        x = np.repeat(x, 2, 0)
    i = at(t)
    if i >= N:
        return
    j = min(N, i + x.shape[1])
    busx[:, i:j] += g * x[:, :j - i]


def bus():
    return np.zeros((2, N))


def chord_at(bar, beat):
    c = CHORDS[bar].split("|")
    return c[0] if len(c) == 1 or beat < 2 else c[1]


# ---------------------------------------------------------------- instruments

def kick():
    t = tt(0.42)
    f = 46 + 120 * np.exp(-t / 0.028) + 60 * np.exp(-t / 0.004)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.2) * np.minimum(1, t / 0.0007)
    click = filt(rng.standard_normal(t.size), "highpass", 2500) * np.exp(-t / 0.003) * 0.3
    y = np.tanh(2.0 * (body + click)) / np.tanh(2.0)
    return y * np.minimum(1, (t[-1] - t) / 0.02)


def clap():
    t = tt(0.45)
    noise = filt(rng.standard_normal((2, t.size)), "bandpass", [900, 7000])
    env = sum(np.where(t >= d, np.exp(-np.clip(t - d, 0, None) / 0.0055), 0) for d in (0, 0.0085, 0.017))
    env = env + np.where(t >= 0.025, np.exp(-np.clip(t - 0.025, 0, None) / 0.1), 0)
    return fade(noise * env)


def snare():
    t = tt(0.22)
    tone = np.sin(2 * np.pi * 200 * t) * np.exp(-t / 0.035)
    noise = filt(rng.standard_normal(t.size), "bandpass", [1200, 9000]) * np.exp(-t / 0.06)
    return fade(0.45 * tone + noise)


METAL = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]  # the 808's six square waves


def metal(t):
    return sum(np.sign(np.sin(2 * np.pi * f * t + i)) for i, f in enumerate(METAL)) / 6


def hat(open_=False):
    t = tt(0.32 if open_ else 0.08)
    x = 0.55 * rng.standard_normal(t.size) + 0.45 * metal(t)
    x = filt(x, "highpass", 6500 if open_ else 8000, 4)
    return fade(x * np.exp(-t / (0.09 if open_ else 0.018)))


def crash(dur=2.6):
    t = tt(dur)
    x = 0.7 * rng.standard_normal((2, t.size)) + 0.3 * metal(t * 1.37)
    x = filt(x, "highpass", 4200, 2)
    return fade(x * np.exp(-t / 0.75) * np.minimum(1, t / 0.002), 60)


def impact():
    t = tt(2.2)
    f = 36 + 60 * np.exp(-t / 0.09)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.65)
    thump = filt(rng.standard_normal(t.size), "lowpass", 180) * np.exp(-t / 0.06) * 3
    return np.tanh(1.4 * (boom + thump))


def riser(dur):
    k = tt(dur) / dur
    x = sweep(rng.standard_normal((2, k.size)), "bandpass", 350, 9000, order=1)
    tone = saw_glide(220, 1760, dur)
    return fade((x / (np.std(x) + 1e-9) + 0.25 * tone) * k ** 2.2)


def saw_glide(f0, f1, dur):
    k = tt(dur) / dur
    f = f0 * (f1 / f0) ** k
    ph = np.cumsum(f) / SR
    return filt(2 * (ph % 1) - 1, "lowpass", 4000)


def whoosh(dur=0.7):
    k = tt(dur) / dur
    x = sweep(rng.standard_normal(k.size), "bandpass", 500, 4500, order=1)[0]
    x = x / (np.std(x) + 1e-9) * np.sin(np.pi * k) ** 2
    a = k * np.pi / 2  # sweep left to right
    return np.stack([x * np.cos(a), x * np.sin(a)])


def pluck(n, dur=0.5):
    t = tt(dur)
    f = hz(n)
    y = np.zeros(t.size)
    for k in range(1, int(min(36, 0.45 * SR / f)) + 1):
        y += (1 if k % 2 else 0.55) / k * np.sin(2 * np.pi * f * k * t + k) * np.exp(-t * (5 + 3.4 * k))
    return y * np.minimum(1, t / 0.0015) * np.minimum(1, (t[-1] - t) / 0.01)


def blip(n):
    t = tt(0.07)
    return (np.sin(2 * np.pi * hz(n) * t) + 0.3 * np.sin(4 * np.pi * hz(n) * t)) * np.exp(-t / 0.025)


def supersaw(notes, dur, detune=0.16):
    n = at(dur)
    offs = [-0.11002313, -0.06288439, -0.01952356, 0, 0.01991221, 0.06216538, 0.10745242]
    out = np.zeros((2, n))
    for note in notes:
        for i, o in enumerate(offs):
            out += pan(saw(hz(note) * (1 + o * detune), n, rng.random()), (i / 3 - 1) * 0.9)
    return out / np.sqrt(len(notes) * len(offs))


def lead_note(n, dur):
    t = tt(dur + 0.25)
    f = hz(n) * (1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.18) / 0.2, 0, 1))
    y = sum(saw(f * d, t.size, r) for d, r in ((1.0, 0.0), (1.006, 0.3), (0.5, 0.6)))  # two saws + sub
    y = filt(y, "lowpass", 3200)
    env = np.minimum(1, t / 0.012) * np.where(t < dur, 1, np.exp(-(t - dur) / 0.07))
    return y * env


def bass_note(n, dur):
    t = tt(dur)
    f = hz(n)
    y = np.sin(2 * np.pi * f * t)  # sub
    for k in range(2, 14):
        if f * k < 5000:
            y += 0.6 / k * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (8 + 6 * k))
    return y * np.minimum(1, t / 0.003) * np.minimum(1, (t[-1] - t) / 0.015)


# ---------------------------------------------------------------- arrangement

STEMS = ["kick", "snare", "hats", "impact", "fx", "bass", "pad", "pluck", "lead"]
st = {k: bus() for k in STEMS}
send = bus()  # reverb send
kick_s, clap_s, chat, ohat, snr, crash_s, imp = kick(), clap(), hat(), hat(True), snare(), crash(), impact()

groove_kicks = [b * BAR + i * BEAT for b in GROOVE for i in range(4)]
for k in groove_kicks + [b * BAR + i * BEAT for b in STABS for i in range(4)] + [19 * BAR]:
    add(st["kick"], kick_s, k)

for b in GROOVE:
    for i in range(4):
        t0 = b * BAR + i * BEAT
        if i % 2:
            add(st["snare"], clap_s, t0)
            add(send, clap_s, t0, 0.8)
        for s, v in ((0, 0.9), (1, 0.5), (3, 0.7)):
            add(st["hats"], pan(chat, 0.25), t0 + s * BEAT / 4, v)
        add(st["hats"], pan(ohat, -0.2), t0 + BEAT / 2)
for b in STABS:
    for i in range(4):
        add(st["snare"], clap_s, b * BAR + i * BEAT, 0.9)
        add(send, clap_s, b * BAR + i * BEAT, 1.2)
for i in range(8):  # intro hats creep in
    add(st["hats"], pan(chat, 0.25), BAR + i * BEAT / 2, 0.15 + 0.06 * i)

for a, b in ROLLS:  # sixteenths, doubling to 32nds near the end
    n = int(round((b - a) / (BEAT / 4)))
    for i in range(n):
        k = i / max(1, n - 1)
        t0 = a + i * BEAT / 4
        for dt in ((0, BEAT / 8) if k >= 0.6 else (0,)):
            add(st["snare"], snr, t0 + dt, 0.15 + 0.6 * k ** 1.5)
            add(send, snr, t0 + dt, 0.4 * k)

for t0 in CRASHES:
    add(st["fx"], crash_s, t0)
    add(send, crash_s, t0, 0.4)
for t0 in DROPS:
    add(st["impact"], imp, t0)
    add(st["fx"], crash(1.2)[:, ::-1] * np.linspace(0, 1, at(1.2)) ** 2, t0 - 1.2, 0.8)  # reverse cymbal
for t0 in WHOOSHES:
    add(st["fx"], whoosh(), t0 - 0.45, 0.25)
for a, b in RISERS:
    r = riser(b - a)
    add(st["fx"], r, a, 0.45)
    add(send, r, a, 0.2)
for i, n in enumerate([77, 79, 81, 84, 86, 89, 91, 93]):  # the 4 MB counter ticking up
    add(st["fx"], pan(blip(n), -0.4 + 0.1 * i), 28.0 + i * BEAT / 8, 0.5)
    add(send, blip(n), 28.0 + i * BEAT / 8, 0.3)

# pad: a supersaw per chord, opened up by a filter in the intro and the build
pad = st["pad"]
for b in range(BARS):
    halves = CHORDS[b].split("|")
    for h, name in enumerate(halves):
        dur = BAR / len(halves)
        t0 = b * BAR + h * dur
        if b in STABS:
            for i in range(4):
                s = supersaw(PAD[name] + [PAD[name][1] + 12], 0.3) * np.exp(-tt(0.3) / 0.11)
                add(pad, filt(s, "lowpass", 6000), b * BAR + i * BEAT, 1.6)
            continue
        hold = 2.2 if b == 19 else dur
        e = tt(hold + 0.04)
        env = np.minimum(1, e / 0.015) * np.minimum(1, (hold + 0.04 - e) / 0.04) * (np.exp(-e / 0.9) if b == 19 else 1)
        add(pad, supersaw(PAD[name], hold + 0.04) * env, t0)
pad[:] = filt(pad, "highpass", 180)
intro, build = slice(0, at(2 * BAR)), slice(at(16 * BAR), at(17 * BAR))
pad[:, intro] = sweep(pad[:, intro], "lowpass", 350, 5000) * np.linspace(0.5, 1, at(2 * BAR))
pad[:, build] = sweep(pad[:, build], "lowpass", 700, 6000)
rest = np.ones(N, bool)
rest[intro] = rest[build] = False
pad[:, rest] = filt(pad[:, rest], "lowpass", 4200)

for b, arp in ARP.items():
    for s, step in enumerate(ARP_STEPS):
        t0 = b * BAR + step * BEAT / 4
        p = pluck(arp[chord_at(b, step / 4)][s])
        g = 0.6 if b < 2 else 1.0
        add(st["pluck"], pan(p, 0.35 if s % 2 else -0.35), t0, g)
        add(send, p, t0, 0.5 * g)
        for e in range(1, 5):  # ping-pong echoes, 3/16 apart
            add(st["pluck"], pan(filt(p, "lowpass", 3500 / e), -0.8 if e % 2 else 0.8), t0 + e * 0.375, g * 0.33 ** e)

lead = st["lead"]
for b in LEAD_BARS:
    for beat, length, n in LEAD["end" if b == 19 else CHORDS[b]]:
        x = lead_note(n, length * BEAT)
        add(lead, x, b * BAR + beat * BEAT)
        add(send, x, b * BAR + beat * BEAT, 0.3)
d = at(0.375)
echo = np.zeros_like(lead)
echo[0, d:] = lead[0, :-d] + lead[1, :-d]
echo[1, 2 * d:] = 0.5 * (lead[0, :-2 * d] + lead[1, :-2 * d])
lead += 0.22 * filt(echo, "lowpass", 2500)

for b in GROOVE:  # offbeat bass, octave up on the last one
    for i in range(4):
        add(st["bass"], bass_note(ROOT[chord_at(b, i)] + (12 if i == 3 else 0), 0.23), b * BAR + i * BEAT + BEAT / 2)
for b in STABS:
    for i in range(4):
        add(st["bass"], bass_note(ROOT[chord_at(b, i)], 0.3) * np.exp(-tt(0.3) / 0.12), b * BAR + i * BEAT)
add(st["bass"], bass_note(ROOT["F"], 2.0) * np.exp(-tt(2.0) / 0.7), 19 * BAR)

# sidechain pump keyed from the groove's kick (not the stabs, which should hit at full level)
duck = np.ones(N)
shape = 1 - (1 - np.minimum(1, tt(BEAT) / 0.3)) ** 2
for k in groove_kicks:
    i = at(k)
    j = min(N, i + shape.size)
    duck[i:j] = np.minimum(duck[i:j], shape[:j - i])
for name, depth in (("pad", 0.75), ("bass", 0.5), ("pluck", 0.3)):
    st[name] *= 1 - depth * (1 - duck)

# gaps right before the drops so they hit harder
for t0 in (4.0, 34.0):
    g = np.ones(N)
    g[at(t0 - 0.125):at(t0)] = 0
    g = np.convolve(g, np.ones(96) / 96, "same")
    for name in ("pad", "pluck", "lead"):
        st[name] *= g


def lufs(x):
    """Integrated loudness per ITU-R BS.1770 (K-weighting, 400 ms blocks, gating)."""
    y = signal.lfilter([1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585], x, axis=-1)
    y = signal.lfilter([1, -2, 1], [1, -1.99004745483398, 0.99007225036621], y, axis=-1)
    w, h = at(0.4), at(0.1)
    z = np.array([(y[:, i:i + w] ** 2).mean(1).sum() for i in range(0, y.shape[1] - w, h)])
    z = z[-0.691 + 10 * np.log10(z + 1e-12) > -70]
    z = z[-0.691 + 10 * np.log10(z + 1e-12) > -0.691 + 10 * np.log10(z.mean()) - 10]
    return -0.691 + 10 * np.log10(z.mean())


def make_ir(rt60=1.8, length=2.8):
    t = tt(length)
    ir = np.zeros((2, t.size))
    for c in range(2):
        noise = rng.standard_normal(t.size)
        lo = filt(noise, "lowpass", 2500)
        ir[c] = lo * np.exp(-6.91 * t / rt60) + 0.5 * (noise - lo) * np.exp(-6.91 * t / (rt60 * 0.4))
    ir[:, :at(0.012)] = 0
    return ir / np.sqrt((ir ** 2).sum(1, keepdims=True))


# mix: every stem is set to a loudness (LUFS while it plays), so the balance doesn't depend on synth gains
LEVELS = {"kick": -17, "snare": -23, "hats": -27, "impact": -22, "fx": -26, "bass": -20, "pad": -22, "pluck": -21, "lead": -21, "verb": -25}
send += 0.3 * st["pad"] / np.abs(st["pad"]).max() + 0.3 * st["lead"] / np.abs(st["lead"]).max()
ir = make_ir()
st["verb"] = np.stack([signal.fftconvolve(filt(send[c], "highpass", 300), ir[c])[:N] for c in range(2)]) * (1 - 0.4 * (1 - duck))
mix = bus()
for name, target in LEVELS.items():
    x = st[name] * 10 ** ((target - lufs(st[name])) / 20)
    print(f"  {name:6s} peak {20 * np.log10(np.abs(x).max()):6.1f} dBFS at {target} LUFS")
    mix += x
mix = filt(mix, "highpass", 28)
mix[:, at(38.6):] *= np.linspace(1, 0, N - at(38.6)) ** 2


def limit(x, ceiling=0.86, release=0.06):
    g = np.minimum(1, ceiling / np.maximum(np.abs(x).max(0), 1e-9))
    g = minimum_filter1d(g, at(0.004) * 2 + 1)  # 4 ms lookahead
    a = np.exp(-1 / (release * SR))
    out = np.empty_like(g)
    prev = 0.0
    for i, v in enumerate(1 - g):  # instant attack, smooth release
        prev = v if v > prev else prev * a
        out[i] = prev
    g = 1 - np.convolve(out, np.ones(at(0.002)) / at(0.002), "same")
    return x * np.minimum(g, ceiling / np.maximum(np.abs(x).max(0), 1e-9))


for _ in range(3):  # loudness to -14 LUFS, peaks limited below -1.3 dBFS
    mix = limit(mix * 10 ** ((-14 - lufs(mix)) / 20))
print(f"music: {lufs(mix):.1f} LUFS, peak {20 * np.log10(np.abs(mix).max()):.1f} dBFS")

os.makedirs(os.path.join(os.path.dirname(__file__) or ".", "out"), exist_ok=True)
pcm = np.clip(mix + (rng.random(mix.shape) - rng.random(mix.shape)) / 32768, -1, 1)  # TPDF dither
with wave.open(os.path.join(os.path.dirname(__file__) or ".", "out", "music.wav"), "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((pcm.T * 32767).astype("<i2").tobytes())
