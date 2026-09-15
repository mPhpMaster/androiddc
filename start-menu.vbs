' Adds AndroidDC to the Start menu: a shortcut for the classic window
' (androiddc.vbs) and one for Nova (androiddc-nova.vbs), with the AndroidDC
' icon. They appear under All apps; right-click one there and choose
' "Pin to Start" to put it on the first page - Windows keeps that step for you.
'
' Run it again after moving this folder, so the shortcuts follow it.
' start-menu-remove.vbs does the reverse.
'
'   start-menu.vbs                add the two shortcuts, or bring them up to date
'   start-menu.vbs /remove        remove them again
'   /quiet                        no message at the end
'   /folder:<path>                another folder instead of the Start menu (tests)
Option Explicit

Dim fso, shell, here, programs, removing, quiet, argument
Dim names, targets, descriptions, i, shortcutPath, link, done, missing, message

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
programs = shell.SpecialFolders("Programs")
removing = False
quiet = False

For Each argument In WScript.Arguments
    If LCase(argument) = "/remove" Then removing = True
    If LCase(argument) = "/quiet" Then quiet = True
    If LCase(Left(argument, 8)) = "/folder:" Then programs = Mid(argument, 9)
Next

names = Array("AndroidDC", "AndroidDC Nova")
targets = Array("androiddc.vbs", "androiddc-nova.vbs")
descriptions = Array("AndroidDC - control Android phones over adb (classic window)", _
    "AndroidDC Nova - control Android phones over adb (Nova window)")

If Not removing And Not fso.FolderExists(programs) Then fso.CreateFolder programs

done = ""
missing = ""
For i = 0 To UBound(names)
    shortcutPath = programs & "\" & names(i) & ".lnk"
    If removing Then
        If fso.FileExists(shortcutPath) Then
            fso.DeleteFile shortcutPath
            done = done & vbCrLf & "    " & names(i)
        End If
    ElseIf fso.FileExists(here & "\" & targets(i)) Then
        ' wscript.exe runs the launcher, the same as a double-click on it
        Set link = shell.CreateShortcut(shortcutPath)
        link.TargetPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
        link.Arguments = """" & here & "\" & targets(i) & """"
        link.WorkingDirectory = here
        If fso.FileExists(here & "\assets\androiddc.ico") Then link.IconLocation = here & "\assets\androiddc.ico, 0"
        link.Description = descriptions(i)
        link.Save
        done = done & vbCrLf & "    " & names(i)
    Else
        missing = missing & vbCrLf & "    " & targets(i)
    End If
Next

If removing Then
    If done = "" Then
        message = "AndroidDC was not in the Start menu."
    Else
        message = "Removed from the Start menu:" & done
    End If
Else
    message = "In the Start menu now, under All apps:" & done & vbCrLf & vbCrLf & _
        "To keep one on the first page of Start, right-click it there and choose Pin to Start."
    If missing <> "" Then message = message & vbCrLf & vbCrLf & "Not found in this folder, so not added:" & missing
End If

If Not quiet Then MsgBox message, vbInformation, "AndroidDC"
If missing <> "" Then WScript.Quit 1
WScript.Quit 0
