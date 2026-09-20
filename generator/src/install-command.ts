/**
 * Server-side rebuild of the PowerShell install command (STAGE 1 / ZIP).
 *
 * Defense-in-depth: the generator NEVER blindly trusts the client-provided
 * `installCommand` string. It reconstructs the enrollment command from the
 * already-resolved per-device values (apiUrl / clientId / siteId / agentType /
 * authToken / features) that come from the Vantra web app. The shape mirrors
 * the web app's `toPowerShellInstallCommand` (vanta/lib/trmm.ts lines 139-150)
 * so both sides agree; see buildEnrollmentCommand below for what actually gets
 * embedded into the .lnk.
 */

export type AgentType = "workstation" | "server";

export interface InstallCommandInputs {
  apiUrl: string;
  clientId: number;
  siteId: number;
  agentType: AgentType;
  authToken: string;
  features?: string[];
}

// Where the tactical agent is always installed by the /VERYSILENT base exe.
const TACTICAL_EXE = "C:\\Program Files\\TacticalAgent\\tacticalrmm.exe";

const DEFAULT_FEATURES = ["rdp", "ping", "power"];

/**
 * buildEnrollmentCommand: the registration step only —
 *   & "C:\Program Files\TacticalAgent\tacticalrmm.exe" -m install
 *       --api <apiUrl> --client-id <c> --site-id <s>
 *       --agent-type <t> --auth <token> --rdp --ping --power --silent
 *
 * --silent (FIX 4): suppresses all TacticalRMM agent install GUI elements —
 * confirmation dialogs, error popups and the final success/broker
 * notification — when the agent installs + enrolls. The agent must run with
 * administrative privileges (it does: the launcher runs elevated via UAC, and
 * the legacy .lnk path launches the OS PowerShell bridge with -Verb RunAs).
 *
 * The .lnk's own embedded downloader (New-AgentShortcut.ps1 `$logic`) already
 * fetches the base exe and silently installs it, so only THIS enrollment line
 * is embedded as the -InstallCmd. This is the value that gets obfuscated into
 * the artifact (auth token is never shipped as plaintext).
 */
export function buildEnrollmentCommand(inputs: InstallCommandInputs): string {
  const features =
    inputs.features && inputs.features.length > 0
      ? inputs.features
      : DEFAULT_FEATURES;
  return [
    `& "${TACTICAL_EXE}" -m install`,
    `--api "${inputs.apiUrl}"`,
    `--client-id ${inputs.clientId}`,
    `--site-id ${inputs.siteId}`,
    `--agent-type ${inputs.agentType}`,
    `--auth ${inputs.authToken}`,
    ...features.map((f) => `--${f}`),
    `--silent`,
  ].join(" ");
}

/**
 * toPowerShellInstallCommand: the FULL command shape (download → silent install
 * → sleep → enroll), exactly mirroring the web app's trmm.ts helper. Used for
 * validation/reference only — the generator embeds buildEnrollmentCommand()
 * because the downloader already performs the download + base install.
 */
export function toPowerShellInstallCommand(
  inputs: InstallCommandInputs,
  downloadUrl: string
): string {
  const exeName = downloadUrl.split("/").pop() || "tacticalagent.exe";
  const enroll = buildEnrollmentCommand(inputs);
  return [
    `$exe = "$env:TEMP\\${exeName}"`,
    `Invoke-WebRequest -Uri "${downloadUrl}" -OutFile $exe`,
    `Start-Process -FilePath $exe -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES" -Wait`,
    `Start-Sleep -Seconds 7`,
    enroll,
  ].join("\n");
}
