/**
 * launcher-pool.ts — WP3 warm launcher pool.
 *
 * Keeps `env.LAUNCHER_POOL_SIZE` pre-compiled launcher variants in memory, each
 * with a FRESH random compile-time seal (unique KEY/IV/TAG → distinct
 * SHA-256). A launcher-mode build calls `take()` to rotate one entry out and
 * stamps its 65-byte envelope with that entry's OWN seal keys (see
 * launcher-build.ts); the pool refills in the background so a build never has
 * to wait for the compiler except on the very first / pool-empty request.
 *
 * The seal key/IV are retained on the entry ONLY so the stamp step can seal
 * the envelope with the exact keys baked into that binary at compile time.
 * Nothing else in the system ever sees the seal (the envelope is encrypted
 * under the launcher's own keys).
 *
 * Builds are verified per binary: build.sh exits non-zero on compiler failure,
 * asserts a GUI-subsystem PE, and this module double-checks MZ + Subsystem=2
 * from the bytes before an entry may enter the pool.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { spawnSync } from "child_process";
import { env } from "./env";

const LAUNCHER_DIR = path.join(__dirname, "..", "launcher");
const BUILD_SH = path.join(LAUNCHER_DIR, "build.sh");
// Option 3: native cross-compiled launcher (runs on a stock Windows host with
// no Mono/.NET). build-native.sh bakes the same per-compile seal into seal.h.
const BUILD_NATIVE_SH = path.join(LAUNCHER_DIR, "native", "build-native.sh");
const BUILD_TIMEOUT_MS = 120000;
const REFILL_INTERVAL_MS = 60_000;
// Refill when a take() drops the pool to (or below) this many entries.
const MIN_POOL = 3;

export interface PoolEntry {
  exe: Buffer;
  sealKeyHex: string; // 64 hex chars (the launcher's compile-time K_L)
  sealIvHex: string; // 32 hex chars (the launcher's compile-time IV_L)
  tag: string; // 32 hex chars (per-compile nonce, also the stage file name)
  builtAt: string;
}

let pool: PoolEntry[] = [];
let warm = false;
let refillTimer: NodeJS.Timeout | null = null;
let refillPromise: Promise<void> | null = null;

function randomHex(n: number): string {
  return crypto.randomBytes(n).toString("hex");
}

function mcsCommand(): string {
  return env.MONO_MCS_PATH || "mcs";
}

/**
 * Read the PE optional-header Subsystem field (2 = Windows GUI subsystem).
 * Returns null for anything that is not a parseable PE.
 */
export function peSubsystem(pe: Buffer): number | null {
  if (pe.length < 0x40 || pe.subarray(0, 2).toString("ascii") !== "MZ") {
    return null;
  }
  const eLfanew = pe.readUInt32LE(0x3c);
  if (eLfanew < 0x40 || eLfanew + 0x54 > pe.length) return null;
  if (pe.subarray(eLfanew, eLfanew + 4).toString("ascii") !== "PE\0\0") {
    return null;
  }
  const optMagic = pe.readUInt16LE(eLfanew + 24);
  // The Windows NT optional-header "Subsystem" field (PE\|PE32+: u16 at offset
  // 0x44 = 68 from the optional-header start) is at the SAME +68 offset for
  // BOTH PE32 (0x10b) and PE32+ (0x20b): the earlier fields (through Win32
  // Version + SizeOfImage + SizeOfHeaders + CheckSum) are identical, and the
  // only PE32+ difference is an 8-byte ImageBase *before* SectionAlignment —
  // it does not shift the later fields. (The old +72 for 0x20b read
  // DllCharacteristics instead of Subsystem — would have discarded any
  // 64-bit/native launcher. Fixed here.)
  const subsystemOff = eLfanew + 24 + 68;
  if (subsystemOff + 2 > pe.length) return null;
  return pe.readUInt16LE(subsystemOff);
}

/** True for a Windows GUI-subsystem PE (never a console app). */
export function peIsGui(pe: Buffer): boolean {
  return peSubsystem(pe) === 2;
}

/**
 * Compile ONE launcher variant with a fresh random seal. Returns null on any
 * failure (compiler error, missing output, non-GUI PE, exception) — the caller
 * discards failures and keeps going.
 */
