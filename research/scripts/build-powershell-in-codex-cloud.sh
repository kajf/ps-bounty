#!/usr/bin/env bash
# Build PowerShell's core engine in Codex Cloud without hitting known proxy-403 feeds.
#
# Codex Cloud currently exposes HTTP(S)_PROXY=http://proxy:8080. In this environment,
# the proxy can allow NuGet.org and Microsoft bootstrap downloads while returning
# CONNECT 403 for PowerShell Gallery and some Azure Artifacts package blob endpoints.
# The reliable local-research build path is therefore:
#   * use -UseNuGetOrg for core dependencies, and
#   * use -NoPSModuleRestore so the build does not restore PSGallery modules.

set -euo pipefail

repo_root="${1:-upstream/PowerShell}"
repo_url="https://github.com/PowerShell/PowerShell"

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_pwsh() {
  if command -v pwsh >/dev/null 2>&1; then
    return
  fi

  if [[ ! -r /etc/os-release ]]; then
    echo "pwsh is not installed and /etc/os-release is unavailable; install PowerShell first." >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "pwsh is not installed; install PowerShell for ${PRETTY_NAME:-this OS} first." >&2
    exit 1
  fi

  as_root apt-get update -y
  as_root apt-get install -y wget apt-transport-https software-properties-common
  wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
  as_root dpkg -i /tmp/packages-microsoft-prod.deb
  as_root apt-get update -y
  as_root apt-get install -y powershell
}

ensure_pwsh

if [[ ! -d "$repo_root/.git" ]]; then
  mkdir -p "$(dirname "$repo_root")"
  git clone --depth 1 "$repo_url" "$repo_root"
fi

cd "$repo_root"

# A shallow clone may not have an annotated tag reachable from HEAD, but the build
# invokes `git describe --abbrev=60 --long`. Add a local annotated tag when needed.
if ! git describe --abbrev=60 --long >/dev/null 2>&1; then
  next_tag="$(pwsh -NoLogo -NoProfile -Command '(Get-Content ./tools/metadata.json -Raw | ConvertFrom-Json).NextReleaseTag' 2>/dev/null || printf 'v7.7.0-preview.3')"
  git tag -fa "${next_tag}-local" -m "${next_tag}-local" HEAD
fi

# Restore tracked NuGet configs before choosing the public core-build source. This
# avoids inheriting half-generated configs from earlier failed attempts.
git checkout -- nuget.config src/Modules/nuget.config test/tools/Modules/nuget.config 2>/dev/null || true

export PATH="$HOME/.dotnet:$PATH"
pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBootstrap -Scenario Both'

# Generate public NuGet configs, then pre-restore only the projects needed for a
# core engine build. Start-PSBuild's restore helper otherwise includes src/Modules,
# which uses PowerShell Gallery and fails with CONNECT 403 in Codex Cloud.
pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Switch-PSNugetConfig -Source Public'
dotnet restore ./src/powershell-unix --runtime linux-x64 /property:SDKToUse=Microsoft.NET.Sdk --verbosity quiet
dotnet restore ./src/TypeCatalogGen --runtime linux-x64 /property:SDKToUse=Microsoft.NET.Sdk --verbosity quiet
dotnet restore ./src/ResGen --runtime linux-x64 /property:SDKToUse=Microsoft.NET.Sdk --verbosity quiet

# Important: -NoPSModuleRestore avoids the post-build Gallery module copy. This
# produces a usable core pwsh for source audits and local repros, but not a fully
# packaged release layout. Do not add -Clean here; it would remove the pre-restored
# assets and force the build helper back through src/Modules.
pwsh -NoLogo -NoProfile -Command 'Import-Module ./build.psm1; Start-PSBuild -UseNuGetOrg -NoPSModuleRestore'
