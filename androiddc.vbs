' Launch AndroidDC without a console window.
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & scriptDir & "\androiddc.ps1"""

CreateObject("Wscript.Shell").Run strCommand, 0, false
