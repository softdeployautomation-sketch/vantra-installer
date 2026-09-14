#!/usr/bin/env node
/*
 * make-stamp.mjs — launcher dev/test stamping tool (WP1 round-trip).
 *
 * Appends the overlay block onto a compiled Launcher.exe:
 *     [hdr 24][envelope 65][config-cipher][payload-cipher]
 * where envelope = AES-256-CTR(sealKey, sealIv, K_B || IV_PAY || IV_CFG || CK)
 * and the config/payload are re-keyed per build (fresh K_B/IV_*).
 *
 * This is the standalone seed of the server-side stamp step (launcher-pool /
 * launcher-build stubs extend it); the produced file must decrypt back to the
 * byte-identical payload through the C# launcher (marker-mode proof).
 *
 *   usage: node make-stamp.mjs <launcher.exe> <payload.bin>
 *          <seal-key-hex> <seal-iv-hex> <out.exe> [config] [flags]
 */
import * as crypto from "crypto";
import * as fs from "fs";

const [, , launcher, payloadPath, sealKeyHex, sealIvHex, outPath, cfgRaw, flagsRaw] =
  process.argv;

const sealKey = Buffer.from(sealKeyHex, "hex");
const sealIv = Buffer.from(sealIvHex, "hex");

const flags = flagsRaw !== undefined ? parseInt(flagsRaw, 10) : 1;
const config =
  cfgRaw ??
  "apiUrl=https%3A%2F%2Fapi.example.test%2Fv3&clientId=7&siteId=9" +
    "&agentType=workstation&authToken=devtoken-0123456789abcdef" +
    "&features=rdp%2Cping%2Cpower&enroll=&debug=1" +
    "&outDir=/tmp/lztest/out";

function ctr(key, iv, data) {
  const c = crypto.createCipheriv("aes-256-ctr", key, iv);
  return Buffer.concat([c.update(data), c.final()]);
}

function u32(buf, off, v) {
  buf[off] = v & 0xff;
  buf[off + 1] = (v >> 8) & 0xff;
  buf[off + 2] = (v >> 16) & 0xff;
  buf[off + 3] = (v >> 24) & 0xff;
}

// ---- per-build re-key material ----
const KB = crypto.randomBytes(32);
const IV_PAY = crypto.randomBytes(16);
const IV_CFG = crypto.randomBytes(16);

// ---- envelope ----
const envPlain = Buffer.concat([KB, IV_PAY, IV_CFG]);
let ck = 0;
for (const b of envPlain) ck ^= b;
const envelope = ctr(sealKey, sealIv, Buffer.concat([envPlain, Buffer.from([ck & 0xff])]));

// ---- config + payload ciphers ----
const encCfg = ctr(KB, IV_CFG, Buffer.from(config, "utf8"));
const payload = fs.readFileSync(payloadPath);
const encPay = ctr(KB, IV_PAY, payload);

// ---- header ----
const hdr = Buffer.alloc(24);
hdr.write("VNTR", 0, "ascii");
hdr[4] = 1; // version
hdr[5] = flags;
u32(hdr, 8, 65);
u32(hdr, 12, encCfg.length);
u32(hdr, 16, encPay.length);

// ---- fixed trailer: cfgLen u32 | payLen u32 | "VNTZ" ----
const trc = Buffer.alloc(12);
u32(trc, 0, encCfg.length);
u32(trc, 4, encPay.length);
trc.write("VNTZ", 8, "ascii");

const overlay = Buffer.concat([hdr, envelope, encCfg, encPay, trc]);
const exe = fs.readFileSync(launcher);
fs.writeFileSync(outPath, Buffer.concat([exe, overlay]));
console.log(
  `stamped ${outPath} overlay=${overlay.length}B cfg=${config.length}B pay=${payload.length}B flags=${flags}`
);