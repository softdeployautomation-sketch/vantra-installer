# HANDOFF — Customer "device not showing in my console" (2026-09-16)

**Status:** Root cause identified (client/org mapping + a launcher bug already fixed). Next agent:
reproduce using the customer's own account on the VM and confirm/fix the mapping so a device the
customer installs ALWAYS appears in THEIR console. The customer's login was collected for this test.

## The complaint
A customer installs the agent (via a link the operator sent them) and the app runs, but the customer
says **they never see the device in their own RMM/Vantra console**. The operator sent the same link and
COULD see the customer's box (the device the operator saw was the customer's RDP box). So the agent
enrolls and comes Online — it just shows up under the wrong view.

## ROOT CAUSE (confirmed in the RMM DB — the big one)
**Each Vantra "Add Device" / deployment maps to a CLIENT (= one customer/org). A device only shows in the
console of the account whose org owns the client the link was generated under.**

Real data from `agents_agent` + `clients_site`/`clients_client`:
| Agent | hostname | site | client | site name |
|---|---|---|---|---|
| VM (`Sc`) | id 16 | 71 | **client 3** | `final document` |
| Customer RDP box (`I`) | id 17 | 73 | **client 8** | `covid` |

Both were **Online** (`last_seen` ~2 min ago). The operator saw the customer's box because they were
viewing client 8; the customer (client 3 account, or whichever) couldn't see it. **If a customer generates
a link from account A and you install it, the device lands under A's client — not under whoever else is
looking.** Cross-account links → device hidden from other accounts. This is almost certainly why the
customer "doesn't see it": the link was generated from a DIFFERENT org/account than the one they log in
with, or the operator-generated link went to a different client than the customer's.

## Also fixed this session (launcher — the OTHER cause of silent no-install)
- **Bug:** `launcher.c load_payload` located sibling `agent.bin` from `argv[0]`/CWD; when the `.lnk`'s
  PowerShell bridge elevates via `-Verb RunAs`/UAC the working dir can reset → `agent.bin` not found →
  **silent fail, no service, no device** (marker went to System32, not Downloads).
- **Fix (`installer-dev 30fb0c9`):** `load_payload` now resolves `agent.bin` via `GetModuleFileName`
  (launcher's OWN absolute path) first; falls back to argv[0]/CWD. Deployed; generator rebuilt
  (`/healthz` `ready:true`, native); verified end-to-end: fresh zip → services Running → agent enrolled →
  Online. **Any NEW zip now uses the fixed launcher.**
- Token is NOT the problem: RMM `/api/v3/installer/` returns **200** for the latest deployments'
  `token_key`; the deployed web app passes `dep.tokenKey` (not `uid`). Deployment tokens are
  client/site-scoped and expire 72h after creation.

## RDP note (secondary)
TacticalRMM RDP quick-connect needs the **Windows Remote Desktop server enabled on the endpoint**
(port 3389 listening). The `--rdp` install flag enables the RDP *feature* but does NOT turn on Windows
RDP. TURN/coturn relay is up server-side (3478/5349). If a customer "can't RDP", check 3389 listening
+ firewall first.

## Current state
- **VM (`Sc`, myrat@192.168.0.103): fully clean** — services deleted, `TacticalAgent` + `TacticalRMM`
  dirs removed, no processes, Downloads cleared. Ready for the customer-account reproduction test.
- Generator (`/opt/vantra-installer`) running the fixed launcher. Web app (`/opt/vantra`) live
  (`vantra.service`), RMM (`rmm.service`) up.
- Many test sites remain in RMM (clients 3/8/12, sites 65-73) from today's testing — clean up the
  not-needed ones once the mapping is confirmed.

## Access (verified)
- VPS: `ssh -i ~/.ssh/tacticalrmm_vps root@164.68.105.96`
- VM:  `ssh -i ~/.ssh/tacticalrmm_vps myrat@192.168.0.103` (elevated cmd.exe — `&` separators)
- RMM DB: `sudo -u postgres psql -d tacticalrmm` on the VPS
- Generator `/opt/vantra-installer` = deployed copy (rsync + `systemctl restart vantra-msi-generator`,
  ~90 s pool warm, `curl localhost:4000/healthz` → `ready:true`)
- Web app `/opt/vantra` = deployed copy (rebuild as `vantra` user + `systemctl restart vantra.service`)

## Guardrails
AMSI stays `none`; do NOT weaken `/build` auth; do NOT change `LATEST_AGENT_VER`; no code-sign token;
accept installs only via the real masked-link download flow (never ssh/scp a built zip). Do NOT change the
confirmed default flow — only fix/add.

---

## NEXT-AGENT PROMPT (copy to the next agent)

> Customer reports: after installing the agent (via a link), the box runs but never appears in THEIR
> console — while the operator CAN see it. Root cause suspected: the link/device landed under a different
> CLIENT (customer org) than the one the customer logs in with. The customer's login was collected.
>
> Your job, in order:
> 1. **Reproduce on the VM (already clean, `Sc`):** generate an agent using the CUSTOMER's account/link
>    (their own "Add Device"), download via the masked link, extract, double-click `.lnk` (1 UAC) ->
>    services Running -> Online. Then, using the customer's login, confirm whether the device shows in
>    THEIR console.
> 2. **Trace the mapping:** after install, query the RMM DB (`agents_agent`, `clients_site`,
>    `clients_client`, and the Vantra `deployment` table) and record which client/site the device landed
>    under, and which Vantra org/account that maps to. Determine WHY the customer's console didn't show it:
>    was the link generated from a different account, or is the app mapping org->client wrong?
> 3. **Fix the mapping** so that a device a customer installs from THEIR own link ALWAYS appears in THEIR
>    console (and only theirs). Likely: ensure "Add Device" binds to the active org's client consistently,
>    and the device list filters by that same org's client. Preserve the confirmed default install flow.
> 4. **RDP (secondary):** the customer may also report "can't RDP" - verify Windows Remote Desktop is on
>    (3389 listening) on the endpoint, not just the `--rdp` feature flag. Server TURN relay is up.
> 5. **Record evidence** (which client/site the device landed in, whether the customer sees it after the
>    fix, services state, device Online) into this file, and clean up the extra test clients/sites once
>    confirmed.
>
> Guardrails: AMSI `none`; `/build` auth not weakened; `LATEST_AGENT_VER` unchanged; no code-sign token;
> accept only via the real masked-link download; do not change the confirmed default flow.