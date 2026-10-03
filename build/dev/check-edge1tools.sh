#!/usr/bin/env bash
#
# Offline check of Edge1 Tools: links its resources with aapt2 and compiles its Java
# against the R class that comes out, the two steps of the build that fail on a
# resource mistake (a missing string, a style whose parent does not exist).
#
#   usage: build/dev/check-edge1tools.sh <android-all-14.jar>
#
# The jar stands in for framework-res and framework.jar, hidden APIs included (the
# app is built with platform_apis): Robolectric's android-all for Android 14 -
#   https://repo1.maven.org/maven2/org/robolectric/android-all/14-robolectric-10818077/android-all-14-robolectric-10818077.jar
# aapt2 is Debian/Ubuntu's (apt install aapt); javac any JDK 17+.
#
# This is how "Text.Body inherits Text, which does not exist" was reproduced - the
# build's own error, nine times, that the first build of the Material 3 screens
# stopped on at 11%.
set -euo pipefail
JAR="$(realpath "${1:?usage: $0 <android-all-14.jar>}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$HERE/device/khadas/edge/apps/Edge1Tools"
for t in aapt2 javac; do
    command -v "$t" > /dev/null || { echo "$t not found (aapt2: apt install aapt)" >&2; exit 2; }
done

W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT

aapt2 compile --dir "$APP/res" -o "$W/res.zip"
aapt2 link -I "$JAR" --manifest "$APP/AndroidManifest.xml" -o "$W/app.apk" \
    --java "$W/gen" "$W/res.zip"
echo "aapt2: resources link"

mkdir "$W/classes"
javac -nowarn -encoding UTF-8 --release 17 -cp "$JAR" -d "$W/classes" \
    "$W"/gen/org/edge1/tools/R.java "$APP"/src/org/edge1/tools/*.java 2>&1 \
    | grep -v '^Note:\|^Picked up JAVA_TOOL_OPTIONS' || true
[[ -f "$W/classes/org/edge1/tools/MainActivity.class" ]] || { echo "javac: failed" >&2; exit 1; }
echo "javac: $(find "$W/classes" -name '*.class' | wc -l) classes"
