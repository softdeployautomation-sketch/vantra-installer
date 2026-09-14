/*
 * spawn.c — process execution for the stage + auto-enroll steps. run_proc is
 * the CreateProcess primitive; run_enroll_staged executes the `enroll` argv
 * against the STAGED payload (the fix for the non-Inno agent), with a portable
 * sleep_ms used for the pre-enroll settle window.
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
#include <time.h>
#include <unistd.h>
#endif

/*
 * Cross-platform millisecond sleep. Used to give the staged agent a short
 * settle window before the enrollment run (mirrors the reference PS command's
 * `Start-Sleep -Seconds 7` between install and enroll).
 */
int sleep_ms(unsigned ms) {
#ifdef _WIN32
    Sleep(ms);
#else
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
#endif
    return 1;
}

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

/*
 * run_enroll_staged: execute the `enroll` config line against the STAGED
 * payload path instead of a fixed installed path. tokenize gives
 *   toks[0] == "&", toks[1] == <old fixed exe path>, toks[2..] == <args>.
 * For the non-Inno payload the old installed path never exists (the staged
 * transport itself performs install + enroll), so we DROP toks[1] and hand the
 * remaining argv directly to run_proc(stagedExe, ...). No /VERYSILENT run, no
 * dependence on C:\Program Files\TacticalAgent\.
 */
int run_enroll_staged(const char *enroll, const char *stagedExe) {
    if (!enroll || enroll[0] == 0 || !stagedExe || stagedExe[0] == 0) return 0;
    size_t nt = 0;
    char **toks = tokenize(enroll, &nt);
    /* need at least: "&" <old exe> <first arg> */
    if (nt < 3) { free_tokens(toks, nt); return 0; }
    int argc = (int)nt - 2; /* skip toks[0]="&" and toks[1]=old exe path */
    if (argc > 256) argc = 256;
    const char *args[256];
    for (int i = 0; i < argc; i++) args[i] = toks[i + 2];
    int rc = run_proc(stagedExe, args, argc);
    free_tokens(toks, nt);
    return rc;
}