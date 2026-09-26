# Status: what was built, what was not, and why

## Summary

The port itself — device tree, AIDL HAL migration, Android TV configuration,
kernel delta, SELinux policy, build pipeline — is written and statically
verified. **No `update.img` was produced, and no compilation was attempted**,
because the environment this was authored in cannot sync or build AOSP. The
measurements are below; they are hard blocks, not preferences.

## What blocked the build

### 1. AOSP 14 sources are unreachable

`android.googlesource.com` is refused by this container's network policy:

```
$ git ls-remote https://android.googlesource.com/platform/build
fatal: unable to access '...': CONNECT tunnel failed, response 403

$ curl -sS "$HTTPS_PROXY/__agentproxy/status"
  "recentRelayFailures": [ { "kind": "connect_rejected",
    "detail": "gateway answered 403 to CONNECT (policy denial or upstream failure)",
    "host": "android.googlesource.com:443" } ]
```

A 403 on CONNECT is a policy denial, not a credentials problem, so no retry or
mirror substitution resolves it. `repo init -u https://android.googlesource.com/platform/manifest`
cannot run, so there is no AOSP 14 tree — and therefore no `build/envsetup.sh`
to source, no `lunch`, and no `m`.

`github.com/khadas` **is** reachable over git, which is why the legacy Android 10
sources could be read and the port grounded in them rather than guessed.

### 2. Disk is ~10x short

30GiB available. An AOSP 14 checkout is ~120GiB and one userdebug output tree is
~150GiB, so ~270GiB is needed.

### 3. RAM is below the documented minimum

15GiB, against Android 14's 16GiB minimum and 64GiB recommendation. R8 and
soong's Java steps get OOM-killed below that.

### 4. CPU width

4 cores. A full platform build is roughly 24 hours at that width even when
everything else fits.

`build/preflight.sh` checks all four and reports them; run on this container it
exits 1 and names each one.

## What this means for the self-correction loop

The requested loop — build, read compiler errors, patch, rebuild until
`update.img` appears — needs a compiler running over a synced tree. With no tree,
there is nothing to compile and no compiler diagnostics to read. Simulating that
loop would mean inventing plausible error messages and "fixing" them, which
produces confident-looking churn with no relationship to what the build would
actually say.

Instead the same discipline was applied to what *can* be checked without a tree.
`build/verify-tree.sh` validates XML well-formedness, every
`PRODUCT_COPY_FILES` and `BoardConfig.mk` file reference, VINTF consistency
between the device manifest and each shim fragment, shell syntax, and mandatory
kernel symbols. Its first run found **14 real errors** (missing keylayouts, media
configs, Wi-Fi/Bluetooth configs, `parameter.txt`, `package-file`, a
`baseparameter.img` that does not exist in this tree). All 14 were fixed; it now
reports 0 errors. That loop is real and repeatable — it just is not the compiler.

Two self-inflicted correctness bugs were also caught by reading the legacy
sources rather than assuming:

* The audio policy initially declared AC3/E-AC3/DTS/DTS-HD passthrough. The
  legacy HAL handles exactly one format, `AUDIO_FORMAT_PCM_16_BIT`, and does
  passthrough as IEC61937-framed PCM. Declaring those formats would have made
  apps request direct passthrough that `open_output_stream` rejects — silent
  playback rather than a clean PCM fallback. Corrected to PCM 16-bit + IEC61937.
* A boot control HAL was declared alongside a non-A/B partition layout. Removed,
  along with the `bootctrl` project in the manifest.

## Also worth correcting in the original brief

* **There is no `device/khadas/edge` in the khadas-edge-Qt manifest.** The
  Khadas Edge1 ships as product `rk3399_all` inside
  `device/rockchip/rk3399`, with `PRODUCT_MODEL := Edge`,
  `PRODUCT_BRAND := Khadas` and `TARGET_BOARD_PLATFORM_PRODUCT := tablet`.
  `device/khadas/edge` is created by this port; it was not extracted.
* **The kernel is 4.19.111, not a 4.4 vendor kernel.** This is good news: 4.19
  is exactly Android 14's minimum for an *upgrade* device, so the port is viable
  without a kernel rebase. See `KERNEL.md`.
* **The GPU is Mali-T860 (`TARGET_BOARD_PLATFORM_GPU := mali-t860`)**, the
  Midgard family — T864 is the MP4 configuration of the same part. The correct
  gralloc backend is `libgralloc/midgard`; `bifrost` is for G-series and is
  deliberately not synced.
* **Khadas' own `android14` kernel branches are for Edge2 (RK3588S), not
  Edge1.** `khadas-edge2-android14` and `khadas-edge-2l-android14` are RK3588S.
  There is no upstream Khadas Android 14 for the RK3399 Edge1, which is why this
  is a port rather than a rebase.

## Remaining work before this boots

Ordered by what blocks what.

1. **composer3 AIDL service.** No display output without it, and no AOSP
   fallback exists. Largest single gap.
2. **audio.core `createOutputStream`.** No sound without it.
3. **Forward-port `libgralloc_rk3399`** (the gralloc0 module the allocator shim
   loads) and `audio.primary.rk3399` to build against the 14 VNDK.
4. **Verify the AOSP tag.** `build/sync.sh` defaults to `android-14.0.0_r50`,
   which could not be confirmed against the unreachable AOSP host. Check with
   `git ls-remote --tags .../platform/manifest 'android-14.0.0_r*'`.
5. **Run `check_vintf`.** `vintf/manifest.xml` declares `target-level="8"`
   (Android 14 FCM) and 22 AIDL HALs. The exact permitted versions must be
   validated against the real framework compatibility matrix; if it rejects the
   manifest, lowering `target-level` is the escape hatch.
6. **Confirm AIDL signatures** with `build/verify-aidl-surface.sh` before writing
   any remaining shim.
7. **Kernel config merge.** `build/build-kernel.sh` reports symbols that did not
   take; several in the fragment are boot-critical. See `KERNEL.md`.
8. **Replace the invented codec performance numbers** in
   `media/media_codecs_performance.xml` with measurements from real hardware.

## Honest expectation

With items 1-3 done this should boot to a leanback launcher over HDMI. It will
not pass CTS: software KeyMint rules out attestation (see `HAL_MIGRATION.md`),
`PRODUCT_SHIPPING_API_LEVEL` is 29 which is correct for an upgrade but not for
certification as a 14 device, and the codec performance points are placeholders.
