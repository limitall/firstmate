#requires -Version 7.0
<#
.SYNOPSIS
fm-bridge.ps1 - serve the bridge HUD over loopback so the browser will actually
give it a microphone.

.DESCRIPTION
WHY THIS EXISTS, MEASURED. Opening ui/bridge.html straight off disk renders
correctly and then fails at the one thing it is for:

    navigator.mediaDevices.getUserMedia({audio:true})
    -> NotAllowedError - Permission denied

A `file://` page has an opaque origin. Chrome has nowhere to attach a microphone
grant, so it refuses rather than prompting, and no amount of clicking allow will
change it. `window.isSecureContext` reports true on file://, which is exactly
what makes this trap easy to miss - the page looks like it should work.

`http://127.0.0.1` is a real origin AND is treated as a secure context without a
certificate, so the grant sticks. That is the whole reason this script exists.

WHAT THIS IS NOT. This is the smallest possible static server: it serves the
files under ui/ to the loopback interface and nothing else. It does not host a
firstmate session, does not supervise, does not accept commands, and has no
write path at all. The full bridge described in data/web-ui/report.md is a
separate, larger piece of work; this is the read-only first slice that report
recommends, and deliberately nothing more.

SECURITY, STATED PLAINLY. It binds 127.0.0.1 only, so nothing off this machine
can reach it. Every process running as the captain can, which is the same
exposure any local dev server has. Because there is no write path, a page in
another tab that POSTs at it can achieve nothing. Do not add a write path here
without revisiting that.

.PARAMETER Port
Loopback port. Default 7433.

.PARAMETER NoLaunch
Do not open a browser; just serve.

.EXAMPLE
bin/fm-bridge.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 7433,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$uiRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui'
if (-not (Test-Path -LiteralPath $uiRoot -PathType Container)) {
    [Console]::Error.WriteLine("error: no ui directory at $uiRoot")
    exit 1
}

$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    [Console]::Error.WriteLine("error: cannot listen on $prefix - $($_.Exception.Message)")
    [Console]::Error.WriteLine('       another process may already hold that port; try -Port <n>')
    exit 1
}

[Console]::Out.WriteLine("fm-bridge: serving $uiRoot at $prefix")
[Console]::Out.WriteLine('fm-bridge: loopback only - nothing off this machine can reach it')
[Console]::Out.WriteLine('fm-bridge: read-only - there is no write path')
[Console]::Out.WriteLine('fm-bridge: Ctrl+C to stop')

if (-not $NoLaunch) { Start-Process "$prefix" }

$types = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
    '.woff2' = 'font/woff2'
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            # Read-only by contract, so anything that is not a plain read is
            # refused rather than ignored - a silent 200 on a POST would invite a
            # caller to believe it did something.
            if ($request.HttpMethod -notin @('GET', 'HEAD')) {
                $response.StatusCode = 405
                $response.Close()
                continue
            }

            $rel = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'bridge.html' }

            # Path containment, checked on the RESOLVED path rather than by
            # inspecting the request string: '..', an absolute path and a symlink
            # that points outside all fail the same single test.
            $full = [System.IO.Path]::GetFullPath((Join-Path $uiRoot $rel))
            $rootFull = [System.IO.Path]::GetFullPath($uiRoot)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $response.StatusCode = 403
                $response.Close()
                continue
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $response.StatusCode = 404
                $response.Close()
                continue
            }

            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
            $response.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
            # A mockup is edited and reloaded constantly; a cached copy of the
            # previous version reads as "the change did nothing".
            $response.Headers.Add('Cache-Control', 'no-store')

            $bytes = [System.IO.File]::ReadAllBytes($full)
            $response.ContentLength64 = $bytes.Length
            if ($request.HttpMethod -eq 'GET') {
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $response.Close()
        } catch {
            try { $response.StatusCode = 500; $response.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    [Console]::Out.WriteLine('fm-bridge: stopped')
}
