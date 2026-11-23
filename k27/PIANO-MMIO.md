# Piano macOS on DroidVM

The tested target is macOS 27.2 (26B8125), 6 vCPUs, 8192 MiB, Gunyah and
1280×800 native display. Its crosvm runtime exposes the boot disk, writable
store, Ethernet, and GPU as virtio-MMIO, in that order. Keep the collection,
ADT, store layout, and trust bundle from the same build. An upstream PCI
image needs its matching runtime and cannot replace this MMIO boot disk.

## Building and registering an instance

`pack-piano-mmio.py` uses the repository's boot packer and records input and
output hashes. Run it under Linux or WSL with Python 3.11+ and mtools. Supply
the K27 kernel collection, the 6 CPU / 8 GiB MMIO ADT, the matching trust
bundle and packed seed, the directory containing `UniXNU.efi` and
`DarwinBoot.efi`, and the tested build's JSON containing `kernel_args`.
The output directory must be new. The writable store is a separate input at
deployment and is not in the boot image or the Git repository.

```sh
python3 k27/pack-piano-mmio.py --kernel "$KC" --adt "$ADT" \
    --trust "$TRUST" --seed "$SEED" --efi-inputs "$EFI_INPUTS" \
    --boot-inputs "$BOOT_INPUTS" out/piano-mmio-package
```

For a side-by-side App instance, stop the source guest before copying its
store. Place `boot.img`, a separate writable `data-store.img`, and the
matching `firmware.fd` in `/data/data/cn.classfun.droidvm/files/<instance>`
with App ownership. Use a new directory and verify the new store is a
separate file. Get `vms.json` and the daemon's `vm_config_status` revision,
then generate a transaction:

```sh
python3 k27/piano-vm-config.py vms.json "$REVISION" \
    --base-id "$BASE_ID" --instance macos-piano-fork \
    --mac 02:44:56:4d:00:03 > create.json
```

Send the transaction to `vm_config_apply`, then start the new ID with
`vm_start_configured`. Select **Native display** in the App. The clone uses
its own boot, writable store, DTB, serial logs, and MAC address. Cloning an
existing store preserves guest accounts and host keys, so treat it as a
local test copy, not a distribution image. The host needs enough space for
the copy and enough free hugepages to run the guest.

## What transfers from the reference ports

- [lenzhang's Piano port](https://github.com/lenzhang/UniXNU-xiaomipad8pro)
  has the strongest 27.3 reference. Its PSCI patch shows which conduit must
  come from the ADT: `hvc` in crosvm and `smc` for the native EL1 path. Its
  K273 compatibility patches and native kernel diagnostics are useful for
  a separate version upgrade. Its SM8750 UFS, display, touch, and Wi-Fi
  drivers assume physical hardware. The VM exposes virtio devices instead.
- [code002-2's macOS experiment](https://github.com/code002-2/piano-macos-unixnu)
  and [the Xiaomi development device tree](https://github.com/xiaomi-pad-8-pro-development/android_device_xiaomi_piano-unixnu)
  record RAM boot and iPadOS userspace on Piano. Their README still marks
  the 27.3 kernel link incomplete. [donyanchen's port](https://github.com/donyanchen/UniXNU-piano)
  records early board bring-up. The separate `code002-2/UniXNU-piano` URL
  did not resolve at review time.
- The [upstream image workflow](https://github.com/Droid-VM/macOS-DroidVM/blob/524d27bf57ae92375aa39e3a81e11727c08973ff/.github/workflows/image.yml)
  supplies a CI model for pinned inputs and separate kernel, GPU and image
  jobs. This branch packages the MMIO boot path already exercised on the
  tablet. A 27.3 test needs its own IPSW inputs, APFS store, kernel collection,
  trust bundle, and transport-matched ADT before boot testing.
