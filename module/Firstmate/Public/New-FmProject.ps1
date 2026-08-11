#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Create a new LOCAL project repository in this home and register it.

.DESCRIPTION
The mechanical half of the project-management procedure's "create a project"
step, for the half of it that is local.

WHY THIS COMMAND NEVER CREATES A GITHUB REPOSITORY. Creating a remote
repository is outward-facing: it needs the captain's explicit consent for the
exact name, owner, visibility, and posture, and a stated default never replaces
that consent. That consent is obtained above this command, and the repository
is then created with gh-axi and brought in with Add-FmProject. So this command
creates a local repository, registers it, and makes no network call - and it
refuses a posture that would require a remote it is not allowed to create.

The captain's request to create a local project authorizes this local
initialization; it does not authorize an unmentioned remote repository.

.PARAMETER Name
The local project name. Becomes projects/<name> and the registry key.

.PARAMETER Mode
The registered standing posture. local-only is the only posture that can be
satisfied without a remote, and is therefore the only one this command creates
under.

.PARAMETER Yolo
Routine approval authority for this project. Off unless the captain says so.

.PARAMETER Description
The registry description: enough to identify the project, nothing more.

.PARAMETER DefaultBranch
The initial branch name. Defaults to main.

.EXAMPLE
New-FmProject -Name notes -Description 'captain-private notes and scratch tooling'
#>
function New-FmProject {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Mode = 'local-only',
        [ValidateSet('on', 'off')][string]$Yolo = 'off',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [string]$DefaultBranch = 'main',
        [string]$ProjectsDir = '',
        [string]$RegistryPath = ''
    )

    $null = Assert-FmProjectName -Name $Name
    $null = Assert-FmDeliveryModeSupported -Mode $Mode -Registry
    if ($Mode -ne 'local-only') {
        throw ("error: this command only creates local-only projects. A $Mode project needs a remote, and " +
            'creating one is outward-facing: get the captain''s explicit consent for the repository name, ' +
            'owner, and visibility, create it with gh-axi, then bring it in with Add-FmProject.')
    }

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

    if (-not $PSCmdlet.ShouldProcess($destination, "create a local git repository and register it as $Mode")) { return $null }

    $null = New-Item -ItemType Directory -Path $destination -Force
    try {
        $init = Invoke-FmChildProcess -FilePath 'git' `
            -ArgumentList @('init', '--initial-branch', $DefaultBranch, '--', $destination) -TimeoutSeconds 120
        if (-not $init.Ok) {
            $detail = ($init.StdErr, $init.StdOut | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
            throw "error: could not create a git repository at $destination`: $detail"
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
        DefaultBranch = $DefaultBranch
        RegistryPath  = $RegistryPath
        RegistryLine  = $line
        Message       = "created: local git repository at $destination, registered [$Mode$(if ($Yolo -eq 'on') { ' +yolo' })]"
    }
}
