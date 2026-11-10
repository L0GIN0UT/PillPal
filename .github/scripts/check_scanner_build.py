"""Check that barcode scanning stays on the bundled model (docs/phase4-plan.md 4.11).

`mobile_scanner` has two Android flavours: the bundled ML Kit model (default;
works on devices without Google Play services, e.g. RuStore users) and the
unbundled one, downloaded through Play Services (`useUnbundled=true`). The
app must keep the bundled one, and nothing else may bring the unbundled
barcode artifacts. Camera usage strings must exist in both languages.

Usage: check_scanner_build.py source          (run in the repository root)
       check_scanner_build.py release         (run in app/ after `flutter build`)
       check_scanner_build.py --self-test
"""

import argparse
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
CAMERA_PERMISSION = "android.permission.CAMERA"
CAMERA_FEATURE = "android.hardware.camera"
# Artifacts of the unbundled (Play Services) barcode scanners and the Google
# code scanner; the bundled model is com.google.mlkit:barcode-scanning.
UNBUNDLED = (
    "play-services-mlkit-barcode-scanning",
    "play-services-code-scanner",
)
BUNDLED = "com.google.mlkit:barcode-scanning"
UNBUNDLED_FLAG = "useUnbundled"
ML_KIT_DEPENDENCIES_META = "com.google.mlkit.vision.DEPENDENCIES"
SCANNER_PIN = re.compile(r"^\s{2}mobile_scanner:\s*(\S+)\s*$", re.MULTILINE)
EXACT_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
ML_KIT_PUB_PACKAGES = re.compile(r"^\s{2}google_mlkit_\w+:", re.MULTILINE)
PLIST_KEY = "NSCameraUsageDescription"


def pubspec_problems(pubspec: str) -> list[str]:
    """The scanner is pinned exactly and no other ML Kit plugin is added."""
    found: list[str] = []
    pin = SCANNER_PIN.search(pubspec)
    if pin is None:
        found.append("mobile_scanner is not a dependency of app/pubspec.yaml")
    elif not EXACT_VERSION.match(pin.group(1)):
        found.append(f"mobile_scanner must be pinned exactly, not {pin.group(1)!r}")
    if ML_KIT_PUB_PACKAGES.search(pubspec):
        found.append("a google_mlkit_* plugin is a dependency (it brings its own ML Kit)")
    return found


def unbundled_text_problems(name: str, text: str) -> list[str]:
    """Gradle files and properties never switch the scanner to Play Services."""
    found: list[str] = []
    if UNBUNDLED_FLAG in text:
        found.append(f"{name} mentions {UNBUNDLED_FLAG}: the bundled model must stay")
    for artifact in UNBUNDLED:
        if artifact in text:
            found.append(f"{name} depends on {artifact}")
    return found


def manifest_problems(manifest_xml: str) -> list[str]:
    """The app manifest asks for the camera and does not require one."""
    root = ET.fromstring(manifest_xml)
    permissions = {e.attrib.get(ANDROID + "name") for e in root.iter("uses-permission")}
    features = {
        e.attrib.get(ANDROID + "name"): e.attrib.get(ANDROID + "required")
        for e in root.iter("uses-feature")
    }
    found: list[str] = []
    if CAMERA_PERMISSION not in permissions:
        found.append("the camera permission is missing from the app manifest")
    if features.get(CAMERA_FEATURE) != "false":
        found.append("the camera feature must be declared with required=false")
    return found


def merged_manifest_problems(manifest_xml: str) -> list[str]:
    """Play Services model download metadata means the unbundled flavour."""
    root = ET.fromstring(manifest_xml)
    names = {e.attrib.get(ANDROID + "name") for e in root.iter("meta-data")}
    if ML_KIT_DEPENDENCIES_META in names:
        return [f"the merged manifest declares {ML_KIT_DEPENDENCIES_META} (unbundled model)"]
    return []


def dependency_report_problems(report: str) -> list[str]:
    """The release classpath carries the bundled model and no unbundled one."""
    found = [f"the release classpath contains {a}" for a in UNBUNDLED if a in report]
    if BUNDLED not in report:
        found.append(f"the release classpath lacks the bundled model {BUNDLED}")
    return found


def plist_problems(plist: str, strings: dict[str, str]) -> list[str]:
    """Info.plist has the camera usage string and RU/EN InfoPlist.strings override it."""
    found: list[str] = []
    if PLIST_KEY not in plist:
        found.append(f"Info.plist has no {PLIST_KEY}")
    for language, text in strings.items():
        if not re.search(rf'"{PLIST_KEY}"\s*=\s*"[^"]+"\s*;', text):
            found.append(f"{language}.lproj/InfoPlist.strings has no {PLIST_KEY}")
    return found


