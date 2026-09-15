' Takes AndroidDC out of the Start menu again: removes the two shortcuts
' start-menu.vbs made, "AndroidDC" and "AndroidDC Nova". Nothing else is
' touched - not this folder, not the settings, not the rules. A shortcut pinned
' to the first page of Start goes with it.
'
'   start-menu-remove.vbs              remove the two shortcuts
'   /quiet                             no message at the end
'   /folder:<path>                     another folder instead of the Start menu (tests)
Option Explicit

Dim fso, shell, programs, quiet, argument, names, i, shortcutPath, removed, message

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
programs = shell.SpecialFolders("Programs")
quiet = False

For Each argument In WScript.Arguments
    If LCase(argument) = "/quiet" Then quiet = True
    If LCase(Left(argument, 8)) = "/folder:" Then programs = Mid(argument, 9)
Next

' the same names start-menu.vbs gives them
names = Array("AndroidDC", "AndroidDC Nova")

removed = ""
For i = 0 To UBound(names)
    shortcutPath = programs & "\" & names(i) & ".lnk"
    If fso.FileExists(shortcutPath) Then
        fso.DeleteFile shortcutPath
        removed = removed & vbCrLf & "    " & names(i)
    End If
Next

If removed = "" Then
    message = "AndroidDC was not in the Start menu, so there was nothing to remove."
Else
    message = "Removed from the Start menu:" & removed & vbCrLf & vbCrLf & _
        "start-menu.vbs puts them back."
End If

If Not quiet Then MsgBox message, vbInformation, "AndroidDC"
WScript.Quit 0
