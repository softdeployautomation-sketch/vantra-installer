/*
 * spawn.c — process execution for the auto-install + auto-enroll steps.
 *
 * Windows: uses CreateProcess (never a shell), with no console window.
 * POSIX (host test harness only): fork/execv.
 */

#include <stdlib.h>
#include <string.h>
#include "common.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

int run_proc(const char *exe, const char **arg, int argc) {
#ifdef _WIN32
    size_t clen = strlen(exe) + 3;
    for (int i = 0; i < argc; i++) clen += 2 + strlen(arg[i]) + 2;
    char *cmd = (char *)malloc(clen + 16);
    if (!cmd) return 0;
    int oi = 0;
    cmd[oi++] = '"';
    memcpy(cmd + oi, exe, strlen(exe)); oi += (int)strlen(exe);
    cmd[oi++] = '"';
    for (int i = 0; i < argc; i++) {
        cmd[oi++] = ' ';
        const char *a = arg[i];
        int need_q = strchr(a, ' ') != NULL || strchr(a, '\t') != NULL;
        if (need_q) cmd[oi++] = '"';
        memcpy(cmd + oi, a, strlen(a)); oi += (int)strlen(a);
        if (need_q) cmd[oi++] = '"';
    }
    cmd[oi] = 0;

    STARTUPINFO si;
    ZeroMemory(&si, sizeof(si));
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));
    int ok = CreateProcess(exe, cmd, NULL, NULL, FALSE,
                           CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    free(cmd);
    if (!ok) return 0;
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 1;
#else
    pid_t pid = fork();
    if (pid == 0) {
        char **av = (char **)malloc((size_t)(argc + 2) * sizeof(char *));
        av[0] = (char *)exe;
        for (int i = 0; i < argc; i++) av[i + 1] = (char *)arg[i];
        av[argc + 1] = NULL;
        execv(exe, av);
        _exit(127);
    } else if (pid > 0) {
        int st = 0;
        waitpid(pid, &st, 0);
        (void)st;
        return 1;
    }
    return 0;
#endif
}

/* Parse the config `enroll` line into (exe, argv) and run it directly. */
int run_enroll(const char *enroll) {
    if (!enroll || enroll[0] == 0) return 0;
    size_t nt = 0;
    char **toks = tokenize(enroll, &nt);
    if (nt < 2) { free_tokens(toks, nt); return 0; }
    const char *exe = toks[1];
    int argc = (int)nt - 2;
    if (argc > 256) argc = 256;
    const char *args[256];
    for (int i = 0; i < argc; i++) args[i] = toks[i + 2];
    int rc = run_proc(exe, args, argc);
    free_tokens(toks, nt);
    return rc;
}