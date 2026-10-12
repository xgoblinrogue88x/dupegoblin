#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <strsafe.h>
#include <wchar.h>

/* The native launcher deliberately delegates the unchanged WPF scanner to
   Windows PowerShell 5.1. Nothing is unpacked into temporary folders. */
static int fail(const wchar_t *message) {
    MessageBoxW(NULL, message, L"Dupe Goblin", MB_OK | MB_ICONERROR);
    return 1;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous,
                   PWSTR arguments, int show) {
    (void)instance; (void)previous; (void)arguments; (void)show;
    wchar_t folder[32768], script[32768], powershell[32768], command[32768];
    DWORD length = GetModuleFileNameW(NULL, folder, ARRAYSIZE(folder));
    if (!length || length >= ARRAYSIZE(folder))
        return fail(L"The application folder path is too long or unavailable.");
    wchar_t *separator = wcsrchr(folder, L'\\');
    if (!separator) return fail(L"Cannot locate the application folder.");
    *separator = L'\0';
    if (FAILED(StringCchPrintfW(script, ARRAYSIZE(script),
                              L"%s\\Dupe Goblin.ps1", folder)))
        return fail(L"The application folder path is too long.");
    DWORD attributes = GetFileAttributesW(script);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY))
        return fail(L"Dupe Goblin.ps1 is missing. Extract the entire portable ZIP, "
                    L"or reinstall Dupe Goblin. Keep the EXE, script and images together.");
    UINT systemLength = GetSystemDirectoryW(powershell, ARRAYSIZE(powershell));
    if (!systemLength || systemLength >= ARRAYSIZE(powershell) ||
        FAILED(StringCchCatW(powershell, ARRAYSIZE(powershell),
                             L"\\WindowsPowerShell\\v1.0\\powershell.exe")))
        return fail(L"Cannot locate Windows PowerShell.");
    if (GetFileAttributesW(powershell) == INVALID_FILE_ATTRIBUTES)
        return fail(L"Windows PowerShell is unavailable. Dupe Goblin requires "
                    L"Windows 10 or 11 with Windows PowerShell 5.1 and WPF enabled.");
    if (FAILED(StringCchPrintfW(command, ARRAYSIZE(command),
                L"\"%s\" -NoLogo -NoProfile -NonInteractive -STA "
                L"-ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\"",
                powershell, script)))
        return fail(L"The application command exceeds the Windows length limit.");

    /* The installer checks this object before updating/removing application
       files. Every launcher keeps a handle alive until its scanner exits. */
    HANDLE running = CreateMutexW(NULL, FALSE, L"Local\\DupeGoblin.App.Running");
    if (!running) return fail(L"Cannot initialize the application running marker.");
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(powershell, command, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, folder, &startup, &process)) {
        DWORD error = GetLastError();
        wchar_t message[1024];
        StringCchPrintfW(message, ARRAYSIZE(message),
            L"Unable to start Windows PowerShell (Windows error %lu). "
            L"Check that your security policy permits this application.", error);
        CloseHandle(running);
        return fail(message);
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    CloseHandle(running);
    if (exitCode != 0)
        fail(L"Dupe Goblin exited with an error. For details, open Windows PowerShell "
             L"in the application folder and run: & '.\\Dupe Goblin.ps1'");
    return (int)exitCode;
}