def _read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def _source_problems() -> list[str]:
    app = pathlib.Path("app")
    found = pubspec_problems(_read(app / "pubspec.yaml"))
    android = app / "android"
    build_files = [
        *android.rglob("*.gradle"),
        *android.rglob("*.gradle.kts"),
        *android.rglob("*.properties"),
    ]
    for path in build_files:
        # Gradle caches and build outputs are not sources.
        if path.is_file() and ".gradle" not in path.parts[:-1] and "build" not in path.parts:
            found += unbundled_text_problems(str(path), _read(path))
    found += manifest_problems(_read(android / "app/src/main/AndroidManifest.xml"))
    ios = app / "ios/Runner"
    found += plist_problems(
        _read(ios / "Info.plist"),
        {lang: _read(ios / f"{lang}.lproj/InfoPlist.strings") for lang in ("en", "ru")},
    )
    return found


def _release_problems() -> list[str]:
    report = subprocess.run(
        ["./gradlew", "-q", ":app:dependencies", "--configuration", "releaseRuntimeClasspath"],
        cwd="android",
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    found = dependency_report_problems(report)
    if found:
        # Who brings the artifact: the path is what a fix needs.
        for artifact in UNBUNDLED:
            insight = subprocess.run(
                ["./gradlew", "-q", ":app:dependencyInsight", "--dependency", artifact,
                 "--configuration", "releaseRuntimeClasspath"],
                cwd="android",
                capture_output=True,
                text=True,
                check=False,
            ).stdout
            print(f"--- dependencyInsight {artifact}")
            print(insight)
    manifests = sorted(pathlib.Path("build/app/intermediates/merged_manifests/release").rglob("AndroidManifest.xml"))
    if not manifests:
        return [*found, "merged release manifest not found"]
    for manifest in manifests:
        found += merged_manifest_problems(_read(manifest))
    return found


def _self_test() -> int:
    assert pubspec_problems("dependencies:\n  mobile_scanner: 7.4.2\n") == []
    assert pubspec_problems("dependencies:\n  mobile_scanner: ^7.4.2\n")
    assert pubspec_problems("dependencies:\n  http: ^1.2.2\n")
    assert pubspec_problems("dependencies:\n  mobile_scanner: 7.4.2\n  google_mlkit_barcode_scanning: 0.1.0\n")
    assert unbundled_text_problems("x", "org.gradle.jvmargs=-Xmx8G") == []
    assert unbundled_text_problems("x", "dev.steenbakker.mobile_scanner.useUnbundled=true")
    assert unbundled_text_problems("x", 'implementation("com.google.android.gms:play-services-code-scanner:16")')
    ns = 'xmlns:android="http://schemas.android.com/apk/res/android"'
    good = (
        f"<manifest {ns}><uses-permission android:name=\"{CAMERA_PERMISSION}\"/>"
        f'<uses-feature android:name="{CAMERA_FEATURE}" android:required="false"/></manifest>'
    )
    assert manifest_problems(good) == []
    assert manifest_problems(f"<manifest {ns}/>")
    assert manifest_problems(good.replace('"false"', '"true"'))
    meta = f'<manifest {ns}><application><meta-data android:name="{ML_KIT_DEPENDENCIES_META}" android:value="barcode"/></application></manifest>'
    assert merged_manifest_problems(meta)
    assert merged_manifest_problems(f"<manifest {ns}><application/></manifest>") == []
    assert dependency_report_problems("+--- com.google.mlkit:barcode-scanning:17.3.0") == []
    assert dependency_report_problems("+--- com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1")
    assert dependency_report_problems("+--- androidx.camera:camera-core:1.6.1")
    strings = {"en": f'"{PLIST_KEY}" = "x";', "ru": f'"{PLIST_KEY}" = "y";'}
    assert plist_problems(f"<key>{PLIST_KEY}</key>", strings) == []
    assert plist_problems("<plist/>", strings)
    assert plist_problems(f"<key>{PLIST_KEY}</key>", {**strings, "ru": "/* empty */"})
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", choices=["source", "release"])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return _self_test()
    if args.mode is None:
        parser.error("mode is required")
    found = _source_problems() if args.mode == "source" else _release_problems()
    for message in found:
        print(f"::error::{message}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
