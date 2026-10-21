#!/bin/bash
set -euo pipefail

vendor_dir=$(cd "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/python-encapsulation-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# Use one real allowlisted API name with a small fixture implementation. Its
# dependency function and common global deliberately collide with the host.
cat > "$work_dir/api.c" <<'EOF'
extern int dependency_function(void);
int Py_InitializeFromConfig(void) { return dependency_function(); }
EOF
cat > "$work_dir/dependency.c" <<'EOF'
int dependency_value;
int dependency_function(void) {
    dependency_value = 7;
    return dependency_value;
}
EOF
cat > "$work_dir/main.c" <<'EOF'
extern int Py_InitializeFromConfig(void);
int dependency_value = 99;
int dependency_function(void) { return 100; }
int main(void) {
    return Py_InitializeFromConfig() == 7 && dependency_value == 99 ? 0 : 1;
}
EOF

for source in api dependency main; do
  xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.3 -fcommon \
    -c "$work_dir/$source.c" -o "$work_dir/$source.o"
done
xcrun libtool -static -o "$work_dir/input.a" \
  "$work_dir/api.o" "$work_dir/dependency.o"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.3 \
  "$work_dir/main.o" "$work_dir/input.a" -o "$work_dir/unencapsulated"
status=0
"$work_dir/unencapsulated" || status=$?
[[ "$status" == 1 ]] || {
  echo "fixture did not demonstrate the dependency collision" >&2
  exit 1
}

bash "$vendor_dir/encapsulate_python.sh" macosx 13.3 \
  "$work_dir/input.a" "$work_dir/encapsulated.a"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.3 \
  "$work_dir/main.o" "$work_dir/encapsulated.a" -o "$work_dir/encapsulated"
"$work_dir/encapsulated"
echo "Python dependency function and common-symbol isolation passed"

# A Python-private Rust personality plus host Rust, C++, and Objective-C
# personalities exceeds compact unwind's three entries. Exercise real unwinding
# and Drop cleanup on both sides of the encapsulation boundary.
cat > "$work_dir/unwind.rs" <<'EOF'
use std::sync::atomic::{AtomicUsize, Ordering};
static DROPS: AtomicUsize = AtomicUsize::new(0);
struct Guard;
impl Drop for Guard {
    fn drop(&mut self) { DROPS.fetch_add(1, Ordering::SeqCst); }
}
#[inline(never)]
fn throw() {
    let _guard = Guard;
    panic!("unwind fixture");
}
fn check() -> i32 {
    std::panic::set_hook(Box::new(|_| {}));
    DROPS.store(0, Ordering::SeqCst);
    let caught = std::panic::catch_unwind(throw).is_err();
    (caught && DROPS.load(Ordering::SeqCst) == 1) as i32
}
#[cfg(python_fixture)]
#[no_mangle]
pub extern "C" fn Py_InitializeFromConfig() -> i32 { check() }
#[cfg(not(python_fixture))]
#[no_mangle]
pub extern "C" fn host_rust_unwind() -> i32 { check() }
EOF
cat > "$work_dir/unwind.cpp" <<'EOF'
struct Guard {
    bool& dropped;
    ~Guard() { dropped = true; }
};
__attribute__((noinline)) static void raise(bool& dropped) {
    Guard guard{dropped};
    throw 7;
}
extern "C" int cpp_unwind() {
    bool dropped = false;
    try { raise(dropped); } catch (int value) { return value == 7 && dropped; }
    return 0;
}
EOF
cat > "$work_dir/unwind.m" <<'EOF'
#import <Foundation/Foundation.h>
extern int Py_InitializeFromConfig(void);
extern int host_rust_unwind(void);
extern int cpp_unwind(void);
int main(void) {
    @autoreleasepool {
        int caught = 0;
        @try { @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil]; }
        @catch (NSException *exception) { caught = [exception.name isEqualToString:@"fixture"]; }
#if HOST_RUST
        if (!host_rust_unwind()) return 1;
#endif
        return caught && cpp_unwind() && Py_InitializeFromConfig() ? 0 : 1;
    }
}
EOF
rustc=${RUSTC:-rustc}
"$rustc" --crate-type staticlib --crate-name python_unwind --cfg python_fixture \
  -C panic=unwind "$work_dir/unwind.rs" -o "$work_dir/python-unwind.a"
"$rustc" --crate-type staticlib --crate-name host_unwind \
  -C panic=unwind "$work_dir/unwind.rs" -o "$work_dir/host-unwind.a"
bash "$vendor_dir/encapsulate_python.sh" macosx 13.3 \
  "$work_dir/python-unwind.a" "$work_dir/python-unwind-encapsulated.a"
xcrun clang++ -arch arm64 -mmacosx-version-min=13.3 \
  -c "$work_dir/unwind.cpp" -o "$work_dir/cpp-unwind.o"
for mode in standalone host-first python-first; do
  libraries=("$work_dir/python-unwind-encapsulated.a")
  defines=(-DHOST_RUST=0)
  if [[ "$mode" != standalone ]]; then
    defines=(-DHOST_RUST=1)
    if [[ "$mode" == host-first ]]; then
      libraries=("$work_dir/host-unwind.a" "${libraries[@]}")
    else
      libraries+=("$work_dir/host-unwind.a")
    fi
  fi
  xcrun clang -arch arm64 -mmacosx-version-min=13.3 "${defines[@]}" \
    -fobjc-exceptions -c "$work_dir/unwind.m" -o "$work_dir/objc-unwind.o"
  xcrun clang++ -arch arm64 -mmacosx-version-min=13.3 \
    "$work_dir/objc-unwind.o" "$work_dir/cpp-unwind.o" "${libraries[@]}" \
    -framework Foundation -o "$work_dir/unwind-$mode"
  "$work_dir/unwind-$mode"
  xcrun llvm-objdump --macho --unwind-info "$work_dir/unwind-$mode" \
    > "$work_dir/unwind-info.txt"
  grep -Eq 'Number of personality functions in array: +0x3$' "$work_dir/unwind-info.txt"
done
echo "Python and host Rust, C++, and Objective-C compact unwinding passed"
