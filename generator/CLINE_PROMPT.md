# Cline — Build the Vantra MSI Generator Service

Paste this entire file as your first message to Cline.

---

## What you're building

A Node.js HTTP server (Fastify) that runs on the Vantra Ubuntu VPS. It receives a
`POST /build` request from the Vantra web app, runs the MSI build script, and returns a
download URL for the resulting `.msi` file. The Vantra app calls this service when a
customer creates a new deployment.

This service lives in the `generator/` directory of the `vantra-installer` repo.

The HTTP contract this service must implement is defined in
`docs/vantra-integration-spec.md` — read it before writing any route handler.

---

## Ground rules — read before writing a single line

1. **No terminal access.** Whenever a step needs a terminal command — installing
   packages, running the server, testing with curl — stop and give the user the exact
   command to run and what output you need back. The senior engineer runs all commands.
   Do not claim a command succeeded without seeing real output.

2. **Never pass user input to a shell string.** All child process calls must use
   `execFile` with an argument array — never `exec()`, never string concatenation to
   build a command. This is not optional.

3. **Validate the job ID is a UUID before using it as a file path.** A job ID that
   contains `../` or any path separator must be rejected with a 400. Use a UUID regex
   check before constructing any file path from it.

4. **Validate PDF magic bytes.** The first 4 bytes of a valid PDF are `%PDF`
   (`0x25 0x50 0x44 0x46`). Read the first 4 bytes of every uploaded file and reject
   anything that doesn't match — regardless of filename or Content-Type.

5. **Never log or expose auth tokens, client IDs, or deployment UIDs** in error
   messages, console output, or HTTP responses. These are credentials.

6. **Never claim a build succeeded without seeing real output** from the child process.
   If `build.sh` exits non-zero, report the exact exit code and the last 500 characters
   of its stderr — do not summarize.

---

## Files to write or modify

### Modify: `msi-builder/build/build.sh`

Add one new optional argument: `--output <path>`. When provided, the MSI is written
to that path instead of the default `dist/VantraAgent.msi`.

Changes needed:
1. Add `OUTPUT_PATH=""` to the variable declarations at the top.
2. Add a `--output` case to the argument parser.
3. After the existing argument validation block, set a default if `OUTPUT_PATH` is
   empty:
   ```
   if [[ -z "$OUTPUT_PATH" ]]; then
       OUTPUT_PATH="$PROJECT_ROOT/dist/VantraAgent.msi"
   fi
   ```
4. Replace the hardcoded `$PROJECT_ROOT/dist/VantraAgent.msi` in the `wixl` command
   with `$OUTPUT_PATH`.
5. Replace the hardcoded path in the `ls -lh` line with `$OUTPUT_PATH`.
6. Create the parent directory of `OUTPUT_PATH` before running wixl:
   `mkdir -p "$(dirname "$OUTPUT_PATH")"` — this replaces the existing
   `mkdir -p "$PROJECT_ROOT/dist"` line.

Do not change any other behaviour of the script.

---

### New directory structure under `generator/`

```
generator/
├── src/
│   ├── server.ts       Fastify app setup, plugin registration, server start
│   ├── routes.ts       POST /build and GET /downloads/:jobId handlers
│   ├── builder.ts      Runs build.sh as a child process, returns result
│   ├── storage.ts      Job folder creation, PDF saving, MSI path, cleanup
│   └── env.ts          Typed, validated environment configuration
├── jobs/               Created at runtime — gitignored, holds per-job files
├── .gitignore
├── package.json
├── tsconfig.json
├── .env.example
└── README.md
```

---

### `generator/src/env.ts`

Typed environment accessor — fail loudly at startup if anything required is missing.

Variables:

| Name | Type | Default | Description |
|---|---|---|---|
| `PORT` | number | `4000` | Port the server listens on |
| `GENERATOR_SECRET` | string | required | Shared secret — Vantra includes this as `Authorization: Bearer <secret>` |
| `MSI_BUILDER_PATH` | string | required | Absolute path to the `msi-builder/` directory on this machine |
| `PUBLIC_URL` | string | required | Public base URL of this service, e.g. `https://generator.yourdomain.com` — used to construct download URLs |
| `JOB_TTL_HOURS` | number | `72` | How long job files are kept on disk before cleanup |

Pattern: same as `lib/env.ts` in the Vantra app — `required()` helper throws if missing,
`number()` helper parses and throws if not numeric.

