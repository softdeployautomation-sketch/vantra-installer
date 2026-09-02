# Payload folder

Place these files here before running a build. Use these exact names:

| File | What it is |
|---|---|
| `guide.pdf` | The customer-facing install guide / Vantra onboarding document |
| `tacticalagent.exe` | The TacticalRMM agent EXE downloaded from your TacticalRMM server for this deployment |

The `tacticalagent.exe` filename is fixed — rename the downloaded file to exactly this.
The downloaded file from TacticalRMM is typically named something like
`tacticalagent-v2.11.0-windows-amd64.exe` — rename it to `tacticalagent.exe` when you
place it here.

**Do not place API tokens, credentials, or `.env` files here.** Those are passed as
arguments to the build script at runtime, not stored in this folder.

Nothing in this folder is committed to git (the `.gitignore` at the repo root excludes
`.exe` and `.msi` files in build/dist directories, and you should not commit the agent
binary anyway — it is generated fresh per deployment from your TacticalRMM server).
