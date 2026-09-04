/**
 * Builder: Runs msi-builder/build/build.sh as a child process.
 */

import { execFile } from "child_process";
import * as path from "path";

export interface BuildParams {
  clientId: number;
  siteId: number;
  agentType: string;
  authToken: string;
  apiUrl: string;
  manufacturer: string;
  pdfPath: string;
  outputPath: string;
  builderPath: string;
}

export interface BuildResult {
  success: boolean;
  output: string;
}

const TIMEOUT_MS = 60000; // 60 seconds

/**
 * runBuild: Execute build.sh with the given parameters.
 * Always resolves (never rejects) with success/failure result.
 */
export async function runBuild(params: BuildParams): Promise<BuildResult> {
  return new Promise((resolve) => {
    try {
      const scriptPath = path.join(params.builderPath, "build", "build.sh");

      const args = [
        "--client-id",
        String(params.clientId),
        "--site-id",
        String(params.siteId),
        "--agent-type",
        params.agentType,
        "--auth-token",
        params.authToken,
        "--api-url",
        params.apiUrl,
        "--manufacturer",
        params.manufacturer,
        "--pdf-path",
        params.pdfPath,
        "--output",
        params.outputPath,
      ];

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
            output: "Build timed out after 60 seconds",
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
