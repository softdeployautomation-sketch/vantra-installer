/**
 * Storage management for per-job files.
 * All job files live under generator/jobs/{jobId}/
 */

import { v4 as uuidv4 } from "uuid";
import * as fs from "fs";
import * as path from "path";

// Jobs directory — relative to generator/ directory
const getJobsDir = () => path.join(__dirname, "..", "jobs");

/**
 * createJob(): Generate a UUID v4 job ID and create its directory.
 */
export function createJob(): string {
  const jobId = uuidv4();
  const jobDir = path.join(getJobsDir(), jobId);
  fs.mkdirSync(jobDir, { recursive: true });
  return jobId;
}

/**
 * savePdf(jobId, data): Write PDF to jobs/{jobId}/guide.pdf
 */
export function savePdf(jobId: string, data: Buffer): void {
  const jobDir = path.join(getJobsDir(), jobId);
  if (!fs.existsSync(jobDir)) {
    throw new Error(`Job directory does not exist: ${jobDir}`);
  }
  const pdfPath = path.join(jobDir, "guide.pdf");
  fs.writeFileSync(pdfPath, data);
}

/**
 * msiOutputPath(jobId): Return the absolute path where the MSI should be written.
 */
export function msiOutputPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "output.msi");
}

/**
 * vbsOutputPath(jobId): Return the absolute path where the VBS launcher should be written.
 */
export function vbsOutputPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "installer.vbs");
}

/**
 * exeOutputPath(jobId): Return the absolute path where the branded EXE launcher should be written.
 */
export function exeOutputPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "installer.exe");
}

/**
 * lnkOutputPath(jobId): Return the absolute path where the ZIP installer's
 * Agent.lnk should be written (STAGE 1 output, consumed by STAGE 2 zipping).
 */
export function lnkOutputPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "Agent.lnk");
}

/**
 * icoPath(jobId): Return the absolute path where the custom company icon should be stored.
 */
export function icoPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "custom.ico");
}

/**
 * cleanupJob(jobId): Delete the entire job directory and contents.
 */
export function cleanupJob(jobId: string): void {
  const jobDir = path.join(getJobsDir(), jobId);
  if (fs.existsSync(jobDir)) {
    fs.rmSync(jobDir, { recursive: true, force: true });
  }
}
