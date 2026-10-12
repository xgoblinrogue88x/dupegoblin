#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"
compiler=${CC:-x86_64-w64-mingw32-gcc}
resource_compiler=${WINDRES:-x86_64-w64-mingw32-windres}
nsis_compiler=${MAKENSIS:-makensis}
mkdir -p build dist/portable/Logs
cd packaging
"$resource_compiler" --preprocessor "$compiler" --preprocessor-arg=-E --preprocessor-arg=-xc --preprocessor-arg=-DRC_INVOKED launcher.rc -O coff -o ../build/launcher.res
"$compiler" -std=c11 -Wall -Wextra -Werror -O2 -municode -mwindows -static \
  -Wl,--no-insert-timestamp -Wl,--nxcompat -Wl,--dynamicbase \
  launcher.c ../build/launcher.res -o '../dist/portable/Dupe Goblin.exe' -luser32
cd "$repo_dir"
cp app/'Dupe Goblin.ps1' app/'Dupe Goblin Mascot.png' \
   app/'Dupe Goblin Wordmark.png' app/'Dupe Goblin Icon.png' \
   app/'Dupe Goblin.ico' app/'README - Dupe Goblin.txt' LICENSE dist/portable/
cp app/'Launch Dupe Goblin.bat' dist/portable/
cd packaging
"$nsis_compiler" -V3 installer.nsi
cd "$repo_dir"
python3 packaging/package.py
