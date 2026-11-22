' Run a PowerShell script with no console window.
' Usage: wscript.exe run-hidden.vbs "C:\path\to\script.ps1" [args...]
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Dim sh, cmd, i
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
  cmd = cmd & " " & WScript.Arguments(i)
Next
sh.Run cmd, 0, False
