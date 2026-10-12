"""Create the portable/source ZIPs and checksums after the native builds."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
VERSION = "1.0.18"


def archive(output, entries):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as target:
        for path, name in sorted(entries):
            info = zipfile.ZipInfo(name, (2026, 10, 12, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            target.writestr(info, path.read_bytes())
    with zipfile.ZipFile(output) as target:
        assert target.testzip() is None


portable = DIST / f"Dupe_Goblin_{VERSION}_Portable.zip"
archive(portable, [(p, f"Dupe Goblin/{p.relative_to(DIST / 'portable').as_posix()}")
                   for p in (DIST / "portable").rglob("*") if p.is_file()])
source_files = [ROOT / "README.md", ROOT / "LICENSE", ROOT / ".gitignore"]
for folder in ("app", "packaging", "docs"):
    source_files.extend(p for p in (ROOT / folder).rglob("*")
                        if p.is_file() and "__pycache__" not in p.parts)
source = DIST / f"Dupe_Goblin_{VERSION}_Source.zip"
archive(source, [(p, f"Dupe Goblin Source/{p.relative_to(ROOT).as_posix()}")
                 for p in source_files])
artifacts = [DIST / f"Dupe_Goblin_{VERSION}_Setup.exe", portable, source]
checksums = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
                    for p in artifacts)
(DIST / "SHA256SUMS.txt").write_text(checksums, encoding="ascii")
print(checksums, end="")
