# SIGILL Investigation Report — libscrapli FFI

**Date:** June 9, 2026  
**Investigator:** GitHub Copilot (Claude Opus 4.6) with @araustin01  
**Issue Reference:** NMS-1049  
**Release under investigation:** v0.0.1-rc.21  

---

## 0. RESOLUTION (June 9, 2026) — supersedes the AVX hypothesis below

> **TL;DR — The crash is real and IS a CPU-feature mismatch, but the encoding and
> the culprit binary were both misidentified below.**
>
> 1. The faulting instruction is **AVX-512** (`vpcmpneqb`, EVEX prefix `0x62`),
>    **not** legacy AVX (VEX prefix `0xC5`/`0xC4`). Sections 3–6 only ever scanned
>    for VEX, so they found "0 AVX" and concluded the binary was clean.
> 2. The binary analyzed below (the **released** `libscrapli-x86_64-linux-gnu.so`)
>    is genuinely baseline-clean — but **it is not the binary that crashed**.
>    ksqueegee does **not** ship the released `.so`; it **rebuilds libscrapli from
>    source** and bundles its own artifact.
> 3. That rebuild (`ksqueegee/scripts/bootstrap-libscrapli.d/build.sh`) runs
>    `zig build ffi` **with no `-Dtarget` and no `-Dcpu`**, i.e. for the build
>    host's **native CPU**. On an AVX-512-capable CI host, Zig emits EVEX
>    instructions, which SIGILL on any deployment CPU lacking AVX-512.

### 0.1 Authoritative decode of the crash bytes

From the agent crash (`scrapligo v2.0.0-rc.11`, SIGILL `sigcode=2` in `cgocall`):

```
instruction bytes: 0x62 0xd3 0x75 0x08 0x3f 0x00 0x04  0x62 0xd3 0x7d 0x08 0x3f 0x4c 0x30 0xff 0x04
```

Assembled into an x86-64 object and disassembled (`objdump --triple=x86_64`):

```
62 d3 75 08 3f 00 04          vpcmpneqb (%r8), %xmm1, %k0
62 d3 7d 08 3f 4c 30 ff 04    vpcmpneqb -0x10(%r8,%rsi), %xmm0, %k1
```

`vpcmpneqb` is **AVX-512BW** (EVEX-encoded, writes a mask register `k0`/`k1`). In
x86-64 long mode the `0x62` lead byte is *unambiguously* the EVEX prefix. This is
the vectorized byte-compare that backs optimized `memchr`/`indexOfScalar`/`eql`
scans — exactly the work `ls_cli_open` does while parsing platform definitions.

### 0.2 Why the analysis below missed it

| Section 3–6 did | Why it returned a false "all clear" |
|---|---|
| Grepped `objdump` for AVX **mnemonics** and raw `0xC5`/`0xC4` (VEX) bytes | AVX-512 uses the **`0x62` (EVEX)** prefix — never searched for |
| Analyzed the **released** `.so` | The released `.so` is built by libscrapli's pipeline with `-Dtarget=x86_64-linux-gnu` ⇒ baseline ⇒ legitimately 0 SIMD-extension instructions. **The deployed agent does not use this file.** |

Re-scan of the released `.so` confirms it is pure baseline SSE2 (0 VEX, 0 EVEX,
13,879 SSE) — correct, but irrelevant to the crash.

### 0.3 The artifact that actually crashed

```
ksqueegee/.goreleaser.yml  (before-hook)
  └─ scripts/bootstrap-libscrapli.sh
       └─ bootstrap-libscrapli.d/build.sh : build_libscrapli()
            zig build ffi -Doptimize=ReleaseSafe -Ddependency-linkage=static
            # ^ NO -Dtarget / NO -Dcpu  ⇒  std.Build.standardTargetOptions
            #   resolves the NATIVE target WITH native CPU features (AVX-512)
  └─ archive bundles .libscrapli/<os>_<arch>/libscrapli.so.<ver>  → bin/
pkg/scrape/driver/scrapli.go : setBundledLibscrapliPath()
  └─ sets LIBSCRAPLI_PATH to the bundled (native-CPU) .so
scrapligo ffi.EnsureLibscrapli()
  └─ LIBSCRAPLI_PATH override ⇒ dlopen the bundled AVX-512 .so  → SIGILL
```

