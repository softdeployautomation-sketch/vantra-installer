/*
 * config.c — percent-encoded URL-query config parser + a shell-free tokenizer
 * for the `enroll` value. `enroll` is never run through a shell; it is parsed
 * into (exe, argv) and handed to CreateProcess directly (spawn.c).
 */

#include <stdlib.h>
#include <string.h>
#include "common.h"

static int hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

static int cfg_get(const char *cfg, const char *key, char *out, int max) {
    const char *p = cfg;
    while (*p) {
        const char *q = strchr(p, '&');
        const char *end = q ? q : p + strlen(p);
        const char *eq = (const char *)memchr(p, '=', (size_t)(end - p));
        if (eq && eq > p) {
            int klen = (int)(eq - p);
            if ((int)strlen(key) == klen && strncmp(p, key, klen) == 0) {
                int vlen = (int)(end - (eq + 1));
                if (vlen > max) vlen = max;
                memcpy(out, eq + 1, (size_t)vlen);
                out[vlen] = 0;
                return 1;
            }
        }
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

static int url_decode(const char *s, char *out, int max) {
    int oi = 0;
    for (int i = 0; s[i] && oi < max; i++) {
        char c = s[i];
        if (c == '%' && i + 2 < (int)strlen(s)) {
            out[oi++] = (char)((hex_val(s[i + 1]) << 4) | hex_val(s[i + 2]));
            i += 2;
        } else if (c == '+') {
            out[oi++] = ' ';
        } else {
            out[oi++] = c;
        }
    }
    out[oi] = 0;
    return oi;
}

char *cfg_decoded(const char *cfg, const char *key, int max) {
    char raw[4096];
    if (!cfg_get(cfg, key, raw, 4095)) return NULL;
    char *out = (char *)malloc((size_t)max + 1);
    if (!out) return NULL;
    url_decode(raw, out, max);
    return out;
}

/*
 * tokenize: split on whitespace, honour double-quoted spans (backslash-quote
 * escapes). Used for the PS-style `enroll` line:
 *   & "C:\Program Files\TacticalAgent\tacticalrmm.exe" -m install --api "…" …
 * toks[0] == "&", toks[1] == exe path, toks[2..] == args.
 */
char **tokenize(const char *s, size_t *out_n) {
    char **toks = NULL;
    size_t n = 0;
    size_t i = 0, L = strlen(s);
    while (i < L) {
        while (i < L && (s[i] == ' ' || s[i] == '\t')) i++;
        if (i >= L) break;
        if (n % 64 == 0) {
            char **t2 = (char **)realloc(toks, (n + 64) * sizeof(char *));
            if (!t2) break;
            toks = t2;
        }
        char tok[4096];
        int oi = 0;
        if (s[i] == '"') {
            i++;
            while (i < L && s[i] != '"') {
                if (s[i] == '\\' && i + 1 < L && (s[i + 1] == '"' || s[i + 1] == '\\')) {
                    i++;
                }
                if (oi < 4095) tok[oi++] = s[i];
                i++;
            }
            if (i < L) i++; /* closing quote */
        } else {
            while (i < L && s[i] != ' ' && s[i] != '\t') {
                if (oi < 4095) tok[oi++] = s[i];
                i++;
            }
        }
        tok[oi] = 0;
        toks[n++] = strdup(tok);
    }
    *out_n = n;
    return toks;
}

void free_tokens(char **toks, size_t n) {
    for (size_t i = 0; i < n; i++) free(toks[i]);
    free(toks);
}