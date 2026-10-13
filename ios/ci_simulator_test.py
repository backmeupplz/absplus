import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from ci_simulator import PREFERRED, choose  # noqa: E402

SCREENS = {
    "iPhone-17": (1206, 2622, 3.0),
    "iPhone-17-Pro": (1206, 2622, 3.0),
    "iPhone-16-Pro": (1206, 2622, 3.0),
    "iPhone-16": (1179, 2556, 3.0),
    "iPhone-Air": (1260, 2736, 3.0),
}


def device_type(short, min_runtime):
    return {
        "identifier": f"com.apple.CoreSimulator.SimDeviceType.{short}",
        "name": short.replace("-", " "),
        "productFamily": "iPhone",
        "minRuntimeVersion": min_runtime,
    }


TYPES = [
    device_type("iPhone-16", 1179648),
    device_type("iPhone-16-Pro", 1179648),
    device_type("iPhone-17", 1703936),
    device_type("iPhone-17-Pro", 1703936),
    device_type("iPhone-Air", 1703936),
    {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro", "name": "iPad Pro", "productFamily": "iPad"},
]


def screen_of(t):
    return SCREENS.get(t["identifier"].rsplit(".", 1)[1])


def runtime(ver, types, available=True, platform="iOS"):
    return {
        "identifier": f"com.apple.CoreSimulator.SimRuntime.{platform}-{ver.replace('.', '-')}",
        "name": f"{platform} {ver}",
        "version": ver,
        "platform": platform,
        "isAvailable": available,
        "supportedDeviceTypes": [{k: t[k] for k in ("identifier", "name", "productFamily")} for t in types],
    }


def device(name, short, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available,
            "deviceTypeIdentifier": f"com.apple.CoreSimulator.SimDeviceType.{short}"}


def listing(runtimes, devices=None, types=TYPES):
    return {"runtimes": runtimes, "devicetypes": types, "devices": devices or {}}


class ChooseTest(unittest.TestCase):
    def pick(self, data, sdk="26.6", minimum="26.1"):
        return choose(data, sdk, minimum, screen_of)

    def test_reuses_existing_iphone_17_on_newest_runtime(self):
        old, new = runtime("26.2", TYPES), runtime("26.5", TYPES)
        data = listing([old, new], {
            old["identifier"]: [device("iPhone 17", "iPhone-17", "OLD")],
            new["identifier"]: [device("iPhone 16", "iPhone-16", "A"), device("iPhone 17", "iPhone-17", "B")],
        })
        rt, t, d, _ = self.pick(data)
        self.assertEqual((rt["version"], t["identifier"], d["udid"]), ("26.5", PREFERRED, "B"))

    def test_creates_iphone_17_when_runtime_has_no_devices(self):
        data = listing([runtime("26.5", TYPES)])
        rt, t, d, reason = self.pick(data)
        self.assertEqual((rt["version"], t["identifier"], d), ("26.5", PREFERRED, None))
        self.assertEqual(reason, "preferred device")

    def test_ignores_unavailable_devices_and_runtimes(self):
        good, broken = runtime("26.2", TYPES), runtime("26.5", TYPES, available=False)
        data = listing([good, broken], {good["identifier"]: [device("iPhone 17", "iPhone-17", "X", available=False)]})
        rt, t, d, _ = self.pick(data)
        self.assertEqual((rt["version"], t["identifier"], d), ("26.2", PREFERRED, None))

    def test_skips_runtimes_newer_than_the_sdk(self):
        data = listing([runtime("26.5", TYPES), runtime("27.0", TYPES)])
        self.assertEqual(self.pick(data)[0]["version"], "26.5")
        self.assertIsNone(self.pick(listing([runtime("27.0", TYPES)])))

    def test_ignores_other_platforms(self):
        self.assertIsNone(self.pick(listing([runtime("26.5", TYPES, platform="tvOS")])))

    def test_falls_back_to_same_screen_device(self):
        types = [t for t in TYPES if t["identifier"] != PREFERRED]
        rt = runtime("26.5", types)
        _, t, d, reason = self.pick(listing([rt], types=types))
        self.assertEqual((t["name"], d), ("iPhone 17 Pro", None))
        self.assertEqual(reason, "same screen as iPhone 17")
        _, t, d, _ = self.pick(listing([rt], {rt["identifier"]: [device("Mine", "iPhone-16-Pro", "P")]}, types=types))
        self.assertEqual((t["name"], d["udid"]), ("iPhone 16 Pro", "P"))

    def test_refuses_a_different_screen(self):
        types = [t for t in TYPES if t["identifier"].rsplit(".", 1)[1] in ("iPhone-16", "iPhone-Air")]
        self.assertIsNone(self.pick(listing([runtime("26.5", types)], types=types)))

    def test_skips_runtimes_older_than_the_deployment_target(self):
        data = listing([runtime("26.0", TYPES), runtime("26.0.1", TYPES)])
        self.assertIsNone(self.pick(data))
        data["runtimes"].append(runtime("26.1", TYPES))
        self.assertEqual(self.pick(data)[0]["version"], "26.1")

    def test_nothing_usable(self):
        self.assertIsNone(self.pick({}))
        self.assertIsNone(self.pick(listing([runtime("26.5", TYPES[-1:])])))


if __name__ == "__main__":
    unittest.main()
