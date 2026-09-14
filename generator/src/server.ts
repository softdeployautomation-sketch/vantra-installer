/**
 * Fastify server setup and initialization.
 */

import Fastify from "fastify";
import multipart from "@fastify/multipart";
import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { env } from "./env";
import { registerRoutes } from "./routes";
import { startPool } from "./launcher-pool";

async function start() {
  // Validate that MSI builder is properly configured
  const builderPath = env.MSI_BUILDER_PATH;
  if (!fs.existsSync(builderPath)) {
    console.error(
      `Error: MSI_BUILDER_PATH does not exist: ${builderPath}`
    );
    process.exit(1);
  }

  const buildScript = path.join(builderPath, "build", "build.sh");
  if (!fs.existsSync(buildScript)) {
    console.error(
      `Error: build script not found at: ${buildScript}`
    );
    process.exit(1);
  }

  // ZIP installer (STAGE 1) requires pwsh (PowerShell 7) to run
  // New-AgentShortcut.ps1. Mirrors the MSI_BUILDER_PATH startup check above.
  const pwshCheck = spawnSync("pwsh", ["-NoProfile", "-NoLogo", "-Command", "\"ok\""], {
    stdio: "ignore",
  });
  if (pwshCheck.status !== 0) {
    console.error(
      "Error: pwsh (PowerShell 7) is required for the ZIP installer but was not found on PATH."
    );
    console.error("Install it (Ubuntu/Debian): sudo apt-get install powershell");
    process.exit(1);
  }

  // Check for MinGW cross-compiler (optional — branded EXE feature only)
  const mingwCheck = spawnSync("x86_64-w64-mingw32-gcc", ["--version"], {
    stdio: "ignore",
  });
  if (mingwCheck.status !== 0) {
    console.warn(
      "WARNING: x86_64-w64-mingw32-gcc not found — branded EXE feature unavailable"
    );
    console.warn("Install with: sudo apt-get install gcc-mingw-w64-x86-64");
  }

  // Create jobs directory
  const jobsDir = path.join(__dirname, "..", "jobs");
  if (!fs.existsSync(jobsDir)) {
    fs.mkdirSync(jobsDir, { recursive: true });
  }

  // Initialize Fastify
  const app = Fastify({
    logger: true,
  });

  // Register multipart plugin with size limit
  await app.register(multipart, {
    limits: {
      fileSize: 21 * 1024 * 1024, // 21 MB hard limit at framework level
    },
  });

  // Register routes
  await registerRoutes(app);

  // Warm launcher pool (WP3): seed env.LAUNCHER_POOL_SIZE pre-compiled
  // launcher variants in the background so launcher-mode builds never block on
  // the mono compiler. Non-fatal — refill failures log and retry.
  startPool();
  console.log(`Launcher pool warmer started (target=${env.LAUNCHER_POOL_SIZE})`);

  // Start server
  try {
    await app.listen({ host: "0.0.0.0", port: env.PORT });
    console.log(`Server listening on port ${env.PORT}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

start().catch((err) => {
  console.error("Failed to start server:", err);
  process.exit(1);
});
