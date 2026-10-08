// macshack-launch.exe: MacShack Play's Windows-side launcher, the role NotProton's macOS loader app plays when it starts
// `wine steam.exe <game> <args>` in the game's folder. Madeira splits its own program arguments at spaces and keeps
// quote characters, so a game path such as C:\Program Files (x86)\Steam\steamapps\common\... cannot reach steam.exe
// through them; Play passes the whole command line in MONO_MACSHACK_LAUNCH (Madeira lets MONO_* variables through to
// Windows) and the working folder in MONO_MACSHACK_LAUNCH_DIR. Starts it, waits, exits with its exit code.
// Built by windows-kit/helpers/build.sh (x86_64, llvm-mingw).
#include <windows.h>

NTSTATUS NTAPI NtSetInformationProcess(HANDLE process, ULONG class, void *info, ULONG size);

int main(void)
{
    static WCHAR line[32768], dir[MAX_PATH];
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 1;

    if (!GetEnvironmentVariableW(L"MONO_MACSHACK_LAUNCH", line, ARRAYSIZE(line))) return 2;
    BOOL hasDir = GetEnvironmentVariableW(L"MONO_MACSHACK_LAUNCH_DIR", dir, ARRAYSIZE(dir)) > 0;
    SetEnvironmentVariableW(L"MONO_MACSHACK_LAUNCH", NULL);   // the program's own children start nothing again
    // Madeira's opt-in fix (ml449) for a self-deadlock in its ARM64EC loader: FEX registers a new image's code while
    // holding its interval lock, and an allocator VirtualFree inside that section re-takes the lock. Without it, a
    // child process (steam.exe here) parks forever right after cryptbase.dll maps. Madeira reads it from the Windows
    // environment, which its own launch does not fill, so it starts here and every child inherits it.
    SetEnvironmentVariableW(L"MADEIRA_IMAGE_MAP_GUARD", L"1");
    // The desktop, as explorer.exe makes it before Proton's steam.exe runs (Madeira on iOS starts no explorer; its first
    // program is normally a GUI program that makes it). user32 here creates the window station and desktop that
    // steam.exe and the game inherit (without them the game's windows fail: KORRIDOR quit with CreateWindow error 5),
    // and loads win32u, whose one-time start stores the GDI handle table in this process's PEB only: Madeira gives
    // every child a copy of the first process's PEB (else KORRIDOR faulted on a NULL GdiSharedHandleTable).
    GetDesktopWindow();
    if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, CREATE_UNICODE_ENVIRONMENT, NULL, hasDir ? dir : NULL, &si, &pi))
        return 3;
    // NotProton starts steam.exe as Wine's first program. steam.exe waits until only "system" processes are left (its
    // ProcessWineMakeProcessSystem event) before it exits, so this launcher must not count as one of the prefix's
    // programs either, or the two wait for each other once the game has quit.
    HANDLE onlySystemLeft;
    NtSetInformationProcess(GetCurrentProcess(), 1000 /* ProcessWineMakeProcessSystem */, &onlySystemLeft, sizeof(HANDLE *));
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
