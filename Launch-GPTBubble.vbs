Option Explicit

Dim shell, fileSystem, scriptDirectory, runnerPath, pwshPath, command, clearStopMarker

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
runnerPath = fileSystem.BuildPath(scriptDirectory, "Run-GPTBubble.ps1")
pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
clearStopMarker = False
If WScript.Arguments.Count > 0 Then
    clearStopMarker = LCase(WScript.Arguments(0)) = "clear"
End If

command = Quote(pwshPath) & _
    " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Quote(runnerPath)
If clearStopMarker Then
    command = command & " -ClearStopMarker"
End If

' Window style 0 keeps PowerShell fully hidden. Waiting preserves task supervision.
WScript.Quit shell.Run(command, 0, True)

Function Quote(ByVal value)
    Quote = Chr(34) & value & Chr(34)
End Function
