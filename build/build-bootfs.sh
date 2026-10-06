#!/usr/bin/env bash
#
# Khadas Edge1 - build bootfs.img, the FAT that is partition 1 of every image.
#
#   usage: build-bootfs.sh [tree-dir]
#
# Output: $OUT/bootfs.img, holding
#
#   boot.scr         the boot script, for whichever U-Boot finds this partition
#   boot.cmd         its source, readable
#   Image            the kernel      \
#   ramdisk.img      the ramdisk      > byte-for-byte out of boot.img
#   edge1.dtb        the board dtb   /
#   edge1-boot.log   written by the boot script at boot: how far it got
#   edge1-pstore.bin the previous kernel's ramoops region, saved by the boot script
#   README.txt       what all this is, for whoever opens the card on a PC
#
# ---------------------------------------------------------------------------
# Why partition 1 is a FAT with a boot script on it
#
# The RK3399 BootROM tries SPI NOR, then the eMMC, then the SD card, and runs the
# first bootloader it finds (Pine64's RK3399 boot-sequence notes; Khadas: "SPI-Flash >
# eMMC > TF-Card"). This board has Armbian on its eMMC, so the U-Boot on our card never
# runs. What does run is the eMMC's U-Boot, and a distro U-Boot looks at the SD card
# first: boot_targets is "mmc1 mmc0 ...", and for each device it scans partition 1 (or
# whichever are flagged bootable) for extlinux/extlinux.conf and boot.scr. The owner's
# OpenWrt card "won" over the eMMC exactly this way.
#
# ---------------------------------------------------------------------------
# Why the kernel, ramdisk and dtb are files here rather than read out of boot.img
#
# The script runs on the eMMC's U-Boot, which on this board is Armbian's 2022.07 built
# from khadas-edge-v-rk3399_defconfig. The first version of this script read the three
# straight out of the raw boot partition, which needs sector arithmetic - and that
# U-Boot has no setexpr (CONFIG_CMD_SETEXPR is not set in that config). On the board
# the header check could not run, the script declined to boot, and distro boot went on
# to Armbian. Every time, with nothing on the screen to say so.
#
# Files and "load" are what every distro boot script uses, Armbian's and OpenWrt's
# included, so they are what is guaranteed to work. The cost is 55MB of duplication on
# a 7GB card. The three are extracted from the same boot.img in the same run, so they
# cannot disagree with the boot partition our own U-Boot reads. build/
# check-uboot-script.py refuses any command in the script that 2022.07 does not have.
set -euo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"
readonly TREE="${1:-$(edge1_default_tree)}"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OUT="$TREE/out/target/product/edge"
readonly FLASH="$TREE/device/khadas/edge/flash"
readonly LAYOUT="$FLASH/partitions.tsv"
readonly TEMPLATE="$FLASH/boot.cmd"
readonly BOOTIMG="$OUT/boot.img"
readonly RESULT="$OUT/bootfs.img"

[[ -f "$BOOTIMG" ]]  || { echo "no $BOOTIMG; run build.sh first" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "no $TEMPLATE; the device tree in $TREE is stale" >&2; exit 1; }
[[ -f "$LAYOUT" ]]   || { echo "no $LAYOUT" >&2; exit 1; }

