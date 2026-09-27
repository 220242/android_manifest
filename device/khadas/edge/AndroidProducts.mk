#
# Khadas Edge1 (RK3399) - Android TV 14
#
# The legacy Android 10 tree exposed this board as device/rockchip/rk3399
# product "rk3399_all" (PRODUCT_MODEL := Edge, TARGET_BOARD_PLATFORM_PRODUCT
# := tablet). This tree replaces it with a board-specific Android TV product
# so the Edge1 no longer inherits Rockchip's shared tablet configuration.
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/edge1_tv.mk

# <product>-<release>-<variant>. Android 14's lunch splits the string on '-' and
# rejects a two-part combo ("Valid combos must be of the form
# <product>-<release>-<variant>", build/envsetup.sh:818), so the two-part form
# these used to be would not have started a build at all.
COMMON_LUNCH_CHOICES := \
    edge1_tv-trunk_staging-userdebug \
    edge1_tv-trunk_staging-user \
    edge1_tv-trunk_staging-eng
