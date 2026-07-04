## Fire-and-forget ntfy.sh push notifier, mirroring pastebin-api/services/NtfyNotifier.cs.
## Silent no-op unless NTFY_TOPIC is set. A single background thread drains a channel and does
## one JSON POST per event with a 5s timeout, swallowing all errors so a slow/unreachable ntfy
## can never block or fail a request.

import std/[httpclient, json, strutils]
import config, types

type NtfyMsg = object
    title, message, click: string

var
    gChan: Channel[NtfyMsg]
    gThread: Thread[void]
    gServer, gTopic, gPublicBase: string
    gEnabled: bool

proc formatSize(bytes: int64): string =
    ## Mirrors NtfyNotifier.FormatSize: B/KB/.../TB, "0.#" for scaled values.
    const units = ["B", "KB", "MB", "GB", "TB"]
    var size = bytes.float
    var unit = 0
    while size >= 1024 and unit < units.len - 1:
        size /= 1024
        unit.inc
    if unit == 0:
        return $bytes & " B"
    # "0.#": one optional decimal, trailing ".0" dropped.
    var s = formatFloat(size, ffDecimal, 1)
    if s.endsWith(".0"): s = s[0 ..< s.len - 2]
    s & " " & units[unit]

proc worker() {.thread.} =
    # gServer/gTopic/gPublicBase are set once in initNtfy before this thread starts and only
    # read here, so the global-access is safe despite Nim's conservative gcsafe check.
    {.cast(gcsafe).}:
        while true:
            let msg = gChan.recv()
            try:
                let client = newHttpClient(timeout = 5000)
                defer: client.close()
                let payload = %*{
                    "topic": gTopic,
                    "title": msg.title,
                    "message": msg.message,
                    "click": msg.click,
                    "tags": ["memo"],
                    "priority": 3,
                }
                client.headers = newHttpHeaders({"Content-Type": "application/json"})
                discard client.request(gServer, HttpPost, body = $payload)
            except CatchableError:
                discard # swallow: ntfy must never affect the request path

proc initNtfy*(cfg: AppConfig) =
    gServer = cfg.ntfyServerUrl.strip(leading = false, trailing = true, {'/'})
    gTopic = cfg.ntfyTopic
    gPublicBase = cfg.publicBaseUrl.strip(leading = false, trailing = true, {'/'})
    gEnabled = gTopic.len > 0
    if gEnabled:
        gChan.open()
        createThread(gThread, worker)

proc notifyPasteCreated*(p: Paste) =
    if not gEnabled: return
    gChan.send(NtfyMsg(
        title: "New paste: " & p.title,
        message: formatSize(p.size) & " · " & p.id,
        click: gPublicBase & "/paste/" & p.id))

proc notifyFileUploaded*(f: StoredFile) =
    if not gEnabled: return
    gChan.send(NtfyMsg(
        title: "New upload: " & f.originalName,
        message: formatSize(f.size) & " · " & f.id,
        click: gPublicBase & "/files/" & f.id))
