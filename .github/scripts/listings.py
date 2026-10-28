#!/usr/bin/env python3
# Shared release script: keep .github/scripts/ identical in absplus, meshtastic-plus and todorant. Repo values come from env.
"""Store listings in every language, from the texts and screenshots in the repo.
  listings.py play [--dry-run]                    Google Play: title, short and full description, feature graphic and
                                                  phone, 7" and 10" screenshots per language; committing sends them to review
  listings.py appstore [--version X.Y.Z] [--dry-run]
                                                  App Store: name and subtitle, description, keywords, promotional text and
                                                  6.9" iPhone screenshots per locale, on the version being prepared, so they
                                                  ship with it; with no such version and none in review, it starts version X.Y.Z
                                                  (default: the last one's patch + 1), which appstore.py then renames and submits
Play: fastlane/metadata/android/<Play language>/title.txt, short_description.txt, full_description.txt and
  images/featureGraphic.{png,jpg}, images/{phone,sevenInch,tenInch}Screenshots/*.{png,jpg}
App Store: appstore/<locale>/listing.md (en-US: appstore/listing.md), sections "## Name", "## Subtitle", "## Keywords",
  "## Promotional text" and "## Description" (a "(max N)" after the title is fine), and appstore/screenshots/<locale>/*.{png,jpg}
--dry-run prints the changes and sends nothing (Play validates them in an edit it then discards). Only what differs
from the store is sent, so running it again is safe.
env: as for play.py and appstore.py."""
import glob, hashlib, json, os, re, sys, time, urllib.error, urllib.request

PLAY_ROOT, APPSTORE_ROOT, SHOTS_ROOT = "fastlane/metadata/android", "appstore", "appstore/screenshots"
PLAY_TEXTS = {"title": "title.txt", "shortDescription": "short_description.txt", "fullDescription": "full_description.txt"}
PLAY_IMAGES = {"featureGraphic": "featureGraphic", "phoneScreenshots": "phoneScreenshots/*",
               "sevenInchScreenshots": "sevenInchScreenshots/*", "tenInchScreenshots": "tenInchScreenshots/*"}
VERSION_TEXTS = {"description": "Description", "keywords": "Keywords", "promotionalText": "Promotional text"}
INFO_TEXTS = {"name": "Name", "subtitle": "Subtitle"}
DISPLAY = "APP_IPHONE_67"  # the 6.9" iPhone set (1320x2868); Apple scales it down for the smaller iPhones
TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def images(pattern):
    return sorted(f for f in glob.glob(pattern + ".*") if os.path.splitext(f)[1].lower() in TYPES)


def digest(path, kind="sha256"):
    return hashlib.new(kind, open(path, "rb").read()).hexdigest()


def sections(path):
    """The "## Title" sections of a listing.md, without their "(max N)" and surrounding blank lines"""
    out, name = {}, None
    for line in open(path, encoding="utf-8").read().split("\n"):
        m = re.match(r"^## (.+?)(?: \(max \d+\))?$", line)
        if m:
            name = m[1]
            out[name] = []
        elif name:
            out[name].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}


def appstore_locales(root=APPSTORE_ROOT):
    """locale -> its listing.md"""
    found = {"en-US": os.path.join(root, "listing.md")} if os.path.isfile(os.path.join(root, "listing.md")) else {}
    for d in sorted(os.listdir(root)):
        if os.path.isfile(os.path.join(root, d, "listing.md")):
            found[d] = os.path.join(root, d, "listing.md")
    return found


def next_version(versions):
    """The patch after the highest X.Y.Z"""
    top = max((tuple(int(p) for p in v.split(".")) + (0, 0))[:3] for v in versions) if versions else (1, 0, -1)
    return f"{top[0]}.{top[1]}.{top[2] + 1}"


