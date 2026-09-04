# Payload folder

Place this one file here before running any build:

| File | What it is |
|---|---|
| `tacticalagent.exe` | The TacticalRMM agent EXE from your TacticalRMM server |

Rename the downloaded file (typically `tacticalagent-v2.x.x-windows-amd64.exe`) to
exactly `tacticalagent.exe` when placing it here. This file is static — it does not
change per deployment.

## The PDF is NOT placed here

The customer guide PDF is uploaded by the user through the Vantra dashboard and passed
to the build script as a path argument (`--pdf-path`). It does not live in this folder.
The build script copies whatever PDF the user provides into the temp build directory,
renames it to `guide.pdf`, and bakes it into the MSI.

## What not to put here

Do not place API tokens, credentials, `.env` files, or the generated `.msi` here.
The `tacticalagent.exe` binary itself should not be committed to git — add it to this
folder on the build server directly.
