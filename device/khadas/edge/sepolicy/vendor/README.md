This board declares no vendor property labels, and the two files that did that -
property_contexts and property.te - are gone.

What happened, in the order it happened:

  1. property_contexts labelled "sys.hwc." with a vendor type. check_prop_prefix
     rejected it at 71% of a six-hour build: a vendor partition may only own
     properties under vendor. odm. ro.vendor. ro.odm. ro.hardware. ro.boot.
     persist.vendor. persist.odm. persist.camera. ctl.vendor. ctl.odm.
     ctl.{start,stop}$vendor. ctl.{start,stop}$odm. init.svc.vendor. and
     init.svc.odm. Those were Rockchip hwcomposer properties and nothing reads
     them here, so they went.

  2. What remained were five ro.hardware.* exact matches - gralloc, hwcomposer,
     egl, vulkan and audio.primary - which are inside the allowed prefixes. They
     failed anyway, on the next run:

       host_init_verifier: Unable to serialize property contexts:
       Duplicate exact match detected for 'ro.hardware.gralloc'

     The platform already labels all five, because the code that reads them is
     platform code: the EGL loader resolves ro.hardware.egl, the gralloc and
     composer loaders resolve ro.hardware.gralloc and ro.hardware.hwcomposer, and
     libaudiohal resolves ro.hardware.audio.primary. A vendor tree relabelling a
     platform property is the error, not a missing grant.

Setting the values is a different thing and still happens: device.mk sets
ro.hardware.egl=mesa, ro.hardware.gralloc=minigbm and
ro.hardware.hwcomposer=drm_minigbm through PRODUCT_PROPERTY_OVERRIDES. A property
needs a label only when a vendor domain has to read or write one the platform does
not know about - and there are none of those on this board yet.

If that changes, the new file must satisfy both rules above: an allowed prefix,
and a name the platform does not already match. The module probe
(build/windows/provision-wsl.sh, stage_probe) checks the second one against the
synced system/sepolicy and stops the run before the build; verify-tree.sh check 9d
checks the first offline.
