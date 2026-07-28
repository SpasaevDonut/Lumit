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
//! Windows is the shipped target (K-033) and is the only one implemented:
//! `GlobalMemoryStatusEx` for installed RAM, and the first DXGI adapter's
//! dedicated video memory for VRAM.

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
    #[cfg(not(windows))]
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
