# envsetup.sh still sources this file on Android 14 (source_vendorsetup, near the
# end of build/envsetup.sh), but add_lunch_combo is gone from it - calling it
# only prints "add_lunch_combo is obsolete. Use COMMON_LUNCH_CHOICES in your
# AndroidProducts.mk instead." on every source. COMMON_LUNCH_CHOICES in
# AndroidProducts.mk is where the combos are declared.
#
# Kept as the hook for board-specific shell helpers, which is all vendorsetup.sh
# is still good for.
