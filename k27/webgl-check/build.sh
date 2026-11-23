#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sdk=${MACOS_SDK:-/opt/macos-droidvm-tools/macos-sdks/MacOSX26.1.sdk}
clang=${PROBE_CLANG:-/usr/lib/llvm-18/bin/clang}
ld=${PROBE_LD:-/usr/lib/llvm-18/bin/ld64.lld}
out=out/webgl-check
mkdir -p "$out/DroidVM WebKit Probe.app/Contents/MacOS"
for name in WKProbe angle-probe; do
    "$clang" -target arm64-apple-macos15 -isysroot "$sdk" -fobjc-arc -O2 \
        -c "k27/webgl-check/$name.m" -o "$out/$name.o"
done
"$ld" -arch arm64 -platform_version macos 15 26.1 -syslibroot "$sdk" -adhoc_codesign \
    -o "$out/DroidVM WebKit Probe.app/Contents/MacOS/WKProbe" "$out/WKProbe.o" \
    -framework Foundation -framework AppKit -framework WebKit -lSystem -lobjc
"$ld" -arch arm64 -platform_version macos 15 26.1 -syslibroot "$sdk" -adhoc_codesign \
    -o "$out/angle-probe" "$out/angle-probe.o" -framework Foundation -framework Metal -lSystem -lobjc
python3 - "$out" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
out = Path(sys.argv[1])
(out / 'DroidVM WebKit Probe.app/Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='org.droidvm.WebGLProbe', CFBundleExecutable='WKProbe',
    CFBundleName='DroidVM WebKit Probe', CFBundlePackageType='APPL', CFBundleVersion='1')))
shutil.copyfile('k27/webgl-check/webgl-check.html', out / 'webgl-check.html')
PY
