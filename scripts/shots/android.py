# python3 scripts/shots/android.py <apk> <out dir> [language ...]   (run from the repo root)
# The Play store shots, like iOS's StoreShots test: home with Continue listening, the library, a book page, the player, a
# podcast and the series list, with the app in each language (per-app locale, Android 13+), from one fresh install and
# sign-in, to <out dir>/<language>/<n>-<name>.png. Drives the emulator or device in ANDROID_SERIAL with adb and uiautomator, finding
# controls by the app's own strings in app/src/main/res/values-*/strings.xml. Needs ABS_URL, ABS_USER and ABS_PASS: the
# public Audiobookshelf demo (https://audiobooks.dev, demo/demo) has the titles below. Languages default to every one
# the app has. Run it once per device size (phone, 7" and 10" tablet) into <raw dir>/{phone,tab7,tab10} for compose.py.
import os, re, subprocess, sys, time
import xml.etree.ElementTree as ET

APP = 'com.borodutch.absplus'
BOOK, PODCAST = 'Volume 01', 'Librivox'  # on the demo: Aesop's Fables (twelve volumes, one series) and its one podcast
RES = 'app/src/main/res'
apk, out = sys.argv[1], os.path.abspath(sys.argv[2])
# app language -> (values folder, locale tag for the per-app locale)
FOLDERS = {'zh-Hans': 'b+zh+Hans', 'zh-Hant': 'b+zh+Hant', 'pt-BR': 'pt', 'pt-PT': 'pt-rPT', 'id': 'in'}
found = sorted(d[len('values-'):] for d in os.listdir(RES) if re.fullmatch(r'values-([a-z]{2}|b\+zh\+Han[st]|pt-rPT|in)', d))
ALL = ['en'] + sorted({next((k for k, v in FOLDERS.items() if v == f), f) for f in found})
languages = sys.argv[3:] or ALL
os.makedirs(out, exist_ok=True)


def strings(folder):
    path = os.path.join(RES, folder, 'strings.xml')
    return {e.get('name'): (e.text or '').replace("\\'", "'").replace('\\"', '"') for e in ET.parse(path).getroot().iter('string')} if os.path.exists(path) else {}


def adb(*args, check=True):
    return subprocess.run(['adb', *args], check=check, capture_output=True).stdout


def nodes():
    for _ in range(5):
        xml = adb('exec-out', 'uiautomator', 'dump', '/dev/tty', check=False).decode('utf8', 'replace')
        xml = xml[xml.find('<?xml'):xml.rfind('>') + 1]
        try:
            return list(ET.fromstring(xml).iter('node'))
        except ET.ParseError:
            time.sleep(1)
    return []


def top(n):
    return int(re.findall(r'\d+', n.get('bounds'))[1])


