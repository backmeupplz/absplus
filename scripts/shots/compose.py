# python3 scripts/shots/compose.py <raw dir> [locale ...]   (run from the repo root, after the raw shots are taken)
# Puts each raw shot under its locale's caption (`## Screenshot captions` in appstore/<locale>/listing.md, en-US in
# appstore/listing.md) at every store size, plus the 1024x500 feature graphic with its `## Feature graphic tagline`, in one
# headless Chrome, and checks every frame's layout in the page: the caption takes at most two lines, and every box stays
# 24 px or more from the edges and from the next box. Arabic is laid out right to left. Raw shots are whole device
# screenshots in <raw dir>/<device>/<app language>/<n>-<name>.png (n = 1 to 6, see TARGETS for the devices; the iPhone
# ones come from ios/store-shots.sh). A device with no folder is skipped. Writes JPEGs to
#   appstore/screenshots/<locale>/<n>.jpg                     iPhone 6.9" (1320x2868), uploaded by listings.py
#   appstore/screenshots/<locale>/duo-outer|duo-inner/<n>.jpg  iPhone Duo (1398x2034 and 2853x2007), kept in the repo
#   fastlane/metadata/android/<Play code>/images/{phone,sevenInch,tenInch}Screenshots/<n>.jpg and featureGraphic.jpg
# and prints a JSON report; exits 1 if any check fails. Shared with Quilcast's scripts/shots/compose.py: the checks and
# the Chrome runner below the frames are the same.
import asyncio, base64, glob, html, json, os, re, subprocess, sys, tempfile, time, urllib.request
import websockets

raw = os.path.abspath(sys.argv[1])
repo = os.getcwd()
work = tempfile.mkdtemp(prefix='shots-frames-')
QUALITY = 82
# target: (width, height, raw device folder)
TARGETS = {
    'ios': (1320, 2868, 'ios'),  # iPhone 6.9"
    'duo-outer': (1398, 2034, 'duo'),  # iPhone Duo cover display
    'duo-inner': (2853, 2007, 'duo-inner'),  # iPhone Duo inner display, landscape: the app shows landscape on it
    'phone': (1080, 2160, 'phone'),  # Play phone
    'tab7': (1200, 1920, 'tab7'),  # Play 7" tablet
    'tab10': (1600, 2560, 'tab10'),  # Play 10" tablet
}
# App Store locale -> (app language, Google Play code)
LOCALES = {
    'en-US': ('en', 'en-US'), 'en-GB': ('en', 'en-GB'), 'de-DE': ('de', 'de-DE'), 'fr-FR': ('fr', 'fr-FR'), 'es-ES': ('es', 'es-ES'),
    'es-MX': ('es', 'es-419'), 'pt-BR': ('pt-BR', 'pt-BR'), 'pt-PT': ('pt-PT', 'pt-PT'), 'it': ('it', 'it-IT'), 'nl-NL': ('nl', 'nl-NL'),
    'ru': ('ru', 'ru-RU'), 'uk': ('uk', 'uk'), 'pl': ('pl', 'pl-PL'), 'tr': ('tr', 'tr-TR'), 'sv': ('sv', 'sv-SE'), 'ar-SA': ('ar', 'ar'),
    'ja': ('ja', 'ja-JP'), 'ko': ('ko', 'ko-KR'), 'zh-Hans': ('zh-Hans', 'zh-CN'), 'zh-Hant': ('zh-Hant', 'zh-TW'), 'hi': ('hi', 'hi-IN'),
    'id': ('id', 'id'), 'vi': ('vi', 'vi'), 'th': ('th', 'th'),
}
only = sys.argv[2:] or list(LOCALES)
FONTS = "-apple-system, 'Helvetica Neue', 'Hiragino Sans', 'PingFang SC', 'Apple SD Gothic Neo', 'Geeza Pro', 'Kohinoor Devanagari', 'Thonburi', sans-serif"
# per locale, so Chinese and Japanese captions get their own glyph shapes
CJK = {'zh-Hans': "'PingFang SC'", 'zh-Hant': "'PingFang TC'", 'ja': "'Hiragino Sans'", 'ko': "'Apple SD Gothic Neo'"}
BG = 'linear-gradient(160deg, #2B1F8F 0%, #4B35C9 50%, #7B5CFF 100%)'  # the feature graphic's and the icon's
GAP = 48  # caption to screenshot
# loanwords Chrome's dictionary would break inside (Thai has no spaces; it splits "podcast" as พอด|แคสต์)
WHOLE = ['พอดแคสต์']
# the icon's headphones and plus, without its background square
MARK = re.sub(r"<rect[^>]*/>", '', open(os.path.join(repo, 'play/icon-512.svg'), encoding='utf8').read())
MARK = re.sub(r"width='512' height='512'", "width='250' height='250' data-box='icon'", MARK, count=1)


