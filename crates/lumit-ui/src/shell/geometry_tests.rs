//! VRAM-eviction and export-filename tests for the shell.
//!
//! The draw-building half of this file went to `lumit-render` with the pixel
//! pass (K-178); what stays is genuinely the shell's — the egui VRAM tier and
//! the export filename template.

use super::*;
use lumit_core::model::Document;

// The VRAM tier's eviction policy (docs/06 §5): oldest entries drop until
// the incoming frame fits the byte budget; an oversize frame clears all.
#[test]
fn vram_eviction_drops_oldest_until_the_budget_fits() {
    // 3 entries of 100 bytes under a 350 cap: adding 100 evicts nothing.
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 100, 350), 1);
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 40, 350), 0);
    // Adding a huge frame drops everything (and still admits it).
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 1000, 350), 3);
    // Empty tier: nothing to drop whatever the sizes.
    assert_eq!(vram_evict_count(&[], 0, 500, 350), 0);
}

// `GpuViewer::set_vram_cap` (Settings → Performance, K-100) reuses this
// same helper with nothing incoming (`incoming = 0`) to evict down to a
// freshly lowered budget.
#[test]
fn vram_evict_count_drops_to_fit_a_lowered_cap_with_nothing_incoming() {
    // 3 entries of 100 bytes, cap dropped to 150: two must go.
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 0, 150), 2);
    // Cap dropped below a single entry's size: everything goes.
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 0, 50), 3);
    // Cap raised (or unchanged): nothing is evicted.
    assert_eq!(vram_evict_count(&[100, 100, 100], 300, 0, 1024), 0);
}

// The byte-identical-default-behaviour regression test: no template (or
// a blank one) must reproduce `preset.default_file_name()` exactly, for
// more than one preset, so an existing install's suggested export name
// never shifts just because the setting now exists.
#[test]
fn no_template_reproduces_the_presets_own_default_file_name() {
    use lumit_render::export::ExportPreset;
    for preset in [ExportPreset::Custom, ExportPreset::Youtube4k60] {
        assert_eq!(
            export_default_file_name(preset, "My Comp", None),
            preset.default_file_name()
        );
        // A template that's blank once trimmed is the same as None.
        assert_eq!(
            export_default_file_name(preset, "My Comp", Some("   ")),
            preset.default_file_name()
        );
    }
}

#[test]
fn template_substitutes_comp_and_preset_tokens_and_ends_in_mp4() {
    use lumit_render::export::ExportPreset;
    let name = export_default_file_name(
        ExportPreset::Youtube1080p60,
        "My Comp",
        Some("{comp}-{preset}"),
    );
    assert_eq!(name, "My Comp-youtube-1080p60.mp4");
}

#[test]
fn template_expands_the_date_token_to_todays_utc_date() {
    let name = render_filename_template("{date}", "comp", "stem");
    assert_eq!(name, format!("{}.mp4", today_utc_date()));
}

// A comp name is free text: the user can put a `:` or `/` in it, and the
// result must be sanitised, not passed through raw into a path.
#[test]
fn illegal_windows_filename_characters_are_sanitised_not_passed_through() {
    let name = render_filename_template("{comp}", "My:Comp/Name?", "stem");
    for illegal in ['<', '>', ':', '"', '/', '\\', '|', '?', '*'] {
        assert!(
            !name.contains(illegal),
            "{name:?} still contains illegal character {illegal:?}"
        );
    }
    assert!(name.ends_with(".mp4"));
}

#[test]
fn civil_from_days_matches_known_calendar_dates() {
    // The Unix epoch itself — proves the +719468 day-count offset lines
    // up, the most bug-prone constant in Hinnant's algorithm.
    assert_eq!(civil_from_days(0), (1970, 1, 1));
    // January has 31 days: day index 31 (0-based) is the first of Feb.
    assert_eq!(civil_from_days(31), (1970, 2, 1));
    // 1970 is not a leap year (365 days): day 365 rolls into 1971.
    assert_eq!(civil_from_days(365), (1971, 1, 1));
}

/// docs/07 §3.3 *Find missing footage*: the missing-only filter shows exactly
/// the broken items and the folders leading to them, narrows further with the
/// search text, and — unlike the plain search — is never relaxed by a folder
/// whose own name happens to match.
#[test]
fn missing_only_filter_keeps_the_path_to_broken_items() {
    use crate::shell::panels::{subtree_matches, ProjectFilter};
    use lumit_core::model::{Folder, FootageItem, MediaRef, ProjectItem};
    use std::collections::HashSet;

    let footage = |name: &str| {
        ProjectItem::Footage(FootageItem {
            id: uuid::Uuid::now_v7(),
            name: name.into(),
            extra: serde_json::Map::new(),
            media: MediaRef {
                relative_path: name.into(),
                absolute_path: String::new(),
                fingerprint: None,
                extra: serde_json::Map::new(),
            },
        })
    };
    let mut doc = Document::new();
    let (gone, here) = (footage("beach gone.mp4"), footage("beach here.mp4"));
    let (gone_id, here_id) = (gone.id(), here.id());
    let folder_id = uuid::Uuid::now_v7();
    doc.items.push(gone);
    doc.items.push(here);
    doc.items.push(ProjectItem::Folder(Folder {
        id: folder_id,
        name: "Rushes".into(),
        children: vec![gone_id, here_id],
        extra: serde_json::Map::new(),
    }));

    let missing: HashSet<uuid::Uuid> = [gone_id].into_iter().collect();
    let none: HashSet<uuid::Uuid> = HashSet::new();
    let shows = |f: &ProjectFilter, id| subtree_matches(&doc, id, f, &mut Vec::new());

    // Missing-only: the broken clip and the folder that leads to it; not the
    // healthy sibling.
    let f = ProjectFilter {
        needle: "",
        missing_only: true,
        missing: &missing,
    };
    assert!(shows(&f, gone_id), "the missing clip shows");
    assert!(!shows(&f, here_id), "a healthy clip is filtered out");
    assert!(shows(&f, folder_id), "its folder shows, as the path to it");

    // The folder's own name matching must NOT reveal healthy children — every
    // visible row under this filter is something to fix.
    let f = ProjectFilter {
        needle: "rushes",
        missing_only: true,
        missing: &missing,
    };
    assert!(
        !f.matches(doc.item(here_id).unwrap()),
        "healthy stays hidden"
    );

    // The two filters narrow together.
    let f = ProjectFilter {
        needle: "gone",
        missing_only: true,
        missing: &missing,
    };
    assert!(shows(&f, gone_id));
    let f = ProjectFilter {
        needle: "nothing-like-this",
        missing_only: true,
        missing: &missing,
    };
    assert!(!shows(&f, folder_id), "text and missing must BOTH match");

    // Nothing missing: the filter empties the panel (the calm note's case),
    // while the plain search is unaffected by it.
    let f = ProjectFilter {
        needle: "",
        missing_only: true,
        missing: &none,
    };
    assert!(!shows(&f, folder_id));
    let f = ProjectFilter {
        needle: "beach",
        missing_only: false,
        missing: &none,
    };
    assert!(
        shows(&f, gone_id) && shows(&f, here_id),
        "search unaffected"
    );
}
