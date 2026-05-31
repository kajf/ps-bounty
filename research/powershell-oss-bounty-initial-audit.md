# PowerShell OSS Bounty Initial Audit Notes

Date: 2026-05-31

## Scope and rules read

- Primary program: Microsoft Open Source Bounty Program, <https://www.microsoft.com/en-us/msrc/opensourcebountyprogram>.
- Primary target: `PowerShell/PowerShell`, cloned locally at `upstream/PowerShell`.
- PowerShell security policy: `upstream/PowerShell/.github/SECURITY.md` requires private MSRC reporting rather than public GitHub issues for suspected vulnerabilities.
- Program triage constraints applied during this pass:
  - PowerShell is listed as in scope.
  - Qualifying reports must be reproducible on the most recent actively maintained branch and have Critical or Important severity.
  - Local-machine-only issues are generally out of scope for this OSS bounty program unless they demonstrate a qualifying impact on a Microsoft service or supply chain.
  - No live Microsoft services were scanned, attacked, or tested.

## Setup notes and commands used

```bash
git clone --depth 1 https://github.com/PowerShell/PowerShell upstream/PowerShell
cd upstream/PowerShell
git rev-parse HEAD
./tools/install-powershell.sh
apt-get update -y
apt-get install -y wget apt-transport-https software-properties-common
wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
apt-get update -y
apt-get install -y powershell
pwsh -NoLogo -NoProfile -Command '$PSVersionTable | Out-String'
pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBootstrap -Scenario Both'
git fetch --tags --depth=1 origin '+refs/tags/*:refs/tags/*'
git tag -a v7.7.0-preview.3-local -m v7.7.0-preview.3-local HEAD
PATH=$HOME/.dotnet:$PATH pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBuild -UseNuGetOrg -NoPSModuleRestore'
```

Environment:

- Container OS: Ubuntu 24.04.4 LTS.
- Installed bootstrap PowerShell: 7.6.2 from Microsoft packages.
- Audited repo commit: `9d87b4346f9faea5ae069edc536578200ac66289`.
- Built local PowerShell: `upstream/PowerShell/src/powershell-unix/bin/Debug/net11.0/linux-x64/publish/pwsh`.

Setup limitations:

- `./tools/install-powershell.sh` failed because its Debian helper rejected Ubuntu 24.04 as unsupported, so PowerShell was installed from Microsoft's Ubuntu 24.04 package feed instead.
- `Start-PSBuild -UseNuGetOrg` initially failed after restoring core projects because the environment proxy returned HTTP 403 for PowerShell Gallery package lookup under `src/Modules/PSGalleryModules.csproj`.
- `Start-PSBuild -UseNuGetOrg -NoPSModuleRestore` built the engine successfully after adding a local annotated tag. The tag was needed because `PowerShell.Common.props` invokes `git describe --abbrev=60 --long`, which fails in a shallow clone when no describing tag reaches `HEAD`.
- `Start-PSPester` could not run the selected Pester file in this environment because publishing test helper modules also attempted to reach PowerShell Gallery and the built output did not contain a restored Pester module.

## Test/check results from this pass

```bash
# PASS: core engine build, with PSGallery modules intentionally skipped due proxy limits.
PATH=$HOME/.dotnet:$PATH pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBuild -UseNuGetOrg -NoPSModuleRestore'

# WARNING: full/default build blocked by proxy 403 to powershellgallery.com for PSGalleryModules.csproj.
PATH=$HOME/.dotnet:$PATH pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBuild -UseNuGetOrg'

# WARNING: focused Pester run blocked by proxy/Pester restore limitations.
PATH=$HOME/.dotnet:$PATH pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSPester -Path test/powershell/Modules/Microsoft.PowerShell.Core/Import-Module.Tests.ps1 -BinDir ./src/powershell-unix/bin/Debug/net11.0/linux-x64/publish -UseNuGetOrg -PassThru'

# PASS: local module path precedence fixture demonstrates expected behavior, not a vulnerability.
./upstream/PowerShell/src/powershell-unix/bin/Debug/net11.0/linux-x64/publish/pwsh -NoLogo -NoProfile -File research/repros/module-path-shadowing.ps1

# PASS: local New-TemporaryFile fixture confirmed mode 600 on Ubuntu.
./upstream/PowerShell/src/powershell-unix/bin/Debug/net11.0/linux-x64/publish/pwsh -NoLogo -NoProfile -File research/repros/new-temporary-file-permissions.ps1
```

## Attack-surface map

