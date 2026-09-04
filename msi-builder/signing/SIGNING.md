# Code Signing — Read Before Phase 2

## Why this matters

An unsigned MSI will trigger Windows SmartScreen ("Windows protected your PC") even if
the installer itself is perfectly clean. For an RMM agent — a category that antivirus
tools watch closely — an unsigned file is the single biggest reason for AV flags.

Signing proves:
- The file came from your organization (not a random stranger on the internet)
- It hasn't been modified since it was signed

## What you need

A **code-signing certificate** issued to your organization. You buy this from a Certificate
Authority. Common options: DigiCert, Sectigo, SSL.com.

Two types:

| Type | SmartScreen behavior | Notes |
|---|---|---|
| Standard OV (Organization Validation) | May still show a warning until the file builds up download reputation | Cheaper, works fine |
| EV (Extended Validation) | Instant SmartScreen trust, no warning | More expensive, certificate lives on a physical USB hardware token |

For an RMM agent distributed to business customers, EV is worth the cost — "Windows
protected your PC" appearing during a client onboarding is a bad look.

## What I need from you when Phase 2 starts

1. The certificate file (`.pfx`) or the USB hardware token, plus the certificate password.
2. The exact legal organization name on the certificate — the installer's `Manufacturer`
   field must match this exactly.

**Do not put the certificate password or any credential in this file or anywhere in this
repo.** When the signing step comes, I will give you the exact `osslsigncode` command to
run on your own machine.

## Background: why the current TacticalRMM EXE gets flagged

The `tacticalagent.exe` you download from TacticalRMM's service is signed with Amidaware's
community certificate — not your organization's. AV vendors flag generic/shared RMM
signing certificates because attackers frequently abuse RMM tools. Wrapping it in your
own properly-signed MSI (even though the inner EXE is the same) gives Windows and AV tools
a trusted outer layer tied to your identity, which significantly reduces false positives.
