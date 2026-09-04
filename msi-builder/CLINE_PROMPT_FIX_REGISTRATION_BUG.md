# Cline — Fix a real bug: the MSI installs the agent but never registers it with TRMM

Paste this entire file as your first message to Cline.

---

## What happened

A real MSI built from this Phase-1 prototype was downloaded and run on a real Windows machine. The TacticalRMM agent installed successfully (files on disk, service running), but the device never appeared in the customer's device list — meaning Step 4 (registration) silently failed to actually register the agent with TRMM.

## Root cause (confirmed by reading the actual template + build script, not guessed)

`msi-builder/src/orchestrator.ps1.template`'s registration call:

```powershell
$regProcess = Start-Process -FilePath $tacticalRmmPath `
    -ArgumentList @(
        "-m", "install",
        "--api",       {{API_URL}},
        "--client-id", {{CLIENT_ID}},
        "--site-id",   {{SITE_ID}},
        "--agent-type","{{AGENT_TYPE}}",
        "--auth",      {{AUTH_TOKEN}}
    ) `
```

Notice `"{{AGENT_TYPE}}"` is quoted, but `{{API_URL}}`, `{{CLIENT_ID}}`, `{{SITE_ID}}`, and `{{AUTH_TOKEN}}` are **not**. `msi-builder/build/build.sh`'s substitution step is a plain `sed` text replace with no added quoting:

```sh
sed -e "s|{{CLIENT_ID}}|$CLIENT_ID|g" \
    -e "s|{{SITE_ID}}|$SITE_ID|g" \
    -e "s|{{AGENT_TYPE}}|$AGENT_TYPE|g" \
    -e "s|{{AUTH_TOKEN}}|$AUTH_TOKEN|g" \
    -e "s|{{API_URL}}|$API_URL|g" \
```

So after substitution, the generated PowerShell array literal looks like:

```powershell
"--api",       https://api.instaweb.top,
```

`https://api.instaweb.top` is not a valid unquoted PowerShell array element (the `:` and `//` have no valid meaning there) — this throws a **parse error**, not a runtime error. Since a parse error happens before any code in the file executes, the `try { ... } catch { exit 1 }` wrapper around the rest of the script never even runs — the whole orchestrator script fails to load. `CLIENT_ID`/`SITE_ID` (small integers) and `AUTH_TOKEN` (likely alphanumeric) might accidentally happen to parse as bare tokens in some cases, but `API_URL` never will — this is the piece that's guaranteed to break every single real MSI run.

## The fix

Add quotes around every placeholder in the `-ArgumentList` array, matching the one that's already correct (`{{AGENT_TYPE}}`):

```powershell
$regProcess = Start-Process -FilePath $tacticalRmmPath `
    -ArgumentList @(
        "-m", "install",
        "--api",       "{{API_URL}}",
        "--client-id", "{{CLIENT_ID}}",
        "--site-id",   "{{SITE_ID}}",
        "--agent-type","{{AGENT_TYPE}}",
        "--auth",      "{{AUTH_TOKEN}}"
    ) `
```

Do a full pass over **every** `.template` file in this repo (`Product.wxs.template`, `installer.vbs.template`, and anything under `generator/`) for the same class of bug — any other place a `{{PLACEHOLDER}}` is substituted via plain text replace into a context where the surrounding language needs quotes (PowerShell, VBScript, WiX XML attributes, etc.) should be checked the same way. Don't assume this is the only occurrence just because it's the only one found so far.

## Verification (don't consider this fixed without doing this)

1. Rebuild the MSI via `build.sh` with a **real** `--api-url` value (not a placeholder) and confirm the generated `orchestrator.ps1` (check the built MSI's extracted contents, or add a debug step that dumps the filled-in script before packaging) has properly quoted values.
2. Run `powershell -NoProfile -File orchestrator.ps1` (with test values) with `-WhatIf`-style dry checking, or at minimum use PowerShell's own parser to validate syntax: `[System.Management.Automation.PSParser]::Tokenize((Get-Content orchestrator.ps1 -Raw), [ref]$null)` should produce no parse errors.
3. Ideally, run the actual built MSI on a real Windows test machine end-to-end and confirm the device actually appears in the TRMM/Vantra device list afterward — this is the only way to be certain the fix actually closes the loop, since the bug was only caught because a real device didn't show up.
4. Report back explicitly whether you found and fixed any other unquoted-placeholder occurrences elsewhere in the repo, per the "full pass" instruction above — don't stay silent about it either way.
