/*
 * aes256.h — AES-256 (encrypt block only) + AES-256-CTR.
 *
 * This is the native (bare) launcher pair to template.cs. The CTR mode must
 * be byte-identical to the existing Node/OpenSSL and C# implementations so
 * that overlaid zips decrypt back to the exact imported payload:
 *   - keystream = AES-256-encrypt(counter block)
 *   - counter starts at the 16-byte IV and increments as a 128-bit BIG-ENDIAN
 *     integer (the low byte at index 15 carries first), matching both the
 *     "128-bit big-endian inc" loop in template.cs and OpenSSL's aes-256-ctr.
 * Only forward AES-256 encryption is required (CTR XORs the keystream in the
 * same direction for encrypt and decrypt).
 */

#ifndef VANTRAL_AES256_H
#define VANTRAL_AES256_H

#include <stddef.h>
#include <stdint.h>

void aes256_expand_key(const uint8_t key[32], uint32_t rk[60]);
void aes256_encrypt_block(const uint32_t rk[60], const uint8_t in[16], uint8_t out[16]);

/* XOR the AES-256-CTR keystream over data[0..len) in place. */
void aes256_ctr_xor(const uint8_t key[32], const uint8_t iv[16],
                    uint8_t *data, size_t len);

#endif