---

### `generator/src/storage.ts`

Manages per-job files on disk. All job files live under `generator/jobs/{jobId}/`.

Export these four functions:

**`createJob(): string`**
Generate a UUID v4 job ID. Create the directory `jobs/{jobId}/`. Return the job ID.

**`savePdf(jobId: string, data: Buffer): void`**
Write `data` to `jobs/{jobId}/guide.pdf`. Throws if the job directory does not exist.

**`msiOutputPath(jobId: string): string`**
Return the absolute path `jobs/{jobId}/output.msi`. Does not check whether the file
exists — that is the caller's concern.

**`cleanupJob(jobId: string): void`**
Delete the entire `jobs/{jobId}/` directory and its contents. Use `rm -rf` equivalent
(`fs.rmSync` with `{ recursive: true, force: true }`). Does not throw if the directory
does not exist.

The `jobs/` directory is relative to the `generator/` directory, not to `cwd()` at
runtime. Resolve it with `path.join(__dirname, '..', 'jobs')` or equivalent.

---

### `generator/src/builder.ts`

Runs `msi-builder/build/build.sh` as a child process.

Export one function:

**`runBuild(params): Promise<{ success: boolean; output: string }>`**

Params type:
```ts
{
  clientId:     number;
  siteId:       number;
  agentType:    string;
  authToken:    string;
  apiUrl:       string;
  manufacturer: string;
  pdfPath:      string;   // absolute path to the saved PDF
  outputPath:   string;   // absolute path where the MSI should be written
  builderPath:  string;   // env.MSI_BUILDER_PATH — absolute path to msi-builder/
}
```

Implementation rules:
- The script to run is `path.join(params.builderPath, 'build', 'build.sh')`.
- Use `child_process.execFile` — not `exec`, not `spawn` with shell. Pass arguments as
  an array, never as a concatenated string.
- Argument array must be exactly:
  ```
  [
    '--client-id',     String(params.clientId),
    '--site-id',       String(params.siteId),
    '--agent-type',    params.agentType,
    '--auth-token',    params.authToken,
    '--api-url',       params.apiUrl,
    '--manufacturer',  params.manufacturer,
    '--pdf-path',      params.pdfPath,
    '--output',        params.outputPath,
  ]
  ```
- Set a timeout of 60 000 ms. If the process times out, resolve with
  `{ success: false, output: 'Build timed out after 60 seconds' }`.
- On non-zero exit: resolve with `{ success: false, output: <last 500 chars of stderr> }`.
- On exit code 0: resolve with `{ success: true, output: <stdout> }`.
- Wrap in try/catch — if `execFile` throws (e.g. script not found), resolve with
  `{ success: false, output: err.message }`. Never reject the promise.

---

### `generator/src/routes.ts`

Two routes. Import `env`, `storage`, `builder`.

**`POST /build`**

Authentication:
- Read the `Authorization` header. Expected value: `Bearer <GENERATOR_SECRET>`.
- If missing or wrong, return `401 { error: 'Unauthorized' }`.
- Use a constant-time comparison to prevent timing attacks:
  [CONSTANT_TIME_COMPARE: compare the provided token against env.GENERATOR_SECRET using
  a timing-safe byte comparison — crypto.timingSafeEqual on Buffer.from() of both strings
  padded to equal length — return 401 if they do not match]

Input parsing (multipart fields):
- `clientId` — string, parse to integer, must be a positive integer
- `siteId` — string, parse to integer, must be a positive integer
- `agentType` — string, must be exactly `"workstation"` or `"server"`
- `authToken` — string, required, non-empty
- `apiUrl` — string, required, must start with `https://`
- `manufacturer` — string, required, non-empty
- `pdf` — file field, required

PDF validation (in this order, stop at first failure):
1. Size must be ≤ 20 MB. Return `413 { error: 'PDF must be under 20 MB' }` if over.
2. Read the first 4 bytes. Must equal `%PDF` (`Buffer.from([0x25,0x50,0x44,0x46])`).
   Return `400 { error: 'File must be a valid PDF' }` if not.

On validation failure: return the appropriate 4xx with `{ error: '...' }`. Do not create
a job folder until all validation passes.

