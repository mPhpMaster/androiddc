' Launch AndroidDC without a console window.
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

' anything given to this file goes on to the script, e.g. -Minimized from the
' start-with-Windows entry
extra = ""
For Each argument In WScript.Arguments
    extra = extra & " """ & argument & """"
Next

strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & scriptDir & "\androiddc.ps1""" & extra

CreateObject("Wscript.Shell").Run strCommand, 0, false
