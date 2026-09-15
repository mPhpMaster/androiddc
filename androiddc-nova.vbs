' Launch AndroidDC Nova - the same tool in the new window - without a console.
' androiddc.vbs next to this file starts the classic window; each window has a
' button that opens the other.
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ _
    & scriptDir & "\nova\androiddc-nova.ps1"""

CreateObject("Wscript.Shell").Run strCommand, 0, false
