#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
# Generated plugin paths must be recreated on this computer by Flutter.
rm -f .flutter-plugins .flutter-plugins-dependencies
flutter pub get
if [[ -n "${CLRS_TRANSLATION_ENDPOINT:-}" ]]; then
  flutter build apk --release --flavor production \
    "--dart-define=CLRS_TRANSLATION_ENDPOINT=$CLRS_TRANSLATION_ENDPOINT"
else
  flutter build apk --release --flavor production
fi
printf '\nAPK: %s/build/app/outputs/flutter-apk/app-production-release.apk\n' "$PWD"
