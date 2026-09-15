' Launch AndroidDC Nova - the same tool in the new window - without a console.
' androiddc.vbs next to this file starts the classic window; each window has a
' button that opens the other.
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

' anything given to this file goes on to the script, e.g. -Minimized from the
' start-with-Windows entry
extra = ""
For Each argument In WScript.Arguments
    extra = extra & " """ & argument & """"
Next

strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ _
    & scriptDir & "\nova\androiddc-nova.ps1""" & extra

CreateObject("Wscript.Shell").Run strCommand, 0, false
