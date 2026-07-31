# Lumit project format

**Status: canonical.** Serialisation of the model in [03-DATA-MODEL.md](03-DATA-MODEL.md),
per decision K-040 (hybrid container) and K-024 (non-destructive always).

Design goals, in priority order: **never lose work** → **portable between machines** (K-065)
→ **human-inspectable** → fast. Speed is engineered around the format (caches, lazy thumbs),
never by making the document opaque.

---

## 1. The `.lum` file

A `.lum` file is a ZIP archive (deflate). Contents:

```
myproject.lum
├── manifest.json          # tiny: format + version info, read first
├── project.json           # the entire document model
└── thumbs/                # planned, not yet written (see below)
    ├── comp-<uuid>.webp
    └── item-<uuid>.webp
```

Rules:
- `manifest.json` MUST be the first entry in the archive and MUST parse standalone:
  `{ "format": "lumit-project", "schema_version": "…", "written_by": "lumit x.y.z",
  "min_reader": "…" }`. A reader newer than `schema_version` migrates; older than
  `min_reader` refuses with a clear message; otherwise it loads and preserves unknowns.
- `project.json` is pretty-printed with stable key order and stable array order, so two
  saves of the same document are byte-identical and version-control diffs are meaningful.
- Thumbnails are disposable previews for the Project panel and file browsers; a reader MUST
  tolerate their absence. **Not yet written** - v1 saves only `manifest.json` and
  `project.json`; the `thumbs/` folder is planned ([TODO.md](TODO.md)).
- Nothing else goes in the container. Media is never embedded; caches never ride along.

### 1.1 project.json conventions

- Times: rational pairs `[num, den]` — never floats ([14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md)).
- Colours: linear-light float arrays `[r, g, b, a]`.
- Ids: UUIDv7 strings; every cross-reference is an id.
- Enums: serialised by serde's default — a unit variant is its PascalCase name
  (`"channel": "Alpha"`, `"blend": "Screen"`); a data-carrying variant is externally tagged
  (`{ "Footage": { … } }`). Variants are additive, so old readers keep unknown ones via the
  preservation rule below.
- **Unknown-field preservation is mandatory**: a reader keeps any keys it does not
  understand and writes them back out. This is what lets shared projects and newer/older
  Lumit versions coexist (K-065) and lets Placeholder effects round-trip
  ([11-AE-IMPORT.md](11-AE-IMPORT.md)).

## 2. Media references and relinking

Per `MediaRef` in [03-DATA-MODEL.md](03-DATA-MODEL.md) §3, a saved reference carries a
**project-relative path** (rebased against the project's folder on every save; forward
slashes, so a save from any OS resolves on any other) and a **fingerprint**
(size + mtime + head/tail hash, stamped at save time). The file's absolute location is
**session-state only** (K-173): it is held in memory while the app runs and is never
serialized — an absolute path embeds the local username, which this section has always
promised the file never contains. Projects saved before K-173 may still carry one; it is
read and honoured as a fallback, and disappears on their next save. On open:

1. Try relative path → 2. a legacy file's absolute path, if present → 3. fingerprint search
   in user-configured search roots and the project's folder tree → 4. mark **missing**
   (placeholder slate, never a blocking error), offer the relink dialogue.

Steps 1–3 are wired (`resolve_all_media`, run before anything probes); step 4's dialogue is
future work — today missing files are named in a notice and keep their reference untouched,
so a later relink loses nothing.

Relinking one file automatically relinks siblings that resolve under the same path mapping.

**Collect for sharing**: an explicit command copies the project plus all referenced media
into one folder, rewriting references relative — the mechanism behind community project
sharing (K-065). Nothing machine-specific is ever written into `project.json` (no cache
paths, no window layout, no local usernames); per-machine state lives in app settings, and
workspaces are app-level with optional project hints.

## 3. The sidecar cache folder

All derived data lives outside the project. **v1 status:** only the rendered-frame cache and
the media index are built; `proxies/`, `peaks/`, and `flow/` are planned
([TODO.md](TODO.md)). What exists today:

```
<global cache root>/
├── frames/<project-uuid>/         # rendered frame cache (06 §5.4), the default location
│   ├── frames/                    #   LZ4 .kfr files, sharded by the first two hex chars
│   ├── index.bin                  #   the index snapshot: hash, size, cost, last use, quality
│   └── index.log                  #   changes since that snapshot, replayed at open
├── media-index/       # frame indexes for exact long-GOP seeking, shared across projects
└── <project-uuid>/journal/ops.jsonl # the crash-recovery journal (§4)

<project>.lum-cache/   # the same frame cache, when the user asks for it beside the project
├── frames/
├── index.bin
└── index.log
```

