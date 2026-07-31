export LIBCLANG_PATH=/usr/lib/llvm18/lib
export LLVM_CONFIG_PATH=/usr/lib/llvm18/bin/llvm-config
RUSTC_WRAPPER="" cargo build
cd flutter_ui/
flutter pub get
# Run both Flutter UI and lumit-gpu on Nvidia dGPU to allow zero-copy DMA-BUF sharing on hybrid laptops.
# For AMD iGPU mode instead, use: WGPU_POWER_PREF=low flutter run
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia flutter run

