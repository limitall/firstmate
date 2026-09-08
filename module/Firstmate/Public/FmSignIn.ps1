#requires -Version 7.0
# FmSignIn.ps1 - is this machine signed in to the account firstmate answers
# through, asked BEFORE the screen opens rather than discovered inside it.
#
# WHAT THIS FIXES, MEASURED 2026-09-08. The captain reached the screen, typed
# "hello", and got back
#
#     Not logged in - Please run /login
#
# in a chat box, which is the one surface where `/login` cannot be typed. Every
# layer above had already said the machine was fine: start.ps1 found `claude` on
# PATH and said nothing, fm-bridge.ps1 printed "session up", and /api/health
# reported `engine: true`. All three were reading the wrong thing. `claude` was
# PRESENT and NOT SIGNED IN, and nothing between the captain's terminal and the
# chat box asked the difference.
#
# WHY PRESENCE IS NOT THE SAME QUESTION. New-FmBridgeSession returns $null only
# when `claude` is missing entirely, and the bridge then serves read-only and
# says so honestly. A signed-out CLI starts, holds the pipe, answers the first
# turn with its own refusal string, and exits 1 - so the session LOOKS up. That
# is why the failure reaches the captain as an answer rather than as a status.
#
# WHY THE CLI IS ASKED, RATHER THAN ITS CREDENTIAL FILE READ. `claude auth
# status` is the CLI's own answer to this question, and it covers every route it
# supports - a claude.ai subscription, ANTHROPIC_API_KEY, an apiKeyHelper,
# Bedrock, Vertex - in one reading. Parsing ~/.claude/.credentials.json here
# would be a second copy of that matrix, and the first one to go stale: a
# machine authenticated by any route this file had not learned would be told it
# was signed out and refused a start that would have worked. The one-owner rule
# applies to somebody else's contract too.
#
# AND IT COSTS NO NETWORK. Measured on this seat, three runs signed in and one
# signed out: 589-683ms every time, dominated by Node's own startup. Behind an
# unroutable proxy (HTTPS_PROXY=http://10.255.255.1:9) it answered in 653ms with
# the same result, which is the proof that it reads local state and does not
# call the auth service. A start therefore gains no round trip, and a machine
# with no network gains no wait. The bounded wait below is belt and braces on
# top of that, not the thing that makes it safe.
#
# THE BIAS IS TOWARDS STARTING. Only a definite "signed out" stops a start.
# A check that cannot reach a verdict - no CLI, a timeout, output this cannot
# parse - reports Known=$false and the caller proceeds in silence, because a
# readiness check that invents its own way to be unable to start is worse than
# the defect it was added for.

Set-StrictMode -Version Latest

function ConvertFrom-FmSignInStatus {
    <#
        .SYNOPSIS
        Read `claude auth status` output into a verdict.

        .DESCRIPTION
        Split from Get-FmSignInStatus so the reading is testable without a CLI
        on PATH and without a process: every shape below is a real thing the
        command has been observed to produce, and the parse is the part that
        decides whether a captain is stopped.

        THREE OUTCOMES, NOT TWO. Signed in, signed out, and cannot tell. The
        third is the one that matters: it is what an unparseable answer, an
        empty answer or a future output format produces, and it must never be
        confused with a signed-out machine, because only signed-out stops a
        start.

        .PARAMETER Output
        Everything the command printed, stdout and stderr together.

        .PARAMETER ExitCode
        What it exited with. 0 signed in, 1 signed out, as observed. It is a
        corroboration and not the verdict: the JSON body is authoritative,
        because the exit code alone cannot distinguish "signed out" from
        "this command does not exist here".

        .EXAMPLE
        (ConvertFrom-FmSignInStatus -Output '{"loggedIn":true}' -ExitCode 0).SignedIn
        True
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Output,
        [int]$ExitCode = 0
    )

    $unknown = [pscustomobject]@{
        SignedIn = $false
        Known    = $false
        Method   = ''
        Account  = ''
        Detail   = 'could not read the sign-in state'
    }

    if ([string]::IsNullOrWhiteSpace($Output)) { return $unknown }

    # The JSON body, not the whole stream. A CLI is free to print a notice or a
    # deprecation line beside its structured answer, and a version nudge landing
    # on stdout must not turn a signed-in machine into an unreadable one.
    $start = $Output.IndexOf('{')
    $end = $Output.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $unknown }

    $parsed = $null
    try { $parsed = $Output.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $unknown }
    if ($null -eq $parsed) { return $unknown }

    $names = @($parsed.PSObject.Properties.Name)
    # Absent `loggedIn` is not a signed-out machine - it is a body this does not
    # recognise. Saying so is the whole point of the third outcome.
    if ($names -notcontains 'loggedIn') { return $unknown }

    $signedIn = [bool]$parsed.loggedIn
    $method = if ($names -contains 'authMethod') { [string]$parsed.authMethod } else { '' }
    $account = if ($names -contains 'email') { [string]$parsed.email } else { '' }

    # Corroboration, deliberately one-directional. `loggedIn: true` beside a
    # non-zero exit is a disagreement this cannot resolve, so it declines to
    # rule rather than starting a session on the optimistic half of it.
    if ($signedIn -and $ExitCode -ne 0) { return $unknown }

    [pscustomobject]@{
        SignedIn = $signedIn
        Known    = $true
        Method   = $method
        Account  = $account
        Detail   = ''
    }
}

