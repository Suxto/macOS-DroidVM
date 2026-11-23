# WebGL bringup checks

Build under WSL with `bash k27/webgl-check/build.sh`. SDK/compiler paths can be
overridden using `MACOS_SDK`, `PROBE_CLANG`, and `PROBE_LD`.

`angle-probe` reports Metal families, their missing features, and ANGLE EGL
initialization. Its optional `override` argument changes the Mac2 answer only
inside that diagnostic process. It does not change installed drivers.

Open `DroidVM WebKit Probe.app` in the logged-in GUI session, passing either
`webgl-check.html` or an HTTPS URL as the executable argument. The probe logs
navigation and results to `DroidVM-WebKit-Probe.log` in the user's Darwin temp
directory. It disables WebKit's extensible SSO integration for diagnostic use.
The HTML checks WebGL 1/2 shader compilation, linking, rendering and pixel
readback. Both `passed` values must be true. `draw120ms` is a coarse browser
timer around batched submissions and is **not a GPU performance measurement**.

Use ordinary OpenSSH on guest port 22 for binary transfers. The diagnostic
server on port 2222 does not forward stdin/SFTP, and its child processes run
outside the Aqua bootstrap session. Start GUI probes using `open` inside
`launchctl asuser 501`, or a LaunchAgent in `gui/501`.

## Current device fix (2026-11-20)

* `scripts/build-metal-plugin.sh` grants the Mac2 family answer only when
  queried by WebCore or libANGLE. Other clients and individual unsupported
  Metal operations retain their original answers.
* The installed bundle is `/System/Library/Extensions/NativeAdrenoMetal.bundle`.
  GPUProcess.sb permits executable mappings there; the original Data-volume
  bundle was retained as `/Library/GPUBundles/NativeAdrenoMetal.before-webkit`.
  Offline staging still uses the Data volume; moving into the System volume is
  a separate live installation step and must not be confused with a Data seed.
* Live replacement must use a **new inode and rename**, not overwrite an
  already-mapped executable. Add the new executable's CDHash to the existing
  boot trust bundle before restarting. An untrusted plugin fails library
  validation and leaves `MTLCreateSystemDefaultDevice()` returning nil.
* Current boot: `out/k27-variants/boot-k27-webgl.img`, SHA-256
  `8e2602b9c1e2c78aecef96218f9800a866d3710b20ea3ff11958bdbff1a7d7c0`.
  Uses the unchanged display-recovery KC, 6 CPUs and 8 GiB RAM.
* `com.apple.AppSSOAgent` (gui/501) and `com.apple.AppSSODaemon` (system) are
  disabled and unloaded. The daemon repeatedly aborts; Safari and CFNetwork
  wait synchronously for the agent's configuration. Unloading the unavailable
  enterprise SSO services lets ordinary navigation continue. Safari's temporary
  `WebKitPreferences.extensibleSSOEnabled` override was removed; safe browsing
  remains enabled.

Restore enterprise SSO after repairing its daemon:

```sh
sudo launchctl enable system/com.apple.AppSSODaemon
sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.AppSSODaemon.plist
sudo launchctl enable gui/501/com.apple.AppSSOAgent
sudo launchctl bootstrap gui/501 /System/Library/LaunchAgents/com.apple.AppSSOAgent.plist
```

The installed old plugin executable is retained as
`NativeAdrenoMetal.before-webgl` beside the executable. The previous phone boot
image is `files/macos-piano/boot.img.before-webgl` under the app data directory.
Restore the binary through a fresh inode, and restore the boot image with the
VM stopped. Do not restore the former trust cache alone while leaving the new
plugin installed.