`libscrapli/build.zig` confirms the mechanism: `buildFFI` only uses the
hardcoded baseline `ffi_targets` list when `-Dall-targets=true`. The default
single-target path (what ksqueegee invokes) builds the **resolved native
target** — so the report's `.cpu_model = .baseline` edit to `ffi_targets` does
**not** affect ksqueegee's build.

### 0.4 Fix

Pin the CPU in `ksqueegee/scripts/bootstrap-libscrapli.d/build.sh` — keep the
native OS/ABI (so the `.so` still links against the build container's glibc) but
force the baseline CPU feature set:

```sh
zig build ffi -Dcpu=baseline -Doptimize=ReleaseSafe -Ddependency-linkage=static
```

`-Dcpu=baseline` is preferred over `-Dtarget=x86_64-linux-gnu` because it only
changes CPU features and leaves Zig's native-glibc-version detection intact (the
reason ksqueegee rebuilds in distro containers in the first place). **Applied.**

### 0.5 Validation

Same vectorizable byte-scan loop, compiled for two CPU levels:

| `-mcpu` | EVEX/AVX-512 insns | SSE insns |
|---|---|---|
| `x86_64_v4` (AVX-512 build host) | **12** | — |
| `baseline` (the fix) | **0** | 6 |

Definitive post-fix check (run on the AVX-512 CI host after rebuilding):
`objdump -d --triple=x86_64 libscrapli.so.<ver> | grep -cE 'vpcmp|%k[0-7]'`
must be **0**.

### 0.6 Status of the changes already in this working tree

- `build.zig` `.cpu_model = .baseline` on `ffi_targets` — only affects
  `-Dall-targets`; **does not fix ksqueegee.** Harmless to keep.
- `-fno-sanitize=all` on libssh2/pcre2 — addresses a *different* class (`ud2`
  SSP traps); **not this crash.** Reasonable hygiene; keep.
- `builder.sh` `-Dtarget` — fixes libscrapli's *own* Docker path; ksqueegee uses
  its own `build.sh`, so **does not fix ksqueegee** either.

### 0.7 Separate issue — the SIGABRT in the parent ticket

The ticket's original `@memcpy arguments alias` **SIGABRT** at
`ffi-root-cli.zig:289` (`ls_cli_fetch_operation`, rc.14) is a **distinct** Zig
safety panic — overlapping `@memcpy`, not a CPU-feature fault. It is being
converted to proper error returns upstream in rc.15+. Bumping the bundled
libscrapli version addresses it independently of the AVX-512 fix above.

> Everything from Section 1 onward is the original (superseded) AVX/VEX
> investigation, retained for history.

---

## 1. Problem Statement

A Go application using libscrapli via purego FFI crashes with **SIGILL** (illegal instruction, `sigcode=2` / `ILL_ILLOPN`) when calling `ls_cli_open`. The crash occurs on Linux x86_64 machines — specifically on CPUs that may lack AVX support.

The initial theory was that VEX-encoded AVX instructions (e.g., `vmovups` with byte prefix `0xC5 0xF8 0x10`) were being emitted by Zig's integrated Clang compiler when building C dependencies (libssh2, pcre2), and these instructions would crash on non-AVX-capable x86_64 CPUs.

---

## 2. Architecture & Build Pipeline

### 2.1 Library Stack
- **libscrapli**: Zig 0.16.0 network automation library
- **C dependencies** (statically linked): OpenSSL 3.4.0, libssh2 1.11.1, pcre2
- **FFI consumers**: Go (via `ebitengine/purego@v0.10.1`), Python
- **Output**: `libscrapli.so` shared library with C ABI exports

