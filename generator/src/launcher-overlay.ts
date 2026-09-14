/**
 * launcher-overlay.ts — shared VNTR overlay assembly + decryption.
 *
 * The overlay layout (LOCKED, both sides in sync — see launcher/template.cs and
 * launcher/dev/make-stamp.mjs):
 *   [hdr 24B]  "VNTR" ver=1 flags(1) rsv(2) envLen u32=65 cfgLen u32 payLen u32 rsv(4)
 *   [env 65B]  AES-256-CTR(seal key/iv) over K_B(32) ‖ IV_PAY(16) ‖ IV_CFG(16) ‖ CK(1)
 *   [cfg …]    AES-256-CTR(K_B, IV_CFG) of the URL-query config
 *   [pay …]    AES-256-CTR(K_B, IV_PAY) of the agent exe
 *   [trc 12B]  cfgLen u32 | payLen u32 | "VNTZ"
 * CK is the xor of byte 0..63 of the envelope plaintext.
 */

import * as crypto from "crypto";

export const HDR_LEN = 24;
export const ENV_LEN = 65; // K_B(32) + IV_PAY(16) + IV_CFG(16) + CK(1)

export function ctr(key: Buffer, iv: Buffer, data: Buffer): Buffer {
  const c = crypto.createCipheriv("aes-256-ctr", key, iv);
  return Buffer.concat([c.update(data), c.final()]);
}

export interface OverlayOptions {
  sealKey: Buffer;
  sealIv: Buffer;
  kb: Buffer;
  ivPay: Buffer;
  ivCfg: Buffer;
  configText: string;
  payload: Buffer;
  payloadCipher?: Buffer; // pre-computed re-key (payloadCache.reKey) — same CTR
  flags: number; // bit0 = TEST_MODE
}

/** Assemble the overlay appended after the PE — byte-identical to make-stamp.mjs. */
export function assembleOverlay(opts: OverlayOptions): Buffer {
  const envPlain = Buffer.concat([opts.kb, opts.ivPay, opts.ivCfg]);
  let ck = 0;
  for (const b of envPlain) ck ^= b;
  const envelope = ctr(
    opts.sealKey,
    opts.sealIv,
    Buffer.concat([envPlain, Buffer.from([ck & 0xff])])
  );

  const encCfg = ctr(opts.kb, opts.ivCfg, Buffer.from(opts.configText, "utf8"));
  const encPay = opts.payloadCipher ?? ctr(opts.kb, opts.ivPay, opts.payload);

  const hdr = Buffer.alloc(HDR_LEN);
  hdr.write("VNTR", 0, "ascii");
  hdr[4] = 1; // version
  hdr[5] = opts.flags; // bit0 = TEST_MODE
  hdr.writeUInt32LE(ENV_LEN, 8);
  hdr.writeUInt32LE(encCfg.length, 12);
  hdr.writeUInt32LE(encPay.length, 16);

  const trc = Buffer.alloc(12);
  trc.writeUInt32LE(encCfg.length, 0);
  trc.writeUInt32LE(encPay.length, 4);
  trc.write("VNTZ", 8, "ascii");

  return Buffer.concat([hdr, envelope, encCfg, encPay, trc]);
}

/**
 * Invert the overlay: locate the trailer at EOF, decrypt the envelope with the
 * launcher's seal, then decrypt config + payload under K_B. Used by the WP6
 * payload round-trip check (must equal the source payload byte-for-byte).
 */
export function decryptOverlay(
  stamped: Buffer,
  sealKey: Buffer,
  sealIv: Buffer
): { config: string; payload: Buffer } {
  const size = stamped.length;
  if (size < HDR_LEN + ENV_LEN + 16) throw new Error("stamped exe too small");
  const t = size - 12;
  if (stamped.subarray(t + 8, t + 12).toString("ascii") !== "VNTZ") {
    throw new Error("missing VNTZ trailer");
  }
  const cfgLen = stamped.readUInt32LE(t);
  const payLen = stamped.readUInt32LE(t + 4);
  if (
    cfgLen <= 0 ||
    cfgLen > 64 * 1024 ||
    payLen <= 0 ||
    payLen > 256 * 1024 * 1024
  ) {
    throw new Error("overlay length fields out of range");
  }
  const ovLen = HDR_LEN + ENV_LEN + cfgLen + payLen;
  const off = size - ovLen - 12;
  if (off < 0) throw new Error("overlay offset negative");
  const ov = stamped.subarray(off, off + ovLen);
  if (ov.subarray(0, 4).toString("ascii") !== "VNTR") {
    throw new Error("missing VNTR magic");
  }
  if (ov[4] !== 1) throw new Error("unexpected overlay version");
  if (
    ov.readUInt32LE(8) !== ENV_LEN ||
    ov.readUInt32LE(12) !== cfgLen ||
    ov.readUInt32LE(16) !== payLen
  ) {
    throw new Error("header/trailer length mismatch");
  }
  const env = ctr(sealKey, sealIv, ov.subarray(HDR_LEN, HDR_LEN + ENV_LEN));
  let ck = 0;
  for (let i = 0; i < 64; i++) ck ^= env[i];
  if (ck !== (env[64] & 0xff)) throw new Error("envelope checksum mismatch");
  const kb = env.subarray(0, 32);
  const ivPay = env.subarray(32, 48);
  const ivCfg = env.subarray(48, 64);
  const config = ctr(
    kb,
    ivCfg,
    ov.subarray(HDR_LEN + ENV_LEN, HDR_LEN + ENV_LEN + cfgLen)
  ).toString("utf8");
  const payload = ctr(
    kb,
    ivPay,
    ov.subarray(HDR_LEN + ENV_LEN + cfgLen, HDR_LEN + ENV_LEN + cfgLen + payLen)
  );
  return { config, payload };
}