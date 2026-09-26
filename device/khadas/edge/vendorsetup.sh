# Retained for AOSP releases that still source vendorsetup.sh.
# On Android 14 COMMON_LUNCH_CHOICES in AndroidProducts.mk is authoritative.
add_lunch_combo edge1_tv-userdebug 2>/dev/null || true
add_lunch_combo edge1_tv-user 2>/dev/null || true