### 2.2 Release Build Path (GitHub Actions)
```
release_linux.yaml → make release-linux-static TARGET=x86_64-linux-gnu
    → zig build ffi -Doptimize=ReleaseSafe -Ddependency-linkage=static -Dtarget=x86_64-linux-gnu
```
- Runs on `ubuntu-latest` (x86_64 runners)
- Uses `mlugg/setup-zig@v2` with Zig 0.16.0
- The `-Dtarget=x86_64-linux-gnu` flag is passed, making Zig treat this as **cross-compilation**

### 2.3 Docker Build Path (builder.sh — alternative flow)
```
builder.sh → zig build (OpenSSL pre-build, NO -Dtarget) → zig build -Dtarget=... --release
```
- Used via `builder.Dockerfile` (Debian bookworm-slim)
- **Bug:** The OpenSSL pre-build step (`cd lib/openssl && zig build`) does NOT pass `-Dtarget`, so it builds for the native host CPU

### 2.4 Key Zig Build Behavior
When `-Dtarget=x86_64-linux-gnu` is specified:
- Zig treats it as **cross-compilation**, even on x86_64 hosts
- Cross-compilation defaults to **baseline** CPU features (SSE2 only, no AVX)
- This means sanitizer instrumentation and codegen cannot emit AVX instructions

When no `-Dtarget` is specified (native build):
- Zig detects the host CPU and enables all supported features (including AVX/AVX2 on modern CPUs)
- In `ReleaseSafe` mode, sanitizer instrumentation code may use VEX-encoded instructions

---

## 3. Investigation Steps & Results

### 3.1 Initial Hypothesis: AVX in Sanitizer Instrumentation

**Theory:** Zig's `ReleaseSafe` mode adds runtime safety checks (UBSan-like). When compiling C code natively on AVX-capable CPUs, the sanitizer instrumentation emits VEX-encoded (AVX) instructions. When deployed on non-AVX CPUs → SIGILL.

**Evidence supporting the theory:**
- OpenSSL's `build.zig` already has `-fno-sanitize=all` with the comment:
  > *"it seems that we need to pass this flag to disable runtime safety checks that seem to get triggered when calling things over the ffi layer bits... zig things would work fine without this but when calling from py/go we would get illegal instructions."*
- libssh2 and pcre2 did NOT have this flag

**Action taken:** Added `-fno-sanitize=all` to libssh2 and pcre2 build configs to match OpenSSL's precedent.

### 3.2 Proposed Fix (4 files)

| File | Change | Rationale |
|---|---|---|
| `build.zig` (lines 15-17) | Added `.cpu_model = .baseline` to x86_64 `ffi_targets` | Pins `--all-targets` builds to baseline x86_64 (no AVX) |
| `build/builder.sh` (line 23) | Changed `zig build` → `zig build "-Dtarget=${LIBSCRAPLI_TARGET}"` | Ensures OpenSSL pre-build also targets the correct architecture |
| `lib/libssh2/build.zig` (line 103) | Added `"-fno-sanitize=all"` to C flags | Matches OpenSSL's existing fix for the same issue |
| `lib/pcre2/build.zig` (line 120) | Added `"-fno-sanitize=all"` to C flags | Matches OpenSSL's existing fix for the same issue |

**Build verification:** The fix compiles successfully (`zig build ffi -Dtarget=x86_64-linux-gnu --release=safe`).

### 3.3 Verification Attempt: Cross-Compile Disassembly (macOS aarch64 → x86_64)

**Method:** Built `libscrapli.so` on macOS M1 Pro targeting `x86_64-linux-gnu`, then disassembled with `objdump -d --triple=x86_64` and grepped for AVX mnemonics.

**Result:** **0 AVX instructions** in both FIXED and UNFIXED versions.

