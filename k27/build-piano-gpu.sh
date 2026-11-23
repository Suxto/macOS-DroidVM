#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo "Usage: $0 EXISTING_K27_BUILD BOOT_INPUTS_JSON NEW_OUTPUT_DIR" >&2
    exit 2
fi
fork=$(cd "$(dirname "$0")/.." && pwd -P)
build=$(realpath "$1")
boot_inputs=$(realpath "$2")
out=$(realpath -m "$3")
tools=${PIANO_TOOLS:-/opt/macos-droidvm-tools}
export XNU_PROBE_CLANG=${XNU_PROBE_CLANG:-/opt/llvm-mingw-droidvm/bin/clang}
export XNU_LINUX_PREFIX=$tools/xnu-toolchain
source "$tools/xnu-linux-toolchain/env.sh"
export UNIXNU_SDKROOT=$tools/ios-sdks/iPhoneOS26.5.sdk UNIXNU_SDK_VERSION=26.5

cd "$build"
transport=$out/transport
driver=$fork/overlay/kext/DroidVMDisplay
python3 "$fork/k27/prepare-piano-gpu.py" out/k27/src/droidvm-display-transport "$transport"
python3 scripts/build-native-kext.py DroidVMDisplayPiano "$driver/DroidVMDisplay.cpp" \
    "$transport/DroidVMVirtioGpu.cpp" "$transport/DroidVMVirtioGpu3D.cpp" overlay/kext/NativeKextGlue.cpp \
    -I "$driver" -I "$transport" -I "$build/out/k27/src/droidvm-display-abi" \
    -D DROIDVM_VIRTIO_GPU_DYNAMIC=1 --obj k27-obj
sed 's@native-kexts/DroidVMDisplay/objects.json@native-kexts/DroidVMDisplayPiano/objects.json@' \
    overlay/kext/DroidVMDisplay.json > "$out/display.json"
mapfile -t keep < <(sed 's/\r$//' "$fork/configs/kc-keep.txt" | \
    sed -E '/^com\.apple\.(iokit\.(IOTimeSyncFamily|IOBluetoothFamily)|plugin\.IOgPTPPlugin)$/d; /^$/d')
keep+=(com.apple.iokit.IOTimeSyncFamily com.apple.plugin.IOgPTPPlugin)
native=(overlay/kext/NativeVirtioBlock.json overlay/kext/NativeAES.json overlay/kext/NativeRamBlock.json
    "$out/display.json" overlay/kext/DroidVMGpu.json overlay/kext/DroidVMEthernet.json overlay/kext/DroidVMInput.json)
kc=$out/kc-piano-mmio.bin
python3 -B out/k27-timesync-prelink.py out/kc/kc27-vma2-small.bin \
    out/k27/kernel-k27-builtin-platform-compact.macho "$kc" --keep "${keep[@]}" --native "${native[@]}"
python3 "$fork/k27/pack-piano-mmio.py" --kernel "$kc" --adt out/k27-variants/gpu-selftest/guest.adt \
    --trust out/metal/stage/kernel.macho.trustcache --seed "$tools/macos-27.2-metal-login/scratch-data.img" \
    --efi-inputs artifacts/boot-inputs --boot-inputs "$boot_inputs" "$out/package"
