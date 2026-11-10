"""Check that barcode scanning stays on the bundled model (docs/phase4-plan.md 4.11).

`mobile_scanner` has two Android flavours: the bundled ML Kit model (default;
works on devices without Google Play services, e.g. RuStore users) and the
unbundled one, downloaded through Play Services (`useUnbundled=true`). The
app must keep the bundled one, and nothing else may bring the unbundled
barcode artifacts. Camera usage strings must exist in both languages, and
the scanner must not hand frames to Dart (`returnImage: false`).

Limitations: the pin check reads `mobile_scanner:` written on one line at two
spaces of indent in app/pubspec.yaml (a hosted/git map form is reported as
not found); `source` greps Gradle files and the workflows for `useUnbundled`
but cannot see a flag passed on a developer's command line.

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
AUTOFOCUS_FEATURE = "android.hardware.camera.autofocus"
RETURN_IMAGE_OFF = "returnImage: false"
# The bundled model is com.google.mlkit:barcode-scanning. Its own POM depends
# on the Play Services artifact below (shared classes; CI of 4.11 showed it),
# so that artifact alone does not mean the unbundled model: what does is a
# direct request for it by anything but the bundled artifact (that is what
# mobile_scanner does with useUnbundled=true), or the model-download metadata
# in the merged manifest. The Google code scanner needs Play Services always.
BUNDLED = "com.google.mlkit:barcode-scanning"
PLAY_SERVICES_BARCODE = "play-services-mlkit-barcode-scanning"
UNBUNDLED = ("play-services-code-scanner",)
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
    for feature in (CAMERA_FEATURE, AUTOFOCUS_FEATURE):
        if features.get(feature) != "false":
            found.append(f"{feature} must be declared with required=false")
    return found


def adapter_problems(adapter_source: str) -> list[str]:
    """The scanner never asks for the camera frames."""
    if RETURN_IMAGE_OFF not in adapter_source:
        return [f"mobile_scanner_adapter.dart must set {RETURN_IMAGE_OFF}"]
    return []


def merged_manifest_problems(manifest_xml: str) -> list[str]:
    """Play Services model download metadata means the unbundled flavour."""
    root = ET.fromstring(manifest_xml)
    names = {e.attrib.get(ANDROID + "name") for e in root.iter("meta-data")}
    if ML_KIT_DEPENDENCIES_META in names:
        return [f"the merged manifest declares {ML_KIT_DEPENDENCIES_META} (unbundled model)"]
    return []


def dependency_report_problems(report: str) -> list[str]:
    """The release classpath carries the bundled model and no Play Services scanner."""
    found = [f"the release classpath contains {a}" for a in UNBUNDLED if a in report]
    if BUNDLED + ":" not in report:
        found.append(f"the release classpath lacks the bundled model {BUNDLED}")
    return found


def play_services_requesters(insight: str) -> list[str]:
    """Direct requesters of the Play Services barcode artifact in a dependencyInsight text.

    Gradle prints the artifact on an unindented line and the things that ask for
    it as unindented `+--- x` / `\\--- x` lines below it.
    """
    requesters: list[str] = []
    inside = False
    for line in insight.splitlines():
        if line and not line.startswith((" ", "+", "\\", "|")):
            inside = f":{PLAY_SERVICES_BARCODE}:" in line
        elif inside and line.startswith(("+--- ", "\\--- ")):
            requesters.append(line[5:].strip())
    return requesters


def play_services_problems(insight: str) -> list[str]:
    """Only the bundled artifact may ask for the Play Services barcode artifact."""
    return [
        f"{PLAY_SERVICES_BARCODE} is requested by {who}, not by {BUNDLED}"
        for who in play_services_requesters(insight)
        if not who.startswith(BUNDLED + ":")
    ]


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
    for workflow in pathlib.Path(".github/workflows").glob("*.yml"):
        found += unbundled_text_problems(str(workflow), _read(workflow))
    found += manifest_problems(_read(android / "app/src/main/AndroidManifest.xml"))
    found += adapter_problems(
        _read(app / "lib/src/features/catalog/mobile_scanner_adapter.dart")
    )
    ios = app / "ios/Runner"
    found += plist_problems(
        _read(ios / "Info.plist"),
        {lang: _read(ios / f"{lang}.lproj/InfoPlist.strings") for lang in ("en", "ru")},
    )
    return found


def _gradle(*args: str) -> str:
    """Runs Gradle in app/android; a failure is an error of the check (fail closed)."""
    return subprocess.run(
        ["./gradlew", "-q", *args],
        cwd="android",
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def _release_problems() -> list[str]:
    report = _gradle(":app:dependencies", "--configuration", "releaseRuntimeClasspath")
    found = dependency_report_problems(report)
    # Exits 0 when nothing matches, so a failure here is a real failure.
    insight = _gradle(
        ":app:dependencyInsight",
        "--dependency", PLAY_SERVICES_BARCODE,
        "--configuration", "releaseRuntimeClasspath",
    )
    found += play_services_problems(insight)
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
        f'<uses-feature android:name="{CAMERA_FEATURE}" android:required="false"/>'
        f'<uses-feature android:name="{AUTOFOCUS_FEATURE}" android:required="false"/></manifest>'
    )
    assert manifest_problems(good) == []
    assert manifest_problems(f"<manifest {ns}/>")
    assert manifest_problems(good.replace('"false"', '"true"'))
    meta = f'<manifest {ns}><application><meta-data android:name="{ML_KIT_DEPENDENCIES_META}" android:value="barcode"/></application></manifest>'
    assert merged_manifest_problems(meta)
    assert manifest_problems(good.replace(AUTOFOCUS_FEATURE, "x"))
    assert adapter_problems("MobileScannerController(returnImage: false)") == []
    assert adapter_problems("MobileScannerController(returnImage: true)")
    assert adapter_problems("MobileScannerController()")
    assert merged_manifest_problems(f"<manifest {ns}><application/></manifest>") == []
    assert dependency_report_problems("+--- com.google.mlkit:barcode-scanning:17.3.0") == []
    assert dependency_report_problems("+--- com.google.android.gms:play-services-code-scanner:16.1.0")
    assert dependency_report_problems("+--- androidx.camera:camera-core:1.6.1")
    bundled_insight = (
        "com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1\n"
        "\\--- com.google.mlkit:barcode-scanning:17.3.0\n"
        "     \\--- project :mobile_scanner\n"
        "          \\--- releaseRuntimeClasspath\n"
    )
    assert play_services_requesters(bundled_insight) == ["com.google.mlkit:barcode-scanning:17.3.0"]
    assert play_services_problems(bundled_insight) == []
    direct = bundled_insight.replace("com.google.mlkit:barcode-scanning:17.3.0", "project :mobile_scanner")
    assert play_services_problems(direct)
    assert play_services_problems("No dependencies matching given input were found") == []
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
    try:
        found = _source_problems() if args.mode == "source" else _release_problems()
    except subprocess.CalledProcessError as error:
        print(f"::error::{' '.join(error.cmd)} failed: {(error.stderr or '').strip()[-500:]}")
        return 1
    except (OSError, ET.ParseError) as error:
        print(f"::error::cannot read the build: {error}")
        return 1
    for message in found:
        print(f"::error::{message}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
