"""Checks for the shared release scripts: python3 -m unittest discover -s .github/scripts"""
import contextlib, io, json, os, subprocess, sys, tempfile, unittest
from unittest import mock

os.environ.setdefault("APP_STORE_APP_ID", "1")
os.environ.setdefault("ASC_KEY_ID", "KEY")
os.environ.setdefault("ASC_ISSUER_ID", "issuer")
sys.path.insert(0, os.path.dirname(__file__))
import appstore, fdroid, notes

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

    def test_es256_signature_from_der(self):
        r, s = b"\x00" + b"\x80" * 32, b"\x01" * 31  # a padded r and a short s
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        self.assertEqual(appstore.raw_signature(der), b"\x80" * 32 + b"\x00" + b"\x01" * 31)


if __name__ == "__main__":
    unittest.main()
