# Hardware video decoding

Where hardware video decoding stands on the mainline kernel, and how it gets
into Android. Today every video plays in software: 1080p H.264 and VP9 are fine
on the A72s, 4K is not.

## What the kernel has (6.12)

The RK3399 has two decoders. On mainline both are **V4L2 stateless** ("request
API") devices: userspace parses the bitstream and hands the decoder one frame or
slice at a time, with its parameters as V4L2 controls.

| Device | Driver | Coded formats, largest frame |
|---|---|---|
| `ff660000.video-codec` (VDEC) | `rkvdec` (staging) | H.264 (`S264`) 4096x2560, VP9 (`VP9F`) 4096x2304 |
| `ff650000.video-codec` (VPU) | `hantro-vpu` | MPEG-2 (`MG2S`) 1080p, VP8 (`VP8F`) 4K; JPEG encode |

Both give NV12. No HEVC: rkvdec's HEVC support is not in 6.12, so HEVC stays in
software until a newer kernel. No AV1 on this SoC at all.

`CONFIG_VIDEO_ROCKCHIP_VDEC` has been built in since the move to mainline;
`CONFIG_VIDEO_HANTRO` since card 19. `init/ueventd.edge1.rc` gives every
`/dev/video*` and `/dev/media*` to `media:media` 0660, and they are labelled
`video_device` (`sepolicy/vendor/file_contexts`).

## Why no existing Android piece drives them

* **Rockchip MPP** (`libcodec2_rk`, the Android 10 BSP's): talks to the BSP
  kernel's `/dev/mpp_service`, which mainline does not have.
* **AOSP's `v4l2_codec2`**: stateful decoders only (a decoder that parses the
  bitstream itself, like the Raspberry Pi's or Amlogic's). Stateless is a
  different protocol.
* **The framework's software codecs** (`c2.android.*`): what plays today.

## The plan: FFmpeg with v4l2-request, as a Codec2 service

FFmpeg can drive stateless decoders through its **v4l2-request hwaccel**: FFmpeg's
own parsers produce the controls, the kernel decodes, the frame comes back as a
DRM PRIME buffer. The hwaccel is not in upstream FFmpeg yet; Jonas Karlman (Kwiboo)
keeps it, rebased per release, in the `v4l2-request-n7.0`, `-n7.1.3`, `-n8.0.1`
and `-n8.1` branches of github.com/Kwiboo/FFmpeg, and LibreELEC ships it on the
same SoCs.

For Android there is already a Codec2 service built on FFmpeg:
**raspberry-vanilla's `android_external_ffmpeg_codec2`** (KonstaKANG, after
Michael Goffioul's Android-x86 work), branch `android-14.0.0_r34`, with
`android_external_ffmpeg` (FFmpeg 7.0.2, branch `android-14.0`). It registers
`c2.ffmpeg.*` decoders, and `ffmpeg_utils/ffmpeg_hwaccel.c` already asks FFmpeg for
a hardware device and copies decoded frames out to NV12 - but only for HEVC, and
the Raspberry Pi FFmpeg's request code (`v4l2_req_*`) only does HEVC. The decoder
side of this board is the opposite: H.264 and VP9.

### Phase 1 - the decoders, seen from the board (card 19)

* hantro built in; node permissions; this document.
* `edge1-v4l2-probe` (`device/khadas/edge/tools/v4l2-probe`): for each
  `/dev/video*` the driver and every format with its largest size, for each
  `/dev/media*` its driver. The bootwatch writes it into every snapshot as
  `video.txt`. Expected: rkvdec with `S264` and `VP9F`, hantro-vpu with `MG2S`
  and `VP8F`, rockchip-rga.
* **Confirmed on card 21:** `/dev/video3` rkvdec, `S264` 1x1..4096x2560 and `VP9F`
  1x1..4096x2304; `/dev/video2` hantro-vpu decoder, `MG2S` 48x48..1920x1088 and
  `VP8F` 48x48..3840x2160; `/dev/video1` the hantro JPEG encoder; `/dev/video0` RGA.
  Media controllers: `/dev/media0` hantro-vpu, `/dev/media1` rkvdec. Every capture
  format is NV12.

### Phases 2 and 3 - the FFmpeg Codec2 service, with the request hwaccels (card 23)

Built, not yet run on the board.

* **Manifest:** raspberry-vanilla's `external/ffmpeg` (FFmpeg 7.0, Android.mk and
  a pre-generated config), `external/ffmpeg_codec2` and `external/libudev-zero`,
  pinned to the commits the patches were made against. AOSP's libdrm, Mesa and
  libdav1d stay.
