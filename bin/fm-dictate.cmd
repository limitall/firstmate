@echo off
rem fm-dictate.cmd - the file the speech engine can actually run.
rem
rem WHY THIS EXISTS. The engine spawns its external-script hook as a process,
rem and Windows CreateProcess cannot execute a .ps1 at all - measured, it raises
rem "The specified executable is not a valid application for this OS platform"
rem (error 193) - while a .cmd it runs through the command processor. So the hook
rem the captain points the engine at is this line, and bin/fm-dictate.ps1 stays
rem the one place the behaviour lives.
rem
rem The transcript arrives on stdin, or as an argument, and both reach the script
rem unchanged: stdin is inherited, and %* forwards the arguments.
setlocal
pwsh -NoProfile -File "%~dp0fm-dictate.ps1" %*
exit /b %ERRORLEVEL%
