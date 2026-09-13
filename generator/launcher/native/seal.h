/*
 * seal.h — per-launcher compile-time seal for the NATIVE launcher.
 *
 *   SEAL_KEY_64 : 32 bytes (64 hex chars)  — AES-256 launcher key (K_L)
 *   SEAL_IV_32  : 16 bytes (32 hex chars)  — AES-256 CTR initial value (IV_L)
 *   SEAL_TAG_32 : 32 hex chars random nonce — every compiled launcher is
 *                 byte-unique (hash diversity); also names the staged artifact
 *                 <outDir>\_stg_<TAG>.exe
 *
 * These are the same values the pool stamps the 65-byte envelope with, exactly
 * as SealData.cs does for the Mono launcher. build-native.sh regenerates this
 * file for every compile (fresh random bytes). Dev placeholder below mirrors
 * SealData.cs so the host SELFTEST round-trips with dev-stamped overlays.
 */

#ifndef LNCH_SEAL_H
#define LNCH_SEAL_H

#define SEAL_KEY_64 "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
#define SEAL_IV_32  "102030405060708090a0b0c0d0e0f1020"
#define SEAL_TAG_32 "a1b2c3d4e5f60718293a4b5c6d7e8f901"

#endif