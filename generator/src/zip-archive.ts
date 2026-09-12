/**
 * Minimal, dependency-free ZIP writer (STAGE 2).
 *
 * Builds a single valid .zip in memory from a set of { name, data } entries,
 * using DEFLATE (method 8) via Node's built-in `zlib` plus a hand-rolled
 * CRC-32. No external `zip` binary or npm dependency is required, so the
 * generator is self-contained on any host (macOS dev, Linux box, container).
 *
 * Layout produced (max 65_535 entries — we only ever write one .lnk):
 *   [local file header + name + deflated data]...  (zip64 never needed)
 *   [central directory header + name]...
 *   [end-of-central-directory record]
 *
 * The output passes `unzip -t` / `zip -T` CRC validation and opens in
 * Windows Explorer/7-Zip. This is obfuscation-adjacent packaging, NOT a
 * security boundary.
 */

import * as zlib from "zlib";

export interface ZipEntryInput {
  name: string;
  data: Buffer;
}

// CRC-32 (IEEE 802.3) lookup table — Node's zlib does not expose crc32.
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

export function crc32(data: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  }
  return c ^ 0xffffffff;
}

function u16(buf: Buffer, off: number, v: number): void {
  buf[off] = v & 0xff;
  buf[off + 1] = (v >> 8) & 0xff;
}

function u32(buf: Buffer, off: number, v: number): void {
  buf[off] = v & 0xff;
  buf[off + 1] = (v >> 8) & 0xff;
  buf[off + 2] = (v >> 16) & 0xff;
  buf[off + 3] = (v >> 24) & 0xff;
}

function dosDateTime(d: Date): { time: number; date: number } {
  const time =
    ((d.getHours()) << 11) | ((d.getMinutes()) << 5) | (d.getSeconds() >> 1);
  const date =
    ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  return { time, date };
}

interface PreparedEntry {
  nameBytes: Buffer;
  crc: number;
  comp: Buffer;
  uncompSize: number;
  localOffset: number;
}

const LOCAL_HEADER_SIZE = 30;
const CENTRAL_HEADER_SIZE = 46;
const EOCD_SIZE = 22;

/**
 * Build an in-memory .zip archive containing the given entries.
 * One agent per zip → callers pass a single `Agent.lnk` entry.
 */
export function createZip(files: ZipEntryInput[], mtime?: Date): Buffer {
  const stamp = dosDateTime(mtime ?? new Date());
  const entries = files.map((f) => {
    const nameBytes = Buffer.from(f.name, "utf-8");
    const crc = crc32(f.data);
    const comp = zlib.deflateRawSync(f.data, { level: 9 }); // raw deflate for zip
    return {
      nameBytes,
      crc,
      comp,
      uncompSize: f.data.length,
      name: f.name,
      data: f.data,
    };
  });

  // ---- pass 1: local headers + compressed data ----
  const localParts: Buffer[] = [];
  const prepared: PreparedEntry[] = [];
  let localOffset = 0;
  for (const e of entries) {
    const lh = Buffer.alloc(
      LOCAL_HEADER_SIZE + e.nameBytes.length + e.comp.length
    );
    u32(lh, 0, 0x04034b50);
    u16(lh, 4, 20); // version needed
    u16(lh, 6, 0); // general purpose flag
    u16(lh, 8, 8); // method: deflate
    u16(lh, 10, stamp.time);
    u16(lh, 12, stamp.date);
    u32(lh, 14, e.crc);
    u32(lh, 18, e.comp.length);
    u32(lh, 22, e.uncompSize);
    u16(lh, 26, e.nameBytes.length);
    u16(lh, 28, 0); // extra length
    e.nameBytes.copy(lh, LOCAL_HEADER_SIZE);
    e.comp.copy(lh, LOCAL_HEADER_SIZE + e.nameBytes.length);
    localParts.push(lh);
    prepared.push({
      nameBytes: e.nameBytes,
      crc: e.crc,
      comp: e.comp,
      uncompSize: e.uncompSize,
      localOffset,
    });
    localOffset += lh.length;
  }
  const localData = Buffer.concat(localParts);

  // ---- pass 2: central directory ----
  const centralParts: Buffer[] = [];
  for (const e of prepared) {
    const ch = Buffer.alloc(CENTRAL_HEADER_SIZE + e.nameBytes.length);
    u32(ch, 0, 0x02014b50);
    u16(ch, 4, 20); // version made by (low byte)
    u16(ch, 6, 20); // version needed
    u16(ch, 8, 0); // flags
    u16(ch, 10, 8); // method: deflate
    u16(ch, 12, stamp.time);
    u16(ch, 14, stamp.date);
    u32(ch, 16, e.crc);
    u32(ch, 20, e.comp.length);
    u32(ch, 24, e.uncompSize);
    u16(ch, 28, e.nameBytes.length);
    u16(ch, 30, 0); // extra length
    u16(ch, 32, 0); // comment length
    u16(ch, 34, 0); // disk number start
    u16(ch, 36, 0); // internal attrs
    u32(ch, 38, 0); // external attrs
    u32(ch, 42, e.localOffset);
    e.nameBytes.copy(ch, CENTRAL_HEADER_SIZE);
    centralParts.push(ch);
  }
  const centralDir = Buffer.concat(centralParts);

  // ---- pass 3: end-of-central-directory ----
  const eocd = Buffer.alloc(EOCD_SIZE);
  u32(eocd, 0, 0x06054b50);
  u16(eocd, 4, 0); // disk number
  u16(eocd, 6, 0); // disk where central dir starts
  u16(eocd, 8, files.length); // entries on this disk
  u16(eocd, 10, files.length); // total entries
  u32(eocd, 12, centralDir.length);
  u32(eocd, 16, localData.length);
  u16(eocd, 20, 0); // comment length

  return Buffer.concat([localData, centralDir, eocd]);
}