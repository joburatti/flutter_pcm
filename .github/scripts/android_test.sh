#!/bin/sh
# Runs one integration test file on the emulator. Installing the app
# sometimes hangs (seen on API 24), so each attempt gets 10 minutes, and the
# app is uninstalled before the second.
for attempt in 1 2; do
  if [ "$attempt" -gt 1 ]; then
    adb -s emulator-5554 uninstall com.example.flutter_pcm_example || true
  fi
  timeout 600 flutter test -r expanded "$1" -d emulator-5554 && exit 0
  echo "Attempt $attempt at $1 failed"
done
exit 1
