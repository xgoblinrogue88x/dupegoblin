# Dupe Goblin

A read-only duplicate-file scanner for Windows, with the original Goblin artwork and a compact dark dashboard. Exact matches are verified with SHA-256; files with different names can still match. Dupe Goblin never deletes, moves, renames or modifies scanned files.

## Download v1.0.18

- [Windows installer](dist/Dupe_Goblin_1.0.18_Setup.exe?raw=true)
- [Portable ZIP](dist/Dupe_Goblin_1.0.18_Portable.zip?raw=true)
- [Source ZIP](dist/Dupe_Goblin_1.0.18_Source.zip?raw=true)
- [SHA-256 checksums](dist/SHA256SUMS.txt)

**Requirements:** Windows 10 or 11 x64, with built-in Windows PowerShell 5.1 and WPF available. The EXE is a native launcher for the bundled PowerShell scanner; no extra runtime installation is needed. Builds are unsigned.

**Portable:** extract the whole ZIP to a writable folder and run `Dupe Goblin.exe`. Keep all supplied files together.

**Installer:** run the setup EXE. It installs for your account, adds desktop and Start menu shortcuts, and registers an uninstaller in Windows Settings. Reports are preserved on uninstall.

## Use

Select drives or add folders, optionally ignore Windows Hidden items, and start scanning. Overlapping sources are deduplicated. One-pass indexing groups size candidates before streaming SHA-256 verification. Progress, cancellation, duplicate results, Explorer selection and plain-text reports are retained from the original app. Reports remain in the application `Logs` folder.

The dashboard fits into smaller windows by scaling the entire layout; source and result lists scroll internally. Very small windows reduce text and control sizes.

## Source and builds

- `app/`: PowerShell/WPF scanner and original images.
- `packaging/`: native EXE launcher, resources, manifest, NSIS installer and build scripts.
- `docs/`: build instructions and validation status.
- `dist/`: published installer, portable/source ZIPs and checksums.

See [build instructions](docs/BUILDING.md) and [validation status](docs/VALIDATION.md). Windows runtime testing remains outstanding; the compiled packages are available for testing.

Licensed under [GPL-3.0](LICENSE).
