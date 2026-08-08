# Assets

Binary files the engine embeds at build time. Everything here is compiled into
the application, so anything added must be licence-clear for redistribution
under the GPLv3 (see `LICENSE`).

## `easter_egg_1337.qoi`

A photograph of a dirty lens filter — grease, dust and out-of-focus highlights —
from **Wikimedia Commons**, free to use. It is the plate the Lens dirt effect
(docs/08 §3.28) is modelled on, and setting that effect's Seed to `1337` draws
it instead of generating a field: a deliberate easter egg, recorded in K-314.

1920×1080, stored as **QOI** (Quite OK Image) — a lossless format whose decoder
is thirty lines of plain Rust, so no image-decoding dependency is pulled into
`lumit-core` for one picture. Lossless on a noisy photograph is not cheap: it is
about 3.1 MB, which is embedded in every build. That is affordable because the
plate is stretched over the whole frame (a thumbnail looks like a thumbnail) and
because it is decoded and uploaded **once** per engine rather than per frame.
