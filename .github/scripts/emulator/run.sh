#!/usr/bin/env bash
# Emulator journeys of milestone 2.5 (docs/phase2-plan.md, "2.5 emulator test
# plan"). Runs inside reactivecircus/android-emulator-runner from the
# repository root, after the backend and host_control.py were started.
#
# One debug build of app/integration_test/app_test.dart is installed once and
# driven through several phases (the phase is served by host_control.py):
#   onboarding  register, verify, add a medication due in ~3 min, Today, the
#               pending reminder's text (names shown / hidden)
#   (workflow)  terminate the app, wait for the reminder, tap "Taken"
#   (workflow)  the backend must hold the taken event BEFORE the app is started
#               again: the WorkManager flush queued by the background handler
#               (ADR 0001 addendum 3.7)
#   taken       one taken event, tray cleared, synced (+ backend count)
#   (workflow)  am force-stop: AlarmManager forgets the app's alarms
#   rearm       app start re-arms them (checked in AlarmManager)
#   sign_out    no pending reminder, empty tray, no alarm left
#   relatives   (Phase 3, milestone 3.10) the app is a relative: the host plays
#               the owner through the API (host_control.py /relatives/*) and
#               opens the invite link with `adb shell am start` (explicit
#               package, no domain verification); preview, confirm, Family
#               tab, day view with the privacy matrix, revoke -> evicted
#
# Env: APK (absolute path), OUT (artifact dir), PHASE_FILE, PSQL_URL.
set -euo pipefail

PACKAGE=com.pillpal.pillpal
DEVICE=emulator-5554
# journeyMedicationName in app/integration_test/support/reminders.dart.
TITLE_PART=Testamin
TAKEN_LABEL=Taken
DEVICE_PY="$(pwd)/.github/scripts/emulator/device.py"
FIRE_TIMEOUT=360
UPLOAD_TIMEOUT=180
mkdir -p "$OUT"
trap 'adb logcat -d > "$OUT/logcat.txt" 2>/dev/null || true' EXIT

summary() { echo "$1" | tee -a "$GITHUB_STEP_SUMMARY" "$OUT/summary.txt"; }

screenshot() { adb exec-out screencap -p > "$OUT/$1.png" || true; }

die() {
  echo "$1" >> "$OUT/failure.txt"
  summary "- FAILED: $1"
  screenshot "failure"
  exit 1
}

alarms() { python3 "$DEVICE_PY" alarms "$OUT/alarms-$1.txt"; }

notifications() { python3 "$DEVICE_PY" notification "$OUT/notifications-$1.txt" "$2"; }

drive() {
  local phase=$1
  echo "$phase" > "$PHASE_FILE"
  echo "::group::phase $phase"
  local status=0
  (cd app && flutter drive --no-pub -d "$DEVICE" \
    --use-application-binary "$APK" \
    --driver test_driver/integration_test.dart \
    --target integration_test/app_test.dart \
    --keep-app-running) > "$OUT/drive-$phase.txt" 2>&1 || status=$?
  cat "$OUT/drive-$phase.txt"
  echo "::endgroup::"
  screenshot "after-$phase"
  if [ "$status" -ne 0 ]; then
    tail -n 150 "$OUT/drive-$phase.txt" >> "$OUT/failure.txt"
    die "phase $phase failed (flutter drive exit $status)"
  fi
  summary "- phase \`$phase\` passed"
}

pid_of_app() { (adb shell pidof "$PACKAGE" || true) | tr -d '\r'; }

# Like the system reclaiming a backgrounded app: the process dies, its alarms
# stay (unlike `am force-stop`).
terminate_app() {
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  adb shell am kill "$PACKAGE" || true
  sleep 2
  local pid
  pid=$(pid_of_app)
  if [ -n "$pid" ]; then
    adb shell run-as "$PACKAGE" kill -9 "$pid" || true
    sleep 2
  fi
  pid=$(pid_of_app)
  [ -z "$pid" ] || die "could not terminate the app (pid $pid)"
}

wait_for_reminder() {
  local deadline=$((SECONDS + FIRE_TIMEOUT))
  until [ "$(notifications fired "$TITLE_PART")" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] ||
      die "the reminder did not fire within $FIRE_TIMEOUT s of the app being terminated"
    sleep 5
  done
}

