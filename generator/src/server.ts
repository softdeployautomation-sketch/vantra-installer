/**
 * Fastify server setup and initialization.
 */

import Fastify from "fastify";
import multipart from "@fastify/multipart";
import * as fs from "fs";
import * as path from "path";
import { env } from "./env";
import { registerRoutes } from "./routes";

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
