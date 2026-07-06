## Public resource IDs for pastes and files: 8 URL-safe base62 chars from a CSPRNG.
## One scheme for both (they share no key space, but a single format keeps the code uniform).

import std/sysrand

const
    Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    IdLen = 8
    # Largest multiple of 62 that fits in a byte; bytes >= this are rejected so every
    # alphabet character is equally likely (no modulo bias).
    Ceiling = 248  # 62 * 4

proc newId*(): string =
    ## 8 base62 characters, rejection-sampled from urandom to avoid modulo bias.
    result = newStringOfCap(IdLen)
    while result.len < IdLen:
        for b in urandom(IdLen):
            if int(b) < Ceiling:
                result.add Alphabet[int(b) mod 62]
                if result.len == IdLen: break