# mkimage wraps the script in the legacy header "source" expects. The one U-Boot's own
# build produced is preferred - it is there after build-uboot.sh - and u-boot-tools'
# is the fallback.
MKIMAGE="$TREE/bootloader/u-boot/tools/mkimage"
[[ -x "$MKIMAGE" ]] || MKIMAGE="$(command -v mkimage || true)"
declare -a need=()
[[ -n "$MKIMAGE" ]] || need+=("mkimage (run build-uboot.sh, or apt-get install u-boot-tools)")
command -v mkfs.vfat >/dev/null 2>&1 || need+=("mkfs.vfat (apt-get install dosfstools)")
command -v mcopy >/dev/null 2>&1     || need+=("mcopy (apt-get install mtools)")
if (( ${#need[@]} )); then
    echo "bootfs.img cannot be built; missing:" >&2
    printf '  %s\n' "${need[@]}" >&2
    echo "dosfstools and mtools are in build/windows/apt-packages.txt; on the WSL" >&2
    echo "pipeline re-run the Provision stage to install them." >&2
    exit 1
fi

# The partition's size comes from the layout, so the FAT always fills it exactly.
size_mib="$(awk -F'\t' '$1 == "bootfs" { print $2 }' "$LAYOUT")"
[[ "$size_mib" =~ ^[0-9]+$ ]] || {
    echo "partitions.tsv has no fixed-size bootfs row (got '${size_mib}')" >&2; exit 1; }
first="$(awk -F'\t' '$1 !~ /^#/ && NF >= 3 { print $1; exit }' "$LAYOUT")"
[[ "$first" == "bootfs" ]] || {
    echo "bootfs must be the FIRST row of partitions.tsv, not '$first': distro boot" >&2
    echo "scans partition 1 when no partition is flagged bootable." >&2
    exit 1; }

readonly WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Take boot.img apart. Header layout from U-Boot's include/android_image.h
# (andr_boot_img_hdr_v0, packed): magic[8], then ten u32 - kernel_size, kernel_addr,
# ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr, page_size,
# header_version, os_version - name[16] at 0x30, cmdline[512] at 0x40, id at 0x240,
# extra_cmdline[1024] at 0x260, recovery_dtbo_size at 0x660, dtb_size at 0x670. Each
# section is padded to page_size: header, kernel, ramdisk, second, recovery_dtbo, dtb.
# ---------------------------------------------------------------------------
python3 - "$BOOTIMG" "$WORK" > "$WORK/vars" <<'PY'
import os, struct, sys

path, work = sys.argv[1], sys.argv[2]
img = open(path, "rb").read()
hdr = img[:0x67C]
if hdr[:8] != b"ANDROID!":
    sys.exit(f"{path}: not an Android boot image (magic {hdr[:8]!r})")

(ksz, _ka, rsz, _ra, ssz, _sa, _tags, page, ver, _osv) = struct.unpack_from("<10I", hdr, 8)
if ver != 2:
    sys.exit(f"{path}: header version {ver}; BoardConfig.mk builds 2")
(rdtbo_sz,) = struct.unpack_from("<I", hdr, 0x660)
(dsz,) = struct.unpack_from("<I", hdr, 0x670)
if not (ksz and rsz and dsz):
    sys.exit(f"{path}: kernel {ksz}, ramdisk {rsz}, dtb {dsz} bytes - all three are needed")

def pages(n):
    return (n + page - 1) // page

k_off = page
r_off = k_off + pages(ksz) * page
d_off = r_off + pages(rsz) * page + pages(ssz) * page + pages(rdtbo_sz) * page
kernel = img[k_off:k_off + ksz]
ramdisk = img[r_off:r_off + rsz]
dtb = img[d_off:d_off + dsz]
if len(kernel) != ksz or len(ramdisk) != rsz or len(dtb) != dsz:
    sys.exit(f"{path}: truncated - the header describes more than the file holds")

# What booti will check, checked here: the arm64 Image magic "ARM\x64" at 0x38
# (U-Boot arch/arm/lib/image.c, booti_setup), and the dtb's own magic.
if kernel[0x38:0x3C] != b"ARM\x64":
    sys.exit(f"{path}: the kernel has no arm64 Image magic at 0x38; booti would refuse it")
if dtb[:4] != b"\xd0\x0d\xfe\xed":
    sys.exit(f"{path}: the dtb section does not start with an FDT header")

cmdline = hdr[0x40:0x240].split(b"\0", 1)[0]
extra = hdr[0x260:0x660].split(b"\0", 1)[0]
cmdline = (cmdline + (b" " + extra if extra else b"")).decode("ascii").strip()
# The script puts the command line inside double quotes in hush.
for bad in '"$;\\`\'':
    if bad in cmdline:
        sys.exit(f"{path}: the kernel command line contains {bad!r}, which the boot script "
                 "cannot quote")
if "androidboot.boot_devices" in cmdline:
    sys.exit(f"{path}: boot.img carries androidboot.boot_devices; it is per medium and "
             "the boot script adds it")

for name, blob in (("Image", kernel), ("ramdisk.img", ramdisk), ("edge1.dtb", dtb)):
    open(os.path.join(work, name), "wb").write(blob)
(image_size,) = struct.unpack_from("<Q", kernel, 0x10)

# The ramoops region build-kernel.sh put in the dtb, read back so the boot script
# saves exactly what the kernel writes. A plain walk of the FDT structure block
# (devicetree spec, chapter 5): FDT_BEGIN_NODE 1, END_NODE 2, PROP 3, NOP 4, END 9.
def ramoops_reg(fdt):
    (off_struct, off_strings) = struct.unpack_from(">II", fdt, 8)
    def name_at(off):
        return fdt[off_strings + off:fdt.index(b"\0", off_strings + off)]
    pos, props = off_struct, [{}]
    while True:
        (tok,) = struct.unpack_from(">I", fdt, pos); pos += 4
        if tok == 1:
            end = fdt.index(b"\0", pos)
            pos = (end + 4) & ~3
            props.append({})
        elif tok == 3:
            (ln, nameoff) = struct.unpack_from(">II", fdt, pos); pos += 8
            props[-1][name_at(nameoff)] = fdt[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
        elif tok == 2:
            node = props.pop()
            parent = props[-1]
            ac = struct.unpack(">I", parent.get(b"#address-cells", b"\0\0\0\2"))[0]
            sc = struct.unpack(">I", parent.get(b"#size-cells", b"\0\0\0\1"))[0]
            if b"ramoops" in node.get(b"compatible", b"").split(b"\0") and b"reg" in node:
                words = struct.unpack(">%dI" % (len(node[b"reg"]) // 4), node[b"reg"])
                addr = sum(w << (32 * (ac - 1 - i)) for i, w in enumerate(words[:ac]))
                size = sum(w << (32 * (sc - 1 - i)) for i, w in enumerate(words[ac:ac + sc]))
                u32 = lambda k: struct.unpack(">I", node[k])[0] if k in node else 0
                return addr, size, u32(b"record-size"), u32(b"console-size"), u32(b"pmsg-size")
        elif tok == 4:
            continue
        elif tok == 9:
            return None
        else:
            sys.exit(f"{path}: unreadable dtb structure (token {tok:#x})")

reg = ramoops_reg(dtb)
# Where the console zone starts: fs/pstore/ram.c lays out the dmesg records first, as
# many whole record-size zones as fit beside console and pmsg. Its header is what the
# boot script checks, because it is the zone that matters and the first word of the
# region is the one most exposed (see build-kernel.sh).
if reg:
    addr, size, record, console, pmsg = reg
    dump = size - console - pmsg
    console_off = (dump // record) * record if record else 0
print(f"CMDLINE={cmdline}")
print(f"KSZ={ksz}")
print(f"KIMAGE={image_size}")
print(f"RSZ={rsz}")
print(f"DSZ={dsz}")
print(f"PSTORE_ADDR={addr:#x}" if reg else "PSTORE_ADDR=")
print(f"PSTORE_SIZE={size:#x}" if reg else "PSTORE_SIZE=")
print(f"PSTORE_CONSOLE={addr + console_off:#x}" if reg and console else "PSTORE_CONSOLE=")
PY

declare -A V=()
while IFS='=' read -r key value; do V["$key"]="$value"; done < "$WORK/vars"

# The kernel's in-memory size (image_size in the Image header: text plus BSS) must end
# below where the script puts the ramdisk, or booti refuses with "RD image overlaps OS
# image". The addresses are the script's own; they are read back out of it so the two
# cannot drift.
kaddr=$(sed -n 's/^setenv edge1_kaddr \(0x[0-9a-fA-F]*\)$/\1/p' "$TEMPLATE")
raddr=$(sed -n 's/^setenv edge1_raddr \(0x[0-9a-fA-F]*\)$/\1/p' "$TEMPLATE")
[[ -n "$kaddr" && -n "$raddr" ]] || { echo "boot.cmd sets no edge1_kaddr/edge1_raddr" >&2; exit 1; }
if (( kaddr + ${V[KIMAGE]} > raddr )); then
    printf 'the kernel occupies 0x%x..0x%x in memory, past the ramdisk at %s\n' \
           "$kaddr" "$(( kaddr + ${V[KIMAGE]} ))" "$raddr" >&2
    echo "Move edge1_raddr up in device/khadas/edge/flash/boot.cmd." >&2
    exit 1
fi

# Fill the template. Python rather than sed: the command line is free text.
python3 - "$TEMPLATE" "$WORK/boot.cmd" "$WORK/vars" <<'PY'
import re, sys
src, dst, varfile = sys.argv[1:4]
vals = {}
for line in open(varfile):
    k, _, v = line.rstrip("\n").partition("=")
    vals[k] = v
text = re.sub(r"@([A-Z0-9_]+)@", lambda m: vals.get(m.group(1), m.group(0)), open(src).read())
left = sorted(set(re.findall(r"@[A-Z0-9_]+@", text)))
if left:
    sys.exit("placeholder(s) in boot.cmd with no value from boot.img: " + ", ".join(left))
open(dst, "w").write(text)
PY

# Nothing the eMMC's U-Boot does not have. This is the check that would have caught
# setexpr before a card was written.
python3 "$HERE/check-uboot-script.py" "$WORK/boot.cmd" | sed 's/^/    /'

"$MKIMAGE" -A arm64 -O linux -T script -C none -n "Edge1 Android boot" \
    -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null

# Pre-created so the first fatwrite at boot replaces a file rather than allocating
# one, the simplest thing U-Boot's FAT writer does.
printf 'No boot attempt recorded yet. The boot script rewrites this file each time it\nruns: edge1_stage says how far it got.\n' > "$WORK/edge1-boot.log"
# The same for the RAM copy of the previous kernel's log, at the region's full size,
# so each save overwrites the file in place.
extra=()
if [[ -n "${V[PSTORE_SIZE]}" ]]; then
    head -c "$(( V[PSTORE_SIZE] ))" /dev/zero > "$WORK/edge1-pstore.bin"
    extra+=("$WORK/edge1-pstore.bin")
else
    echo "    (the dtb has no ramoops region - an older kernel stage? - so the boot" >&2
    echo "     script will not save the previous kernel's log)" >&2
fi
# Settings the owner can change on a PC between two boots; edge1-bootwatch reads
# them at every boot (userdebug), boot.scr reads "logs". In Russian, the owner's
# language: it is the one file on the card meant to be edited by hand. Every mode sets all three limits, so
# the last uncommented mode in the file wins whole. The one on is the power test:
# card 19 reset at random moments under load, at 40-57C, its ramoops bit-flipped
# throughout - a hardware reset; card 21 ran 14 minutes at these clocks without one.
# The steps are rk3399.dtsi's OPP tables (6.12); the voltages are why the top steps
# cost so much more power than the ones below them.
cat > "$WORK/edge1-options.txt" <<'EOF'
# Khadas Edge1 - настройки, которые читаются при каждой загрузке.
#
# Как менять: вставьте карту в ПК, откройте этот файл Блокнотом, поправьте,
# сохраните, верните карту в плату и включите её. Строки с # в начале не
# действуют. Работает на userdebug-сборке (её собирает Start-EdgeBuild.ps1).
#
# Что можно задать - верхний предел частоты, в МГц:
#   cpu_big_max_mhz     2 быстрых ядра A72:  408 600 816 1008 1200 1416 1608 1800
#   cpu_little_max_mhz  4 малых ядра A53:    408 600 816 1008 1200 1416
#   gpu_max_mhz         графика Mali-T860:   200 297 400 500 600 800
# Число между ступенями округляется вниз до ступени. Ниже предела частота
# меняется как обычно - по нагрузке. Чем выше ступень, тем выше и напряжение:
# A72 на 1800 потребляет почти вдвое больше, чем на 1416, GPU на 800 - почти
# вдвое больше, чем на 600. Поэтому при слабом питании сбоят именно верхние.
#
# Режимы ниже. Включён один - строки без #. Чтобы выбрать другой, поставьте #
# перед строками включённого и уберите # у строк нужного. Если включено
# несколько, действует нижний: каждый режим задаёт все три предела.
# Что применилось, видно в edge1-logs/boots.txt (options: ...).
#
# Разделы файла: логи, питание USB-C (pd=), память (zram= и запись на карту),
# видео (декодер и вывод на экран), режимы частот. Значение пишите сразу после "=", без пробелов; пояснение -
# отдельной строкой с #, не в той же строке.

# --- Логи загрузки ------------------------------------------------------
# logs=1: каждая загрузка пишет на карту отчёт для поиска неисправностей -
# папку edge1-logs, edge1-boot.log и edge1-pstore.bin.
# logs=0: на карту не пишется ничего - когда сборка проверена и логи больше
# не нужны. Режимы ниже действуют и так. Переключается и в Edge1 Tools.
logs=1

# --- Питание USB-C (PD) -----------------------------------------------
# Плата питается через любой из двух разъёмов USB-C и сама просит у блока
# питания напряжение - по протоколу USB PD. Пока она не просила (до карты
# 25), блок давал только 5 В: под нагрузкой (старт Android, видео, полные
# частоты) напряжение проседало, и плата перезагружалась без всяких ошибок.
# Прошивка Khadas просит 12 В - так и здесь.
#   pd=12   12 В, а если блок их не умеет - 9 В, иначе 5 В. Рекомендуется.
#   pd=15   то же, плюс 15 В - для блока без 12 В (бывает у павербанков).
#   pd=20   плюс 20 В. Вход платы рассчитан до 20 В, но Khadas держит 12 В;
#           нужно, только если блок не даёт ни 12, ни 15 В.
#   pd=9    не выше 9 В.   pd=5   только 5 В, но по договору (до 3 А).
#   pd=0    не договариваться совсем - как раньше. Если с новым питанием
#           плата перезагружается по кругу сразу при старте, поставьте 0.
# Договаривается ядро, а оно стартует секунд через 10 после включения.
# Некоторые блоки к этому времени перестают предлагать напряжения и ждут
# "сброса", при котором на секунду снимают питание - плата без батареи от
# этого выключается. Такого сброса плата не делает (с карты 26): если блок
# уже замолчал, она остаётся на 5 В, как раньше. Тогда помогает другой блок
# питания (сетевой, который предлагает напряжения постоянно).
# Нужен кабель USB-C - USB-C: через USB-A - USB-C договориться нельзя, будет
# 5 В при любом pd. Что договорилось - в edge1-logs/.../power.txt
# (voltage_now в микровольтах). Применяется при загрузке, Edge1 Tools не
# меняет.
pd=12

# --- Память (4 ГБ ОЗУ) и запись на карту ------------------------------
# Свободную память Linux и так занимает кэшем файлов: прочитанное с карты
# второй раз берётся из ОЗУ. Буфер видео задаёт само приложение: в
# SmartTube - в настройках плеера, пункт о буферизации (больший буфер -
# меньше пауз при плохой сети). Ниже - то, что можно настроить ещё.
# Строка с # в начале - стандартное поведение.
# Больше всего пишут на карту логи загрузки: logs=0 выше.
#
# zram - сжатая подкачка в ОЗУ, в процентах от памяти (стандартно 50).
# Когда памяти не хватает, редко используемое сжимается в ОЗУ, а не
# выгружается. При 4 ГБ её нужно мало: zram=25 - меньше работы процессору
# на сжатие, zram=0 - выключить совсем. Больше 75 не принимается.
#zram=25
#
# sd_readahead_kb - сколько КБ читать с карты наперёд (стандартно 128).
# 512-2048 ускоряет большие файлы: видео с карты или флешки, установку
# приложений, первый запуск. Занимает немного ОЗУ. От 16 до 8192.
#sd_readahead_kb=1024
#
# sd_write_delay_s - сколько секунд изменённые данные могут ждать в ОЗУ,
# прежде чем лечь на карту (стандартно 30). 60-120 - карта пишется реже и
# крупнее, меньше изнашивается. Приложения, которые сохраняют данные
# явно (базы, настройки), пишут сразу и не теряют ничего; при внезапном
# отключении питания пропадут только кэши за последние секунды. От 5 до 600.
#sd_write_delay_s=60

# --- Видео: декодер и вывод на экран ---------------------------------
# H.264, VP9 (YouTube), VP8 и MPEG-2 декодирует аппаратный декодер платы,
# AV1 и HEVC - процессор. Готовый кадр процессор копирует в буфер экрана,
# а видеовыход показывает его отдельным слоем под меню. Строка с # в
# начале - стандартное поведение; нужно только для проверки и на случай
# сбоя. Действует со следующего запущенного видео после загрузки.
#
# vop - какой из двух видеовыходов RK3399 ведёт HDMI.
#   vop=big  большой (стандартно, с карты 28): 3 аппаратных слоя - видео,
#            меню и оверлей накладываются без графического процессора;
#            до 4K. Тогда в оверлее GPU почти не занят во время видео.
#   vop=lit  малый, как до карты 28: один слой, и каждый кадр экрана
#            (видео, меню, оверлей) собирает GPU. Только если с big нет
#            изображения или оно искажено.
#vop=lit
#
# ui - в каком размере Android рисует меню. На 4K-телевизоре видеовыход
# включает 3840x2160, и меню 4K вчетверо тяжелее для графического процессора,
# чем 1080p. Стандартно (строки нет или ui=1080) меню рисуется в 1920x1080,
# а видеовыход растягивает его на весь экран; видео идёт своим слоем в
# полном размере - 4K остаётся 4K. На 1080p-телевизоре разницы нет.
#   ui=native  меню в размере режима телевизора (на 4K - в 4K). Если с 1080
#              на 4K-телевизоре нет изображения или оно искажено.
# Применяется при загрузке, Edge1 Tools не меняет.
#ui=native
#
# video_hw=0 - всё видео декодирует процессор (медленно; для сравнения).
#video_hw=0
#
# video_nv12=0 - кадр в формате YV12, как до карты 27: такой видеовыход
# не показывает, и его собирает GPU. Стандартно NV12 - формат декодера и
# видеовыхода.
#video_nv12=0
#
# video_threads - сколько кадров декодер готовит одновременно. Стандартно
# 2 (с карты 28): следующий кадр декодируется, пока предыдущий копируется -
# 4K на треть быстрее. 1 - по одному, как раньше; 3-4 - ещё кадр в
# очереди, скорость та же.
#video_threads=1
#
# video_copy_threads - сколько ядер копируют кадр больше 1080p (1440p, 4K)
# в буфер экрана. Стандартно 2 (с карты 29): для 4K60 одного ядра мало.
# 1 - одно ядро, как на карте 28; 3-4 - ещё быстрее, если 4K60 не успевает,
# но память у ядер общая, и выигрыш меньше.
#video_copy_threads=1
#
# hdmi_audio=0 - звук идёт на устройство «Динамик», как до карты 29.
# Стандартно (с карты 29) Android видит выход HDMI как HDMI: так плееры
# узнают, что звук идёт на телевизор, и появляются настройки объёмного
# звука. Только если с HDMI звука нет, а раньше был.
#hdmi_audio=0

# === Тест питания =====================================================
# A72 1416, A53 1416, GPU 600. Верхние ступени выключены - самые
# прожорливые. Для блока питания без USB PD (5 В): карты 18-19 и 24 на
# полных частотах перезагружались, карты 21-23 в этом режиме - нет.
#cpu_big_max_mhz=1416
#cpu_little_max_mhz=1416
#gpu_max_mhz=600

# === Полная скорость (включена сейчас) =================================
# A72 1800, A53 1416, GPU 800 - как задумано производителем. Нужен блок
# питания USB-C PD и pd=12 выше: с карты 26 плата получает 12 В (видно в
# power.txt). Если перезагрузки вернутся - посмотрите power.txt: на 5 В
# включите тест питания.
cpu_big_max_mhz=1800
cpu_little_max_mhz=1416
gpu_max_mhz=800

# === Видео ============================================================
# A72 1800, A53 1416, GPU 600. H.264 и VP9 (YouTube) декодирует аппаратный
# декодер, но кадр ещё копирует процессор, а AV1 и HEVC декодирует он
# целиком - ему нужна вся скорость. Графике хватает 600: меню рисуется в
# 1080p, на 4K его растягивает видеовыход.
#cpu_big_max_mhz=1800
#cpu_little_max_mhz=1416
#gpu_max_mhz=600

# === Игры и эмуляторы =================================================
# A72 1608, A53 1416, GPU 800. Для 3D важнее всего графика - она на
# максимуме; быстрые ядра на ступень ниже, чтобы пик потребления был меньше.
#cpu_big_max_mhz=1608
#cpu_little_max_mhz=1416
#gpu_max_mhz=800

# === Тихий и холодный =================================================
# A72 1200, A53 1200, GPU 400. Меньше нагрев, вентилятор тише, слабому
# блоку питания легче. Для меню и музыки хватает с запасом, видео 1080p
# обычно идёт; 4K-видео в этом режиме будет дёргаться.
#cpu_big_max_mhz=1200
#cpu_little_max_mhz=1200
#gpu_max_mhz=400

# === Минимальный (проверка) ===========================================
# A72 816, A53 816, GPU 297. Для диагностики, не для просмотра: если плата
# перезагружается даже так, причина не в нагрузке на питание - пришлите
# edge1-logs (в папке перезагрузившейся загрузки будет pstore).
#cpu_big_max_mhz=816
#cpu_little_max_mhz=816
#gpu_max_mhz=297
EOF
cat > "$WORK/README.txt" <<'EOF'
Khadas Edge1 - Android TV 14, boot partition
============================================

This small partition is how the card boots on a board whose eMMC already holds a
system (the RK3399 tries the eMMC before the card). The U-Boot on the eMMC looks
here first, runs boot.scr, and that starts Android from Image, ramdisk.img and
edge1.dtb. Nothing on the eMMC is written.

edge1-boot.log is rewritten by boot.scr on every boot. If Android does not start,
the edge1_stage line in it says how far the script got (edge1_where is the
device and partition it ran from; the sizes are hex):

  started         the script ran and stopped before loading anything
  no-kernel       Image could not be loaded
  no-dtb          edge1.dtb could not be loaded
  no-ramdisk      ramdisk.img could not be loaded
  booti           everything loaded and the kernel was started - from here on
                  it is the kernel's story, which is on the HDMI screen
  booti-returned  U-Boot refused to start the kernel

edge1-pstore.bin is the previous kernel's log, saved from RAM by boot.scr before
it starts the next one. It is only meaningful after a warm reset (a panic reboots
by itself after 20 seconds on a userdebug build; a power cut loses it), and
edge1_prev in edge1-boot.log says whether it held one: "found" or "none".
build/edge1-pstore.py in the source tree turns it into text.

edge1-logs/ appears once Android has run on a userdebug build. edge1-bootwatch
gives every boot a folder, boot-00001, boot-00002 and on (the last ten are kept),
and writes the whole boot into it as it happens: logcat.txt and dmesg.txt, from the
first line, for as long as the board runs, and alive.txt, which says how long the
boot has been up. If a boot ended in a reset, the next one copies that boot's last
seconds, kept by the kernel in RAM, into its folder as pstore/. Folders 120s,
completed and timeout hold a snapshot of the system's state (getprop, ps, services,
the display). boots.txt has a line per boot: when it started and how long it lasted.
If Android has not finished booting after 5 minutes, the board reboots by itself,
warm, so edge1-pstore.bin is saved too. Plain text, and the most complete record of
a boot there is.
Send the whole edge1-logs folder (zip it), with edge1-boot.log and edge1-pstore.bin.

edge1-options.txt is the one file here meant to be edited on a PC: settings read at
every boot - CPU and GPU clock limits, with ready-made modes (power test, full speed,
video, games, quiet, minimal), and "logs": logs=0 stops every write to this card
(no edge1-logs, edge1-boot.log or edge1-pstore.bin) once the build needs no more
debugging. "pd" is the USB-C PD voltage the board asks its supply for (12V; pd=0
for none), "vop" the display controller on HDMI (big; lit is the old one) and
"ui" the size the menus are drawn at (1080, scaled up on a 4K TV; native for the
TV's own mode), all applied by boot.scr; zram, sd_readahead_kb and sd_write_delay_s tune memory and
the card's writes; video_hw, video_nv12, video_threads and video_copy_threads set
the video decoder; hdmi_audio=0 keeps the sound on the audio HAL's "Speaker". It says what each line does, in Russian. Edge1 Tools
on the box changes the clock and logs lines.

Do not edit the other files on a PC; rebuild the image instead.
EOF

rm -f "$RESULT"
# -C creates the file at the given size in KiB. The label is what Windows and a Linux
# automounter show when the card is plugged into a desktop.
mkfs.vfat -n EDGE1BOOT -C "$RESULT" $(( size_mib * 1024 )) >/dev/null
mcopy -i "$RESULT" "$WORK/boot.scr" "$WORK/boot.cmd" "$WORK/Image" "$WORK/ramdisk.img" \
      "$WORK/edge1.dtb" "$WORK/edge1-boot.log" "$WORK/README.txt" "$WORK/edge1-options.txt" \
      "${extra[@]}" ::

echo "==> bootfs.img (${size_mib}MiB FAT)"
printf '    Image        %9s bytes (%s in memory with BSS)\n' "${V[KSZ]}" "${V[KIMAGE]}"
printf '    ramdisk.img  %9s bytes\n' "${V[RSZ]}"
printf '    edge1.dtb    %9s bytes\n' "${V[DSZ]}"
[[ -z "${V[PSTORE_ADDR]}" ]] || printf '    ramoops      %s, %s bytes - saved as edge1-pstore.bin\n' "${V[PSTORE_ADDR]}" "$(( V[PSTORE_SIZE] ))"
echo "    cmdline      androidboot.boot_devices=<per medium> ${V[CMDLINE]}"