On success:
1. `const jobId = storage.createJob()`
2. `storage.savePdf(jobId, pdfBuffer)`
3. Call `builder.runBuild({ ...params, pdfPath, outputPath, builderPath: env.MSI_BUILDER_PATH })`
4. If `result.success` is false:
   - `storage.cleanupJob(jobId)`
   - Return `502 { error: 'MSI build failed. Check server logs.' }`
   - Log the `result.output` to stderr (server-side only — do not send to client)
5. If `result.success` is true:
   - Schedule cleanup: `setTimeout(() => storage.cleanupJob(jobId), env.JOB_TTL_HOURS * 3600 * 1000)`
   - Return `200`:
     ```json
     {
       "downloadUrl": "<env.PUBLIC_URL>/downloads/<jobId>",
       "expiresAt": "<ISO timestamp: now + JOB_TTL_HOURS>"
     }
     ```

**`GET /downloads/:jobId`**

1. Validate that `:jobId` matches the UUID v4 format exactly:
   `/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i`
   Return `400 { error: 'Invalid job ID' }` if it does not match.

2. Resolve the MSI path: `storage.msiOutputPath(jobId)`.

3. Check the file exists with `fs.existsSync`. Return `404 { error: 'Not found' }` if not.

4. Set response headers:
   - `Content-Type: application/octet-stream`
   - `Content-Disposition: attachment; filename="VantraAgent.msi"`

5. Stream the file using `fs.createReadStream` piped into the reply.

6. After the stream finishes, call `storage.cleanupJob(jobId)` to delete the job folder.
   Attach to the stream's `close` or `end` event — do not block the response.

---

### `generator/src/server.ts`

Fastify app setup and server start.

- Register `@fastify/multipart` with a `limits` option: `{ fileSize: 21 * 1024 * 1024 }`
  (21 MB hard cap at the framework level — the route handler enforces the 20 MB business
  limit, this prevents reading the entire stream before we can check).
- Register the routes from `routes.ts`.
- On startup, check that `env.MSI_BUILDER_PATH` exists as a directory and that
  `build/build.sh` exists inside it. If either check fails, print a clear error and
  `process.exit(1)` — a misconfigured server should not start silently.
- Create the `jobs/` directory if it does not exist (using `fs.mkdirSync` with
  `{ recursive: true }`).
- Listen on `0.0.0.0:env.PORT`. Log the port on startup.

---

### `generator/package.json`

```json
{
  "name": "vantra-msi-generator",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "start": "tsx src/server.ts",
    "dev":   "tsx watch src/server.ts"
  },
  "dependencies": {
    "@fastify/multipart": "^9.0.0",
    "fastify": "^5.0.0",
    "uuid": "^10.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/uuid": "^10.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.0.0"
  }
}
```

---

### `generator/tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "lib": ["ES2022"],
    "strict": true,
    "esModuleInterop": true,
    "resolveJsonModule": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"]
}
```

---

### `generator/.env.example`

```
PORT=4000
GENERATOR_SECRET=change-this-to-a-long-random-string
MSI_BUILDER_PATH=/home/ubuntu/vantra-installer/msi-builder
PUBLIC_URL=https://generator.yourdomain.com
JOB_TTL_HOURS=72
```

---

### `generator/.gitignore`

```
node_modules/
jobs/
dist/
.env
```

---

### `generator/README.md`

Write real documentation covering:
- What this service is and what it does
- Prerequisites: Node.js 20+, `msitools` (`wixl`) installed, `tacticalagent.exe` in
  `msi-builder/payload/`
- How to install: `npm install` in the `generator/` directory
- How to configure: copy `.env.example` to `.env` and fill in all values
- How to run: `npm start` (production) and `npm run dev` (development with auto-reload)
- How to test with curl: a real example `curl` command for `POST /build` with a test PDF
- Security note: `GENERATOR_SECRET` must be a long random string, shared only with the
  Vantra app via `MSI_GENERATOR_URL` and `MSI_GENERATOR_SECRET` env vars

---

## Definition of done

- All files written and matching the specs above.
- `msi-builder/build/build.sh` updated with `--output` flag.
- `npm install` has been run by the senior engineer (stop and ask).
- TypeScript compiles without errors (stop and ask the senior engineer to run
  `npx tsc --noEmit` and report the output).
- The senior engineer has run the server and confirmed it starts (`npm start`).
- The senior engineer has tested `POST /build` with a real curl command and confirmed
  either a successful MSI download URL or a clear, correct error response.
- README.md contains a working curl example the senior engineer has actually verified.
