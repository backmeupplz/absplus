#!/usr/bin/env node
// Renders index.html frame by frame in headless Chromium and muxes it with the soundtrack.
//   node render.mjs              -> out/absplus-promo.mp4 and the site's copy in docs/ (runs music.py first)
//   node render.mjs 4.5 9.8 ...  -> out/stills/<t>.png, single frames for checking a change
// Env: CHROME (browser binary, default chromium), JOBS (parallel browsers), FPS (default 60).
import { execFileSync, spawn } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { availableParallelism, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const dir = dirname(fileURLToPath(import.meta.url))
const out = join(dir, 'out')
const FPS = +(process.env.FPS || 60)
const JOBS = +(process.env.JOBS || Math.min(8, Math.max(1, availableParallelism() >> 1)))
const procs = []
process.on('exit', () => procs.forEach(p => p.kill())) // don't leave browsers behind if anything throws

async function open() {
  const profile = mkdtempSync(join(tmpdir(), 'absplus-promo-'))
  const proc = spawn(process.env.CHROME || 'chromium', [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--hide-scrollbars',
    '--mute-audio', '--allow-file-access-from-files', '--force-device-scale-factor=1', '--window-size=1920,1080',
    '--run-all-compositor-stages-before-draw', '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, XDG_CONFIG_HOME: profile } }) // skip ~/.config/chromium-flags.conf
  procs.push(proc)
  const exited = new Promise(r => proc.once('exit', r))
  const ws = new WebSocket(await new Promise((res, rej) => {
    let log = ''
    proc.stderr.on('data', d => { log += d; const m = log.match(/ws:\/\/\S+/); if (m) res(m[0]) })
    proc.on('exit', code => rej(new Error(`chromium exited (${code}):\n${log}`)))
  }))
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
  let id = 0
  const waiting = new Map()
  ws.onmessage = e => {
    const m = JSON.parse(e.data)
    const w = waiting.get(m.id)
    if (!w) return
    waiting.delete(m.id)
    m.error ? w.rej(new Error(m.error.message)) : w.res(m.result)
  }
  const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
    waiting.set(++id, { res, rej })
    ws.send(JSON.stringify({ id, method, params, sessionId }))
  })
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
  const page = (method, params) => send(method, params, sessionId)
  const evaluate = async expression => {
    const r = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text)
    return r.result.value
  }
  await page('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false })
  await page('Page.navigate', { url: pathToFileURL(join(dir, 'index.html')).href + '?render' })
  for (;;) {
    const ready = await evaluate(`location.search === '?render' && document.readyState === 'complete'`).catch(() => false)
    if (ready) break
    await new Promise(r => setTimeout(r, 50))
  }
  const duration = await evaluate('boot()')
  return {
    duration,
    async shot(t, file) {
      await evaluate(`frame(${t})`)
      const { data } = await page('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true })
      writeFileSync(file, Buffer.from(data, 'base64'))
    },
    async close() {
      proc.kill()
      await exited
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
    },
  }
}

const stills = process.argv.slice(2).map(Number)
if (stills.length) {
  mkdirSync(join(out, 'stills'), { recursive: true })
  const b = await open()
  for (const t of stills) await b.shot(t, join(out, 'stills', `${t.toFixed(2)}.png`))
  await b.close()
} else {
  execFileSync('python3', [join(dir, 'music.py')], { stdio: 'inherit' })
  const frames = join(out, 'frames')
  rmSync(frames, { recursive: true, force: true })
  mkdirSync(frames, { recursive: true })
  const browsers = await Promise.all(Array.from({ length: JOBS }, open))
  const n = Math.round(browsers[0].duration * FPS)
  let done = 0
  const started = Date.now()
  await Promise.all(browsers.map(async (b, j) => {
    for (let i = j; i < n; i += JOBS) {
      await b.shot(i / FPS, join(frames, `${String(i).padStart(5, '0')}.png`))
      if (++done % 30 === 0) process.stdout.write(`\rframes ${done}/${n} (${Math.round((Date.now() - started) / 1000)}s)`)
    }
  }))
  await Promise.all(browsers.map(b => b.close()))
  console.log()
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-stats', '-framerate', String(FPS), '-i', join(frames, '%05d.png'), '-i', join(out, 'music.wav'),
    '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '16',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-c:a', 'aac', '-b:a', '256k',
    '-movflags', '+faststart', '-shortest', join(out, 'absplus-promo.mp4')], { stdio: 'inherit' })
  rmSync(frames, { recursive: true, force: true })
  // the landing page's copy (docs/): a lighter encode, and a poster frame from the hook scene
  const site = join(dir, '..', 'docs')
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', join(out, 'absplus-promo.mp4'), '-c:v', 'libx264', '-preset', 'slow', '-crf', '24', '-pix_fmt', 'yuv420p',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart',
    join(site, 'video', 'absplus-promo.mp4')], { stdio: 'inherit' })
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-ss', '6.9', '-i', join(out, 'absplus-promo.mp4'), '-frames:v', '1', '-vf', 'scale=1280:-1',
    '-c:v', 'libwebp', '-quality', '82', join(site, 'img', 'promo-poster.webp')], { stdio: 'inherit' })
  console.log(join(out, 'absplus-promo.mp4'))
}
