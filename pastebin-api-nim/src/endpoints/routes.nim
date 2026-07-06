import dispatch

import
    pastes/recentPastes, pastes/createPaste, pastes/getPaste, pastes/rawPaste,
    files/uploadFile, files/uploadFolder, files/createPasteFromFile,
    files/getFile, files/deleteFile, files/downloadFile, files/viewFile,
    admin/listPastes, admin/deletePaste

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
    
    # Admin (X-Admin-Token — each handler calls requireAdmin upfront)
    result.get(   "/api/admin/pastes",                 handleAdminListPastes)
    result.delete("/api/admin/pastes/{id}",            handleAdminDeletePaste)
