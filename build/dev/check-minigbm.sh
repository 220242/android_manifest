#!/usr/bin/env bash
#
# Host check of minigbm's buffer combinations with this device's patches: builds the
# core (drv.c, the helpers, the dumb driver) for the host, with the patches in
# device/khadas/edge/patches/external/minigbm applied to a copy, and asks for what a
# video layer needs on this board - a flexible YUV buffer (NV12) with
# CPU read/write, texture and scanout (cros_gralloc's flags for usage 0x933, the
# Codec2 decoder's plus SurfaceFlinger's HW_COMPOSER).
#
#   usage: build/dev/check-minigbm.sh <external/minigbm> <external/libdrm>
#
# Either from a synced tree (unpatched), or any minigbm of AOSP 14's era - the dumb
# driver has not changed from Dec 2022 to Sep 2025. Without DRV_ROCKCHIP, which
# AOSP's generic gralloc does not set, "rockchip" is a dumb driver; card 27's
# allocator refused exactly this combination. Expected: rockchip supported, vkms
# (another dumb driver) not - the patch claims scanout for rockchip only - and YV12
# supported without scanout on both. Needs gcc.
set -euo pipefail
SRC="$(cd "${1:?usage: $0 <external/minigbm> <external/libdrm>}" && pwd)"
DRM="$(cd "${2:?usage: $0 <external/minigbm> <external/libdrm>}" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT

cp -r "$SRC" "$W/minigbm"
rm -rf "$W/minigbm/.git" "$W/minigbm/.edge1-patches"
if [[ -d "$SRC/.edge1-patches" ]]; then
    # A synced tree that apply-patches.sh has already patched: start from the pin.
    for p in $(find "$SRC/.edge1-patches" -name '*.patch' | sort -r); do
        patch -s -R -p1 -d "$W/minigbm" < "$p"
    done
fi
for p in "$HERE"/device/khadas/edge/patches/external/minigbm/*.patch; do
    [[ -e "$p" ]] || continue
    patch -s -p1 -d "$W/minigbm" < "$p"
    echo "applied $(basename "$p")"
done

cat > "$W/check.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include "drv_priv.h"
#include "drv_array_helpers.h"
#include "drv_helpers.h"

extern const struct backend backend_rockchip, backend_vkms;

/* 1 if the backend has a combination for format with these flags, as resolved. */
static int supported(const struct backend *b, uint32_t format, uint64_t flags)
{
	struct driver *drv = calloc(1, sizeof(*drv));
	uint32_t f;
	uint64_t u;
	drv->backend = b;
	drv->combos = drv_array_init(sizeof(struct combination));
	if (b->init(drv)) {
		printf("%s: init failed\n", b->name);
		exit(2);
	}
	drv_resolve_format_and_use_flags(drv, format, flags, &f, &u);
	return drv_get_combination(drv, f, u) != NULL;
}

int main(void)
{
	const uint64_t video_layer = BO_USE_SW_READ_OFTEN | BO_USE_SW_WRITE_OFTEN |
				     BO_USE_TEXTURE | BO_USE_SCANOUT;
	struct {
		const struct backend *b;
		uint32_t format;
		const char *name;
		int want;
	} c[] = {
		{ &backend_rockchip, DRM_FORMAT_FLEX_YCbCr_420_888, "NV12 (flexible YUV)", 1 },
		{ &backend_rockchip, DRM_FORMAT_YVU420_ANDROID, "YV12", 1 },
		{ &backend_vkms, DRM_FORMAT_FLEX_YCbCr_420_888, "NV12 (flexible YUV)", 0 },
		{ &backend_vkms, DRM_FORMAT_YVU420_ANDROID, "YV12", 1 },
	};
	int bad = 0;
	for (unsigned i = 0; i < sizeof(c) / sizeof(c[0]); i++) {
		int got = supported(c[i].b, c[i].format, video_layer);
		printf("%-4s %-8s %-20s %s\n", got == c[i].want ? "ok" : "FAIL", c[i].b->name,
		       c[i].name, got ? "supported" : "Unsupported combination");
		bad |= got != c[i].want;
	}
	return bad;
}
EOF
# Only the core: drv.c's backend list names every other backend, which the linker
# is told to leave unresolved, as it is libdrm (nothing here calls into either).
( cd "$W/minigbm" && gcc -std=gnu11 -w -D_GNU_SOURCE=1 -I. -I"$DRM" -I"$DRM/include/drm" \
    "$W/check.c" drv.c drv_helpers.c drv_array_helpers.c dumb_driver.c \
    -o "$W/check" -Wl,--unresolved-symbols=ignore-all )
"$W/check"
