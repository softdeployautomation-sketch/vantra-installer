# Generator — Phase 3 (not started)
# vantra-msi-generator

Small Fastify service that builds Vantra agent MSIs by invoking the `msi-builder` toolchain.

## What it does

- Accepts authenticated `POST /build` requests containing build parameters and a PDF guide.
- Runs the existing `msi-builder/build/build.sh` script to create a per-customer MSI.
- Exposes `GET /downloads/:jobId` to download the generated MSI; job files are cleaned up after a TTL.

## Prerequisites

- Node.js 20+ installed on the server.
- `msitools` (provides `wixl`) installed: `sudo apt-get install msitools`.
- Place `tacticalagent.exe` in [msi-builder/payload](msi-builder/payload/README.md) before building.

## Install

1. Change to the generator directory:

```bash
cd generator
```

2. Install dependencies (run on the server / CI machine):

```bash
npm install
```

Note: I cannot run `npm install` from here — please run the command above and paste the output if you want me to continue verifying.

## Configuration

1. Copy the example env file and edit:

```bash
cp .env.example .env
# Edit .env and set: GENERATOR_SECRET, MSI_BUILDER_PATH, PUBLIC_URL, etc.
```

Required env vars are declared in `src/env.ts` and the process will exit on startup if any required value is missing.

## Run

- Production: `npm start`
- Development (auto-reload): `npm run dev`

The server listens on `0.0.0.0:$PORT` (default 4000). On startup it verifies `MSI_BUILDER_PATH` and `build/build.sh` exist and creates the `jobs/` directory.

## Test with curl

Replace placeholders (`<...>`) with real values. `GENERATOR_SECRET` must match the service's `.env` value.

```bash
curl -v -X POST "http://localhost:4000/build" \
  -H "Authorization: Bearer <GENERATOR_SECRET>" \
  -F "clientId=123" \
  -F "siteId=456" \
  -F "agentType=workstation" \
  -F "authToken=<AGENT_AUTH_TOKEN>" \
  -F "apiUrl=https://api.example.com" \
  -F "manufacturer=ExampleCorp" \
  -F "pdf=@./test-guide.pdf;type=application/pdf"
```

Expected success response (HTTP 200):

```json
{
  "downloadUrl": "https://generator.yourdomain.com/downloads/<jobId>",
  "expiresAt": "2026-09-05T...Z"
}
```

If the build fails, the service will return `502 {"error":"MSI build failed. Check server logs."}` and the server logs will contain the build output for inspection.

## Security notes

- `GENERATOR_SECRET` must be a long, random string and kept secret. Do not log it or include it in responses.
- The service validates PDF magic bytes and enforces a 20 MB PDF size limit.

## Where to look in the code

- Server entry: [src/server.ts](src/server.ts)
- Routes: [src/routes.ts](src/routes.ts)
- Builder wrapper: [src/builder.ts](src/builder.ts)
- Storage helpers: [src/storage.ts](src/storage.ts)
- Env validation: [src/env.ts](src/env.ts)

## Next steps for you

- Run `npm install` in the `generator/` directory and paste the output here.
- Run `npx tsc --noEmit` and paste any TypeScript errors (if any).
- Start the server (`npm start`) and run the example `curl` above; paste the HTTP response and any server logs if something fails.

Thanks — tell me the outputs and I'll help debug any issues.