The intended full per-project layout (`<cache root>/<project-uuid>/` with `disk-cache/`,
`proxies/`, `peaks/`, `flow/`, `index/`) is the design direction; audio peaks are currently
computed on demand rather than stored.

**Where the frame cache sits is the user's choice (K-214, docs/07 §15):** under the global
root keyed by the document's uuid (the default), in a `<project>.lum-cache/` sidecar beside the
project file, or under a folder the user picks. The global root is the platform's own cache
directory, resolved by `directories::ProjectDirs` exactly as the journal and media index resolve
theirs, so one Lumit folder serves all three: `%LOCALAPPDATA%\Lumit\Lumit\cache` on Windows
(**local**, never roaming — a cache this size must not follow a domain profile over the
network), `~/Library/Caches/dev.Lumit.Lumit` on macOS, and `$XDG_CACHE_HOME/lumit` (default
`~/.cache/lumit`) on Linux. The cache directory, not the temp directory: these survive a
reboot, and may be reclaimed by the operating system under disk pressure — which is correct for
a folder deletable at any time. The sidecar cannot be the default because it
needs the project to *have* a file, and a project caches from the moment it is created — the
document uuid is inside the `.lum` and survives every save, so the global-root folder still
finds its frames after a save and a reopen.

The choice is application-wide by default and **may be made per project** (K-215), in which case
it is a field on the document (`cache_location`) and therefore inside `project.json`: it travels
with a copy of the project and survives being opened on another machine, which a setting in one
machine's settings file cannot. Absent when the project follows the application, so a project
that has never been given a place of its own gains no line for it and an older build reads the
file unchanged (§1.1's forward-compatibility rule). Nothing is moved when the choice changes —
the frames in the old folder simply stop being addressed.

Rules, binding:
- The global cache root defaults under the user's local app-data and is configurable with a
  size budget ([13-PERFORMANCE-RULES.md](13-PERFORMANCE-RULES.md)).
- Deleting any or all of the sidecar at any time MUST be safe: Lumit rebuilds on demand.
- The project file never references sidecar contents; the sidecar is keyed by project uuid
  and content hashes.

## 4. Save, autosave, crash recovery

- **Atomic saves**: write to a temp file in the destination directory, fsync, rename over
  the target. A crash mid-save can never corrupt the previous save.
- **Autosave**: every N minutes (default 5) and before risky operations (export start,
  plugin install), rotating `<name>.autosave-<k>.lum` copies (default keep 5) in an
  `autosaves/` folder beside the project.
- **Journal recovery**: the operation journal ([03-DATA-MODEL.md](03-DATA-MODEL.md) §10) is
  appended between saves to `<global cache root>/<project-uuid>/journal/ops.jsonl` (kept out
  of the `.lum` beside the project so shared projects carry no local paths). After a crash,
  Lumit offers: last save + replayed journal (usually everything), or last save, or an
  autosave. The journal is truncated on successful save.
- Recovery is offered calmly on next launch — one dialogue, no error storm
  ([15-DESIGN.md](15-DESIGN.md) voice rules).

## 5. Presets and templates

- **Preset** (`.lumfx`): a JSON document containing an effect stack (or single effect,
  or animation) parameter tree — same conventions as project.json, shareable, importable by
  drag onto a layer.
- **Template**: an ordinary `.lum` file opened in "new from template" mode (copy, not
  edit-in-place). Community "CC packs" and project files are just these two forms.

## 6. Interchange (summary)

- AE Bridge JSON bundles import into this model — [11-AE-IMPORT.md](11-AE-IMPORT.md).
- Lottie JSON: import as comps (subset), export is a possible future.
- OpenTimelineIO: possible future for cut interchange; the Sequence layer/clip model maps
  naturally. Not v1.

## Open questions

- Zip member compression level vs stored-for-speed on large projects — measure once real
  projects exist.
- Should the journal be inside the `.lum` on save (perfect portability of undo history)
  or stay sidecar (smaller files)? Currently sidecar; undo history does not travel.
- Embedded fonts: reference-only v1 with a missing-font warning; embedding raises licensing
  questions — revisit with the text animator work.
- Autosave cadence: time-based v1; consider operation-count-based too.
