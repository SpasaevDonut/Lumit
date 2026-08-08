# Assets

Binary files the engine embeds at build time. Everything here is compiled into
the application, so anything added must be licence-clear for redistribution
under the GPLv3 (see `LICENSE`).

## `easter_egg_1337.qoi`

A photograph of a dirty lens filter — grease, dust and out-of-focus highlights —
from **Wikimedia Commons**, free to use. It is the plate the Lens dirt effect
(docs/08 §3.28) is modelled on, and setting that effect's Seed to `1337` draws
it instead of generating a field: a deliberate easter egg, recorded in K-314.

Stored as **QOI** (Quite OK Image), a lossless format whose decoder is thirty
lines of plain Rust — so the asset costs about 120 KB in the repository rather
than 1.2 MB, and no image-decoding dependency is pulled into `lumit-core` for
one picture.
