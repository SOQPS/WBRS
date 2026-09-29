#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
# Generated plugin paths must be recreated on this computer by Flutter.
rm -f .flutter-plugins .flutter-plugins-dependencies
flutter pub get
CLRS_BUILD_ARGS=(--release --flavor production)
if [[ -n "${CLRS_TRANSLATION_ENDPOINT:-}" ]]; then
  CLRS_BUILD_ARGS+=("--dart-define=CLRS_TRANSLATION_ENDPOINT=$CLRS_TRANSLATION_ENDPOINT")
fi
if [[ -n "${CLRS_PUSH_ENDPOINT:-}" ]]; then
  CLRS_BUILD_ARGS+=("--dart-define=CLRS_PUSH_ENDPOINT=$CLRS_PUSH_ENDPOINT")
fi
flutter build apk "${CLRS_BUILD_ARGS[@]}"
printf '\nAPK: %s/build/app/outputs/flutter-apk/app-production-release.apk\n' "$PWD"
