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
 * zipOutputPath(jobId): Where the STAGE 2 packaged zip (one Agent.lnk inside)
 * is written. Task D: the zip is KEPT until expiry (72h) — unlike the lnk,
 * which is deleted right after zipping.
 */
export function zipOutputPath(jobId: string): string {
  return path.join(getJobsDir(), jobId, "output.zip");
}

/**
 * Expiry metadata file so the download handler can enforce the 72h window
 * independently of file mtimes (the web app supplies expiryHours).
 */
const EXPIRY_FILE = "expiry";

/** Persist the absolute expiresAt (ISO) for a job's zip. */
export function saveZipExpiry(jobId: string, expiresAt: Date): void {
  const jobDir = path.join(getJobsDir(), jobId);
  fs.writeFileSync(path.join(jobDir, EXPIRY_FILE), expiresAt.toISOString());
}

/** Read back the stored zip expiry, or null when absent/unreadable. */
export function getZipExpiry(jobId: string): Date | null {
  try {
    const raw = fs.readFileSync(path.join(getJobsDir(), jobId, EXPIRY_FILE), "utf8");
    const d = new Date(raw.trim());
    return Number.isNaN(d.getTime()) ? null : d;
  } catch {
    return null;
  }
}

/**
 * removeLnk(jobId): Delete ONLY the temp Agent.lnk after it has been zipped —
 * Task D: clean up the temp .lnk, keep the zip until expiry.
 */
export function removeLnk(jobId: string): void {
  const lnk = lnkOutputPath(jobId);
  if (fs.existsSync(lnk)) {
    fs.rmSync(lnk, { force: true });
  }
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
