' Open-Shell 4.4.1004+: request a purge before caches are opened on next startup.
' Keep this block synchronized with WinSlim_Ultra_CacheCleaner.vbs.
Sub CleanOpenShellCaches()
    Dim root, pending, state, names, name, f, stream, hasCache, elapsed

    openShellText = "Sin cachés que regenerar"
    root = NormalizePath(localAppData) & "\OpenShell"
    If Not objFSO.FolderExists(root) Then Exit Sub
    If Not OpenShellCacheDirectorySafe(root) Then
        openShellText = "Omitida: carpeta redirigida o inaccesible"
        Exit Sub
    End If

    On Error Resume Next ' [io]
    pending = root & "\CacheCleanup.pending"
    state = root & "\CacheMaintenance.state"
    If objFSO.FolderExists(pending) Then
        openShellText = "Omitida: solicitud no válida"
        Exit Sub
    End If
    If objFSO.FileExists(pending) Then
        Set f = objFSO.GetFile(pending)
        If Err.Number <> 0 Then
            Err.Clear
            openShellText = "Omitida: solicitud inaccesible"
        ElseIf IsReparsePoint(f) Then
            openShellText = "Omitida: solicitud redirigida"
        Else
            openShellText = "Pendiente del próximo inicio de Open-Shell"
        End If
        Exit Sub
    End If

    names = Array("DataCache.db", "DataCache.tmp", "ModernSettings.dat", "DataCache.txt")
    hasCache = False
    For Each name In names
        If objFSO.FolderExists(root & "\" & name) Then
            openShellText = "Omitida: archivo de caché no válido"
            Exit Sub
        End If
        If objFSO.FileExists(root & "\" & name) Then
            Set f = objFSO.GetFile(root & "\" & name)
            If Err.Number <> 0 Then
                Err.Clear
                openShellText = "Omitida: caché inaccesible"
                Exit Sub
            End If
            If IsReparsePoint(f) Then
                openShellText = "Omitida: archivo de caché redirigido"
                Exit Sub
            End If
            hasCache = True
        End If
    Next
    If Not hasCache Then Exit Sub

    If OPENSHELL_CACHE_DAYS > 0 And objFSO.FileExists(state) Then
        Set f = objFSO.GetFile(state)
        If Err.Number = 0 Then
            If Not IsReparsePoint(f) Then
                elapsed = DateDiff("d", f.DateLastModified, Now)
                If Err.Number = 0 And elapsed < OPENSHELL_CACHE_DAYS Then
                    openShellText = "Conservada: mantenimiento reciente"
                    Exit Sub
                End If
            End If
        End If
        Err.Clear
    End If

    ProgressDetail "Programando la regeneración de cachés de Open-Shell"
    If isDryRun Then
        openShellText = "Se programaría para el próximo inicio de Open-Shell"
    Else
        ' CREATE_NEW semantics: never overwrite a pre-existing file/link.
        Set stream = Nothing
        Set stream = objFSO.CreateTextFile(pending, False, True)
        If Err.Number <> 0 Then
            Err.Clear
            openShellText = "No se pudo programar la regeneración"
            AddNote warnNotes, "No se pudo crear la solicitud de limpieza de Open-Shell"
            Exit Sub
        End If
        stream.Close
        Err.Clear
        openShellText = "Programada para el próximo inicio de Open-Shell"
    End If
    LogLine "Open-Shell: " & openShellText
    ' No bytes counted as freed yet. Never kill Explorer, delete pins or reset settings.
End Sub


Function OpenShellCacheDirectorySafe(path)
    Dim p, folder, parent

    OpenShellCacheDirectorySafe = False
    On Error Resume Next ' [io]
    p = NormalizePath(path)
    If Len(p) < 3 Then Exit Function
    If Mid(p, 2, 2) <> ":\" Then Exit Function
    Do
        Set folder = GetFolderSafe(p)
        If folder Is Nothing Then Exit Function
        If IsReparsePoint(folder) Then Exit Function
        parent = objFSO.GetParentFolderName(p)
        If Err.Number <> 0 Then
            Err.Clear
            Exit Function
        End If
        If parent = "" Or LCase(parent) = LCase(p) Then Exit Do
        p = parent
    Loop
    OpenShellCacheDirectorySafe = True
End Function
