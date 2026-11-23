#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root=/opt/macos-droidvm-tools/crosvm-macos
gpu_lib="$PWD/out/k27/android-gpu"
ndk=/opt/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin
scanout_patch="$PWD/patches/droidvm-crosvm/0001-speed-up-native-cpu-scanout.patch"
if ! git -C "$source_root" apply --reverse --check "$scanout_patch"; then
    git -C "$source_root" apply "$scanout_patch"
fi
"$ndk/aarch64-linux-android35-clang++" -std=c++17 -O2 -Wall -Wextra -Werror -fPIC -shared \
    -Wl,-soname,libk27_native_display.so -static-libstdc++ -o "$gpu_lib/libk27_native_display.so" \
    overlay/display/AndroidDisplayBridge.cpp -lbinder_ndk -lnativewindow -ldl -llog

# Keep the existing VNC CPU paths when the Windows bridge's GPU/H.264 symbols are absent.
python3 - "$source_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for file, feature, value in [
    ("Cargo.toml", 'android_display = ["devices/android_display"]',
     'android_display_cpu_bridge = ["android_display", "devices/android_display_cpu_bridge"]'),
    ("devices/Cargo.toml", 'android_display = ["gpu_display/android_display"]',
     'android_display_cpu_bridge = ["gpu_display/android_display_cpu_bridge"]'),
    ("gpu_display/Cargo.toml", 'android_display = []', 'android_display_cpu_bridge = []'),
]:
    path = root / file
    source = path.read_text()
    if value not in source:
        assert source.count(feature) == 1, path
        path.write_text(source.replace(feature, feature + "\n" + value, 1))
for file in ("vnc_blit.rs", "video_encoder.rs"):
    path = root / "gpu_display/src" / file
    source = path.read_text()
    old = 'any(feature = "android_display", feature = "android_display_stub")'
    new = ('any(all(feature = "android_display", not(feature = "android_display_cpu_bridge")), '
           'feature = "android_display_stub")')
    if new not in source:
        assert source.count(old) == 2, path
        path.write_text(source.replace(old, new))
PY

sed -e 's/gpu,virgl_renderer,vnc/gpu,virgl_renderer,vnc,net,android_display_cpu_bridge/' \
    -e '/-l dylib=vncserver|/s/-l dylib=vncserver|/-l dylib=vncserver -l dylib=k27_native_display|/' \
    out/build-crosvm-k27-gpu.sh > out/build-k27-crosvm-native-temp.sh
K27_VNC=1 bash out/build-k27-crosvm-native-temp.sh
cp "$source_root/target/aarch64-linux-android/release/crosvm" out/k27/crosvm-macos-native
