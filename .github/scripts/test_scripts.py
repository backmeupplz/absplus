"""Checks for the shared release scripts: python3 -m unittest discover -s .github/scripts"""
import contextlib, hashlib, io, json, os, subprocess, sys, tempfile, unittest
from unittest import mock

os.environ.setdefault("APP_STORE_APP_ID", "1")
os.environ.setdefault("ASC_KEY_ID", "KEY")
os.environ.setdefault("ASC_ISSUER_ID", "issuer")
sys.path.insert(0, os.path.dirname(__file__))
import appstore, fdroid, listings, notes


class FakeStore:
    """App Store Connect for listings.appstore: versions, one app info, localizations and screenshots, recording writes"""
    def __init__(self, versions, localizations=None):
        self.versions = [{"id": i, "attributes": {"versionString": s, "appStoreState": state}} for i, s, state in versions]
        self.localizations = {locale: {"id": "loc-" + locale, "attributes": dict(a, locale=locale)} for locale, a in (localizations or {}).items()}
        self.writes, self.uploaded, self.count = [], [], 0

    def data(self, method, path, query=None, body=None, ok=()):
        if method != "GET":
            self.writes.append((method, path, body))
            self.count += 1
            new = {"id": f"new-{self.count}", "attributes": dict(body["data"].get("attributes", {}))}
            if path == "/v1/appStoreVersions":
                new["attributes"]["appStoreState"] = "PREPARE_FOR_SUBMISSION"
            if path == "/v1/appScreenshots":
                new["attributes"]["uploadOperations"] = [{"method": "PUT", "url": f"https://upload/{self.count}", "offset": 0,
                                                          "length": new["attributes"]["fileSize"], "requestHeaders": []}]
            return new
        if path.endswith("/appStoreVersions"):
            return self.versions
        if path.endswith("/appAvailabilityV2"):
            return {"id": "avail"}
        if path.endswith("/territoryAvailabilities"):
            return [{"attributes": {"available": t != "CHN"}, "relationships": {"territory": {"data": {"id": t}}}} for t in ("USA", "CHN")]
        if path.endswith("/appInfos"):
            return [{"id": "info", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]
        if path.endswith("/ageRatingDeclaration"):
            return {"attributes": {"socialMedia": False}}
        if path.endswith("/appStoreVersionLocalizations"):
            return list(self.localizations.values())
        return []  # no app info localizations, screenshot sets or screenshots yet

    def api(self, method, path, query=None, body=None, ok=()):
        return {"data": self.data(method, path, query, body=body, ok=ok)}

    def urlopen(self, request):
        self.uploaded.append(request.data)
        return mock.MagicMock()

    def __enter__(self):
        self.patches = [mock.patch.object(appstore, "data", self.data), mock.patch.object(appstore, "api", self.api),
                        mock.patch.object(appstore, "versions", lambda: self.versions),
                        mock.patch.object(listings.urllib.request, "urlopen", self.urlopen)]
        for p in self.patches: p.start()
        return self

    def __exit__(self, *exc):
        for p in self.patches: p.stop()

METADATA = """AutoName: Mesh+

RepoType: git
Repo: https://github.com/backmeupplz/meshtastic-plus.git
Binaries:
  https://github.com/backmeupplz/meshtastic-plus/releases/download/v%v/meshplus.apk

Builds:
  - versionName: 0.4.3
    versionCode: 7
    commit: 793ee7cd8fe0103fb4857c13a73bc0c4af1a8926
    subdir: app
    gradle:
      - fdroid

AllowedAPKSigningKeys: 9216a9c3839474e6d9702f93baa0f4b7c26be5f606606c32d806f23ce91977a8

AutoUpdateMode: Version
UpdateCheckMode: Tags
CurrentVersion: 0.4.3
CurrentVersionCode: 7
""".replace("Binaries:\n", "Binaries: \n")  # rewritemeta leaves a space after Binaries:

# metadata/com.todorant.yml on the fork's com.todorant branch, 2026-10-16
TODORANT = """Categories:
  - Task
License: MPL-2.0
AuthorName: borodutch
WebSite: https://todorant.com
SourceCode: https://github.com/backmeupplz/todorant
IssueTracker: https://github.com/backmeupplz/todorant/issues

AutoName: Todorant

RepoType: git
Repo: https://github.com/backmeupplz/todorant.git
Binaries:
  https://github.com/backmeupplz/todorant/releases/download/android-v%v/todorant-fdroid-%v.apk

Builds:
  - versionName: 2.2.4
    versionCode: 5000006
    commit: b3ae215ce4916d7a669ed3350a4b622964b1d153
    subdir: android/app
    gradle:
      - fdroid

AllowedAPKSigningKeys: c9c7aa8d153d7e7d16b5848b320448e82a565ff9cd761e8ecf1734558ee90731

AutoUpdateMode: Version
UpdateCheckMode: Tags ^android-v
CurrentVersion: 2.2.4
CurrentVersionCode: 5000006
""".replace("Binaries:\n", "Binaries: \n")


class Scripts(unittest.TestCase):
    def test_fdroid_rewrite_touches_only_the_version_lines(self):
        new = fdroid.rewrite(METADATA, "0.4.4", "8", "662f13bb36d7ccd19f5813a06b0f89729ceb4ad2")
        changed = [(a, b) for a, b in zip(METADATA.splitlines(), new.splitlines()) if a != b]
        self.assertEqual([b for a, b in changed], [
            "  - versionName: 0.4.4", "    versionCode: 8", "    commit: 662f13bb36d7ccd19f5813a06b0f89729ceb4ad2",
            "CurrentVersion: 0.4.4", "CurrentVersionCode: 8"])
        self.assertIn("Binaries: \n  https://", new)  # rewritemeta's wrapping survives

    def test_fdroid_quotes_versions_yaml_would_read_as_numbers(self):
        self.assertIn("  - versionName: '1.3'\n", fdroid.rewrite(METADATA, "1.3", "9", "a" * 40))

    def test_fdroid_refuses_more_than_one_build(self):
        with self.assertRaises(SystemExit):
            fdroid.rewrite(METADATA.replace("Builds:\n", "Builds:\n  - versionName: 0.4.2\n    versionCode: 6\n"), "0.4.4", "8", "a" * 40)

    def test_fdroid_moves_todorant_to_v_tags(self):
        new = fdroid.rewrite(TODORANT, "2.2.5", "5000007", "b" * 40, "Tags ^v",
                             "https://github.com/backmeupplz/todorant/releases/download/v%v/todorant-fdroid-%v.apk")
        self.assertIn("\nBinaries: \n  https://github.com/backmeupplz/todorant/releases/download/v%v/todorant-fdroid-%v.apk\n\nBuilds:", new)
        self.assertIn("\nUpdateCheckMode: Tags ^v\nCurrentVersion: 2.2.5\nCurrentVersionCode: 5000007\n", new)
        self.assertEqual(len(new.splitlines()), len(TODORANT.splitlines()))

    def test_fdroid_binaries_wrap_like_rewritemeta(self):
        # rewritemeta (fdroidserver 2.4.2, ruamel.yaml 0.18.10) wraps values over 80 characters: Mesh+'s 81, not ABS+'s 75
        for url, wrapped in (("https://github.com/backmeupplz/meshtastic-plus/releases/download/v%v/meshplus.apk", True),
                             ("https://github.com/backmeupplz/absplus/releases/download/v%v/absplus-%v.apk", False),
                             ("x" * 80, False), ("x" * 81, True)):
            new = fdroid.rewrite(METADATA, "0.4.3", "7", "793ee7cd8fe0103fb4857c13a73bc0c4af1a8926", binaries=url)
            self.assertIn(("Binaries: \n  " if wrapped else "Binaries: ") + url + "\n\nBuilds:", new)

    def test_fdroid_same_values_change_nothing(self):
        self.assertEqual(fdroid.rewrite(METADATA, "0.4.3", "7", "793ee7cd8fe0103fb4857c13a73bc0c4af1a8926", "Tags",
                                        "https://github.com/backmeupplz/meshtastic-plus/releases/download/v%v/meshplus.apk"), METADATA)

    def test_fdroid_rewrite_sets_the_gradle_flavor(self):
        # A flavored app's entry needs its flavor: with gradle: [yes] Gradle builds every flavor and fdroidserver finds no APK
        old = METADATA.replace("      - fdroid\n", "      - yes\n")
        new = fdroid.rewrite(old, "0.4.4", "8", "a" * 40, gradle="fdroid")
        self.assertEqual(new, fdroid.rewrite(METADATA, "0.4.4", "8", "a" * 40))
        self.assertIn("    subdir: app\n    gradle:\n      - fdroid\n\nAllowedAPKSigningKeys", new)
        # The same value changes nothing, and without FDROID_GRADLE the entry keeps the flavor it has
        self.assertEqual(fdroid.rewrite(new, "0.4.4", "8", "a" * 40, gradle="fdroid"), new)
        self.assertIn("    gradle:\n      - fdroid\n", fdroid.rewrite(new, "0.4.5", "9", "b" * 40))
        with self.assertRaises(SystemExit):
            fdroid.rewrite(METADATA.replace("    gradle:\n      - fdroid\n", ""), "0.4.4", "8", "a" * 40, gradle="fdroid")

    def test_fdroid_main_takes_the_gradle_flavor_from_the_env(self):
        old = METADATA.replace("      - fdroid\n", "      - yes\n")
        def urlopen(url):
            body = json.dumps({"state": "opened", "iid": 123, "web_url": "https://gitlab.com/mr"}) if "merge_requests" in url else old
            return io.BytesIO(body.encode())
        env = {"FDROID_MR": "123", "FDROID_APP_ID": "com.example", "FDROID_FORK": "backmeupplz/fdroiddata", "FDROID_BRANCH": "com.example",
               "FDROID_GRADLE": "fdroid"}
        with mock.patch.dict(os.environ, env), mock.patch("sys.argv", ["fdroid.py", "0.4.4", "8", "a" * 40, "--dry-run"]), \
                mock.patch.object(fdroid.urllib.request, "urlopen", urlopen), contextlib.redirect_stdout(io.StringIO()) as out:
            fdroid.main()
        self.assertIn("\n-      - yes\n+      - fdroid\n", out.getvalue())
        self.assertIn("Dry run: nothing pushed", out.getvalue())

    def test_fdroid_push_failure_reports_git_output_without_the_token(self):
        def urlopen(url):
            body = json.dumps({"state": "opened", "iid": 123, "web_url": "https://gitlab.com/mr"}) if "merge_requests" in url else METADATA
            return io.BytesIO(body.encode())
        def run(argv, cwd, **kw):
            self.assertTrue(kw["capture_output"])
            if "push" not in argv:
                if "sparse-checkout" in argv:
                    os.makedirs(os.path.join(cwd, "metadata"))
                return subprocess.CompletedProcess(argv, 0, "", "")
            return subprocess.CompletedProcess(argv, 1, "", "remote: HTTP Basic: Access denied for s3cret-token\nfatal: Authentication failed for 'https://gitlab.com/backmeupplz/fdroiddata.git/'\n")
        env = {"GITLAB_TOKEN": "s3cret-token", "FDROID_MR": "123", "FDROID_APP_ID": "com.example", "FDROID_FORK": "backmeupplz/fdroiddata", "FDROID_BRANCH": "com.example"}
        with mock.patch.dict(os.environ, env), mock.patch("sys.argv", ["fdroid.py", "0.4.4", "8", "a" * 40]), \
                mock.patch.object(fdroid.urllib.request, "urlopen", urlopen), mock.patch.object(fdroid.subprocess, "run", run), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit:
            fdroid.main()
        self.assertEqual(exit.exception.code, "git push failed with status 1: remote: HTTP Basic: Access denied for *** | fatal: Authentication failed for 'https://gitlab.com/backmeupplz/fdroiddata.git/'")

    def test_notes_per_language_fall_back_to_english(self):
        with tempfile.TemporaryDirectory() as root:
            def write(folder, text):
                os.makedirs(os.path.join(root, folder, "changelogs"), exist_ok=True)
                with open(os.path.join(root, folder, "changelogs", "7.txt"), "w") as f: f.write(text)
            write("en-US", "Faster sync.\n")
            write("de-DE", "Schnellere Synchronisierung.\n")
            write("zh-CN", "同步更快。")
            write("es-419", "Sincronización más rápida.")
            write("fr-FR", "  \n")  # empty: the English
            english = os.path.join(root, "en-US", "changelogs", "7.txt")
            self.assertEqual(notes.read(english, "de-DE", 500), "Schnellere Synchronisierung.")
            self.assertEqual(notes.read(english, "zh-Hans", 4000), "同步更快。")  # App Store locale -> Play folder
            self.assertEqual(notes.read(english, "es-MX", 4000), "Sincronización más rápida.")
            self.assertEqual(notes.read(english, "fr-FR", 500), "Faster sync.")
            self.assertEqual(notes.read(english, "ja", 4000), "Faster sync.")  # no folder
            self.assertEqual(notes.read(english, "de-DE", 10), "Schnellere")
            self.assertEqual(notes.path(english, "en-US"), english)

    def test_listing_sections_and_versions(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "de-DE"))
            os.makedirs(os.path.join(root, "screenshots"))  # no listing.md: not a locale
            with open(os.path.join(root, "listing.md"), "w") as f:
                f.write("# App Store listing (en-US)\n\n## Name (max 30)\nQuilcast\n\n## Description (max 4000)\nOne.\n\nTwo.\n\n## URLs\n- x\n")
            with open(os.path.join(root, "de-DE", "listing.md"), "w") as f:
                f.write("## Name\nQuilcast DE\n")
            self.assertEqual(listings.appstore_locales(root), {"en-US": os.path.join(root, "listing.md"), "de-DE": os.path.join(root, "de-DE", "listing.md")})
            self.assertEqual(listings.sections(os.path.join(root, "listing.md")), {"Name": "Quilcast", "Description": "One.\n\nTwo.", "URLs": "- x"})
        self.assertEqual(listings.next_version(["1.0.0", "0.9.12", "1.0"]), "1.0.1")
        self.assertEqual(listings.next_version([]), "1.0.0")

    def test_listings_wait_for_a_version_in_review(self):
        store = FakeStore([("v1", "1.0.0", "WAITING_FOR_REVIEW")])
        with store:
            listings.appstore("1.0.1", False)
        self.assertEqual(store.writes, [])

    def test_listings_start_the_next_version_and_fill_every_locale(self):
        store = FakeStore([("v1", "1.0.0", "READY_FOR_SALE")], {"en-US": {"supportUrl": "https://s", "description": "Old"}})
        with tempfile.TemporaryDirectory() as root, store:
            cwd = os.getcwd()
            try:
                os.chdir(root)
                os.makedirs("appstore/de-DE")
                os.makedirs("appstore/screenshots/de-DE")
                with open("appstore/listing.md", "w") as f: f.write("## Name\nQuilcast\n## Description\nOld\n")
                with open("appstore/de-DE/listing.md", "w") as f: f.write("## Name\nQuilcast\n## Subtitle\nFarcaster-Client\n## Description\nNeu\n")
                for n in (1, 2):
                    with open(f"appstore/screenshots/de-DE/{n}.jpg", "wb") as f: f.write(b"jpeg %d" % n)
                listings.appstore(None, True)
                self.assertEqual(store.writes, [])  # a dry run sends nothing
                listings.appstore("1.0.1", False)
            finally:
                os.chdir(cwd)
        kinds = [(method, path.split("/")[2]) for method, path, _ in store.writes]
        self.assertEqual(kinds[0], ("POST", "appStoreVersions"))
        self.assertEqual(store.writes[0][2]["data"]["attributes"]["versionString"], "1.0.1")
        added = [body["data"]["attributes"] for method, path, body in store.writes if path == "/v1/appStoreVersionLocalizations"]
        self.assertEqual(added, [{"description": "Neu", "locale": "de-DE", "supportUrl": "https://s"}])  # en-US was already right
        self.assertEqual([body["data"]["attributes"]["fileName"] for method, path, body in store.writes if path == "/v1/appScreenshots"], ["1.jpg", "2.jpg"])
        self.assertEqual(store.uploaded, [b"jpeg 1", b"jpeg 2"])
        done = [body["data"]["attributes"] for method, path, body in store.writes if method == "PATCH" and "appScreenshots/" in path]
        self.assertEqual([d["sourceFileChecksum"] for d in done], [hashlib.md5(b"jpeg 1").hexdigest(), hashlib.md5(b"jpeg 2").hexdigest()])

    def test_es256_signature_from_der(self):
        r, s = b"\x00" + b"\x80" * 32, b"\x01" * 31  # a padded r and a short s
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        self.assertEqual(appstore.raw_signature(der), b"\x80" * 32 + b"\x00" + b"\x01" * 31)


if __name__ == "__main__":
    unittest.main()
