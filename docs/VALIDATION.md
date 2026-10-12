# Validation status: v1.0.18

Build and structural checks are run on Linux. No Windows GUI environment is available in this session.

Checks completed successfully:

- Native x64 GUI executable compiled with GCC warnings treated as errors.
- NSIS 3 Unicode installer generated successfully.
- Real PE headers, embedded icon, version and manifest resources verified.
- Portable/source ZIP integrity, complete payloads and SHA-256 checksums verified.
- Installer archive tested and extracted with 7-Zip; all eight application files match the portable build byte-for-byte.
- Application script compared to v1.0.17: only the version comment changed.
- Shell/Python build scripts passed syntax checks.

Required before declaring a Windows-tested release:

1. Install on clean Windows 10/11 x64 under a standard user account, including a Unicode username/path. Verify shortcuts, app launch and Windows Apps uninstall registration.
2. Launch the extracted portable build, including from a folder containing spaces and Unicode characters. Verify no console window and correct branding.
3. Scan renamed identical files and same-sized different-content files; compare results and report. Cancel during indexing and hashing. Verify source files remain unchanged.
4. Resize during idle, indexing, hashing and results; test common resolutions and 125/150 percent display scaling.
5. Upgrade while app is closed; confirm installer refuses to proceed while a launched app is running. Uninstall and confirm reports and unrelated files survive.
6. Test missing script, failed PowerShell launch and startup errors; confirm helpful launcher messages.

The source script is preserved from v1.0.17 apart from its version comment. Native executable compilation and installer generation do not constitute Windows runtime validation. Artifacts are unsigned because no code-signing certificate was supplied.
