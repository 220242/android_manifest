#!/usr/bin/env python3
"""APK and JAR signature helpers for the build scripts. Python 3 and openssl only.

  apk-cert.py cert <file.apk>
      SHA-256 of the APK's signing certificate, lower-case hex: from the APK
      Signature Scheme v3 or v2 block when there is one (what Android checks on
      every modern APK), else from the v1 JAR signature. Exit 1 if none is found.

  apk-cert.py verify-jar <file.jar> <entry>
      Verify a v1-signed JAR down to one entry: the PKCS#7 signature over the .SF
      file (openssl cms, the embedded certificate, no chain), the .SF's digest of
      MANIFEST.MF, and the manifest's digest of <entry>. Prints the signer
      certificate's SHA-256 on success, exit 1 on any mismatch. This is how
      F-Droid's signed index (index-v1.jar) is checked.
"""
import base64
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

V2_ID = 0x7109871A
V3_ID = 0xF05368C0
MAGIC = b"APK Sig Block 42"


def die(msg):
    sys.stderr.write(f"apk-cert: {msg}\n")
    sys.exit(1)


def _lp(buf, off):
    """A uint32-length-prefixed field: (bytes, offset after it)."""
    if off + 4 > len(buf):
        raise ValueError("truncated length prefix")
    (n,) = struct.unpack_from("<I", buf, off)
    off += 4
    if off + n > len(buf):
        raise ValueError("truncated field")
    return buf[off:off + n], off + n


def signing_block_pairs(data):
    """The ID-value pairs of the APK Signing Block, or {} when there is none."""
    eocd = data.rfind(b"PK\x05\x06", max(0, len(data) - 65557))
    if eocd < 0:
        raise ValueError("not a zip file (no end of central directory)")
    (cd_off,) = struct.unpack_from("<I", data, eocd + 16)
    if cd_off < 32 or data[cd_off - 16:cd_off] != MAGIC:
        return {}
    (size,) = struct.unpack_from("<Q", data, cd_off - 24)
    start = cd_off - size - 8
    if start < 0 or struct.unpack_from("<Q", data, start)[0] != size:
        raise ValueError("APK Signing Block sizes disagree")
    pairs, off, end = {}, start + 8, cd_off - 24
    while off < end:
        (n,) = struct.unpack_from("<Q", data, off)
        (pid,) = struct.unpack_from("<I", data, off + 8)
        pairs[pid] = data[off + 12:off + 8 + n]
        off += 8 + n
    return pairs


def scheme_cert(block):
    """First signer's first certificate (DER) from a v2 or v3 block value."""
    signers, _ = _lp(block, 0)
    signer, _ = _lp(signers, 0)
    signed_data, _ = _lp(signer, 0)
    _digests, off = _lp(signed_data, 0)
    certs, _ = _lp(signed_data, off)
    cert, _ = _lp(certs, 0)
    return cert


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=False)


def der_fingerprint_from_pem(pem):
    m = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    if not m:
        return None
    r = openssl("x509", "-outform", "DER", data=m.group(0))
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 and r.stdout else None


def v1_cert(zf):
    sigs = [n for n in zf.namelist() if re.match(r"META-INF/[^/]+\.(RSA|EC|DSA)$", n)]
    if not sigs:
        return None
    r = openssl("pkcs7", "-inform", "DER", "-print_certs", data=zf.read(sigs[0]))
    return der_fingerprint_from_pem(r.stdout) if r.returncode == 0 else None


def cmd_cert(path):
    data = open(path, "rb").read()
    try:
        pairs = signing_block_pairs(data)
    except (ValueError, struct.error) as e:
        die(f"{path}: {e}")
    for pid in (V3_ID, V2_ID):
        if pid in pairs:
            try:
                print(hashlib.sha256(scheme_cert(pairs[pid])).hexdigest())
                return
            except (ValueError, struct.error) as e:
                die(f"{path}: malformed signature scheme block: {e}")
    try:
        with zipfile.ZipFile(path) as zf:
            fp = v1_cert(zf)
    except zipfile.BadZipFile as e:
        die(f"{path}: {e}")
    if not fp:
        die(f"{path}: no signature found")
    print(fp)


def _digest_lines(text, prefix=""):
    """{algorithm: base64} for the "<alg>-Digest<suffix>:" lines of one section."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"(SHA-?256|SHA1|SHA-1)-Digest" + re.escape(prefix) + r":\s*(\S+)$", line)
        if m:
            out[m.group(1).replace("-", "").upper()] = m.group(2)
    return out


def _check(alg_b64, payload):
    for alg, want in alg_b64.items():
        h = hashlib.sha256 if alg == "SHA256" else hashlib.sha1
        if base64.b64encode(h(payload).digest()).decode() == want:
            return True
    return False


def manifest_sections(mf):
    """Manifest sections keyed by Name, with continuation lines joined."""
    text = mf.decode("utf-8", "replace").replace("\r\n", "\n").replace("\n ", "")
    sections = {}
    for chunk in text.split("\n\n"):
        m = re.search(r"^Name:\s*(.+)$", chunk, re.M)
        if m:
            sections[m.group(1).strip()] = chunk
    return sections


def cmd_verify_jar(path, entry):
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        sfs = [n for n in names if re.match(r"META-INF/[^/]+\.SF$", n)]
        if len(sfs) != 1:
            die(f"{path}: expected one .SF file, found {len(sfs)}")
        sf_name = sfs[0]
        base = sf_name[:-3]
        blocks = [n for n in names if n in (base + ".RSA", base + ".EC", base + ".DSA")]
        if not blocks:
            die(f"{path}: no signature block for {sf_name}")
        sf, block = zf.read(sf_name), zf.read(blocks[0])
        mf, payload = zf.read("META-INF/MANIFEST.MF"), zf.read(entry)

    with tempfile.TemporaryDirectory() as tmp:
        sig, content, certs = (os.path.join(tmp, n) for n in ("sig", "content", "certs.pem"))
        open(sig, "wb").write(block)
        open(content, "wb").write(sf)
        r = openssl("cms", "-verify", "-binary", "-inform", "DER", "-in", sig,
                    "-content", content, "-noverify", "-certsout", certs, "-out", os.devnull)
        if r.returncode != 0:
            die(f"{path}: the signature over {sf_name} does not verify:\n"
                + r.stderr.decode(errors="replace").strip())
        fp = der_fingerprint_from_pem(open(certs, "rb").read())
    if not fp:
        die(f"{path}: no signer certificate")

    sf_text = sf.decode("utf-8", "replace").replace("\r\n", "\n")
    sf_main = sf_text.split("\n\n", 1)[0]
    whole = _digest_lines(sf_main, "-Manifest")
    if whole:
        if not _check(whole, mf):
            die(f"{path}: {sf_name} does not match MANIFEST.MF")
    else:
        die(f"{path}: {sf_name} carries no whole-manifest digest")

    section = manifest_sections(mf).get(entry)
    if section is None:
        die(f"{path}: MANIFEST.MF does not list {entry}")
    if not _check(_digest_lines(section), payload):
        die(f"{path}: {entry} does not match its digest in MANIFEST.MF")
    print(fp)


def main(argv):
    if len(argv) == 3 and argv[1] == "cert":
        cmd_cert(argv[2])
    elif len(argv) == 4 and argv[1] == "verify-jar":
        cmd_verify_jar(argv[2], argv[3])
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
