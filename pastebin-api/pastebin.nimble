# Package

version     = "0.1.0"
author      = "nicholas"
description = "Nim backend for Pastebin (hand-rolled HTTP framework + SQLite + blob store)"
license     = "MIT"
srcDir      = "src"
bin         = @["main"]

# Dependencies
#
# The HTTP layer is our own small framework (../webframework/ at the repo root, reached via
# --path:".." in nim.cfg; server on std/net) — no external web framework.
requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0" # maintained successor to std/db_sqlite
requires "zippy >= 0.10.11"      # folder -> zip archiving
