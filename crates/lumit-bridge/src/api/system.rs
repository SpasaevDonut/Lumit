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
