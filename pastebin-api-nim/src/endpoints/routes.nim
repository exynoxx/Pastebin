## The endpoint map — the one place that shows every route the API serves, in the spirit of an
## ASP.NET minimal-API `Program.cs`. Each line is: verb, path (with {param}s), handler, and any
## per-route middleware flags — `admin` (X-Admin-Token gated) / `upload` (uploads rate-limit
## policy). Every handler body lives one-per-file under endpoints/<feature>/.

import dispatch

import
    pastes/recentPastes, pastes/createPaste, pastes/getPaste, pastes/rawPaste,
    files/uploadFile, files/uploadFolder, files/createPasteFromFile,
    files/getFile, files/deleteFile, files/downloadFile, files/viewFile,
    admin/listPastes, admin/deletePaste,
    debug/ip

proc registerRoutes*(): RouteTable =
    # Pastes
    result.get(   "/api/pastes",                       handleRecentPastes)
    result.post(  "/api/pastes",                       handleCreatePaste)
    result.get(   "/api/pastes/{id}",                  handleGetPaste)
    result.get(   "/api/pastes/{id}/raw",              handleRawPaste)
    # Files
    result.post(  "/api/files/upload",                 handleUploadFile,          upload = true)
    result.post(  "/api/files/upload-folder",          handleUploadFolder,        upload = true)
    result.post(  "/api/files/create-paste-from-file", handleCreatePasteFromFile)
    result.get(   "/api/files/{id}",                   handleGetFile)
    result.delete("/api/files/{id}",                   handleDeleteFile)
    result.get(   "/api/files/{id}/download",          handleDownloadFile)
    result.get(   "/api/files/{id}/raw",               handleViewFile)
    # Admin (X-Admin-Token)
    result.get(   "/api/admin/pastes",                 handleAdminListPastes,     admin = true)
    result.delete("/api/admin/pastes/{id}",            handleAdminDeletePaste,    admin = true)
    # Debug
    result.get(   "/api/debug/ip",                     handleDebugIp)
