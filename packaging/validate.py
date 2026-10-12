"""Check actual build artifacts; this is not a Windows runtime test."""
from pathlib import Path
import hashlib
import struct
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
VERSION = "1.0.18"


def pe_header(path):
    data = path.read_bytes()
    assert data[:2] == b"MZ", path
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[offset:offset + 4] == b"PE\0\0", path
    machine = struct.unpack_from("<H", data, offset + 4)[0]
    optional = offset + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    assert subsystem == 2, "Expected Windows GUI subsystem"
    return data, offset, optional, machine, magic


exe = DIST / "portable" / "Dupe Goblin.exe"
data, pe, optional, machine, magic = pe_header(exe)
assert machine == 0x8664 and magic == 0x20B, "Expected x64 app"
# Parse section/resource records to verify a real icon, version and manifest.
section_count = struct.unpack_from("<H", data, pe + 6)[0]
optional_size = struct.unpack_from("<H", data, pe + 20)[0]
sections = pe + 24 + optional_size
resource_rva = struct.unpack_from("<I", data, optional + 112 + 2 * 8)[0]
resource_offset = None
for i in range(section_count):
    entry = sections + i * 40
    virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from("<IIII", data, entry + 8)
    if virtual_address <= resource_rva < virtual_address + max(virtual_size, raw_size):
        resource_offset = raw_offset + resource_rva - virtual_address
        break
assert resource_offset is not None
named, ids = struct.unpack_from("<HH", data, resource_offset + 12)
resource_types = {struct.unpack_from("<I", data, resource_offset + 16 + i * 8)[0]
                  for i in range(named + ids)}
assert {3, 14, 16, 24} <= resource_types, "Missing icon/version/manifest resources"
_, _, _, machine, magic = pe_header(DIST / f"Dupe_Goblin_{VERSION}_Setup.exe")
assert machine == 0x14C and magic == 0x10B, "Expected NSIS bootstrap executable"

script = (ROOT / "app" / "Dupe Goblin.ps1").read_text(encoding="utf-8-sig")
start = script.index("$xaml = @'\n") + len("$xaml = @'\n")
end = script.index("\n'@", start)
ET.fromstring(script[start:end])
ET.parse(ROOT / "packaging" / "launcher.manifest")

with zipfile.ZipFile(DIST / f"Dupe_Goblin_{VERSION}_Portable.zip") as archive:
    assert archive.testzip() is None
    for path in (DIST / "portable").rglob("*"):
        if path.is_file():
            name = f"Dupe Goblin/{path.relative_to(DIST / 'portable').as_posix()}"
            assert archive.read(name) == path.read_bytes(), name
with zipfile.ZipFile(DIST / f"Dupe_Goblin_{VERSION}_Source.zip") as archive:
    assert archive.testzip() is None
    for name in ("app/Dupe Goblin.ps1", "packaging/launcher.c", "packaging/installer.nsi", "LICENSE"):
        assert archive.read(f"Dupe Goblin Source/{name}") == (ROOT / name).read_bytes()
for line in (DIST / "SHA256SUMS.txt").read_text().splitlines():
    expected, filename = line.split("  ", 1)
    assert hashlib.sha256((DIST / filename).read_bytes()).hexdigest() == expected
print("PASS: Windows PE headers/resources, XAML/manifest XML, complete portable/source ZIPs, SHA-256 checksums.")
print("NOT RUN: Windows launching, GUI scans, installation, upgrade and uninstall.")