def find(match, timeout=60, last=False, above=None):
    """The first (or with last, the lowest) on-screen node whose text, content description or hint passes match, and
    with above, whose top is above that y (the mini player, low on the screen, names the book playing and has a Play button)"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = nodes()
        # a slow emulator's "isn't responding" (wait) or a crashed system app's "keeps stopping" (close)
        crash = [n for n in found if n.get('resource-id') in ('android:id/aerr_wait', 'android:id/aerr_close')]
        if crash:
            tap(crash[0])
            continue
        hits = [n for n in found if any(match(n.get(a) or '') for a in ('text', 'content-desc', 'hint')) and n.get('bounds') != '[0,0][0,0]'
                and (above is None or top(n) < above)]
        if hits:
            return hits[-1] if last else hits[0]
        time.sleep(1)
    open(os.path.join(out, 'zz-fail.png'), 'wb').write(adb('exec-out', 'screencap', '-p'))
    print('\n'.join(f"{n.get('text')!r} {n.get('content-desc')!r} {n.get('bounds')}" for n in nodes() if n.get('text') or n.get('content-desc')))
    raise SystemExit(f'nothing on screen matches {match.__doc__}')


def tap(n):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))


def exactly(s):
    m = lambda v: v == s
    m.__doc__ = repr(s)
    return m


def containing(s):
    m = lambda v: s in v
    m.__doc__ = f'... {s!r} ...'
    return m


def shot(folder, name):
    time.sleep(3)  # let covers load
    open(os.path.join(folder, name + '.png'), 'wb').write(adb('exec-out', 'screencap', '-p'))


def demo_status_bar():
    adb('shell', 'settings', 'put', 'global', 'sysui_demo_allowed', '1')
    for extra in (['clock', '-e', 'hhmm', '0941'], ['battery', '-e', 'level', '100', '-e', 'plugged', 'false'],
                  ['network', '-e', 'wifi', 'show', '-e', 'level', '4'], ['network', '-e', 'mobile', 'show', '-e', 'level', '4', '-e', 'datatype', 'none'],
                  ['notifications', '-e', 'visible', 'false']):
        adb('shell', 'am', 'broadcast', '-a', 'com.android.systemui.demo', '-e', 'command', 'enter')
        adb('shell', 'am', 'broadcast', '-a', 'com.android.systemui.demo', '-e', 'command', *extra)


def sign_in():
    en = strings('values')
    adb('shell', 'cmd', 'locale', 'set-app-locales', APP, '--locales', 'en')
    adb('shell', 'monkey', '-p', APP, '-c', 'android.intent.category.LAUNCHER', '1')
    for hint, value in (('hint_server_url', os.environ['ABS_URL']), ('hint_username', os.environ['ABS_USER']), ('hint_password', os.environ['ABS_PASS'])):
        field = find(exactly(en[hint]))
        tap(field)
        typed = ''
        done = lambda: typed == value or (hint == 'hint_password' and len(typed) == len(value))  # a password can show as dots
        for _ in range(8):  # a busy emulator drops typed characters, so check what arrived and type what's missing
            if done():
                break
            if len(typed) < len(value) and (value.startswith(typed) or hint == 'hint_password'):
                if value[len(typed)] == '.' and typed:  # a text that starts with "." gets lost: retype the character before it
                    adb('shell', 'input', 'keyevent', '67')
                    typed = typed[:-1]
                missing = value[len(typed):]
            else:
                adb('shell', 'input', 'keycombination', '113', '29')  # ctrl+a, then delete
                adb('shell', 'input', 'keyevent', '67')
                missing = value
            adb('shell', 'input', 'text', missing.replace(' ', '%s'))
            time.sleep(1)
            # the focused field itself: not the empty wrapper around it with the same bounds, and on a tablet the
            # keyboard moves the field, so not by its bounds either
            typed = next((n.get('text') or '' for n in nodes() if n.get('focused') == 'true' and n.get('class') == field.get('class')), '')
            typed = '' if typed == en[hint] else typed
        if not done():
            raise SystemExit(f'typing {hint} failed')
    adb('shell', 'input', 'keyevent', '111')  # escape: hide the keyboard
    tap(find(exactly(en['action_sign_in'])))
    find(exactly(en['tab_library']))
    adb('shell', 'am', 'force-stop', APP)


def walk(language):
    folder = os.path.join(out, language)
    os.makedirs(folder, exist_ok=True)
    t = strings('values') | strings('values-' + FOLDERS.get(language, language)) if language != 'en' else strings('values')
    height = int(adb('shell', 'wm', 'size').split(b'x')[-1])
    low = height * 3 // 4  # the mini player sits below this
    adb('shell', 'am', 'force-stop', APP)
    adb('shell', 'cmd', 'locale', 'set-app-locales', APP, '--locales', language)
    demo_status_bar()  # again, in case a busy emulator restarted the system UI
    adb('shell', 'am', 'start', '-W', '-n', APP + '/.Main')

    tap(find(exactly(t['tab_library'])))
    tap(find(exactly('Audiobooks')))  # the app keeps the library picked last, which was Podcasts
    find(containing(BOOK), above=low)
    shot(folder, '2-library')
    tap(find(containing(BOOK), above=low))
    play = find(lambda v: v in (t['action_play'], t['action_resume']), above=low)
    shot(folder, '3-book')
    tap(play)
    time.sleep(4)

    tap(find(exactly(t['tab_series'])))
    find(containing("Aesop"))
    shot(folder, '6-series')

    tap(find(exactly(t['tab_library'])))
    tap(find(exactly('Podcasts')))  # library names come from the server
    tap(find(containing(PODCAST), above=low))
    find(exactly(t['section_episodes']))
    shot(folder, '5-podcast')

    # after the others, so the server has had time to put the book playing under Continue listening
    tap(find(exactly(t['tab_home'])))
    find(exactly(t['section_continue_listening']))
    shot(folder, '1-home')

    # last, so no step has to close the player: the mini player's title (the lowest node naming the book) opens it
    mini = find(containing(BOOK), last=True)
    if top(mini) < low:
        raise SystemExit('no mini player')
    tap(mini)
    # the player is a dialog, its own window. uiautomator can't dump it while it plays ("could not get idle state" as
    # the timeline moves), so wait for the app's second window instead
    deadline = time.time() + 60
    while len(re.findall(rf'Window #\d+ Window\{{\w+ u0 {re.escape(APP)}/'.encode(), adb('shell', 'dumpsys', 'window', 'windows'))) < 2:
        if time.time() > deadline:
            raise SystemExit('no player')
        time.sleep(1)
    time.sleep(6)  # a few seconds in, so the timeline shows progress
    shot(folder, '4-player')


for scale in ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale'):  # less work, steadier dumps
    adb('shell', 'settings', 'put', 'global', scale, '0')
demo_status_bar()
# A tablet's launcher keeps its taskbar (app icons) over the bottom of every app, so turn the launcher off for the walk
home = None
if int(adb('shell', 'wm', 'size').split(b'x')[0].split()[-1]) * 160 // int(adb('shell', 'wm', 'density').split()[-1]) >= 600:
    for package in adb('shell', 'pm', 'list', 'packages', '-d').decode().split():  # one a killed walk left off
        if 'launcher' in package:
            adb('shell', 'pm', 'enable', package.split(':')[-1])
    home = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-c', 'android.intent.category.HOME',
               '-a', 'android.intent.action.MAIN').decode().split()[-1].split('/')[0]
    if home == 'com.android.settings':  # its fallback home: there's no launcher to turn off
        home = None
    else:
        adb('shell', 'pm', 'disable-user', '--user', '0', home)
failed = []
try:
    # One install and sign-in per device: a busy emulator drops typed characters, so the fewer sign-ins the better
    adb('uninstall', APP, check=False)
    adb('install', '-r', apk)
    adb('shell', 'pm', 'grant', APP, 'android.permission.POST_NOTIFICATIONS', check=False)  # no permission prompt over a shot
    sign_in()
    for language in languages:
        for attempt in range(2):  # a busy emulator now and then misses a step, so a language gets a second walk
            try:
                walk(language)
                break
            except SystemExit as e:
                print(language, 'attempt', attempt + 1, e, flush=True)
        else:
            failed.append(language)
            continue
        print(language, ' '.join(sorted(os.listdir(os.path.join(out, language)))), flush=True)
finally:
    if home:
        adb('shell', 'pm', 'enable', home)
if failed:
    raise SystemExit('failed: ' + ' '.join(failed))
