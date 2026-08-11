#requires -Version 7.0

<#
.SYNOPSIS
    Install bootstrap tools the captain has explicitly approved in this session.

.DESCRIPTION
    Port of `fm-bootstrap.sh install <tool>...`.

    NEVER INSTALL UNASKED. AGENTS.md section 3 is explicit: bootstrap detects
    first, asks for consent, and installs only after the captain approves in the
    current session. This command therefore refuses to run without -Approved,
    which is how the caller states that consent was actually obtained. A tool
    that has no automated install route is refused with its manual instructions
    rather than guessed at.

.PARAMETER Name
    The tools to install. Only the ones the captain approved.

.PARAMETER Approved
    Assert that the captain approved these installs in the current session.
    Without it nothing is installed and the detected install plan is printed
    instead, so the caller can present it and ask.

.PARAMETER WhatIf
    Print the resolved install commands without running them.

.EXAMPLE
    Install-FmTool -Name gh-axi -Approved
#>
function Install-FmTool {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Name,
        [switch]$Approved
    )

    begin { $tools = @() }
    process { $tools += $Name }
    end {
        $plan = @()
        foreach ($tool in $tools) {
            $cmd = Get-FmBootstrapInstallCommand -Tool $tool
            if (-not $cmd) {
                $instructions = Get-FmBootstrapManualInstallUrl -Tool $tool
                if ($instructions) {
                    throw "error: $tool requires manual installation (instructions: $instructions)"
                }
                throw "error: unknown tool $tool"
            }
            # The trailing "  # or ..." hint is advice for a human, not part of
            # the command to run.
            $plan += [pscustomobject]@{ Tool = $tool; Command = ($cmd -replace '\s\s#.*$', '') }
        }

        if (-not $Approved) {
            Write-Output 'refused: Install-FmTool needs -Approved. Bootstrap detects, then asks for consent, then installs - never installs unasked.'
            foreach ($item in $plan) { Write-Output "would install $($item.Tool): $($item.Command)" }
            return
        }

        foreach ($item in $plan) {
            if (-not $PSCmdlet.ShouldProcess($item.Tool, "run: $($item.Command)")) { continue }
            Write-Output "installing $($item.Tool): $($item.Command)"
            # The install strings are captain-facing shell one-liners (pipelines,
            # && chains). They are executed through the platform's own shell so a
            # published install line runs exactly as documented.
            if ($IsWindows) {
                & (Get-Process -Id $PID).Path -NoProfile -Command $item.Command
            } else {
                & '/bin/sh' '-c' $item.Command
            }
            if ($LASTEXITCODE -ne 0) { throw "error: installing $($item.Tool) failed with exit code $LASTEXITCODE" }
        }
    }
}
