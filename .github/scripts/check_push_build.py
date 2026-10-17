"""Check what a build made of the push settings (docs/adr/0008-push-delivery.md).

Without PILLPAL_FCM_* and PILLPAL_RUSTORE_PROJECT_ID defines a build must be
the build it was before push existed: no Firebase resources, no RuStore project
in the merged manifest, and Firebase must not make a token by itself. With
them, the native side must carry exactly what Dart is told.

Usage: check_push_build.py <variant> [--fcm] [--rustore-project ID]
       (run in app/ after `flutter build`; no flags: a build without settings)
       check_push_build.py --self-test
"""

import argparse
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
RUSTORE_KEY = "ru.rustore.sdk.pushclient.project_id"
AUTO_INIT_KEY = "firebase_messaging_auto_init_enabled"
# Firebase collects nothing beyond delivering messages (ADR 0008 section 7).
DATA_FLAGS = {
    AUTO_INIT_KEY: "false",
    "firebase_analytics_collection_deactivated": "true",
    "google_analytics_adid_collection_enabled": "false",
    "delivery_metrics_exported_to_big_query_enabled": "false",
}
AD_ID_PERMISSION = "com.google.android.gms.permission.AD_ID"
STUB_MODULE = "rustore_sdk_stub"
FIREBASE_STRINGS = ("google_app_id", "google_api_key", "gcm_defaultSenderId", "project_id")


def metadata(manifest_xml: str) -> dict[str, str]:
    """Every meta-data entry of a manifest, by name."""
    root = ET.fromstring(manifest_xml)
    return {
        element.attrib.get(ANDROID + "name", ""): element.attrib.get(ANDROID + "value", "")
        for element in root.iter("meta-data")
    }


def permissions(manifest_xml: str) -> set[str]:
    """Names of the permissions a manifest requests."""
    root = ET.fromstring(manifest_xml)
    return {
        element.attrib.get(ANDROID + "name", "")
        for element in root.iter("uses-permission")
    }


def string_names(resources_xml: str) -> set[str]:
    """Names of the <string> resources of a values file."""
    return {
        element.attrib.get("name", "")
        for element in ET.fromstring(resources_xml).iter("string")
    }


def problems(
    meta: dict[str, str],
    strings: set[str],
    fcm: bool,
    rustore_project: str | None,
    requested_permissions: set[str] | None = None,
) -> list[str]:
    """What is wrong with a build given the settings it was built with."""
    found: list[str] = []
    for key, expected in DATA_FLAGS.items():
        if meta.get(key) != expected:
            found.append(f"{key} is not {expected} in the merged manifest")
    if AD_ID_PERMISSION in (requested_permissions or set()):
        found.append("the advertising id permission is in the merged manifest")
    if rustore_project is None and RUSTORE_KEY in meta:
        found.append("the RuStore project id is in the manifest of a build without one")
    if rustore_project is not None and meta.get(RUSTORE_KEY) != rustore_project:
        found.append("the RuStore project id of the build is not in the merged manifest")
    present = set(FIREBASE_STRINGS) & strings
    if not fcm and present:
        found.append(f"Firebase resources in a build without settings: {sorted(present)}")
    if fcm and present != set(FIREBASE_STRINGS):
        missing = sorted(set(FIREBASE_STRINGS) - strings)
        found.append(f"Firebase resources missing from the build: {missing}")
    return found


def stub_in_report(dependency_report: str) -> bool:
    """Whether a Gradle dependency report resolves anything to the SDK stub."""
    return STUB_MODULE in dependency_report


def _release_uses_stub() -> bool:
    """Runs the dependency report of the release classpath (in app/android)."""
    report = subprocess.run(
        ["./gradlew", "-q", ":app:dependencies", "--configuration", "releaseRuntimeClasspath"],
        cwd="android",
        capture_output=True,
        text=True,
        check=True,
    )
    return stub_in_report(report.stdout)


def _read(paths: list[pathlib.Path]) -> list[str]:
    return [path.read_text(encoding="utf-8") for path in paths]


def _check_build(variant: str, fcm: bool, rustore_project: str | None) -> int:
    build = pathlib.Path("build/app")
    manifests = sorted((build / "intermediates/merged_manifests" / variant).rglob("AndroidManifest.xml"))
    if not manifests:
        print(f"::error::merged {variant} manifest not found")
        return 1
    meta: dict[str, str] = {}
    requested: set[str] = set()
    for text in _read(manifests):
        meta.update(metadata(text))
        requested |= permissions(text)
    generated = sorted(build.rglob(f"resValues/{variant}/**/*.xml"))
    if fcm and not generated:
        print(f"::error::generated {variant} resValues not found")
        return 1
    strings: set[str] = set()
    for text in _read(generated):
        strings |= string_names(text)
    found = problems(meta, strings, fcm, rustore_project, requested)
    if variant == "release" and rustore_project is not None and _release_uses_stub():
        found.append(f"the release of a RuStore build resolves {STUB_MODULE}")
    for message in found:
        print(f"::error::{message}")
    return 1 if found else 0


def _self_test() -> int:
    ok_meta = dict(DATA_FLAGS)
    full = set(FIREBASE_STRINGS)
    assert problems(ok_meta, set(), False, None) == []
    assert problems({}, set(), False, None)  # auto-init must be disabled
    assert problems({**ok_meta, RUSTORE_KEY: "x"}, set(), False, None)
    assert problems(ok_meta, {"google_app_id"}, False, None)
    assert problems({**ok_meta, RUSTORE_KEY: "abc"}, full, True, "abc") == []
    assert problems({**ok_meta, RUSTORE_KEY: "other"}, full, True, "abc")
    assert problems(ok_meta, {"google_app_id"}, True, None)
    assert problems(ok_meta, full, True, None) == []  # FCM without RuStore
    assert problems({**ok_meta, RUSTORE_KEY: "abc"}, set(), False, "abc") == []
    for key in DATA_FLAGS:  # each flag must be present with its value
        assert problems({k: v for k, v in ok_meta.items() if k != key}, set(), False, None)
        assert problems({**ok_meta, key: "wrong"}, set(), False, None)
    assert problems(ok_meta, set(), False, None, {AD_ID_PERMISSION})
    assert problems(ok_meta, set(), False, None, {"android.permission.INTERNET"}) == []
    assert stub_in_report("+--- ru.rustore.sdk:pushclient:7.2.0 -> project :rustore_sdk_stub")
    assert not stub_in_report("+--- ru.rustore.sdk:pushclient:7.2.0")
    manifest = (
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
        f'<uses-permission android:name="{AD_ID_PERMISSION}"/><application>'
        f'<meta-data android:name="{AUTO_INIT_KEY}" android:value="false"/></application></manifest>'
    )
    assert metadata(manifest) == {AUTO_INIT_KEY: "false"}
    assert permissions(manifest) == {AD_ID_PERMISSION}
    assert string_names('<resources><string name="a">1</string></resources>') == {"a"}
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("variant", nargs="?")
    parser.add_argument("--fcm", action="store_true", help="the build had all four FCM settings")
    parser.add_argument("--rustore-project", help="the RuStore project of the build, if any")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return _self_test()
    if not args.variant:
        parser.error("variant is required")
    return _check_build(args.variant, args.fcm, args.rustore_project)


if __name__ == "__main__":
    sys.exit(main())
