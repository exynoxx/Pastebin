## Public resource IDs for pastes and files: 8 URL-safe base62 chars from a CSPRNG.
## One scheme for both (they share no key space, but a single format keeps the code uniform).

import std/sysrand

const Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

proc newId*(): string =
    ## 8 base62 chars from a CSPRNG. Bytes >= 248 (62*4) are rejected so every
    ## character is equally likely (no modulo bias).
    while result.len < 8:
        let b = int(urandom(1)[0])
        if b < 248: result.add Alphabet[b mod 62]
