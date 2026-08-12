@{
    # PSScriptAnalyzer settings for firstmate's PowerShell tree.
    # Encodes the coding conventions in docs/powershell-port.md. Run through
    # tools/fm-ps-lint.ps1, which layers the conventions PSScriptAnalyzer
    # cannot express (strict-mode preamble, LF/no-BOM, Twin: pairing line) on
    # top of these rules.

    # Warning severity is the bar: "PSScriptAnalyzer clean at warning severity"
    # per docs/powershell-port.md. Information-level noise is not a gate.
    Severity     = @('Error', 'Warning')

    IncludeDefaultRules = $true

    ExcludeRules = @(
        # The port FORBIDS byte-order marks: contract 2 requires state files
        # and script output to be LF, UTF-8, no BOM. This rule wants the
        # opposite for any file containing non-ASCII. tools/fm-ps-lint.ps1
        # enforces the no-BOM rule directly.
        'PSUseBOMForUnicodeEncodedFile'

        # Entrypoint twins are scripts, not modules; they legitimately have no
        # exported-function documentation surface.
        'PSUseToExportFieldsInManifest'
    )

    Rules        = @{
        # No aliases anywhere - a converted file must read the same on a host
        # with different aliases defined.
        PSAvoidUsingCmdletAliases = @{
            Enable = $true
            # No whitelist: docs/powershell-port.md says "no aliases", flat.
            Whitelist = @()
        }

        # stdout must stay byte-controlled so the differential harness can
        # compare it. Write-Host bypasses the stream entirely.
        PSAvoidUsingWriteHost = @{
            Enable = $true
        }

        # Explicit over positional: the twins mirror bash argument order, and a
        # positional slip is invisible in review.
        PSAvoidUsingPositionalParameters = @{
            Enable = $true
        }

        # $global: leaks across the module boundaries the port introduces.
        PSAvoidGlobalVars = @{
            Enable = $true
        }

        # Trailing whitespace changes bytes and shows up in every diff.
        PSAvoidTrailingWhitespace = @{
            Enable = $true
        }

        # Approved verbs keep the *-Fm* naming greppable against the bash twin.
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # A state-changing cmdlet-shaped function without ShouldProcess is a
        # real hazard in a tree that writes durable records.
        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $true
        }
    }
}
