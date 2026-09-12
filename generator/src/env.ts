/**
 * Typed environment configuration with validation.
 * Fails loudly at startup if any required value is missing.
 */

// Load .env from the generator/ directory before any process.env reads happen.
import "dotenv/config";

function required(key: string): string {
  const value = process.env[key];
  if (!value) {
    console.error(`Error: Environment variable ${key} is required but not set.`);
    process.exit(1);
  }
  return value;
}

function optional(key: string, fallback: string): string {
  const value = process.env[key];
  return value && value.trim() !== "" ? value.trim() : fallback;
}

function number(key: string, defaultValue: number): number {
  const value = process.env[key];
  if (!value) {
    return defaultValue;
  }
  const parsed = parseInt(value, 10);
  if (isNaN(parsed)) {
    console.error(
      `Error: Environment variable ${key}="${value}" is not a valid number.`
    );
    process.exit(1);
  }
  return parsed;
}

export const env = {
  PORT: number("PORT", 4000),
  GENERATOR_SECRET: required("GENERATOR_SECRET"),
  MSI_BUILDER_PATH: required("MSI_BUILDER_PATH"),
  PUBLIC_URL: required("PUBLIC_URL"),
  JOB_TTL_HOURS: number("JOB_TTL_HOURS", 72),

  // Masked, customer-facing download host (STAGE 2). The handed zip link is
  // `${REDIRECT_BASE_URL}/d/<jobId>` so the generator's actual origin never
  // appears in the URL. Sensible default: unset → PUBLIC_URL (the generator's
  // own public origin), which works end-to-end for dev/lab. To ACTUALLY mask
  // the origin, set REDIRECT_BASE_URL to the separate link-routing/redirector
  // host (e.g. https://dl.vantra.instaweb.top) that 302s /d/<jobId> →
  // <PUBLIC_URL>/downloads/<jobId>/zip.
  REDIRECT_BASE_URL: optional("REDIRECT_BASE_URL", ""),
};
