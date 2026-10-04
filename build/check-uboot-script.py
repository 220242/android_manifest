#!/usr/bin/env python3
"""Check a U-Boot hush script against the commands the board's U-Boot actually has.

    usage: check-uboot-script.py <script.cmd>

The boot script on bootfs is run by whatever U-Boot is on the eMMC, and on this board
that is Armbian's 2022.07 built from khadas-edge-v-rk3399_defconfig. Its command set is
narrower than a current U-Boot's, and the first version of the script found that out on
the hardware: it used setexpr, which that config does not build, and so it declined to
boot every time - with no serial console to say why. A U-Boot sandbox run did not catch
it, because the sandbox was the current release, which has setexpr.

So the list below is what may appear in the script, and every entry is in the 2022.07
config (generated with `make khadas-edge-v-rk3399_defconfig` on the v2022.07 tag):

    CMD_* enabled:  BOOTI BOOTM ECHO EXPORTENV FAT (FAT_WRITE=y) FDT FS_GENERIC ITEST
                    MMC PART SOURCE ... and test, which is built with HUSH_PARSER
    CMD_* absent:   SETEXPR READ GPIO NVME ABOOTIMG LED

It is deliberately smaller than what that U-Boot has: only what the script needs, so a
new command has to be added here, with its reason, before it can be used.

Also refused: "a && b || c". U-Boot's hush skips the || branch when the && side fails
(measured in its sandbox), so that construct never does what it reads as.
"""
import re
import sys

ALLOWED = {
    "echo":     "always built",
    "test":     "built with HUSH_PARSER (cmd/Makefile: obj-$(CONFIG_HUSH_PARSER) += test.o)",
    "setenv":   "always built",
    "run":      "CMD_RUN=y",
    "load":     "CMD_FS_GENERIC=y - what distro boot itself uses",
    "env":      "CMD_EXPORTENV=y, for 'env export -t'",
    "fatwrite": "CMD_FAT=y with FAT_WRITE=y",
    "booti":    "CMD_BOOTI=y; raw initrd addr:size needs SUPPORT_RAW_INITRD=y, selected by DISTRO_DEFAULTS",
    "itest":    "CMD_ITEST=y; itest.l *addr == value is the only way to read memory without setexpr",
    "fdt":      "CMD_FDT=y (default with OF_LIBFDT; checked in the 2022.07 khadas-edge-v .config), for pd=",
}
# Measured absent from the 2022.07 khadas-edge-v config - using any of these is not a
# style question, the script simply stops working on the board.
ABSENT = {"setexpr", "read", "gpio", "nvme", "abootimg", "led"}
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "for", "while", "until"}


def split_statements(text):
    """Yield every simple command in a hush script, including the ones inside a
    single-quoted string, which is how 'setenv x ...; run x' stores a command list."""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # Single-quoted strings hold scripts for 'run'; check their contents too.
        for inner in re.findall(r"'([^']*)'", line):
            yield from split_statements(inner.replace(";", "\n"))
        line = re.sub(r"'[^']*'", "''", line)
        line = re.sub(r'"[^"]*"', '""', line)
        for part in re.split(r";|&&|\|\|", line):
            yield part.strip()


def command_of(statement):
    words = statement.split()
    while words and words[0] in KEYWORDS:
        words = words[1:]
    if not words:
        return None
    # "setexpr.l" and "cp.b" name the command before the dot.
    return words[0].split(".", 1)[0]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    text = open(path, encoding="utf-8").read()
    bad = []
    for stmt in split_statements(text):
        cmd = command_of(stmt)
        if cmd and cmd not in ALLOWED:
            bad.append((cmd, stmt))
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    trap = [l.strip() for l in body.splitlines() if "&&" in l and "||" in l]
    if bad or trap:
        for cmd, stmt in bad:
            if cmd in ABSENT:
                why = "is NOT built into the eMMC's U-Boot 2022.07"
            else:
                why = ("is not on the allowed list; add it, with the 2022.07 config "
                       "symbol that provides it, if it is really needed")
            print(f"{path}: '{cmd}' {why}: {stmt}", file=sys.stderr)
        for l in trap:
            print(f"{path}: '&& ... ||' does not work in U-Boot's hush: {l}", file=sys.stderr)
        sys.exit(1)
    used = sorted({c for c in (command_of(s) for s in split_statements(text)) if c})
    print(f"{path}: {len(used)} commands, all available on U-Boot 2022.07: {' '.join(used)}")


if __name__ == "__main__":
    main()
