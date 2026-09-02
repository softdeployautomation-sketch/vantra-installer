# Generator — Phase 3 (not started)

This folder will hold the server-side MSI generation service. It is not being built yet.

## What it will do

A Node.js API service running on the Ubuntu VPS that Vantra calls whenever a customer
creates a new deployment. It:

1. Receives deployment parameters from Vantra (CLIENT_ID, SITE_ID, AGENT_TYPE, AUTH_TOKEN,
   AGENT_VERSION)
2. Downloads the correct `tacticalagent.exe` from the TacticalRMM build service
3. Fills in the `Product.wxs` and `orchestrator.ps1` templates from `msi-builder/src/`
4. Runs `wixl` to build the `.msi`
5. Signs the `.msi` (Phase 2 must be complete first)
6. Returns the signed `.msi` for Vantra to serve as the customer's download

## Prerequisites before starting Phase 3

- Phase 1 (MSI prototype) must be proven working end-to-end
- Phase 2 (signing) must be in place — a generator that produces unsigned MSIs is not
  production-ready
- The open question in the repo README must be answered: does Vantra serve the MSI directly
  from a download link, or does the generator need a different integration point?

## Stack (planned)

- Node.js (Fastify or Express)
- BullMQ + Redis job queue (one build job per deployment request)
- `wixl` (from `msitools`) — called as a child process
- `osslsigncode` — for signing the output MSI on Linux
- Local file storage for temp build artifacts (cleaned up after each job)
