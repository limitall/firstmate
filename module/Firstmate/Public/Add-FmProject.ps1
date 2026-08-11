#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Clone an existing project into this home and register its standing posture.

.DESCRIPTION
The mechanical half of the project-management procedure's "add or clone an
existing project" step. The decisions - which project, which name, which
delivery posture, whether an existing second mate already owns that domain -
belong above this command and are made before it runs. What this owns is doing
the resolved operation without leaving the clone and the registry disagreeing.

WHAT IT REFUSES
  - a destination that already exists: an existing path is never overwritten or
    repurposed.
  - a name already in the registry: two lines for one project would make its
    posture depend on which one a reader hit first.
  - a posture this port cannot deliver (no-mistakes, no-mistakes-prod-only):
    both require the no-mistakes pipeline, which has no established Windows
    support. Registering one would look pipeline-gated while nothing here can
    run the gate.
  - a direct-PR project whose clone has no origin remote: the posture's whole
    delivery path is a push and a PR.

ROLLBACK. When a step after the clone fails, the clone THIS command created is
removed - and only that. A pre-existing directory is never touched, because the
command refuses before cloning if one is there.

.PARAMETER Name
The local project name. Becomes projects/<name> and the registry key.

.PARAMETER Source
Anything `git clone` accepts: a URL, or a path to a local repository.

.PARAMETER Mode
The registered standing posture: direct-PR or local-only on this port.

.PARAMETER Yolo
Routine approval authority for this project. Off unless the captain says so.

.PARAMETER Description
The registry description: enough to identify the project, and nothing more -
the registry is a navigation registry, not project documentation.

.EXAMPLE
Add-FmProject -Name thing -Source https://github.com/acme/thing.git -Mode direct-PR -Description 'the thing service'
#>
function Add-FmProject {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [ValidateSet('on', 'off')][string]$Yolo = 'off',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [string]$ProjectsDir = '',
        [string]$RegistryPath = ''
    )

    $null = Assert-FmProjectName -Name $Name
    $null = Assert-FmDeliveryModeSupported -Mode $Mode -Registry

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }
    if (-not $RegistryPath) { $RegistryPath = Join-Path (Get-FmSessionPaths).Data 'projects.md' }

    $destination = Join-Path $ProjectsDir $Name
    if (Test-Path -LiteralPath $destination) {
        throw "error: $destination already exists; refusing to overwrite or repurpose it"
    }
    $registered = @(Get-FmProjectRegistryEntry -RegistryPath $RegistryPath | Where-Object { $_.Name -eq $Name })
    if ($registered.Count -gt 0) {
        throw "error: project `"$Name`" is already in the registry at $RegistryPath"
    }

    if (-not $PSCmdlet.ShouldProcess($destination, "clone $Source and register it as $Mode")) { return $null }

    if (-not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $ProjectsDir -Force
    }

    $clone = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('clone', '--', $Source, $destination) -TimeoutSeconds 1800
    if (-not $clone.Ok) {
        $detail = ($clone.StdErr, $clone.StdOut | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
        if (Test-Path -LiteralPath $destination) {
            $null = Remove-FmProjectDirectory -Path $destination -Confirm:$false
        }
        throw "error: could not clone $Source into $destination`: $detail"
    }

    try {
        if ($Mode -eq 'direct-PR') {
            if (-not (Invoke-FmGit -Directory $destination -Arguments @('remote', 'get-url', 'origin')).Ok) {
                throw ("error: a direct-PR project must have an origin remote, and the clone at $destination " +
                    'has none; register it local-only, or add the remote first')
            }
        }
        $line = New-FmProjectRegistryLine -Name $Name -Mode $Mode -Yolo $Yolo -Description $Description
        $null = Add-FmProjectRegistryEntry -RegistryPath $RegistryPath -Line $line
    } catch {
        $null = Remove-FmProjectDirectory -Path $destination -Confirm:$false
        throw
    }

    [pscustomobject]@{
        Name          = $Name
        Path          = $destination
        Mode          = $Mode
        Yolo          = $Yolo
        RegistryPath  = $RegistryPath
        RegistryLine  = $line
        Message       = "added: cloned $Source into $destination and registered it [$Mode$(if ($Yolo -eq 'on') { ' +yolo' })]"
    }
}
