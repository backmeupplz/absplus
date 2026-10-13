#!/usr/bin/env python3
"""Resolve the iOS Simulator CI runs the UI tests on and print its UDID.

Some hosted macos-26 runners start with none of the preinstalled simulators
visible to xcodebuild (actions/runner-images#12948, #13220), so a hard-coded
`name=iPhone 17` destination fails before any test runs. This waits for
CoreSimulator, then uses an existing iPhone 17 on the newest iOS runtime the
active Xcode can test the app on, else creates one, else uses a device with the
same screen (the UI tests assert on-screen geometry). It fails rather than test
on a different screen size. The chosen device and runtime are logged on stderr.
"""
import json
import os
import plistlib
import re
import subprocess
import sys
import time

PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ABSPlus.xcodeproj")
SCHEME = "ABSPlus"
PREFERRED = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
# iPhone 17 screen in pixels (width, height, scale), used when its device type
# bundle is missing from the runner.
PREFERRED_SCREEN = (1206, 2622, 3.0)
CREATED_PREFIX = "ABS+ CI "

WAIT_SECONDS = 180
RESTART_AFTER_SECONDS = 60
POLL_SECONDS = 10
ATTEMPTS = 2


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


def choose(listing, sdk, minimum, screen_of=screen):
    """Pick (runtime, device type, existing device or None, reason) or None.

    `listing` is `xcrun simctl list -j`, `sdk` the active iphonesimulator SDK
    version and `minimum` the app's deployment target. Pure apart from
    `screen_of`, so it can be tested without a runner.
    """
    runtimes = [
        r for r in listing.get("runtimes", [])
        if is_ios(r) and r.get("isAvailable")
        and version(minimum)[:2] <= version(r["version"])[:2] <= version(sdk)[:2]
    ]
    if not runtimes:
        return None
    runtime = max(runtimes, key=lambda r: version(r["version"]))
    types = {t["identifier"]: t for t in listing.get("devicetypes", [])}
    supported = [
        types.get(t["identifier"], t) for t in runtime.get("supportedDeviceTypes", [])
        if t.get("productFamily") == "iPhone"
    ]
    devices = sorted(
        (d for d in listing.get("devices", {}).get(runtime["identifier"], []) if d.get("isAvailable")),
        key=lambda d: (d["name"], d["udid"]),
    )

    def existing(type_id):
        return next((d for d in devices if d.get("deviceTypeIdentifier") == type_id), None)

    preferred = next((t for t in supported if t["identifier"] == PREFERRED), None)
    if preferred:
        return runtime, preferred, existing(PREFERRED), "preferred device"
    reference = (screen_of(types[PREFERRED]) if PREFERRED in types else None) or PREFERRED_SCREEN
    # Newest same-screen type first; reuse an existing device before creating one.
    same_screen = sorted(
        (t for t in supported if screen_of(t) == reference),
        key=lambda t: (t.get("minRuntimeVersion", 0), t["name"]), reverse=True,
    )
    if not same_screen:
        return None
    reused = next(((t, existing(t["identifier"])) for t in same_screen if existing(t["identifier"])), None)
    device_type, device = reused or (same_screen[0], None)
    return runtime, device_type, device, "same screen as iPhone 17"


def run(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode:
        log(f"{' '.join(args)} exited {result.returncode}: {result.stderr.strip()}")
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result


def deployment_target():
    with open(os.path.join(PROJECT, "project.pbxproj")) as f:
        targets = re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);", f.read())
    return max(targets, key=version)


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


def restart_simulator_service():
    # A stuck CoreSimulatorService is the usual reason for a runner that lists
    # no simulators; launchd restarts it on the next simctl call.
    result = run("sudo", "-n", "killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService", check=False)
    log(f"Restarted CoreSimulatorService (killall exited {result.returncode})")


def wait_for_choice(sdk, minimum, seconds, restart=True):
    deadline = time.monotonic() + seconds
    restart_at = time.monotonic() + RESTART_AFTER_SECONDS
    while True:
        data = listing()
        picked = choose(data, sdk, minimum)
        if picked:
            return picked
        log(f"No usable iOS {minimum}-{sdk} iPhone simulator yet: {summary(data)}")
        if time.monotonic() >= deadline:
            return None
        if restart and time.monotonic() >= restart_at:
            restart_simulator_service()
            restart = False
        time.sleep(POLL_SECONDS)


def prepare(picked):
    """Create (if needed) and boot the picked simulator; return its UDID and origin."""
    runtime, device_type, device, _ = picked
    if device:
        udid, origin = device["udid"], f"existing \"{device['name']}\""
    else:
        name = CREATED_PREFIX + device_type["name"]
        udid = run("xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"]).stdout.strip()
        origin = f"created \"{name}\""
    # Booting here surfaces a broken simulator before the build, not mid-suite.
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    destinations = run("xcodebuild", "-project", PROJECT, "-scheme", SCHEME, "-showdestinations").stdout
    if f"id:{udid}" not in destinations:
        log(destinations)
        raise RuntimeError(f"xcodebuild does not list simulator {udid}")
    return udid, origin


def main():
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").stdout.strip()
    minimum = deployment_target()
    log(run("xcodebuild", "-version").stdout.strip().replace("\n", ", ")
        + f", iphonesimulator SDK {sdk}, deployment target {minimum}")
    picked = wait_for_choice(sdk, minimum, WAIT_SECONDS)
    if not picked:
        log("No usable iOS runtime appeared; downloading the iOS platform for this Xcode")
        # Streamed rather than captured so a slow multi-GB download shows progress.
        subprocess.run(["xcodebuild", "-downloadPlatform", "iOS"], stdout=sys.stderr, stderr=sys.stderr)
        picked = wait_for_choice(sdk, minimum, POLL_SECONDS * 6, restart=False)
    for attempt in range(1, ATTEMPTS + 1):
        if not picked:
            break
        try:
            udid, origin = prepare(picked)
            break
        except (subprocess.CalledProcessError, RuntimeError) as error:
            log(f"Simulator attempt {attempt} failed: {error}")
            picked = None
            if attempt < ATTEMPTS:
                restart_simulator_service()
                picked = wait_for_choice(sdk, minimum, WAIT_SECONDS, restart=False)
    if not picked:
        log(run("xcrun", "simctl", "list", check=False).stdout)
        print(f"::error::No iPhone simulator with the iPhone 17 screen on iOS {minimum}-{sdk} is usable on this runner",
              file=sys.stderr)
        return 1
    runtime, device_type, _, reason = picked
    message = (f"iOS Simulator: {device_type['name']} on {runtime['name']} ({runtime.get('buildversion', '?')}), "
               f"{origin}, {reason}, UDID {udid}")
    print(f"::notice::{message}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
