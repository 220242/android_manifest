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

### Phase 2 - the FFmpeg Codec2 service, software only

Sync the two raspberry-vanilla projects (local manifest), build
`android.hardware.media.c2@1.2-service-ffmpeg` and its `media_codecs_ffmpeg_c2.xml`,
and give the service its SELinux domain (`mediacodec`), seccomp policy and VINTF
fragment. Worth having on its own: AC-3, E-AC-3 and DTS audio, which AOSP does not
decode at all, and a second video path to compare against.

### Phase 3 - v4l2-request for H.264 and VP9

* FFmpeg: Kwiboo's v4l2-request hwaccels (H.264, VP9; MPEG-2, VP8 for hantro)
  on the Android FFmpeg tree - either ported onto raspberry-vanilla's 7.0.2 or
  the tree moved to `v4l2-request-n7.1.3` with the Android config regenerated
  (`gen-android-configs`). Its device probe enumerates media devices with
  libudev; Android has none, so either a libudev port or a small patch that
  scans `/dev/media*` (what `edge1-v4l2-probe` does).
* ffmpeg_codec2: `ffmpeg_hwaccel_init()` opens a hardware device only for HEVC
  behind `persist.ffmpeg_codec2.v4l2.h265`; widen it to H.264, VP9, MPEG-2 and
  VP8 behind a property of this device's, so it can be switched off on the board.
* `media_codecs`: rank the `c2.ffmpeg` H.264 and VP9 decoders above
  `c2.android.*`.

### Phase 4 - zero copy

Phase 3 copies every frame from the decoder's buffer into a gralloc buffer
(`av_hwframe_transfer_data` to NV12): fine for 1080p, a lot of memory bandwidth
for 4K60. Zero copy hands the DRM PRIME buffer to SurfaceFlinger directly, as a
gralloc buffer minigbm imports.

## Checking it

* `video.txt` in a bootwatch snapshot: the nodes and formats (phase 1).
* The performance overlay's `HW decode:` line: the decoders the framework's
  MediaCodecList marks hardware-accelerated. "none - software decoding" until
  phase 3.
* During playback, `grep video-codec /proc/interrupts`: both decoders' interrupts
  are named after their device, and only a hardware decode raises them.
