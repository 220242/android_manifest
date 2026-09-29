# Where the AOSP tree is. Sourced, not run.
#
# This exists because getting it wrong looks exactly like not having synced:
#
#   $ build/build-uboot.sh ~/aosp-14-edge1
#   no U-Boot at /home/builder/aosp-14-edge1/bootloader/u-boot; run sync.sh first
#
# on a machine whose tree was synced, built and imaged. The WSL pipeline puts
# everything under one directory - build/windows/provision-wsl.sh:31-33 sets
# WORK=$HOME/android_khadas and TREE=$WORK/aosp-14-edge1 - while every script here
# defaulted to a bare $HOME/aosp-14-edge1 and every example in the docs repeated it.
# The scripts never noticed because the pipeline always passes the path explicitly;
# only a hand-run A/B ever used the default, which is when it cost a round.
#
# So the default is resolved rather than assumed: the pipeline's location first,
# then the bare one for a tree laid out by hand. An explicit argument always wins.
edge1_default_tree() {
    local c
    for c in "$HOME/android_khadas/aosp-14-edge1" "$HOME/aosp-14-edge1"; do
        if [[ -d "$c" ]]; then printf '%s' "$c"; return 0; fi
    done
    # Neither is there. Name the one the pipeline would create, so the error the
    # caller prints next says where it looked and matches what sync.sh will make.
    printf '%s' "$HOME/android_khadas/aosp-14-edge1"
}