**Why:** Cross-compiling from aarch64 → x86_64 inherently uses baseline CPU features. This environment **cannot reproduce the bug** — it will never emit AVX regardless of our changes.

### 3.4 Verification Attempt: Docker x86_64 Emulation (Rosetta 2)

**Method:** Attempted full build inside Docker with `--platform linux/amd64` on macOS M1 Pro.

**Result:** **Failed / impractical** for two reasons:
1. **Performance:** Full build under Rosetta x86_64 emulation is prohibitively slow (did not complete after extended waiting)
2. **CPU flags:** Rosetta's `VirtualApple @ 2.50GHz` reports `avx avx2` in CPU flags, meaning:
   - The compiler would still "see" an AVX-capable CPU and potentially emit AVX
   - Runtime testing would succeed (Rosetta can execute AVX instructions)
   - This environment cannot distinguish buggy from fixed binaries

### 3.5 Critical Finding: Released Binary Analysis

**Method:** Downloaded the actual released `libscrapli-x86_64-linux-gnu.so.0.0.1-rc.21` (13 MB, built on GitHub Actions `ubuntu-latest` x86_64 runner) and disassembled it.

**Result:**
```
File: libscrapli-x86_64-released.so
Disassembly lines: 863,340
AVX instructions (objdump mnemonic grep): 0
```

**Raw byte scan results (Python ELF parser):**
- Raw `0xC5` bytes in .text: 4,070 (most are NOT VEX prefixes — false positives from immediate operands)
- Known VEX instruction patterns (3-byte signatures): **0**
- Broader heuristic (2-byte VEX with valid opcodes + 3-byte VEX with valid map): 783 candidates
  - However, these are largely false positives since the authoritative disassembler (`objdump`) found **zero** AVX mnemonics

### 3.6 Conclusion from Binary Analysis

**The released v0.0.1-rc.21 binary contains ZERO AVX instructions.**

This is because the release pipeline already passes `-Dtarget=x86_64-linux-gnu`, which makes Zig cross-compile with baseline features even on x86_64 CI runners.

**This means the original SIGILL crash is NOT caused by AVX instructions in the released `.so`.** The root cause must be something else.

---

## 4. Current State of Changes

The working tree currently has all 4 changes applied (unstashed). Full diff:

```diff
# build.zig — pin x86_64 ffi_targets to baseline CPU
-    .{ .cpu_arch = .x86_64, .os_tag = .macos },
-    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
-    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
+    .{ .cpu_arch = .x86_64, .os_tag = .macos, .cpu_model = .baseline },
+    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .cpu_model = .baseline },
+    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl, .cpu_model = .baseline },

# build/builder.sh — pass -Dtarget to OpenSSL pre-build
-zig build
+zig build "-Dtarget=${LIBSCRAPLI_TARGET}"

# lib/libssh2/build.zig — disable sanitizers for C code
+                "-fno-sanitize=all",

# lib/pcre2/build.zig — disable sanitizers for C code
+                "-fno-sanitize=all",
```

### 4.1 Are these changes still valuable?
- **`builder.sh` fix:** Yes — the Docker build path has a real bug (OpenSSL pre-build uses native CPU). If builder.sh is ever used on x86_64 with AVX, this would cause issues.
- **`-fno-sanitize=all` for libssh2/pcre2:** Yes as defense-in-depth and consistency with OpenSSL. Reduces risk if native builds are ever used.
- **`.cpu_model = .baseline`:** Yes for the `--all-targets` path, which currently doesn't pass `-Dtarget` and could theoretically use native features.
- **Do they fix the reported SIGILL?** **Unlikely**, since the released binary already has 0 AVX instructions.

---

## 5. What We Know About the Crash

### 5.1 The crash occurs at `ls_cli_open`
- This is the FFI entry point for opening a CLI connection
- It goes through `FfiDriver.open()` before any operation dequeue happens
- PR #6's `dequeueOperation` fix is for a different bug (panic when fetching sizes for incomplete operations)