def sections(path):
    out, name = {}, None
    for line in open(path, encoding='utf8').read().split('\n'):
        m = re.match(r'^## (.+?)(?: \(max \d+\))?$', line)
        if m:
            name = m[1]
            out[name] = []
        elif name:
            out[name].append(line)
    return {k: '\n'.join(v).strip() for k, v in out.items()}


def texts(locale):
    s = sections(os.path.join(repo, 'appstore', 'listing.md' if locale == 'en-US' else f'{locale}/listing.md'))
    captions = [re.sub(r'^\d+\.\s*', '', c).strip() for c in s['Screenshot captions'].split('\n') if c.strip()]
    assert len(captions) == 6, f'{locale}: {len(captions)} captions'
    return captions, s['Feature graphic tagline']


def text(s):
    s = html.escape(s)
    for w in WHOLE:
        s = s.replace(w, f'<span style="white-space:nowrap">{w}</span>')
    return s


def page(locale, rtl, body, W, H):
    lang = LOCALES[locale][0]
    fonts = (CJK[lang] + ', ' if lang in CJK else '') + FONTS
    return f'''<!doctype html><html lang="{lang}" dir="{'rtl' if rtl else 'ltr'}"><meta charset="utf-8"><style>
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ background: {BG}; font-family: {fonts}; color: #fff; position: relative; -webkit-font-smoothing: antialiased; }}
</style><body>{body}</body></html>'''


def shot_frame(target, locale, rtl, caption, img):
    W, H, _ = TARGETS[target]
    short = min(W, H)
    m = round(short * 0.06)
    cap = round(H * (0.15 if H > W else 0.21))  # caption area: from the top edge to here
    fs = round(short * (0.072 if target in ('ios', 'phone', 'duo-outer') else 0.058))
    lh = 1.4 if LOCALES[locale][0].startswith('zh') else 1.18  # PingFang's glyphs run taller than a 1.18 line
    # the whole screenshot, as large as fits under the caption; the image's own box hugs it. Strict line breaking keeps
    # small kana off the start of a line, and auto-phrase breaks Japanese between phrases, not inside a word
    body = f'''<div class="area" style="position:absolute; left:{m}px; right:{m}px; top:{round(m * 1.1)}px; height:{cap - round(m * 1.1)}px; display:flex; align-items:center; justify-content:center;">
<div class="cap" data-box="caption" style="display:inline-block; font-size:{fs}px; line-height:{lh}; font-weight:750; letter-spacing:-0.01em; text-align:center; text-wrap:balance; line-break:strict; word-break:auto-phrase; max-width:100%;">{text(caption)}</div></div>
<div style="position:absolute; left:{m}px; right:{m}px; top:{cap + GAP}px; bottom:{m}px; display:flex; align-items:flex-start; justify-content:center;">
<img data-box="screenshot" src="file://{img}" style="display:block; max-width:100%; max-height:100%; border-radius:{round(short * 0.04)}px; box-shadow:0 {round(m * 0.3)}px {round(m * 0.9)}px rgb(10 0 60 / 0.45);"></div>'''
    return page(locale, rtl, body, W, H)


def feature(locale, rtl, tagline):
    body = f'''<div style="position:absolute; inset:0; display:flex; align-items:center; gap:40px; padding:0 56px; box-sizing:border-box;">
<div style="flex:none; display:flex;">{MARK}</div>
<div class="area" style="flex:1; min-width:0; height:320px; display:flex; flex-direction:column; justify-content:center; align-items:flex-start; gap:24px;">
<div data-box="name" dir="ltr" lang="en" style="display:inline-block; font-size:120px; line-height:1.25; white-space:nowrap; font-weight:800; letter-spacing:-0.02em; font-family:-apple-system, sans-serif;">ABS<span style="color:#FFC94D">+</span></div>
<div class="cap" data-box="tagline" style="display:inline-block; font-size:38px; line-height:1.3; font-weight:600; opacity:0.92; text-wrap:balance; line-break:strict; word-break:auto-phrase; max-width:100%;">{text(tagline)}</div></div></div>'''
    return page(locale, rtl, body, 1024, 500)