wait_for_cleared_tray() {
  local deadline=$((SECONDS + 30))
  until [ "$(notifications after-taken "$TITLE_PART")" -eq 0 ]; do
    [ "$SECONDS" -lt "$deadline" ] || die "the notification stayed in the tray after Taken"
    sleep 3
  done
}

taken_count() { psql "$PSQL_URL" -tAc "select count(*) from dose_events where type = 'taken'"; }

# The app is not started: only the background isolate and the WorkManager job
# (network constraint) ran since the tap, so the event got to the server on its
# own. Jobs are dumped into the artifact for the diagnosis of a failure.
wait_for_background_upload() {
  local deadline=$((SECONDS + UPLOAD_TIMEOUT))
  until [ "$(taken_count)" -ge 1 ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      adb shell dumpsys jobscheduler > "$OUT/jobscheduler.txt" 2>&1 || true
      die "the backend has no taken event $UPLOAD_TIMEOUT s after the tap, before the app was started again (background upload)"
    fi
    sleep 3
  done
}

prepare_device() {
  adb wait-for-device
  adb shell settings put system screen_off_timeout 1800000
  adb shell svc power stayon true
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard || true
  summary "- device time $(adb shell date | tr -d '\r'), runner time $(date)"
  (cd app && flutter install -d "$DEVICE" --use-application-binary "$APK") > "$OUT/install.txt" 2>&1 ||
    { cat "$OUT/install.txt"; die "flutter install failed"; }
  # What a user grants on first start (ADR 0001 §5), done up front: the
  # system dialogs are not part of the app's UI.
  adb shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS
  adb shell appops set "$PACKAGE" SCHEDULE_EXACT_ALARM allow
}

prepare_device

drive onboarding
terminate_app
summary "- app terminated; $(alarms after-terminate) alarm(s) of the app pending"

wait_for_reminder
summary "- the reminder fired with the app terminated"
screenshot fired
python3 "$DEVICE_PY" tap-action "$OUT" "$TITLE_PART" "$TAKEN_LABEL" ||
  die "could not tap \"$TAKEN_LABEL\" on the notification (UI dumps in the artifact)"
screenshot tapped
# The action runs in a background isolate started by the broadcast; give it
# time on a slow emulator before checking.
sleep 15
wait_for_cleared_tray
adb shell cmd statusbar collapse || true
summary "- \"$TAKEN_LABEL\" tapped in the shade; the tray is cleared"

wait_for_background_upload
summary "- the backend has the taken event before the app was started again"

drive taken
taken=$(taken_count)
[ "$taken" = "1" ] || die "the backend has $taken taken events, expected exactly 1"
summary "- the backend has exactly one taken event"

before=$(alarms before-force-stop)
[ "$before" -ge 1 ] || die "no alarm of the app before the force stop"
adb shell am force-stop "$PACKAGE"
sleep 2
stopped=$(alarms after-force-stop)
summary "- am force-stop: $before -> $stopped alarm(s)"
[ "$stopped" -eq 0 ] ||
  echo "::warning title=emulator::am force-stop kept $stopped alarm(s); the re-arm check is not conclusive"
drive rearm
rearmed=$(alarms after-rearm)
[ "$rearmed" -ge 1 ] || die "the app start did not re-arm the alarms after a force stop"
summary "- app start after the force stop re-armed $rearmed alarm(s)"

drive sign_out
left=$(alarms after-sign-out)
[ "$left" -eq 0 ] || die "$left alarm(s) of the app left after signing out"
tray=$(notifications after-sign-out "")
[ "$tray" -eq 0 ] || die "$tray notification(s) of the app left after signing out"
summary "- signed out: no alarm, no notification left"

# The signed-out app registers as a relative; everything the journey checks is
# in the app, the host only plays the owner (and opens the link).
drive relatives
grants=$(psql "$PSQL_URL" -tAc "select count(*) from profile_grants")
[ "$grants" = "0" ] || die "the backend still holds $grants grant(s) after the owner revoked them"
summary "- relatives: invite link opened, accepted, privacy matrix on the day view, revoked and evicted"