### 5.2 The crash signal
- **SIGILL** with `sigcode=2` (`ILL_ILLOPN` = illegal operand)
- This can be caused by:
  1. ~~AVX instructions on non-AVX CPUs~~ (disproven for released binaries)
  2. **Misaligned SSE operations** (SSE `movaps` requires 16-byte alignment; misalignment → SIGILL on some CPUs)
  3. **Stack corruption** causing execution to jump into data or misaligned code
  4. **Undefined behavior in C code** triggered through FFI calling conventions
  5. **Zig safety checks** in `ReleaseSafe` mode that deliberately emit `ud2` (illegal instruction) to trap on safety violations (bounds checks, null pointer unwraps, integer overflow)

### 5.3 Key OpenSSL comment
The existing comment in `lib/openssl/build.zig` is highly relevant:
> *"it seems that we need to pass this flag to disable runtime safety checks that seem to get triggered when calling things over the ffi layer bits... zig things would work fine without this but when calling from py/go we would get illegal instructions."*

This says "illegal instructions" — not specifically AVX. In Zig's `ReleaseSafe` mode, safety check failures emit `ud2` (0x0F 0x0B), which causes SIGILL. The OpenSSL developers found that sanitizer checks were failing when called via FFI and fixed it with `-fno-sanitize=all`.

---

### 5.4 ud2 Scan of Released Binary

Scanned the released v0.0.1-rc.21 binary for `ud2` instructions (the x86 "undefined instruction" that Zig/UBSan emits for safety check failures):

```
Total ud2 instructions: 5
```

All 5 are in **compiler-rt stack-smashing protection (SSP) functions**:
- `compiler_rt.ssp.__memset_chk` — buffer overflow check for memset
- `compiler_rt.ssp.__memmove_chk` — buffer overflow check for memmove
- `compiler_rt.ssp.__strncpy_chk` — buffer overflow check for strncpy
- `compiler_rt.ssp.__chk_fail` — generic stack protection failure handler
- One additional in a memcpy-related path

These are **intentional traps** — they fire when a buffer overflow is detected at runtime. If FFI calls from Go trigger a buffer size mismatch (e.g., Go passes a smaller buffer than Zig expects), these `ud2` instructions would fire and produce SIGILL with `sigcode=2`.

**This is a strong candidate for the root cause** — especially since the OpenSSL comment specifically mentions "illegal instructions" when calling from Go/Python over FFI.

---

## 6. Follow-Up Theories & Next Steps

### Theory A: Compiler-RT SSP / Sanitizer `ud2` Traps (STRONGEST — supported by evidence)

Zig's ReleaseSafe mode compiles C code with safety checks including stack-smashing protection (SSP). The released binary contains 5 `ud2` instructions, ALL in `compiler_rt.ssp.__*_chk` functions. These are fortified versions of `memset`, `memmove`, `strncpy` that validate buffer sizes at runtime. If the buffer size check fails → `ud2` → SIGILL.

The OpenSSL comment explicitly describes this: sanitizer checks *"get triggered when calling things over the ffi layer."* OpenSSL already has `-fno-sanitize=all` applied and works. libssh2 and pcre2 do NOT (until our fix).

**Why this could happen to libssh2/pcre2:**
- FFI calling conventions may pass values that violate fortified function size assumptions
- Go/purego may allocate buffers with different size metadata than Zig's compiler-rt expects
- The `__*_chk` functions compare actual buffer size against the operation size; any mismatch triggers `ud2`
- `__memset_chk`, `__memmove_chk` are called frequently in libssh2 (crypto operations, session handling) and pcre2 (pattern compilation, matching)

**Status:** Our fix (`-fno-sanitize=all` on libssh2/pcre2) directly addresses this by removing the fortified function calls. This is the same fix that was already applied to OpenSSL for the same reason.

