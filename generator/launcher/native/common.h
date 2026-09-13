/*
 * common.h — NATIVE Vantra launcher (Option 3): shared types + prototypes.
 *
 * Replaces the Mono-IL launcher with a bare native Windows PE that runs on a
 * stock host (no Mono/.NET) and performs the full deployment automatically:
 * decrypt the LOCKED VNTR overlay in memory → stage the agent →
 * silently install it → run the `enroll` value → the device registers with
 * ZERO manual steps. Compiled with -mwindows (PE Subsystem 2): no console.
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
    uint8_t *payload;
    size_t payload_len;
    char *config;
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

#endif