| Area | Trust boundary | Key source paths reviewed | Initial assessment |
| --- | --- | --- | --- |
| Module path construction | Environment/config to module discovery and implicit execution | `src/System.Management.Automation/engine/Modules/ModuleIntrinsics.cs` | Security-sensitive because earlier `PSModulePath` entries can shadow later ones. Current behavior appears intentional/user-controlled. |
| Module enumeration | Filesystem content to command discovery/autoload | `src/System.Management.Automation/engine/Modules/ModuleUtils.cs` | Recurses module roots, skips hidden/offline/recall-on-open files, handles inaccessible dirs. No validated traversal or unexpected execution found in first pass. |
| Import-Module workflows | Module manifests/scripts/binaries to runspace state | `src/System.Management.Automation/engine/Modules/ImportModuleCommand.cs`, `ModuleCmdletBase.cs` | High value area. First pass focused on path search and remoting proxy creation only. |
| Implicit remoting proxy generation | Remote session metadata to local temp module files | `src/System.Management.Automation/engine/Modules/RemoteDiscoveryHelper.cs`, `ImportModuleCommand.cs` | Temp path includes sanitized remote module/computer plus local runspace GUID. Interesting for temp/path collision review, but not validated as exploitable. |
| Temporary files | Shared temp directory to file creation/use | `src/Microsoft.PowerShell.Commands.Utility/commands/utility/NewTemporaryFileCommand.cs`, `PathUtils.CreateTemporaryDirectory` call sites | `New-TemporaryFile` uses `Path.GetTempFileName`; local Unix fixture produced mode `600`. No issue validated. |
| Archive extraction | ZIP entry names to filesystem writes | `Microsoft.PowerShell.Archive` is pulled as a gallery module, not implemented in this repo's core source tree | Needs a separate audit of `PowerShell/Microsoft.PowerShell.Archive`; not completed in this repo pass. |
| GitHub Actions/release supply chain | GitHub events/artifacts/secrets to build/release workflows | `.github/workflows/*`, `.github/actions/*`, `tools/ci.psm1`, `tools/packaging/packaging.psm1` | Only coarse search completed. Some artifact `Expand-Archive` usage exists in CI actions; no untrusted-artifact write primitive validated. |

## Ranked audited code paths

1. `ModuleIntrinsics.GetModulePath(bool includeSystemModulePath, ExecutionContext context)` and `ProcessOneModulePath(...)`.
   - Reason: converts `PSModulePath` into canonical filesystem paths and suppresses invalid/missing providers.
   - Notes: Uses provider resolution with wildcard escaping, de-duplicates resolved paths case-insensitively, and skips missing/invalid paths. Search-order shadowing remains expected behavior if a user or process places an attacker-controlled directory first.
2. `ModuleUtils.GetDefaultAvailableModuleFiles(...)`.
   - Reason: recursively discovers module files used for list-available and autoload paths.
   - Notes: Uses `EnumerationOptions` with attributes to skip hidden/offline cloud placeholder files and catches inaccessible directories. No traversal across module root observed from the reviewed code.
3. `ImportModuleCommand` remote proxy import blocks around `Export-PSSession`, local proxy manifest rename, and CIM proxy file materialization.
   - Reason: remote metadata is written to local filesystem and then imported.
   - Notes: CIM-generated filenames use `Path.GetFileName`, truncation, random suffixes, and `Path.Combine`; raw file content is remote-provided by design. The temp directory naming model deserves deeper review, but no reproducible exploit was found.
4. `RemoteDiscoveryHelper.GetModulePath(...)`.
   - Reason: creates implicit-remoting temporary module path under `Path.GetTempPath()`.
   - Notes: Sanitizes remote module and computer names and includes `localRunspace.InstanceId`; collision/race seems hard without local same-user access and was not elevated beyond local-machine-only impact.
5. `NewTemporaryFileCommand.ProcessRecord()`.
   - Reason: shared temp directory file creation primitive.
   - Notes: On Ubuntu, `New-TemporaryFile` created files with Unix mode `600`; no world-readable secret leak found.

## Dead ends and ruled-out ideas

- **PSModulePath shadowing**: Reproduced that earlier entries win during implicit autoload. This is expected module search-order behavior and requires attacker influence over the victim process environment or a writable earlier path. Classified as local/user-configuration dependent and not a bounty-quality issue.
- **New-TemporaryFile disclosure**: Checked local Unix permissions. The file was owner-only (`600`), so no default cross-user disclosure was observed.
- **Full build/test inability**: Gallery access was blocked by the environment proxy for `powershellgallery.com`, affecting PSGallery module restore and Pester setup. This is an environment limitation, not a PowerShell vulnerability.
- **Archive extraction in core repo**: `Expand-Archive` implementation is not in the core `PowerShell/PowerShell` source tree reviewed here; it is packaged from `Microsoft.PowerShell.Archive`. This should be audited in a separate clone if archive behavior remains a priority.
- **Implicit-remoting temp path collision**: The path construction is notable but includes the per-runspace GUID. No credible non-local or privilege-crossing exploit was validated in this pass.

## Minimal repro fixtures

- `research/repros/module-path-shadowing.ps1`: creates two same-named modules in separate module roots and demonstrates expected precedence of the first `PSModulePath` entry.
- `research/repros/new-temporary-file-permissions.ps1`: checks local temporary file permissions created by `New-TemporaryFile`.
- `research/repros/remoting-proxy-temp-path-shape.ps1`: records the static remoting temp-path observation and dead-end triage.

## Current finding status

No validated, reproducible, in-scope vulnerability was found in this initial setup/orientation/first-pass audit. No MSRC report should be submitted from these notes alone.

## Recommended next steps

1. Clone and audit `PowerShell/Microsoft.PowerShell.Archive` separately for ZIP Slip/path traversal, symlink, overwrite, ADS, and permission-preservation behavior.
2. Continue deep review of `ImportModuleCommand` and `ModuleCmdletBase` for manifest fields that cross language-mode or policy boundaries.
3. Exercise constrained language mode test suites locally once Pester dependencies are available without PowerShell Gallery proxy failures.
4. Review GitHub Actions artifact download/extraction paths with event trigger trust levels, especially any PR-controlled artifact names or paths.
5. Re-run focused Pester suites in a network environment that can restore PowerShell Gallery dependencies, or vendor the exact test dependencies in a local cache.