**How to definitively verify:**
1. ✅ Already scanned: 5 `ud2` in `compiler_rt.ssp` functions confirmed
2. Build with the fix and test on the actual crashing hardware
3. Alternatively, build a `-Doptimize=ReleaseFast` (no safety) version to see if crash disappears

### Theory B: Zig Safety Checks on Zig Code

Even with C code sanitizers disabled, Zig's own `ReleaseSafe` codegen includes safety checks. If a safety check fails in Zig code (e.g., in `ffi-driver.zig`, `session.zig`, `transport-ssh2.zig`), it emits `ud2`.

**How to verify:**
1. Get the exact crash address from the original stacktrace
2. Map it to a function using `objdump` + symbol table
3. Check if the crash address corresponds to a `ud2` instruction in Zig-generated code

### Theory C: Alignment Issues in FFI Memory

Go's memory model and Zig's may disagree on struct alignment. When Go passes a pointer via purego that doesn't meet Zig's alignment requirements, `movaps` (aligned SSE move) could SIGILL.

**How to verify:**
1. Check if purego marshals pointers/structs with correct alignment
2. Look for `movaps` instructions near the crash site (requires exact crash address)

### Theory D: Race Condition / Concurrent Access

The PR #6 description mentions "under heavy load" causing panics. The global `var threaded: std.Io.Threaded = .init_single_threaded` in `ffi-common.zig` is shared across all FfiDriver instances. Under concurrent access, memory corruption could cause jumps to invalid code.

**How to verify:**
1. Check if multiple goroutines call FFI functions concurrently
2. Review thread-safety of the Io.Threaded singleton
3. Test with `-fsanitize=thread` (TSan) in a debug build

### Theory E: Specific CPU Microarchitecture Bug

Some older x86_64 CPUs have known errata. The crash may only happen on specific CPU models.

**How to verify:**
1. Collect `/proc/cpuinfo` from the crashing machine
2. Compare with machines where it works
3. Check if the CPU model has known errata

---

## 7. Recommended Next Steps (Priority Order)

1. **Get the exact crash address and full stacktrace** — map it to a symbol/function using the released .so's debug info
2. **Scan the released .so for `ud2` instructions** — `objdump -d --triple=x86_64 libscrapli-x86_64-released.so | grep 'ud2'` to count Zig/UBSan safety traps
3. **Apply the `-fno-sanitize=all` fix to libssh2/pcre2** anyway — it's correct, consistent with OpenSSL, and eliminates one class of crashes
4. **Test the fix on the actual crashing hardware** — the only definitive verification
5. **If the crash persists after the fix**, investigate Zig-side safety checks by building with `-Doptimize=ReleaseFast` (no safety checks) as a diagnostic test
6. **Collect CPU info** from the crashing machine(s) to rule out hardware-specific issues

---

## 8. Files of Interest

| File | Role |
|---|---|
| `build.zig` | Main build config, `ffi_targets` list, `buildFFI`/`buildFFITarget` |
| `build/builder.sh` | Docker-based build script (has OpenSSL pre-build bug) |
| `build/builder.Dockerfile` | Docker build environment definition |
| `.github/workflows/release_linux.yaml` | GitHub Actions release workflow |
| `Makefile` (lines 212-219) | `release-linux-static` target definition |
| `lib/openssl/build.zig` | OpenSSL build config (has `-fno-sanitize=all` with comment) |
| `lib/libssh2/build.zig` | libssh2 build config (NOW has `-fno-sanitize=all`) |
| `lib/pcre2/build.zig` | pcre2 build config (NOW has `-fno-sanitize=all`) |
| `src/ffi-common.zig` | FFI globals, allocator, `Io.Threaded` singleton |
| `src/ffi-driver.zig` | FFI driver, `dequeueOperation`, operation queue |
| `src/ffi-root-cli.zig` | CLI FFI exports (`ls_cli_open`, etc.) |
