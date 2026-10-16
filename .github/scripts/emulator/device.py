"""adb checks for the emulator job (`run.sh`); every dump is kept as an artifact.

  alarms <out-file>
      Saves `dumpsys alarm` and prints how many alarms of the app are pending.
  notification <out-file> <title-part>
      Saves `dumpsys notification --noredact` and prints how many notifications
      of the app in it contain <title-part>.
  tap-action <out-dir> <title-part> <action-label>
      Opens the notification shade and taps <action-label> on the notification
      whose text contains <title-part> (expanding it first if its actions are
      hidden). Exits 1 if the button cannot be found.

The package comes from $APP_PACKAGE (default com.pillpal.pillpal).
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path

PACKAGE = os.environ.get("APP_PACKAGE", "com.pillpal.pillpal")
UI_DUMP = "/sdcard/pillpal-ui.xml"
BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def adb(*args: str) -> str:
    result = subprocess.run(
        ["adb", *args], capture_output=True, text=True, timeout=60, check=False
    )
    return result.stdout


def count_alarms(out: Path) -> int:
    text = adb("shell", "dumpsys", "alarm")
    out.write_text(text, encoding="utf-8")
    # Alarm.toString(): "Alarm{<hash> type <t> origWhen <ms>  whenElapsed <ms> <package>}".
    pattern = re.compile(r"Alarm\{([0-9a-f]+) [^}]*\b" + re.escape(PACKAGE) + r"\}")
    return len(set(pattern.findall(text)))


def count_notifications(out: Path, title_part: str) -> int:
    text = adb("shell", "dumpsys", "notification", "--noredact")
    out.write_text(text, encoding="utf-8")
    records = text.split("NotificationRecord(")[1:]
    return sum(
        1
        for record in records
        if f"pkg={PACKAGE} " in record.split("\n", 1)[0] and title_part in record
    )


def dump_ui(out: Path) -> ET.Element:
    for _ in range(5):
        if "dumped to" in adb("shell", "uiautomator", "dump", UI_DUMP):
            break
        time.sleep(2)
    text = adb("shell", "cat", UI_DUMP)
    out.write_text(text, encoding="utf-8")
    return ET.fromstring(text)


def center(node: ET.Element) -> tuple[int, int]:
    match = BOUNDS.fullmatch(node.get("bounds", ""))
    if match is None:
        raise ValueError("node without bounds")
    x1, y1, x2, y2 = (int(value) for value in match.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def notification_row(root: ET.Element, title_part: str) -> ET.Element | None:
    """The notification row (or, failing that, the window) holding the title."""
    parents = {child: parent for parent in root.iter() for child in parent}
    for node in root.iter("node"):
        if title_part not in node.get("text", ""):
            continue
        current: ET.Element | None = node
        while current is not None:
            if current.get("resource-id", "").endswith("expandableNotificationRow"):
                return current
            current = parents.get(current)
        return root
    return None


def find_in(row: ET.Element, predicate: Callable[[ET.Element], bool]) -> ET.Element | None:
    return next((node for node in row.iter("node") if predicate(node)), None)


def tap_action(out_dir: Path, title_part: str, label: str) -> int:
    adb("shell", "cmd", "statusbar", "expand-notifications")
    time.sleep(2)
    wanted = label.casefold()
    for attempt in range(4):
        root = dump_ui(out_dir / f"shade-{attempt}.xml")
        row = notification_row(root, title_part)
        if row is None:
            print(f"attempt {attempt}: no notification with the title in the shade")
            adb("shell", "cmd", "statusbar", "expand-notifications")
            time.sleep(3)
            continue
        button = find_in(
            row,
            lambda node: node.get("text", "").strip().casefold() == wanted
            or node.get("content-desc", "").strip().casefold() == wanted,
        )
        if button is not None:
            x, y = center(button)
            adb("shell", "input", "tap", str(x), str(y))
            print(f"tapped '{label}' at {x},{y}")
            return 0
        expand = find_in(
            row,
            lambda node: node.get("resource-id", "").endswith(":id/expand_button"),
        )
        if expand is not None:
            x, y = center(expand)
            adb("shell", "input", "tap", str(x), str(y))
            print(f"attempt {attempt}: expanded the notification")
        else:
            print(f"attempt {attempt}: no '{label}' button and no expand button")
        time.sleep(2)
    return 1


def main() -> int:
    command, *args = sys.argv[1:]
    if command == "alarms":
        print(count_alarms(Path(args[0])))
        return 0
    if command == "notification":
        print(count_notifications(Path(args[0]), args[1]))
        return 0
    if command == "tap-action":
        return tap_action(Path(args[0]), args[1], args[2])
    print(f"unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