function Get-FmSignInStatus {
    <#
        .SYNOPSIS
        Ask the Claude CLI whether this machine is signed in. Local, and bounded.

        .DESCRIPTION
        Runs `claude auth status` and reads the answer with
        ConvertFrom-FmSignInStatus. Returns Known=$false rather than throwing
        for every way this can fail to produce a verdict, because the caller's
        job is to start firstmate and not to diagnose a CLI.

        THE WAIT IS BOUNDED AND THE CHILD IS KILLED. The command reads local
        state and has never been measured above 683ms, so the bound is not the
        expected path - it is the guarantee that a machine where it hangs gets a
        start rather than a frozen terminal. A timed-out child is killed instead
        of left running, so nothing outlives the check.

        .PARAMETER TimeoutSeconds
        How long to wait before giving up and reporting "cannot tell". The
        default is generous against a ~0.6s reading because the cost of being
        wrong is asymmetric: a slow answer that arrives is worth waiting for,
        and a captain is never made to wait on a verdict that would not stop
        them anyway.

        .PARAMETER CommandName
        The CLI to ask. A parameter so the tests can put a stub in its place;
        callers have no reason to pass it.

        .EXAMPLE
        (Get-FmSignInStatus).SignedIn
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20,
        [string]$CommandName = 'claude'
    )

    $cli = Get-Command -Name $CommandName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cli) {
        return [pscustomobject]@{
            SignedIn = $false
            Known    = $false
            Method   = ''
            Account  = ''
            Detail   = "no $CommandName on PATH"
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cli.Source
    $psi.ArgumentList.Add('auth')
    $psi.ArgumentList.Add('status')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) {
            return (ConvertFrom-FmSignInStatus -Output '' -ExitCode 0)
        }
    } catch {
        return [pscustomobject]@{
            SignedIn = $false
            Known    = $false
            Method   = ''
            Account  = ''
            Detail   = "could not run $CommandName"
        }
    }

    try {
        # READ BEFORE WAITING, both pipes at once. A child that fills a
        # redirected pipe blocks on the write, so waiting for exit first and
        # reading afterwards deadlocks on any output larger than the buffer -
        # and a deadlock here is precisely the hung start this check exists to
        # rule out.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            # A child that exited between the timeout and the kill is already
            # gone, which is the outcome the kill was for; the verdict below is
            # the same either way, so this is noted and not raised.
            try { $proc.Kill($true) } catch { Write-Verbose "could not kill the timed-out check: $($_.Exception.Message)" }
            return [pscustomobject]@{
                SignedIn = $false
                Known    = $false
                Method   = ''
                Account  = ''
                Detail   = 'the sign-in check did not answer in time'
            }
        }
        # AND THE READS ARE BOUNDED TOO. A process can exit while a grandchild it
        # left behind still holds the write end of the pipe, and the read task
        # then never completes - so reading .Result straight after a successful
        # WaitForExit can hang on exactly the machine this check is supposed to
        # protect. The exit has already happened here, so this bound is short.
        $text = ''
        if ([System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 5000)) {
            try { $text = ($stdout.Result, $stderr.Result) -join "`n" } catch { $text = '' }
        }
        ConvertFrom-FmSignInStatus -Output $text -ExitCode $proc.ExitCode
    } finally {
        $proc.Dispose()
    }
}

