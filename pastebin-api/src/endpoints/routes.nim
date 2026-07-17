## The app's HTTP composition root: the app's `Ctx` alias, the shared handler imports, and the route
## table `main` hands to the framework's `run`. The generic per-request flow (match → build context →
## middleware chain → handler/404) lives in the framework (webframework); here we only supply the
## app-specific pieces: the `Ctx[AppConfig]` binding, the route map, and the cross-cutting policy
## chain (the rate limiter — see ratelimit.nim). (Admin auth isn't composed here — admin handlers
## call requireAdmin upfront; see endpoints/admin/guard.)

import webframework/server
import webframework/context as fctx
import common/templates
import ../config
importuse ratelimit
importuse accesslog

# Re-export what handlers reach for through this module — httpserver (Request + response helpers),
# config (AppConfig), the framework's Ctx-level helpers, and the shared control-flow templates
# (fetchOr404/returnif/swallowException). NOT the framework's generic `Ctx`: the app-bound alias below
# owns that name, and re-exporting the generic one would make it ambiguous.
export httpserver, config
export fctx.errorJson, fctx.respondError, fctx.parseJsonBodyOr400
export templates

type
    Ctx* = fctx.Ctx[AppConfig]
        ## The framework's generic context bound to this app's config. Handlers name it as `Ctx`.

# Handlers are imported AFTER `Ctx` is declared: each handler imports this module for `Ctx`, and this
# module imports them to register them. That mutual dependency only resolves because `Ctx` is already
# in scope by the time these imports pull the handlers in — do not move this above the alias.
import
    pastes/recentPastes, pastes/createPaste, pastes/getPaste, pastes/rawPaste,
    files/uploadFile, files/uploadFolder, files/createPasteFromFile,
    files/getFile, files/deleteFile, files/downloadFile, files/viewFile,
    admin/listPastes, admin/deletePaste

func registerRoutes*(): RouteTable[AppConfig] =
    result.use(accesslog.accessLog())   # outermost: records every access, even those rate-limited (503) or 404
    result.use(ratelimit.rateLimit())
    result.get(   "/api/pastes",                       handleRecentPastes)
    result.post(  "/api/pastes",                       handleCreatePaste)
    result.get(   "/api/pastes/{id}",                  handleGetPaste)
    result.get(   "/api/pastes/{id}/raw",              handleRawPaste)
    result.post(  "/api/files/upload",                 handleUploadFile)
    result.post(  "/api/files/upload-folder",          handleUploadFolder)
    result.post(  "/api/files/create-paste-from-file", handleCreatePasteFromFile)
    result.get(   "/api/files/{id}",                   handleGetFile)
    result.delete("/api/files/{id}",                   handleDeleteFile)
    result.get(   "/api/files/{id}/download",          handleDownloadFile)
    result.get(   "/api/files/{id}/raw",               handleViewFile)

    # Admin (X-Admin-Token — each handler calls requireAdmin upfront)
    result.get(   "/api/admin/pastes",                 handleAdminListPastes)
    result.delete("/api/admin/pastes/{id}",            handleAdminDeletePaste)
