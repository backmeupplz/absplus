#!/usr/bin/env python3
"""Resolve the iOS Simulator CI runs the UI tests on and print its UDID.

Some hosted macos-26 runners start with none of the preinstalled simulators
visible to xcodebuild (actions/runner-images#12948, #13220), so a hard-coded
`name=iPhone 17` destination fails before any test runs. This waits for
CoreSimulator, then uses an existing iPhone 17 on the newest iOS runtime the
active Xcode can test on, else creates one, else falls back to the newest
iPhone with the same screen (the UI tests assert on-screen geometry), else the
newest iPhone at all. The chosen device and runtime are logged on stderr.
"""
import json
import os
import plistlib
import subprocess
import sys
import time

PREFERRED = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
# iPhone 17 screen in pixels (width, height, scale), used when its device type
# bundle is missing from the runner.
PREFERRED_SCREEN = (1206, 2622, 3.0)
CREATED_PREFIX = "ABS+ CI "

WAIT_SECONDS = 180
RESTART_AFTER_SECONDS = 60
POLL_SECONDS = 10


def log(message):
    print(message, file=sys.stderr, flush=True)


def version(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())


def is_ios(runtime):
    return runtime.get("platform", runtime.get("name", "").split(" ")[0]) == "iOS"


def screen(device_type):
    """Pixel width, height and scale from the device type bundle, if readable."""
    path = os.path.join(device_type.get("bundlePath", ""), "Contents/Resources/capabilities.plist")
    try:
        with open(path, "rb") as f:
            plist = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    dims = plist.get("capabilities", plist).get("ScreenDimensionsCapability") or {}
    size = tuple(dims.get(key) for key in ("main-screen-width", "main-screen-height", "main-screen-scale"))
    return None if None in size else size


def choose(listing, sdk, screen_of=screen):
    """Pick (runtime, device type, existing device or None, reason) or None.

    `listing` is `xcrun simctl list -j`; `sdk` is the active iphonesimulator SDK
    version. Pure apart from `screen_of`, so it can be tested without a runner.
    """
    runtimes = [
        r for r in listing.get("runtimes", [])
        if is_ios(r) and r.get("isAvailable") and version(r["version"])[:2] <= version(sdk)[:2]
    ]
    if not runtimes:
        return None
    runtime = max(runtimes, key=lambda r: version(r["version"]))
    types = {t["identifier"]: t for t in listing.get("devicetypes", [])}
    supported = [
        types.get(t["identifier"], t) for t in runtime.get("supportedDeviceTypes", [])
        if t.get("productFamily") == "iPhone"
    ]
    if not supported:
        return None
    devices = sorted(
        (d for d in listing.get("devices", {}).get(runtime["identifier"], []) if d.get("isAvailable")),
        key=lambda d: (d["name"], d["udid"]),
    )

    def existing(type_id):
        return next((d for d in devices if d.get("deviceTypeIdentifier") == type_id), None)

    def newest(candidates):
        return max(candidates, key=lambda t: (t.get("minRuntimeVersion", 0), t["name"]))

    by_id = {t["identifier"]: t for t in supported}
    if PREFERRED in by_id:
        return runtime, by_id[PREFERRED], existing(PREFERRED), "preferred device"
    reference = (screen_of(types[PREFERRED]) if PREFERRED in types else None) or PREFERRED_SCREEN
    same_screen = [t for t in supported if screen_of(t) == reference]
    if same_screen:
        # Reuse any existing same-screen device before creating the newest one.
        for t in sorted(same_screen, key=lambda t: (t.get("minRuntimeVersion", 0), t["name"]), reverse=True):
            if existing(t["identifier"]):
                return runtime, t, existing(t["identifier"]), "same screen as iPhone 17"
        return runtime, newest(same_screen), None, "same screen as iPhone 17"
    fallback = newest(supported)
    return runtime, fallback, existing(fallback["identifier"]), "newest iPhone; screen differs from iPhone 17"


def run(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode:
        log(f"{' '.join(args)} exited {result.returncode}: {result.stderr.strip()}")
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result


def listing():
    try:
        return json.loads(run("xcrun", "simctl", "list", "-j").stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        log(f"simctl list failed: {error}")
        return {}


def summary(data):
    ios = [f"{r['name']} ({'available' if r.get('isAvailable') else 'unavailable'})"
           for r in data.get("runtimes", []) if is_ios(r)]
    return ", ".join(ios) or "no iOS runtimes"


def wait_for_choice(sdk, seconds):
    deadline = time.monotonic() + seconds
    restart_at = time.monotonic() + RESTART_AFTER_SECONDS
    restarted = False
    while True:
        data = listing()
        picked = choose(data, sdk)
        if picked:
            return picked
        log(f"No usable iOS {sdk} simulator yet: {summary(data)}")
        if time.monotonic() >= deadline:
            return None
        if not restarted and time.monotonic() >= restart_at:
            # A stuck CoreSimulatorService is the usual reason for a runner that
            # lists no simulators; launchd restarts it on the next simctl call.
            log("Restarting CoreSimulatorService")
            run("sudo", "-n", "killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService", check=False)
            restarted = True
        time.sleep(POLL_SECONDS)


def main():
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").stdout.strip()
    log(run("xcodebuild", "-version").stdout.strip().replace("\n", ", ") + f", iphonesimulator SDK {sdk}")
    picked = wait_for_choice(sdk, WAIT_SECONDS)
    if not picked:
        log(f"No iOS runtime appeared; downloading the iOS {sdk} platform")
        download = run("xcodebuild", "-downloadPlatform", "iOS", check=False)
        log(download.stdout[-2000:] + download.stderr[-2000:])
        picked = wait_for_choice(sdk, POLL_SECONDS * 6)
    if not picked:
        log(run("xcrun", "simctl", "list", check=False).stdout)
        print(f"::error::No iOS Simulator usable with iOS {sdk} SDK on this runner", file=sys.stderr)
        return 1
    runtime, device_type, device, reason = picked
    if device:
        udid, origin = device["udid"], f"existing \"{device['name']}\""
    else:
        name = CREATED_PREFIX + device_type["name"]
        udid = run("xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"]).stdout.strip()
        origin = f"created \"{name}\""
    # Booting here surfaces a broken simulator before the build, not mid-suite.
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    message = (f"iOS Simulator: {device_type['name']} on {runtime['name']} ({runtime.get('buildversion', '?')}), "
               f"{origin}, {reason}, UDID {udid}")
    log(message)
    if "screen differs" in reason:
        print(f"::warning::{message}", file=sys.stderr)
    else:
        print(f"::notice::{message}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