function Get-FmSignInDecision {
    <#
        .SYNOPSIS
        Whether the screen may open, and what the captain is told when it may not.

        .DESCRIPTION
        The whole readiness rule as one testable decision, in the shape
        Get-FmMachineStartDecision already established for the install's start
        question.

        SILENCE IS A REQUIREMENT, NOT A DEFAULT. A machine that is signed in
        gets no lines at all. A start that prints a paragraph of green ticks
        before every session teaches the captain to read past it, which is how
        the one line that mattered would be missed.

        CANNOT TELL PROCEEDS, SILENTLY. See this file's header: only a definite
        signed-out answer stops a start.

        AND THE DEFAULT ANSWER IS YES, unlike Get-FmMachineStartDecision's. The
        difference is what the two questions do. That one starts a process and
        opens a browser on a machine whose captain has not asked for it, so
        pressing Enter must be a no. This one FINISHES the thing they already
        asked for by typing start: they are standing at a terminal, the screen
        they want cannot answer without this, and signing in is safe and
        reversible. It is the same reasoning install.ps1's speech-model download
        is defaulted yes on.

        .PARAMETER Status
        A reading from Get-FmSignInStatus.

        .PARAMETER CaptainPresent
        Somebody is at the keyboard to answer. A redirected stdin is not.

        .PARAMETER Answer
        What they typed, or an empty string when they were not asked. Empty
        from a present captain is the default, which is yes.

        .EXAMPLE
        (Get-FmSignInDecision -Status (Get-FmSignInStatus) -CaptainPresent).Proceed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # AllowNull, and the guard below is why. A caller holding nothing is a
        # caller whose check did not run, which is the "cannot tell" case and
        # must start the captain rather than throw at them. Mandatory without
        # this rejects $null at the binder and makes that guard unreachable.
        [Parameter(Mandatory)][AllowNull()]$Status,
        [switch]$CaptainPresent,
        [AllowEmptyString()][string]$Answer = ''
    )

    $silent = [pscustomobject]@{ Proceed = $true; SignIn = $false; Lines = [string[]]@() }

    if ($null -eq $Status) { return $silent }
    $names = @($Status.PSObject.Properties.Name)
    if ($names -notcontains 'SignedIn' -or $names -notcontains 'Known') { return $silent }

    if (-not $Status.Known) { return $silent }
    if ($Status.SignedIn) { return $silent }

    # ONE LINE ABOUT WHAT IS WRONG, ONE ABOUT WHAT IT COSTS, AND THE WAY OUT.
    # Not a diagnostic dump: the captain asked for a screen, and what they need
    # here is the sentence that gets them one.
    $explain = [string[]]@(
        '  firstmate answers through your Claude account, and this machine is not signed in yet.'
        '  The screen would open and then have nothing to say, so this asks first.'
    )

    if (-not $CaptainPresent) {
        return [pscustomobject]@{
            Proceed = $false
            SignIn  = $false
            Lines   = $explain + [string[]]@(
                ''
                '  Sign in with this, then start again:'
                ''
                '    claude auth login'
                ''
            )
        }
    }

    # Trimmed, because a trailing space is still an answer. Anchored, because on
    # a default-yes question the string that must be recognised exactly is the
    # NO - anything unrecognised falling through to "sign in" is the harmless
    # direction, since the captain is standing there and can decline the browser.
    if ($Answer.Trim() -match '^(n|no)$') {
        return [pscustomobject]@{
            Proceed = $false
            SignIn  = $false
            Lines   = [string[]]@(
                '  Nothing started. Sign in whenever you like with:'
                ''
                '    claude auth login'
                ''
            )
        }
    }

    # THE SAME EXPLANATION, carried rather than re-typed by the caller. What the
    # captain is told about a signed-out machine is written once, here, and both
    # the asking path and the nobody-home path above hand back the same two
    # sentences. A caller printing its own wording is the copy that goes stale
    # the first time only one of them is edited.
    [pscustomobject]@{ Proceed = $false; SignIn = $true; Lines = $explain }
}

function Invoke-FmSignIn {
    <#
        .SYNOPSIS
        Hand the terminal to `claude auth login`.

        .DESCRIPTION
        Runs the CLI's own sign-in, inheriting this console so the captain can
        answer it, and reports whether the machine is signed in afterwards.

        IT DOES NOT PARSE THE SIGN-IN. Whether that flow used a browser, a code
        paste or a device prompt is the CLI's business and changes between
        versions; the only thing this needs to know is the state it left behind,
        which Get-FmSignInStatus already answers. So the verdict is a fresh
        reading rather than the login's exit code.

        NO REDIRECTION, DELIBERATELY. The flow is interactive, and capturing its
        output would take the prompts away from the person who has to answer
        them.

        .PARAMETER CommandName
        The CLI to run. A parameter so the tests can put a stub in its place.

        .EXAMPLE
        Invoke-FmSignIn
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Writes to the captain''s console around an interactive flow that owns it; a stream would be redirectable away from them.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string]$CommandName = 'claude'
    )

    if (-not $PSCmdlet.ShouldProcess($CommandName, 'sign in to your Anthropic account')) {
        return [pscustomobject]@{ SignedIn = $false; Known = $false; Method = ''; Account = ''; Detail = 'not run' }
    }

    $cli = Get-Command -Name $CommandName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cli) {
        return [pscustomobject]@{
            SignedIn = $false
            Known    = $false
            Method   = ''
            Account  = ''
            Detail   = "no $CommandName on PATH"
        }
    }

    try { & $cli.Source 'auth' 'login' } catch {
        # A refused or failed launch is not a crash for the caller to handle -
        # the reading below is still the honest answer about the machine.
        Write-Verbose "sign-in did not complete: $($_.Exception.Message)"
    }

    Get-FmSignInStatus -CommandName $CommandName
}
