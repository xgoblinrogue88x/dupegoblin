Unicode True
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!define VERSION "1.0.18"
!define APP "Dupe Goblin"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\DupeGoblin"
Name "${APP} ${VERSION}"
OutFile "../dist/Dupe_Goblin_${VERSION}_Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\Dupe Goblin"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "1.0.18.0"
VIAddVersionKey /LANG=1033 "ProductName" "${APP}"
VIAddVersionKey /LANG=1033 "FileDescription" "Dupe Goblin per-user installer"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "GPL-3.0"
!define MUI_ICON "../app/Dupe Goblin.ico"
!define MUI_UNICON "../app/Dupe Goblin.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Dupe Goblin.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Dupe Goblin"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "../LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

!macro CheckRunning
retry_running:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\DupeGoblin.App.Running") p.r0'
  StrCmp $0 0 not_running
  System::Call 'kernel32::CloseHandle(p r0)'
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Close Dupe Goblin before continuing. Cancel an active scan and wait for its window to close." IDRETRY retry_running
  Abort
not_running:
!macroend

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "This build requires 64-bit Windows 10 or 11."
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "This build requires Windows 10 or 11."
    Abort
  ${EndIf}
  SetShellVarContext current
  !insertmacro CheckRunning
FunctionEnd
Function un.onInit
  SetShellVarContext current
  !insertmacro CheckRunning
FunctionEnd

Section "Dupe Goblin"
  !insertmacro CheckRunning
  SetOutPath "$INSTDIR"
  File "../dist/portable/Dupe Goblin.exe"
  File "../app/Dupe Goblin.ps1"
  File "../app/Dupe Goblin Mascot.png"
  File "../app/Dupe Goblin Wordmark.png"
  File "../app/Dupe Goblin Icon.png"
  File "../app/Dupe Goblin.ico"
  File "../app/README - Dupe Goblin.txt"
  File "../LICENSE"
  CreateDirectory "$INSTDIR\Logs"
  WriteUninstaller "$INSTDIR\Uninstall Dupe Goblin.exe"
  CreateDirectory "$SMPROGRAMS\Dupe Goblin"
  CreateShortcut "$SMPROGRAMS\Dupe Goblin\Dupe Goblin.lnk" "$INSTDIR\Dupe Goblin.exe" "" "$INSTDIR\Dupe Goblin.ico"
  CreateShortcut "$SMPROGRAMS\Dupe Goblin\Uninstall Dupe Goblin.lnk" "$INSTDIR\Uninstall Dupe Goblin.exe"
  CreateShortcut "$DESKTOP\Dupe Goblin.lnk" "$INSTDIR\Dupe Goblin.exe" "" "$INSTDIR\Dupe Goblin.ico"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Dupe Goblin"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Dupe Goblin.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall Dupe Goblin.exe$\"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  !insertmacro CheckRunning
  Delete "$DESKTOP\Dupe Goblin.lnk"
  Delete "$SMPROGRAMS\Dupe Goblin\Dupe Goblin.lnk"
  Delete "$SMPROGRAMS\Dupe Goblin\Uninstall Dupe Goblin.lnk"
  RMDir "$SMPROGRAMS\Dupe Goblin"
  Delete "$INSTDIR\Dupe Goblin.exe"
  Delete "$INSTDIR\Dupe Goblin.ps1"
  Delete "$INSTDIR\Dupe Goblin Mascot.png"
  Delete "$INSTDIR\Dupe Goblin Wordmark.png"
  Delete "$INSTDIR\Dupe Goblin Icon.png"
  Delete "$INSTDIR\Dupe Goblin.ico"
  Delete "$INSTDIR\README - Dupe Goblin.txt"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\Uninstall Dupe Goblin.exe"
  ; Remove empty folders only. Preserve reports and all unrelated user files.
  RMDir "$INSTDIR\Logs"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