def jobs():
    for target, (W, H, device) in TARGETS.items():
        if not os.path.isdir(os.path.join(raw, device)):
            print(f'no {device} shots: skipping {target}', file=sys.stderr)
    for loc in only:
        ui, play = LOCALES[loc]
        captions, tagline = texts(loc)
        rtl = ui == 'ar'
        for target, (W, H, device) in TARGETS.items():
            if not os.path.isdir(os.path.join(raw, device)):
                continue
            for n in range(1, 7):
                img = (glob.glob(os.path.join(raw, device, ui, f'{n}-*.png')) or [os.path.join(raw, device, ui, f'{n}-?.png')])[0]
                if target == 'ios':
                    out = os.path.join(repo, 'appstore/screenshots', loc, f'{n}.jpg')
                elif target.startswith('duo'):
                    out = os.path.join(repo, 'appstore/screenshots', loc, target, f'{n}.jpg')
                else:
                    sub = {'phone': 'phoneScreenshots', 'tab7': 'sevenInchScreenshots', 'tab10': 'tenInchScreenshots'}[target]
                    out = os.path.join(repo, 'fastlane/metadata/android', play, 'images', sub, f'{n}.jpg')
                yield out, (target, W, H), shot_frame(target, loc, rtl, captions[n - 1], img), img
        yield os.path.join(repo, 'fastlane/metadata/android', play, 'images/featureGraphic.jpg'), ('feature', 1024, 500), feature(loc, rtl, tagline), None


# The width of an element's widest line. A line can be several runs (a number in Arabic text is its own left-to-right
# run, and digits in Chinese come from another font with its own height), so runs are put on a line by their middle
WIDEST = '''const widest = (el) => {
  const r = document.createRange(), top = el.getBoundingClientRect().top, lh = parseFloat(getComputedStyle(el).lineHeight), ends = {}
  r.selectNodeContents(el)
  for (const x of r.getClientRects()) { const k = Math.floor(((x.top + x.bottom) / 2 - top) / lh); ends[k] = [Math.min(x.left, (ends[k] || [x.left])[0]), Math.max(x.right, (ends[k] || [0, x.right])[1])] }
  return Math.max(...Object.values(ends).map(([a, b]) => b - a)) }
'''
CHECK = '''(() => {
''' + WIDEST + '''  const W = innerWidth, H = innerHeight, out = []
  const box = (el) => { const r = el.getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom } }
  const cap = document.querySelector('.cap')
  const lines = cap ? Math.round(cap.getBoundingClientRect().height / parseFloat(getComputedStyle(cap).lineHeight)) : 0
  const boxes = [...document.querySelectorAll('[data-box]')].map((el) => ({ n: el.dataset.box, ...box(el) }))
  for (const b of boxes) {
    if (b.l < 24 || b.t < 24 || W - b.r < 24 || H - b.b < 24) out.push(`${b.n} within 24 px of the edge`)
    if (b.r - b.l < 1 || b.b - b.t < 1) out.push(`${b.n} is empty`)
  }
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const a = boxes[i], b = boxes[j]
    const gap = Math.max(b.l - a.r, a.l - b.r, b.t - a.b, a.t - b.b)
    if (gap < 24) out.push(`${a.n} and ${b.n} are ${Math.round(gap)} px apart`)
  }
  for (const el of document.querySelectorAll('[data-box]')) if (el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1) out.push(`${el.dataset.box} overflows (${el.scrollWidth}x${el.scrollHeight} in ${el.clientWidth}x${el.clientHeight})`)
  // the text boxes hug their text: an inline-block as wide as its longest line
  for (const el of document.querySelectorAll('.cap, [data-box="name"]')) {
    // the widest line, joining the runs on it (the name's plus is its own span)
    const w = widest(el)
    if (el.getBoundingClientRect().width - w > 2) out.push(`${el.dataset.box} is ${Math.round(el.getBoundingClientRect().width - w)} px wider than its text`)
  }
  return { problems: out, lines, font: cap ? parseFloat(getComputedStyle(cap).fontSize) : 0 }
})()'''
# shrink the caption until it takes at most two lines and fits its area
FIT = '''(() => { const c = document.querySelector('.cap'), area = document.querySelector('.area'); let f = parseFloat(getComputedStyle(c).fontSize)
''' + WIDEST + '''  const lines = () => Math.round(c.getBoundingClientRect().height / parseFloat(getComputedStyle(c).lineHeight))
  while (f > 20 && (lines() > 2 || c.getBoundingClientRect().width > area.clientWidth || c.getBoundingClientRect().height > area.clientHeight)) { f -= 2; c.style.fontSize = f + 'px' }
  // a wrapped line leaves its box as wide as the area: narrow it to the longest line. Balanced wrapping can then break
  // the lines elsewhere, so narrow again until the box holds still
  for (let i = 0; i < 5 && c.getBoundingClientRect().width - widest(c) > 2; i++) c.style.width = Math.ceil(widest(c)) + 1 + 'px'
  return f })()'''