def play(dry):
    import play as p
    token = p.access_token()
    edits = p.ROOT + f"androidpublisher/v3/applications/{os.environ['PLAY_PACKAGE']}/edits"

    def call(method, url, body=b"", content_type="application/json"):
        for attempt in range(5):
            request = urllib.request.Request(url, body, method=method, headers={"Authorization": "Bearer " + token, "Content-Type": content_type})
            try:
                with urllib.request.urlopen(request) as response:
                    return json.loads(response.read() or b"{}")
            except urllib.error.HTTPError as e:
                # Play answers 503 now and then, more so with dozens of image calls in one edit
                if e.code < 500 or attempt == 4:
                    sys.exit(f"{method} {url.split('?')[0]}: {e.code} {e.read().decode()}")
                print(f"{method} {url.split('?')[0]}: {e.code}, trying again")
                time.sleep(5 * 2 ** attempt)

    edit = call("POST", edits, b"{}")["id"]
    current = {listing["language"]: listing for listing in call("GET", f"{edits}/{edit}/listings").get("listings", [])}
    changed = 0
    for language in sorted(os.listdir(PLAY_ROOT)):
        folder = os.path.join(PLAY_ROOT, language)
        if not os.path.isfile(os.path.join(folder, "title.txt")):
            continue
        listing = {"language": language, **{k: open(os.path.join(folder, f), encoding="utf-8").read().strip()
                                              for k, f in PLAY_TEXTS.items() if os.path.isfile(os.path.join(folder, f))}}
        old = current.get(language, {})
        if any(old.get(k) != v for k, v in listing.items()):
            print(f"{language}: {'update' if old else 'add'} the listing ({listing['title']})")
            call("PUT", f"{edits}/{edit}/listings/{language}", json.dumps(listing).encode())
            changed += 1
        for kind, pattern in PLAY_IMAGES.items():
            files = images(os.path.join(folder, "images", pattern))
            if not files:
                continue
            shas = [digest(f) for f in files]
            if [i.get("sha256") for i in call("GET", f"{edits}/{edit}/listings/{language}/{kind}").get("images", [])] == shas:
                continue
            print(f"{language}: {kind} becomes {len(files)} image{'s' if len(files) > 1 else ''}")
            call("DELETE", f"{edits}/{edit}/listings/{language}/{kind}", None)
            for f in files:
                call("POST", edits.replace(p.ROOT, p.ROOT + "upload/") + f"/{edit}/listings/{language}/{kind}?uploadType=media",
                     open(f, "rb").read(), TYPES[os.path.splitext(f)[1].lower()])
            changed += 1
    if not changed:
        call("DELETE", f"{edits}/{edit}", None)
        print("Play listings are up to date")
    elif dry:
        call("POST", f"{edits}/{edit}:validate")
        call("DELETE", f"{edits}/{edit}", None)
        print(f"Play accepts {changed} change{'s' if changed != 1 else ''}; nothing was sent (dry run)")
    else:
        # A release or listing still in review makes this fail rather than withdrawing it
        call("POST", f"{edits}/{edit}:commit")
        print(f"{changed} Play listing change{'s' if changed != 1 else ''} sent to review")


def upload_screenshots(a, localization, files, say, dry):
    """Makes the locale's 6.9" set exactly these files, in this order; returns whether anything changed"""
    sets = {s["attributes"]["screenshotDisplayType"]: s for s in a.data("GET", f"/v1/appStoreVersionLocalizations/{localization}/appScreenshotSets")}
    shots = a.data("GET", f"/v1/appScreenshotSets/{sets[DISPLAY]['id']}/appScreenshots") if DISPLAY in sets else []
    if [s["attributes"].get("sourceFileChecksum") for s in shots] == [digest(f, "md5") for f in files]:
        return False
    say(f"  {len(files)} screenshots replace {len(shots)}")
    if dry:
        return True
    if DISPLAY in sets:
        shot_set = sets[DISPLAY]["id"]
        for s in shots:
            a.api("DELETE", f"/v1/appScreenshots/{s['id']}")
    else:
        shot_set = a.data("POST", "/v1/appScreenshotSets", body=a.resource("appScreenshotSets", attributes={"screenshotDisplayType": DISPLAY},
                          appStoreVersionLocalization={"type": "appStoreVersionLocalizations", "id": localization}))["id"]
    for f in files:
        raw = open(f, "rb").read()
        shot = a.data("POST", "/v1/appScreenshots", body=a.resource("appScreenshots", attributes={"fileName": os.path.basename(f), "fileSize": len(raw)},
                      appScreenshotSet={"type": "appScreenshotSets", "id": shot_set}))
        for op in shot["attributes"]["uploadOperations"]:
            part = urllib.request.Request(op["url"], raw[op["offset"]:op["offset"] + op["length"]], method=op["method"],
                                          headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])})
            urllib.request.urlopen(part).read()
        a.data("PATCH", f"/v1/appScreenshots/{shot['id']}", body=a.resource("appScreenshots", shot["id"], {"uploaded": True, "sourceFileChecksum": digest(f, "md5")}))
    return True


