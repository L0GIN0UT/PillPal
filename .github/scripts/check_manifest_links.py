"""Check the merged Android manifest for unsafe VIEW intent filters.

Invite links are https App Links only (docs/adr/0009-invite-links.md): a
custom URL scheme can be claimed by any other app and would hand it the
invite token. This script fails when a component of the *merged* manifest
(the app and every plugin) declares a VIEW intent filter that is not
https-only with a concrete host, or that is not verified (autoVerify).
`<queries>` entries are not intent filters and are ignored.

Usage: check_manifest_links.py <merged AndroidManifest.xml>
       check_manifest_links.py --self-test
"""

import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
VIEW = "android.intent.action.VIEW"
COMPONENTS = ("activity", "activity-alias")


def _name(element: ET.Element) -> str:
    return element.attrib.get(ANDROID + "name", "?")


def problems(manifest_xml: str) -> list[str]:
    """Return one message per offending intent filter (empty: all good)."""
    root = ET.fromstring(manifest_xml)
    found: list[str] = []
    for component in root.iter():
        if component.tag not in COMPONENTS:
            continue
        for index, intent_filter in enumerate(component.findall("intent-filter")):
            actions = {a.attrib.get(ANDROID + "name") for a in intent_filter.findall("action")}
            if VIEW not in actions:
                continue
            where = f"{_name(component)} filter #{index + 1}"
            data = intent_filter.findall("data")
            schemes = {d.attrib.get(ANDROID + "scheme") for d in data}
            if not data or schemes != {"https"}:
                found.append(f"{where}: VIEW filter is not https-only (schemes: {sorted(map(str, schemes))})")
                continue
            hosts = [d.attrib.get(ANDROID + "host") for d in data if ANDROID + "host" in d.attrib]
            if not hosts or any("$" in host for host in hosts):
                found.append(f"{where}: https filter without a concrete host")
            if intent_filter.attrib.get(ANDROID + "autoVerify") != "true":
                found.append(f"{where}: https filter without autoVerify")
    return found


_GOOD = """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
<application><activity android:name=".Main">
<intent-filter><action android:name="android.intent.action.MAIN"/></intent-filter>
<intent-filter android:autoVerify="true">
<action android:name="android.intent.action.VIEW"/>
<data android:scheme="https" android:host="links.example.invalid" android:path="/i"/>
</intent-filter></activity></application>
<queries><intent><action android:name="android.intent.action.VIEW"/>
<data android:scheme="geo"/></intent></queries></manifest>"""


def _variant(old: str, new: str) -> str:
    assert old in _GOOD
    return _GOOD.replace(old, new)


def self_test() -> None:
    assert problems(_GOOD) == []
    custom = _variant('android:scheme="https"', 'android:scheme="pillpal"')
    assert len(problems(custom)) == 1
    mixed = _variant(
        '<data android:scheme="https" android:host="links.example.invalid" android:path="/i"/>',
        '<data android:scheme="https" android:host="h.invalid"/><data android:scheme="http"/>',
    )
    assert len(problems(mixed)) == 1
    unverified = _variant(' android:autoVerify="true"', "")
    assert len(problems(unverified)) == 1
    unresolved = _variant("links.example.invalid", "${linkHostRu}")
    assert len(problems(unresolved)) == 1
    alias = _GOOD.replace(
        "</activity></application>",
        '</activity><activity-alias android:name=".Alias" android:targetActivity=".Main">'
        '<intent-filter android:autoVerify="true">'
        '<action android:name="android.intent.action.VIEW"/>'
        '<data android:scheme="pillpal" android:host="x"/></intent-filter>'
        "</activity-alias></application>",
    )
    assert len(problems(alias)) == 1
    good_alias = alias.replace('android:scheme="pillpal"', 'android:scheme="https"')
    assert problems(good_alias) == []
    bare = _variant(
        '<data android:scheme="https" android:host="links.example.invalid" android:path="/i"/>', ""
    )
    assert len(problems(bare)) == 1
    print("self-test ok")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        found = problems(handle.read())
    for message in found:
        print(f"::error title=Android manifest::{message}")
    if not found:
        print("merged manifest: every VIEW intent filter is a verified https App Link")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
