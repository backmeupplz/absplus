#!/usr/bin/env python3
# Shared release script: keep .github/scripts/ identical in absplus, meshtastic-plus and todorant. Repo values come from env.
"""Brings the app's open fdroiddata merge request up to a release: its metadata keeps one build entry, this version.
Once the merge request is merged, F-Droid's checkupdates follows new tags itself and this does nothing.
  fdroid.py <version> <version code> <commit> [--dry-run]   (--dry-run prints the change and pushes nothing)
  env: FDROID_MR (merge request number in fdroid/fdroiddata), FDROID_APP_ID, FDROID_FORK (e.g. backmeupplz/fdroiddata),
       FDROID_BRANCH, GITLAB_TOKEN (write_repository on the fork; only needed to push)"""
import difflib, json, os, re, subprocess, sys, tempfile, urllib.request
from urllib.parse import quote

API = "https://gitlab.com/api/v4/projects/"


def rewrite(metadata, version, code, commit):
    """The metadata at this release; exits if it doesn't hold exactly one build entry"""
    if len(re.findall(r"(?m)^  - versionName:", metadata)) != 1:
        sys.exit("The merge request's metadata should hold exactly one build entry")
    # YAML reads 1.2 as a number, so such versions get quotes like rewritemeta gives them
    name = f"'{version}'" if re.fullmatch(r"\d+(\.\d+)?", version) else version
    for key, value in (("versionName", name), ("versionCode", code), ("commit", commit), ("CurrentVersion", name), ("CurrentVersionCode", code)):
        metadata, found = re.subn(rf"(?m)^([ -]*{key}): .*$", rf"\g<1>: {value}", metadata)
        if found != 1:
            sys.exit(f"Expected one {key} line in the metadata, found {found}")
    return metadata


def main():
    version, code, commit = sys.argv[1:4]
    dry = "--dry-run" in sys.argv
    fork, branch, path = os.environ["FDROID_FORK"], os.environ["FDROID_BRANCH"], f"metadata/{os.environ['FDROID_APP_ID']}.yml"
    mr = json.load(urllib.request.urlopen(API + "fdroid%2Ffdroiddata/merge_requests/" + os.environ["FDROID_MR"]))
    if mr["state"] != "opened":
        return print(f"F-Droid merge request !{mr['iid']} is {mr['state']}: F-Droid picks up new tags itself")
    old = urllib.request.urlopen(f"{API}{quote(fork, safe='')}/repository/files/{quote(path, safe='')}/raw?ref={quote(branch)}").read().decode()
    new = rewrite(old, version, code, commit)
    if new == old:
        return print(f"F-Droid merge request !{mr['iid']} is at {version} already")
    print("".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), path, path)))
    if dry:
        return print("Dry run: nothing pushed")
    if not os.environ.get("GITLAB_TOKEN"):
        return print(f"::warning::No GITLAB_TOKEN secret: update F-Droid merge request !{mr['iid']} by hand")
    app = re.search(r"(?m)^AutoName: (.*)$", new).group(1)
    # The token reaches git through a credential helper, so it's never in a URL, an argument or the log
    helper = '!f() { echo username=oauth2; echo "password=$GITLAB_TOKEN"; }; f'
    with tempfile.TemporaryDirectory() as clone:
        def git(*args):
            subprocess.run(["git", "-c", "credential.helper=", "-c", "credential.helper=" + helper, "-c", "user.name=backmeupplz",
                            "-c", "user.email=backmeupplz@users.noreply.gitlab.com", *args], check=True, cwd=clone,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
        git("clone", "-q", "--depth", "1", "--single-branch", "--branch", branch, "--filter=blob:none", "--sparse",
            f"https://gitlab.com/{fork}.git", ".")
        git("sparse-checkout", "set", "--no-cone", "/" + path)
        with open(os.path.join(clone, path), "w") as f:
            f.write(new)
        git("commit", "-q", "-am", f"{app} {version}")
        git("push", "-q", "origin", "HEAD:" + branch)
    print(f"F-Droid merge request !{mr['iid']} is at {version} now: {mr['web_url']}")


if __name__ == "__main__":
    main()