def appstore(version_string, dry):
    import appstore as a
    say = (lambda text: print("Would " + text[0].lower() + text[1:])) if dry else print
    all_versions = a.versions()
    availability = (a.data("GET", f"/v1/apps/{a.APP}/appAvailabilityV2", ok=(403, 404)) or {}).get("id")
    if availability:
        where = a.data("GET", f"/v2/appAvailabilities/{availability}/territoryAvailabilities", {"include": "territory", "limit": 200}, ok=(403, 404)) or []
        on = {t["relationships"]["territory"]["data"]["id"] for t in where if t["attributes"].get("available")}
        print(f"On sale in {len(on)} of {len(where)} territories; China mainland {'included' if 'CHN' in on else 'left out'}")
    version = next((v for v in all_versions if v["attributes"]["appStoreState"] in a.EDITABLE), None)
    pending = next((v for v in all_versions if v["attributes"]["appStoreState"] in a.OPEN), None)
    if not version and pending:
        # A version waiting for or in review is locked: what's sent now would wait for the one after it
        print(f"::warning::Version {pending['attributes']['versionString']} is {pending['attributes']['appStoreState']}, so its listing "
              "can't change; run this again once Apple is done with it (a release does, before it submits)")
        return
    if not version:
        version_string = version_string or next_version([v["attributes"]["versionString"] for v in all_versions])
        say(f"Start version {version_string}, which the next release takes over")
        if dry:
            return
        version = a.data("POST", "/v1/appStoreVersions", body=a.resource(
            "appStoreVersions", attributes={"platform": "IOS", "versionString": version_string, "releaseType": "AFTER_APPROVAL"},
            app={"type": "apps", "id": a.APP}))
    print(f"Version {version['attributes']['versionString']} ({version['attributes']['appStoreState']})")
    # The app info being edited is the one that isn't live yet
    infos = a.data("GET", f"/v1/apps/{a.APP}/appInfos")
    live = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "ACCEPTED", "REPLACED_WITH_NEW_INFO"}
    info = next((i for i in infos if i["attributes"].get("state", i["attributes"].get("appStoreState")) not in live), infos[0])
    rating = a.data("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration") or {}
    if rating.get("attributes", {}).get("socialMedia") is None:
        print("::warning::The age rating doesn't answer socialMedia yet: App Review rejects the submission until it does")
    listings = {locale: sections(path) for locale, path in appstore_locales().items()}
    targets = (("appStoreVersionLocalizations", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", VERSION_TEXTS,
                ("supportUrl", "marketingUrl"), {"appStoreVersion": {"type": "appStoreVersions", "id": version["id"]}}),
               ("appInfoLocalizations", f"/v1/appInfos/{info['id']}/appInfoLocalizations", INFO_TEXTS,
                ("privacyPolicyUrl",), {"appInfo": {"type": "appInfos", "id": info["id"]}}))
    for kind, path, names, copied, parent in targets:
        existing = {l["attributes"]["locale"]: l for l in a.data("GET", path, {"limit": 200})}
        base = existing.get("en-US") or next(iter(existing.values()), {"attributes": {}})
        for locale, texts in listings.items():
            fields = {attribute: texts[section] for attribute, section in names.items() if texts.get(section)}
            old = existing.get(locale)
            if old and all(old["attributes"].get(k) == v for k, v in fields.items()):
                continue
            say(f"{'Update' if old else 'Add'} {locale} {', '.join(fields)}")
            if dry:
                continue
            if old:
                a.data("PATCH", f"/v1/{kind}/{old['id']}", body=a.resource(kind, old["id"], fields))
            else:
                fields.update({k: base["attributes"][k] for k in copied if base["attributes"].get(k)})
                existing[locale] = a.data("POST", f"/v1/{kind}", body=a.resource(kind, attributes=dict(fields, locale=locale), **parent))
        if kind == "appStoreVersionLocalizations":
            for locale in listings:
                files = images(os.path.join(SHOTS_ROOT, locale, "*"))
                if not files:
                    continue
                if locale not in existing:
                    say(f"{locale}: upload {len(files)} screenshots once the localization exists")
                    continue
                print(f"{locale} screenshots:")
                if not upload_screenshots(a, existing[locale]["id"], files, say, dry):
                    print("  up to date")


def main():
    args = [x for x in sys.argv[1:] if x != "--dry-run"]
    dry = "--dry-run" in sys.argv
    if not args or args[0] not in ("play", "appstore"):
        sys.exit(__doc__)
    if args[0] == "play":
        play(dry)
    else:
        appstore(args[args.index("--version") + 1] if "--version" in args else None, dry)


if __name__ == "__main__":
    main()
