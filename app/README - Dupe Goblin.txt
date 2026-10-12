Dupe Goblin v1.0.18

Windows 10/11 x64. Uses built-in Windows PowerShell 5.1 and WPF.

Portable: extract the ENTIRE ZIP to a writable folder and double-click Dupe Goblin.exe. Keep the script and images alongside the EXE. No installer needed.

Installer: run Dupe_Goblin_1.0.18_Setup.exe. Installs for your account under LocalAppData\Programs\Dupe Goblin and creates desktop/Start menu shortcuts. Uninstall through Windows Settings > Apps. Reports are preserved when uninstalling.

Select drives or add folders, then scan. Detection uses size candidates and SHA-256 verification; renamed identical files match. Scanned files are never deleted, moved, renamed or modified. Reports are saved under the application Logs folder.

The native EXE launches the bundled PowerShell/WPF scanner. No third-party runtime download is required. These builds are unsigned. Windows execution-policy or organization security restrictions may prevent launching.

Troubleshooting: in Windows PowerShell, open the app folder and run & ".\Dupe Goblin.ps1" to see startup errors.

Prepared with structural/build checks on Linux. Windows installation, UI and scan tests have not yet been executed.
