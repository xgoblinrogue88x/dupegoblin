# Building Dupe Goblin 1.0.18

The Linux cross-build requires Python 3, MinGW-w64 x64 GCC/binutils and NSIS 3 Unicode. On Debian: install `gcc-mingw-w64-x86-64`, `binutils-mingw-w64-x86-64`, and `nsis` through the signed package repositories, then run:

```sh
bash packaging/build.sh
```

If your compiler is named `x86_64-w64-mingw32-gcc-posix`, set `CC` to that executable. `WINDRES` and `MAKENSIS` override the resource compiler and installer compiler. For locally extracted NSIS packages, set `NSISDIR` to their `usr/share/nsis` directory and put the compiler tools on `PATH`.

Outputs in `dist/`: Setup EXE, portable ZIP, source ZIP and SHA256SUMS.txt. Build outputs under `build/` and `dist/portable/` are disposable. Packaging does not embed dependencies downloaded from unofficial sources or disable signature/checksum verification.

The native x64 Windows launcher uses the system PowerShell executable, passes the script path as a quoted Unicode argument, requests STA mode for WPF, sets the working directory to the application folder, and waits for the scanner to exit. It holds a named running marker that the installer/uninstaller checks before replacing or removing files. Direct script launches are not covered by this marker; close those manually before upgrading.

The installer requires no elevation, writes only per-user installation/shortcut/registry locations, and removes only explicit application files. It preserves Logs reports and unrelated files. Run `packaging/validate.py` after building for structural validation. Windows execution is still required to validate real launch/install/uninstall behavior.
