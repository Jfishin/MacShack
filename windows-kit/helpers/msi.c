// msi.dll for NotProton's steam.exe under Madeira's Wine (MacShack Play, N2). Madeira ships no msi, and Wine's would
// need cabinet, sxs, mspatcha and odbccp32, which it lacks too. steam.exe imports one msi function,
// MsiConfigureProductExW, called only to uninstall an EA app it found broken; nothing is installed through msi in these
// prefixes, so the answer is Windows' own for that case: unknown product. Built by windows-kit/helpers/build.sh (x86_64,
// as steam.exe) without a C runtime (no imports, no TLS callbacks: steam.exe loads it while its process starts) and
// staged beside it in the prefix's Steam folder.
#include <windows.h>

BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}

__declspec(dllexport) UINT WINAPI MsiConfigureProductExW(LPCWSTR product, int level, int state, LPCWSTR commandLine)
{
    (void)product; (void)level; (void)state; (void)commandLine;
    return ERROR_UNKNOWN_PRODUCT;
}
