//! What the machine has, for the settings that spend it (K-194).
//!
//! The cache budgets in Settings → Performance are typed numbers now rather
//! than a pick from a fixed list, so they need a real ceiling: asking for more
//! memory than the machine owns is not a setting, it is a way to make the
//! session swap. Both answers are **bytes, or 0 for "not known here"** — the
//! frontend falls back to its own documented ceiling on 0 rather than
//! pretending, so a platform without an implementation is honest rather than
//! wrong.
//!
//! Windows is the shipped target (K-033), but installed RAM is answerable on
//! every supported desktop target (K-082), so all three answer it (K-204):
//! `GlobalMemoryStatusEx` on Windows, `MemTotal:` from `/proc/meminfo` on
//! Linux, and the `hw.memsize` sysctl on macOS. Windows and macOS report the
//! installed total; Linux's `MemTotal` is *usable* RAM, which excludes what
//! firmware and an integrated GPU reserved before the kernel booted (about
//! 15.5 GB on a 16 GB host). That errs low, which is the safe direction for a
//! budget ceiling — the same choice `video_memory_bytes` makes below.
//!
//! Video memory stays Windows-only: the first DXGI adapter's dedicated video
//! memory, with 0 elsewhere.

use flutter_rust_bridge::frb;

/// The machine's installed memory in bytes, or 0 where it cannot be asked.
#[frb(sync)]
pub fn system_memory_bytes() -> u64 {
    #[cfg(windows)]
    {
        use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut status = MEMORYSTATUSEX {
            dwLength: u32::try_from(std::mem::size_of::<MEMORYSTATUSEX>()).unwrap_or(0),
            ..Default::default()
        };
        // SAFETY: `status` is a correctly sized, zeroed MEMORYSTATUSEX with
        // its `dwLength` set, which is the whole of this call's contract.
        if unsafe { GlobalMemoryStatusEx(&mut status) }.is_ok() {
            return status.ullTotalPhys;
        }
        0
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(meminfo) = std::fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if line.starts_with("MemTotal:") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        if let Ok(kb) = parts[1].parse::<u64>() {
                            return kb * 1024;
                        }
                    }
                }
            }
        }
        0
    }
    #[cfg(target_os = "macos")]
    {
        extern "C" {
            fn sysctlbyname(
                name: *const std::os::raw::c_char,
                oldp: *mut std::os::raw::c_void,
                oldlenp: *mut usize,
                newp: *mut std::os::raw::c_void,
                newlen: usize,
            ) -> std::os::raw::c_int;
        }

        let mut memsize: u64 = 0;
        let mut len = std::mem::size_of::<u64>();
        let name = c"hw.memsize";
        // SAFETY: `name` is a NUL-terminated literal that outlives the call;
        // `memsize` is a zeroed u64 and `len` its size, which matches
        // `hw.memsize`'s uint64_t, so sysctl has room for exactly what it
        // writes; `newp`/`newlen` are the documented null/0 for a read. The
        // return code is checked before `memsize` is trusted.
        let ret = unsafe {
            sysctlbyname(
                name.as_ptr(),
                &mut memsize as *mut _ as *mut _,
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if ret == 0 && memsize > 0 {
            return memsize;
        }
        0
    }
    #[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
    {
        0
    }
}

/// The primary adapter's dedicated video memory in bytes, or 0 where it
/// cannot be asked.
///
/// The *first* adapter DXGI enumerates, which is the one the renderer takes
/// too. A machine with a discrete card behind an integrated one would report
/// the integrated adapter's memory; that is a smaller ceiling than the truth,
/// which errs the safe way for a budget.
#[frb(sync)]
pub fn video_memory_bytes() -> u64 {
    #[cfg(windows)]
    {
        use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter, IDXGIFactory1};
        // SAFETY: both calls are plain COM creation/enumeration, and every
        // result is checked before it is read.
        unsafe {
            let Ok(factory) = CreateDXGIFactory1::<IDXGIFactory1>() else {
                return 0;
            };
            let Ok(adapter) = factory.EnumAdapters(0) else {
                return 0;
            };
            let adapter: IDXGIAdapter = adapter;
            let Ok(desc) = adapter.GetDesc() else {
                return 0;
            };
            u64::try_from(desc.DedicatedVideoMemory).unwrap_or(0)
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// Where the pointer was when a drag took hold of it, for the tools that hold
/// it still (K-230).
///
/// **In plain terms.** Dragging a camera about is not a gesture with a *place*
/// — nothing on the picture is being aimed at, only the movement matters — so
/// the pointer running off the edge of the picture, and eventually off the edge
/// of the screen, is pure loss: the drag stops when the pointer runs out of
/// desk. Every 3D application answers this the same way: the pointer is pinned
/// where it was pressed and only its *movement* is read, and it reappears where
/// it started when the button comes up.
///
/// Windows has no "lock the pointer" call, so this is the way it is done
/// everywhere: remember where it was, and put it back after each movement.
/// Putting it back is itself a movement, which the frontend recognises and
/// ignores (see the camera tools' layer).
static FROZEN_CURSOR: std::sync::Mutex<Option<(i32, i32)>> = std::sync::Mutex::new(None);

/// Remember where the pointer is, and say whether it could be — a platform
/// with no implementation answers `false`, and the frontend then simply lets
/// the pointer travel as it always did.
#[frb(sync)]
pub fn freeze_cursor() -> bool {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::POINT;
        use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
        let mut point = POINT::default();
        // SAFETY: `point` is a live, correctly sized POINT; the call fills it.
        if unsafe { GetCursorPos(&mut point) }.is_err() {
            return false;
        }
        let Ok(mut held) = FROZEN_CURSOR.lock() else {
            return false;
        };
        *held = Some((point.x, point.y));
        true
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Put the pointer back where [freeze_cursor] left it. Nothing at all when
/// nothing is frozen, so an extra call is harmless.
#[frb(sync)]
pub fn restore_frozen_cursor() {
    #[cfg(windows)]
    {
        use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;
        let Ok(held) = FROZEN_CURSOR.lock() else {
            return;
        };
        if let Some((x, y)) = *held {
            // SAFETY: a plain call with two integers; a refusal (a locked
            // desktop, another window holding the pointer) is not an error
            // worth acting on — the drag carries on either way.
            let _ = unsafe { SetCursorPos(x, y) };
        }
    }
}

/// Let the pointer go again, at the end of the drag.
#[frb(sync)]
pub fn thaw_cursor() {
    if let Ok(mut held) = FROZEN_CURSOR.lock() {
        *held = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Freezing and thawing must be safe to call in any order, and thawing must
    /// actually let go — a restore after it moves nothing, which is what keeps a
    /// drag that ended from dragging the pointer back later.
    ///
    /// The pointer is never *moved* here: `restore_frozen_cursor` with nothing
    /// frozen is by construction a no-op, and a test that warped the developer's
    /// mouse would be a rude test.
    #[test]
    fn thawing_lets_the_pointer_go() {
        freeze_cursor();
        thaw_cursor();
        assert!(
            FROZEN_CURSOR
                .lock()
                .map(|held| held.is_none())
                .unwrap_or(false),
            "thawing leaves nothing to restore to"
        );
        restore_frozen_cursor();
    }

    /// A platform with no implementation answers `false` rather than pretending,
    /// which is what lets the camera drag fall back to reading movement between
    /// events instead of measuring against an anchor that is not being held.
    #[test]
    fn freezing_says_whether_it_worked() {
        let held = freeze_cursor();
        assert_eq!(held, cfg!(windows));
        thaw_cursor();
    }
}
