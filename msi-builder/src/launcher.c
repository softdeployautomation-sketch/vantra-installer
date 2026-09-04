#include <windows.h>
#include <stdio.h>

#define VBS_RESOURCE_ID 101

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow) {
    HRSRC hRes = FindResource(NULL, MAKEINTRESOURCE(VBS_RESOURCE_ID), RT_RCDATA);
    if (!hRes) return 1;

    HGLOBAL hMem = LoadResource(NULL, hRes);
    if (!hMem) return 1;

    DWORD size = SizeofResource(NULL, hRes);
    LPVOID pData = LockResource(hMem);
    if (!pData) return 1;

    char tempDir[MAX_PATH];
    char vbsPath[MAX_PATH];
    GetTempPathA(MAX_PATH, tempDir);
    snprintf(vbsPath, MAX_PATH, "%sVantraLauncher_%lu.vbs", tempDir, GetCurrentProcessId());

    FILE *f = fopen(vbsPath, "wb");
    if (!f) return 1;
    fwrite(pData, 1, size, f);
    fclose(f);

    char cmd[MAX_PATH + 64];
    snprintf(cmd, sizeof(cmd), "wscript //B //Nologo \"%s\"", vbsPath);

    STARTUPINFOA si = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {0};

    BOOL ok = CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
                              CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    DeleteFileA(vbsPath);
    if (!ok) return 1;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return (int)exitCode;
}