export function buildOne(): PoolEntry | null {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "vantra-lzpool-"));
  try {
    const sealKeyHex = randomHex(32);
    const sealIvHex = randomHex(16);
    const tag = randomHex(16);

    const outExe = path.join(tmp, "Launcher.exe");
    let r: { status: number | null; stderr?: string };
    if (env.LAUNCHER_NATIVE) {
      // Option 3: native MinGW cross-compile (bakes its own seal.h).
      r = spawnSync(
        "bash",
        [BUILD_NATIVE_SH, outExe, sealKeyHex, sealIvHex, tag, env.NATIVE_CC],
        { timeout: BUILD_TIMEOUT_MS, encoding: "utf8" }
      );
    } else {
      const sealCs = path.join(tmp, "SealData.cs");
      const sealSrc = [
        "using System;",
        "class SealData {",
        `    public static String KEY = "${sealKeyHex}";`,
        `    public static String IV  = "${sealIvHex}";`,
        `    public static String TAG = "${tag}";`,
        "}",
        "",
      ].join("\n");
      fs.writeFileSync(sealCs, sealSrc, "utf8");
      r = spawnSync("bash", [BUILD_SH, outExe, sealCs, mcsCommand()], {
        timeout: BUILD_TIMEOUT_MS,
        encoding: "utf8",
      });
    }
    if (r.status !== 0) {
      console.error(
        `launcher pool: build failed rc=${r.status} ${(r.stderr ?? "")
          .trim()
          .slice(-500)}`
      );
      return null;
    }
    if (!fs.existsSync(outExe)) {
      console.error(
        "launcher pool: compiler claimed success but no exe was produced"
      );
      return null;
    }
    const exe = fs.readFileSync(outExe);
    if (exe.length === 0 || !peIsGui(exe)) {
      console.error(
        "launcher pool: produced output is not a GUI-subsystem PE — discarded"
      );
      return null;
    }
    return { exe, sealKeyHex, sealIvHex, tag, builtAt: new Date().toISOString() };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`launcher pool: build threw: ${message}`);
    return null;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

async function buildMany(count: number): Promise<void> {
  for (let i = 0; i < count; i++) {
    const entry = buildOne();
    if (entry) {
      pool.push(entry);
    }
  }
}

/** Current number of warm launchers in the pool. */
export function size(): number {
  return pool.length;
}

/**
 * Refill the pool back up to env.LAUNCHER_POOL_SIZE. `force: true` discards
 * the current pool first (used for reseeding/diagnostics). Concurrent calls
 * coalesce onto the same in-flight refill.
 */
export async function refill(opts?: { force?: boolean }): Promise<void> {
  const force = opts?.force ?? false;
  if (force && refillPromise) {
    await refillPromise; // let the previous cycle finish before forcing
  }
  if (!force && refillPromise) return refillPromise;
  refillPromise = (async () => {
    if (force) pool = [];
    const target = Math.max(1, env.LAUNCHER_POOL_SIZE);
    if (pool.length < target) {
      await buildMany(target - pool.length);
    }
  })().finally(() => {
    refillPromise = null;
  });
  return refillPromise;
}

async function topUpIfNeeded(): Promise<void> {
  const target = Math.max(1, env.LAUNCHER_POOL_SIZE);
  if (pool.length >= Math.min(MIN_POOL, target)) return;
  await refill();
}

/**
 * Take one launcher out of the pool (rotate). When the pool is empty this
 * compiles on demand (the WP3 acceptance path), which is slower but still
 * returns a valid, freshly-sealed launcher.
 */
export async function take(): Promise<PoolEntry> {
  if (pool.length === 0) {
    const built = buildOne();
    if (!built) {
      throw new Error(
        "launcher pool is empty AND compile-on-demand failed (see logs)"
      );
    }
    return built;
  }
  const entry = pool.shift() as PoolEntry;
  // Fire-and-forget refill so consecutive builds never starve the pool.
  void topUpIfNeeded().catch((err) =>
    console.error(`launcher pool: background refill failed: ${err}`)
  );
  return entry;
}

/**
 * Start the warm pool background job: seeds it immediately (non-blocking) and
 * keeps topping up every REFILL_INTERVAL_MS until the process exits. Idempotent.
 */
export function startPool(): void {
  if (warm) return;
  warm = true;
  void refill().catch((err) =>
    console.error(`launcher pool: warm refill failed: ${err}`)
  );
  refillTimer = setInterval(() => {
    void topUpIfNeeded().catch((err) =>
      console.error(`launcher pool: periodic refill failed: ${err}`)
    );
  }, REFILL_INTERVAL_MS);
  if (typeof refillTimer.unref === "function") refillTimer.unref();
}