/**
 * EXE Builder: Runs msi-builder/build/build-exe.sh as a child process.
 */

import { execFile } from "child_process";
import * as path from "path";

export interface ExeBuildParams {
  vbsPath: string;
  icoPath?: string; // optional — undefined means no custom icon
  outputPath: string;
  builderPath: string; // MSI_BUILDER_PATH env var (same as MSI builder)
}

export interface ExeBuildResult {
  success: boolean;
  output: string;
}

const TIMEOUT_MS = 90000; // 90 seconds — compilation takes longer than wixl

/**
 * runExeBuild: Execute build-exe.sh with the given parameters.
 * Always resolves (never rejects) with success/failure result.
 */
export async function runExeBuild(
  params: ExeBuildParams
): Promise<ExeBuildResult> {
  return new Promise((resolve) => {
    try {
      const scriptPath = path.join(params.builderPath, "build", "build-exe.sh");

      const args = [
        "--vbs-path",
        params.vbsPath,
        "--output",
        params.outputPath,
      ];

      if (params.icoPath) {
        args.push("--ico-path", params.icoPath);
      }

      let stdout = "";
      let stderr = "";

      const proc = execFile(scriptPath, args, { timeout: TIMEOUT_MS });

      proc.stdout?.on("data", (data: Buffer) => {
        stdout += data.toString();
      });

      proc.stderr?.on("data", (data: Buffer) => {
        stderr += data.toString();
      });

      proc.on("error", (err: Error) => {
        // execFile throws on error (e.g., script not found)
        resolve({
          success: false,
          output: err.message,
        });
      });

      proc.on("exit", (code: number | null) => {
        if (code === 0) {
          resolve({
            success: true,
            output: stdout,
          });
        } else if (code === null) {
          // Process was killed (e.g., timeout)
          resolve({
            success: false,
            output: "EXE build timed out after 90 seconds",
          });
        } else {
          // Non-zero exit code: report last 500 chars of stderr
          const errorOutput =
            stderr.length > 500 ? stderr.slice(-500) : stderr || stdout;
          resolve({
            success: false,
            output: errorOutput,
          });
        }
      });
    } catch (err) {
      // Catch any synchronous errors
      const message = err instanceof Error ? err.message : String(err);
      resolve({
        success: false,
        output: message,
      });
    }
  });
}