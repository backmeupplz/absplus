"""Checks for the shared release scripts: python3 -m unittest discover -s .github/scripts"""
import os, sys, unittest

os.environ.setdefault("APP_STORE_APP_ID", "1")
os.environ.setdefault("ASC_KEY_ID", "KEY")
os.environ.setdefault("ASC_ISSUER_ID", "issuer")
sys.path.insert(0, os.path.dirname(__file__))
import appstore, fdroid

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

    def test_es256_signature_from_der(self):
        r, s = b"\x00" + b"\x80" * 32, b"\x01" * 31  # a padded r and a short s
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        self.assertEqual(appstore.raw_signature(der), b"\x80" * 32 + b"\x00" + b"\x01" * 31)


if __name__ == "__main__":
    unittest.main()
