' pfd-saas: run a PowerShell script with no console window.
' Scheduled Tasks call: wscript.exe run-hidden.vbs "<path-to-script.ps1>"
' Without this, the watchdog task would flash a console window every 5 minutes.
' Installed by setup-windows.ps1 into %USERPROFILE%\pfd-watchdog.
If WScript.Arguments.Count < 1 Then WScript.Quit 2
Set sh = CreateObject("WScript.Shell")
WScript.Quit sh.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """", 0, True)
