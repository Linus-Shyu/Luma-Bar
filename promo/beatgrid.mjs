// Estimates tempo, beat phase and downbeat phase from an audio file so the cut
// can be locked to a real musical grid instead of a guessed offset.
//
//   node beatgrid.mjs <audio file>
//
// Uses an STFT spectral-flux onset envelope (the standard, and far steadier
// than raw energy flux), autocorrelates it for the beat period, then scans
// phase at beat level and again at bar level.

import { spawnSync } from "node:child_process";

const SR = 22050;
const FFT = 1024;
const HOP = 256;                       // ~11.6ms per envelope frame
const file = process.argv[2];
if (!file) { console.error("usage: node beatgrid.mjs <audio>"); process.exit(1); }

const pcm = spawnSync("ffmpeg", [
  "-v", "error", "-i", file, "-vn", "-ac", "1", "-ar", String(SR), "-f", "f32le", "-",
], { maxBuffer: 1 << 30 });
if (pcm.status !== 0) { console.error(pcm.stderr.toString()); process.exit(1); }
const x = new Float32Array(pcm.stdout.buffer, pcm.stdout.byteOffset, Math.floor(pcm.stdout.length / 4));

// ---- in-place iterative radix-2 FFT -----------------------------------------
const LOG = Math.log2(FFT);
const rev = new Uint16Array(FFT);
for (let i = 0; i < FFT; i++) {
  let r = 0;
  for (let b = 0; b < LOG; b++) if (i & (1 << b)) r |= 1 << (LOG - 1 - b);
  rev[i] = r;
}
const cosT = new Float64Array(FFT / 2), sinT = new Float64Array(FFT / 2);
for (let i = 0; i < FFT / 2; i++) {
  cosT[i] = Math.cos(-2 * Math.PI * i / FFT);
  sinT[i] = Math.sin(-2 * Math.PI * i / FFT);
}
function fft(re, im) {
  for (let i = 0; i < FFT; i++) {
    const j = rev[i];
    if (j > i) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= FFT; len <<= 1) {
    const step = FFT / len, half = len >> 1;
    for (let i = 0; i < FFT; i += len) {
      for (let k = 0; k < half; k++) {
        const c = cosT[k * step], s = sinT[k * step];
        const a = i + k, b = a + half;
        const tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr;        im[a] += ti;
      }
    }
  }
}

// ---- spectral flux onset envelope -------------------------------------------
const win = new Float64Array(FFT);
for (let i = 0; i < FFT; i++) win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / FFT);

const BINS = FFT / 2;
const N = Math.max(0, Math.floor((x.length - FFT) / HOP));
const env = new Float32Array(N);
const re = new Float64Array(FFT), im = new Float64Array(FFT);
let prev = new Float64Array(BINS);
for (let f = 0; f < N; f++) {
  const o = f * HOP;
  for (let i = 0; i < FFT; i++) { re[i] = x[o + i] * win[i]; im[i] = 0; }
  fft(re, im);
  let flux = 0;
  for (let k = 1; k < BINS; k++) {
    const m = Math.log1p(80 * Math.hypot(re[k], im[k]));
    const d = m - prev[k];
    if (d > 0) flux += d;
    prev[k] = m;
  }
  env[f] = flux;
}

// Subtract a moving average so sustained loudness doesn't masquerade as onsets.
const W = 24;
const oss = new Float32Array(N);
for (let i = 0; i < N; i++) {
  let s = 0, n = 0;
  for (let j = Math.max(0, i - W); j <= Math.min(N - 1, i + W); j++) { s += env[j]; n++; }
  oss[i] = Math.max(0, env[i] - s / n);
}

const fps = SR / HOP;
let mean = 0;
for (let i = 0; i < N; i++) mean += oss[i];
mean /= N;
const d0 = new Float32Array(N);
for (let i = 0; i < N; i++) d0[i] = oss[i] - mean;

function ac(lag) {
  const L = Math.round(lag);
  let s = 0;
  for (let i = 0; i + L < N; i++) s += d0[i] * d0[i + L];
  return s / (N - L);
}

let best = null;
for (let bpm = 70; bpm <= 180; bpm += 0.02) {
  const l = (60 / bpm) * fps;
  const s = ac(l) + 0.6 * ac(l * 2) + 0.35 * ac(l * 4);
  if (!best || s > best.s) best = { bpm, s };
}
const BPM = best.bpm, BEAT = 60 / BPM, BAR = BEAT * 4;

// Phase scan: a grid is good when its ticks sit on onset energy.
function score(off, period) {
  let s = 0, n = 0;
  for (let t = off; t * fps < N - 2; t += period) {
    const i = Math.round(t * fps);
    s += oss[i - 1] * 0.5 + oss[i] + oss[i + 1] * 0.5;
    n++;
  }
  return n ? s / n : 0;
}

// Autocorrelation alone resolves tempo only to a few hundredths of a BPM, which
// drifts audibly over a 45s cut. Refine it by jointly optimising period and
// phase against the onset envelope across the whole track.
let refined = { bpm: BPM, phase: 0, s: -1 };
for (let bpm = BPM - 1.2; bpm <= BPM + 1.2; bpm += 0.005) {
  const beat = 60 / bpm;
  for (let o = 0; o < beat; o += 0.004) {
    const s = score(o, beat);
    if (s > refined.s) refined = { bpm, phase: o, s };
  }
}
const BPM2 = refined.bpm, BEAT2 = 60 / BPM2;
console.log(`refined    ${BPM2.toFixed(3)} BPM  phase ${refined.phase.toFixed(3)}s  score ${refined.s.toFixed(2)}`);
console.log(`vs 128.000 BPM best score ${
  (() => { let b = -1; for (let o = 0; o < 0.46875; o += 0.002) b = Math.max(b, score(o, 0.46875)); return b; })().toFixed(2)
}`);

let beatPhase = refined.phase, bs = refined.s;
while (beatPhase - BEAT2 > 0) beatPhase -= BEAT2;

console.log(`file       ${file}`);
console.log(`duration   ${(x.length / SR).toFixed(3)}s`);
console.log(`tempo      ${BPM.toFixed(2)} BPM  (beat ${BEAT.toFixed(5)}s  bar ${BAR.toFixed(5)}s)`);
console.log(`beat phase ${beatPhase.toFixed(3)}s   score ${bs.toFixed(2)}`);
console.log(`halfbeat   ${score(beatPhase + BEAT2 / 2, BEAT2).toFixed(2)} (must be clearly lower)`);

const BAR2 = BEAT2 * 4;
let downbeat = beatPhase, ds = -1;
for (let k = 0; k < 4; k++) {
  const o = beatPhase + k * BEAT2, s = score(o, BAR2);
  console.log(`  beat ${k + 1} as downbeat  ${o.toFixed(3)}s  score ${s.toFixed(2)}`);
  if (s > ds) { ds = s; downbeat = o; }
}
console.log(`downbeat   ${downbeat.toFixed(3)}s`);
console.log(`bar lines  ${Array.from({ length: 8 }, (_, b) => (downbeat + b * BAR2).toFixed(3)).join("  ")}`);
console.log(`late check ${Array.from({ length: 4 }, (_, b) => (downbeat + (64 + b) * BAR2).toFixed(3)).join("  ")}`);
