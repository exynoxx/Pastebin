## Per-IP storage quota.
## Usage = SUM(size) across BOTH pastes and files for owner_ip. Checked BEFORE writing a blob
## so a rejected upload never orphans bytes. Intentionally non-transactional (TOCTOU): the tiny
## race window is acceptable for a personal instance.

import std/strformat
import apperrors
import common/templates
importuse pastecache
importuse db

proc ensureWithinQuota*(ownerIp: string, newSize, maxStorageBytesPerIp: int64) =
    ## Raises PayloadTooLargeError (-> 413) when newSize would push the IP over its budget.
    ## Counts not-yet-persisted (in-cache) bytes too, so a burst can't slip past the cap while its
    ## rows aren't in the DB yet.
    let usage = db.sumUsageForOwner(ownerIp) + pastecache.pendingBytesForOwner(ownerIp)
    if usage + newSize > maxStorageBytesPerIp:
        let quotaMb = maxStorageBytesPerIp div (1024 * 1024)
        raise newException(PayloadTooLargeError,
            &"Storage quota exceeded for your address ({quotaMb} MB). Delete old pastes or try later.")
