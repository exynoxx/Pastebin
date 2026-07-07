# Admin list: files + private pastes, relative time, size indicator

## Problem

The admin page (`GET /api/admin/pastes` → `pastebin-frontend/src/pages/Admin.js`) lists
**pastes only**. Private pastes are already included (the query has no visibility filter and the
UI shows each paste's `visibility`), but **uploaded files never appear** — the admin query hits
only the `pastes` table, and the UI has no file rows. Admins therefore can't see or manage files.

Two presentation gaps also exist: timestamps show only an absolute date (hard to scan for
"what's recent"), and size is plain text (hard to spot large items at a glance).

## Goal

The admin list shows **all content** — public pastes, private pastes, and files — in one unified
list, newest first, with per-item view/delete that works for both kinds. Plus a human-friendly
relative timestamp and a color indicator for size.

## Non-goals

- No access-control change to `visibility` — it stays an unlisted/direct-link concept.
- No pagination, search, or filtering (not present today; out of scope).
- No new delete endpoints — admin-gated deletes already exist for both kinds.

## Design

### Backend (`pastebin-api/`)

**Query — `db.nim`:** add `selectAllContent(): seq[AdminContentRow]`, a `UNION ALL` over both
tables with **no visibility filter**, newest first (mirrors the public `selectRecentSummaries`
pattern, but admin-flavored — keeps `owner_ip`/`blob_id`, ignores visibility):

```sql
SELECT id, 'paste' AS kind, title AS name, '' AS content_type, size, is_truncated,
       blob_id, created_at, visibility, owner_ip FROM pastes
UNION ALL
SELECT id, 'file' AS kind, original_name AS name, content_type, size, 0 AS is_truncated,
       blob_id, uploaded_at AS created_at, visibility, owner_ip FROM files
ORDER BY created_at DESC;
```

`hasBlob` is derived per row from `blob_id` being non-empty, as in `selectAllPastes` today.

**Type — `types.nim`:** add `AdminContentRow` = existing `AdminPasteRow` fields
(`id, title, size, isTruncated, hasBlob, createdAt, visibility, ownerIp`) **plus**:
- `kind: string` — `"paste"` | `"file"`
- `contentType: string` — the file's content type; `""` for pastes

(`title` carries the paste title or the file's `original_name`.)

**Endpoint — `endpoints/admin/listPastes.nim`:** `handleAdminListPastes` calls
`selectAllContent()` and serializes `AdminContentRow` (still `serialize(...)` with no `omit`, so
`kind`/`contentType` are emitted). **Route unchanged:** `GET /api/admin/pastes` — kept to avoid
frontend/route churn; it's an internal, unlisted API and the misnomer is acceptable.

**Cleanup:** remove `selectAllPastes` (`db.nim`) and `AdminPasteRow` (`types.nim`) if nothing
else references them after the switch.

**Deletes (already exist, no change):**
- `DELETE /api/admin/pastes/{id}` → `handleAdminDeletePaste` (admin-gated)
- `DELETE /api/files/{id}` → `handleDeleteFile` (admin-gated)

### Frontend

**Helpers — `src/utils/format.js`** (alongside `formatBytes`):
- `timeAgo(ms)`: relative form from epoch-millis → now, e.g. `"just now"`, `"5min ago"`,
  `"3h ago"`, `"30d ago"`. Coarse single-unit buckets (s → min → h → d; larger falls back to
  `d`). Tolerates future timestamps (clock skew) by clamping to `"just now"`.
- `sizeColor(bytes)`: returns a color for a size bucket — green `< 1 MB`, amber `1–50 MB`,
  red `> 50 MB`. Returns a CSS color string so it can drive an inline style.

**`src/pages/Admin.js`** — `renderPasteItem` becomes kind-aware:
- **Kind badge:** `[paste]` / `[file]` from `p.kind`.
- **File extra:** show `p.contentType` for files.
- **Timestamp:** keep the absolute `toLocaleString()`, then append `timeAgo(p.createdAt)` in a
  muted style, e.g. `2026-07-07 14:32 · 5min ago`.
- **Size indicator:** a small colored dot/pill next to `formatBytes(p.size)`, its color from
  `sizeColor(p.size)` (inline style).
- **View:** pastes → `/paste/:id`; files → `/files/:id` (currently always `/paste/:id`).
- **Delete (per item):** dispatch by kind → `DELETE /admin/pastes/:id` for pastes,
  `DELETE /files/:id` for files.
- **"Delete all from this IP":** the loop dispatches per item's kind (same rule as above).
- **Group-by-IP:** logic unchanged — groups by `ownerIp`, so it naturally spans both kinds;
  size totals sum both. Update the count label wording from `paste(s)` to `item(s)`.

## Testing

Local e2e per `CLAUDE.md` (temp SQLite + blob dir, `ADMIN_TOKEN` set):
1. Create a **public paste**, a **private paste** (`visibility=private`), and **upload a file**.
2. `GET /api/admin/pastes` with `X-Admin-Token`: assert all three appear, newest first, with
   correct `kind`, `visibility`, and `contentType` (`""` for pastes, real type for the file).
3. `DELETE /api/admin/pastes/{pasteId}` and `DELETE /api/files/{fileId}` with the token; re-GET
   and confirm both are gone and the survivors remain.
4. `nim check --hints:off src/main.nim` → exit 0.

Frontend: manual smoke — load `/admin`, confirm files and pastes interleave by date, badges/
content-type/relative-time/size-color render, and View/Delete route correctly per kind.