port = 9900 + (os.getpid() % 50)
prof = tempfile.mkdtemp(prefix='shots-chrome-')
chrome = subprocess.Popen(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new', f'--remote-debugging-port={port}', f'--user-data-dir={prof}',
                           '--use-mock-keychain', '--no-first-run', '--remote-allow-origins=*', '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
report, bad = [], 0


async def main():
    global bad
    tabs = None
    for _ in range(80):
        time.sleep(0.25)
        try:
            tabs = json.load(opener.open(f'http://127.0.0.1:{port}/json'))
            if any(t['type'] == 'page' for t in tabs):
                break
        except Exception:
            pass
    pg = next(t for t in tabs if t['type'] == 'page')
    async with websockets.connect(pg['webSocketDebuggerUrl'], proxy=None, max_size=None) as ws:
        n = 0

        async def send(method, params={}):
            nonlocal n
            n += 1
            await ws.send(json.dumps({'id': n, 'method': method, 'params': params}))
            while True:
                m = json.loads(await ws.recv())
                if m.get('id') == n:
                    return m

        async def js(expr):
            r = await send('Runtime.evaluate', {'expression': expr, 'returnByValue': True, 'awaitPromise': True})
            return r.get('result', {}).get('result', {}).get('value')

        size = None
        for i, (out, (kind, W, H), doc, img) in enumerate(jobs()):
            if img and not os.path.exists(img):
                report.append({'out': os.path.relpath(out, repo), 'problems': [f'missing raw shot {img}']})
                bad += 1
                continue
            if size != (W, H):
                await send('Emulation.setDeviceMetricsOverride', {'width': W, 'height': H, 'deviceScaleFactor': 1, 'mobile': False})
                size = (W, H)
            path = os.path.join(work, f'{i}.html')
            open(path, 'w', encoding='utf8').write(doc)
            await send('Page.navigate', {'url': 'file://' + path})
            for _ in range(50):
                await asyncio.sleep(0.1)
                if await js("document.readyState === 'complete' && [...document.images].every((i) => i.complete && i.naturalWidth)"):
                    break
            await js('document.fonts.ready.then(() => 1)')
            await js(FIT)
            r = await js(CHECK)
            if kind != 'feature' and r['lines'] > 2:
                r['problems'].append(f"caption takes {r['lines']} lines")
            r['out'] = os.path.relpath(out, repo)
            report.append({k: r[k] for k in ('out', 'problems', 'lines', 'font')})
            bad += bool(r['problems'])
            s = await send('Page.captureScreenshot', {'format': 'jpeg', 'quality': QUALITY, 'clip': {'x': 0, 'y': 0, 'width': W, 'height': H, 'scale': 1}})
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, 'wb').write(base64.b64decode(s['result']['data']))


try:
    asyncio.run(main())
finally:
    chrome.kill()
json.dump(report, open(os.path.join(work, 'report.json'), 'w'), ensure_ascii=False, indent=1)
print(json.dumps({'frames': len(report), 'failed': bad, 'report': os.path.join(work, 'report.json'), 'problems': [r for r in report if r['problems']][:20]}, ensure_ascii=False))
sys.exit(1 if bad else 0)