* **FFmpeg** (`device/khadas/edge/patches/external/ffmpeg/`): Kwiboo's
  `v4l2-request-n7.0` commits for the common request code and the H.264, MPEG-2,
  VP8 and VP9 hwaccels, ported onto raspberry-vanilla's tree with their authors.
  Left out: `configure` (the Android build reads `android/config.mak`), Kwiboo's
  HEVC (this tree has the Raspberry Pi's, and rkvdec has no HEVC on 6.12) and the
  `hwcontext_drm` "no DRM device" hack (already there). The last patch is ours: the
  four hwaccels on in the Android config, libdav1d off (AOSP's is a static library
  for its own AV1 decoder), and two things the Android headers lack -
  `v4l2_timeval_to_ns()` (an inline function bionic's uapi copy drops) and
  `fourcc_mod_is_vendor()` (libdrm >= 2.4.111). Every changed file compiles with
  clang for `aarch64-linux-android34` against bionic's android-14.0.0_r75 headers.
* **ffmpeg_codec2** (`patches/external/ffmpeg_codec2/`): `ffmpeg_hwaccel_init()`
  tries the hardware for H.264, VP9, MPEG-2 and VP8 too, unless
  `persist.vendor.edge1.hwdec=0`; E-AC-3, DTS, DTS-HD (its core) and TrueHD
  components. A stream the hardware refuses falls back to FFmpeg's software decoder
  in the same component.
* **build/apply-patches.sh** puts the patches on after sync (place-device.sh), with
  the kernel patches' bookkeeping: `<project>/.edge1-patches/` holds the applied
  set; a changed set is reverted and reapplied.
* **Device:** the service package; `media/media_codecs.xml` lists the four video
  decoders at rank 64, ahead of `c2.android.*` (0x200) and reported as hardware,
  and the audio decoders AOSP lacks; a seccomp extension, because the request code
  waits with `select()` - `pselect6`, which the service's own policy does not allow
  and which would kill it on the first hardware frame; SELinux: the service is
  `mediacodec` (AOSP already gives it `video_device`), plus sysfs reads for
  libudev-zero's device scan.

Known limit until phase 4: each frame is copied out of the decoder's buffer
(`av_hwframe_transfer_data`) and converted to I420 by the component. The V4L2
buffers are uncached for the CPU on the RK3399, so the copy is slow: 1080p should
keep up, 4K probably not.

### Phase 4 - zero copy

Phase 3 copies every frame from the decoder's buffer into a gralloc buffer
(`av_hwframe_transfer_data` to NV12): fine for 1080p, a lot of memory bandwidth
for 4K60. Zero copy hands the DRM PRIME buffer to SurfaceFlinger directly, as a
gralloc buffer minigbm imports.

## Checking it

* `video.txt` in a bootwatch snapshot: the nodes and formats, the decoders'
  interrupt counts (above zero only after a hardware decode), and
  `persist.vendor.edge1.hwdec`.
* logcat: `ffmpeg_hwaccel_init: ... hw device = drm` when a stream goes to the
  hardware; FFmpeg's `v4l2_request` lines name the device it picked.
* The performance overlay's `HW decode:` line: the decoders MediaCodecList marks
  hardware-accelerated - the four c2.ffmpeg ones once the service runs.
* `setprop persist.vendor.edge1.hwdec 0` (root) and replaying the same video tells
  hardware from software.
