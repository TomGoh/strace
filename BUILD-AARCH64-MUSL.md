# Building strace for aarch64-linux-musl

This document describes how to cross-compile strace for aarch64 architecture with musl libc support.

## Quick Start (Automated Build)

For a fully automated build, use the provided script:

```bash
./build-aarch64-musl.sh
```

This script will:
- Check for aarch64-linux-musl-gcc
- Install all required packages (autoconf, automake, etc.)
- Apply the musl compatibility fix
- Generate the configure script
- Configure and compile strace
- Display the final binary location and information

For manual build instructions, continue reading below.

---

## Manual Build Instructions

### Prerequisites

- `aarch64-linux-musl-gcc` cross-compiler toolchain
- Autotools (autoconf, automake)
- Basic build tools (make, etc.)

Verify the cross-compiler is available:
```bash
which aarch64-linux-musl-gcc
# Should output: /opt/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc (or similar)
```

## Build Steps

### 1. Generate Configure Script

If you're building from a git checkout or the configure script doesn't exist:

```bash
./bootstrap
```

This generates the `configure` script and other build files from `configure.ac`.

### 2. Apply musl Compatibility Fix

There's a known issue with header conflicts between musl libc and Linux kernel headers on aarch64. Apply this fix to `src/ptrace.h`:

Find this section (around line 17-33):
```c
#ifndef STRACE_PTRACE_H
# define STRACE_PTRACE_H

# include <stdint.h>
# include <sys/ptrace.h>

# ifdef HAVE_STRUCT_IA64_FPREG
#  define ia64_fpreg XXX_ia64_fpreg
# endif
# ifdef HAVE_STRUCT_PT_ALL_USER_REGS
#  define pt_all_user_regs XXX_pt_all_user_regs
# endif
# ifdef HAVE_STRUCT_PTRACE_PEEKSIGINFO_ARGS
#  define ptrace_peeksiginfo_args XXX_ptrace_peeksiginfo_args
# endif

# include <linux/ptrace.h>
```

And modify it to:
```c
#ifndef STRACE_PTRACE_H
# define STRACE_PTRACE_H

# include <stdint.h>
# include <sys/ptrace.h>

# ifdef HAVE_STRUCT_IA64_FPREG
#  define ia64_fpreg XXX_ia64_fpreg
# endif
# ifdef HAVE_STRUCT_PT_ALL_USER_REGS
#  define pt_all_user_regs XXX_pt_all_user_regs
# endif
# ifdef HAVE_STRUCT_PTRACE_PEEKSIGINFO_ARGS
#  define ptrace_peeksiginfo_args XXX_ptrace_peeksiginfo_args
# endif

/* Workaround for musl + linux headers conflict on aarch64 */
# if defined(__aarch64__)
#  define sigcontext __kernel_sigcontext
#  define _aarch64_ctx __kernel_aarch64_ctx
#  define fpsimd_context __kernel_fpsimd_context
#  define esr_context __kernel_esr_context
#  define extra_context __kernel_extra_context
#  define sve_context __kernel_sve_context
# endif

# include <linux/ptrace.h>

# if defined(__aarch64__)
#  undef sigcontext
#  undef _aarch64_ctx
#  undef fpsimd_context
#  undef esr_context
#  undef extra_context
#  undef sve_context
# endif
```

This prevents structure redefinition errors by temporarily renaming kernel structures before including `<linux/ptrace.h>`.

### 3. Configure the Build

**For custom OS deployment (recommended - static binary):**
```bash
./configure \
    --host=aarch64-linux-musl \
    CC=aarch64-linux-musl-gcc \
    --enable-mpers=no \
    LDFLAGS="-static"
```

**For systems with musl already installed (dynamic binary):**
```bash
./configure \
    --host=aarch64-linux-musl \
    CC=aarch64-linux-musl-gcc \
    --enable-mpers=no
```

**Configuration flags explained:**
- `--host=aarch64-linux-musl`: Target platform (aarch64 with musl libc)
- `CC=aarch64-linux-musl-gcc`: Use the musl cross-compiler
- `--enable-mpers=no`: Disable multi-personality support (not needed for single-architecture builds)
- `LDFLAGS="-static"`: Create a static binary with no external dependencies (recommended for custom OS)

### 4. Compile

```bash
make -j$(nproc)
```

This will compile strace using all available CPU cores.

### 5. Verify the Binary

```bash
ls -lh src/strace
file src/strace
```

**Expected output (static binary):**
```
-rwxr-xr-x 1 user user 7.8M Oct 31 15:44 src/strace
src/strace: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV),
statically linked, with debug_info, not stripped
```

**Expected output (dynamic binary):**
```
-rwxr-xr-x 1 user user 7.5M Oct 31 15:29 src/strace
src/strace: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV),
dynamically linked, interpreter /lib/ld-musl-aarch64.so.1,
with debug_info, not stripped
```

**Static vs Dynamic:**
- **Static binary**: No external dependencies, works on any aarch64 Linux system, slightly larger (~7.8MB)
- **Dynamic binary**: Requires musl libc on target system, slightly smaller (~7.5MB)

### 6. Optional: Strip Debug Symbols

To reduce binary size for deployment:

```bash
aarch64-linux-musl-strip src/strace
```

This reduces the size from ~7.5MB to ~2-3MB.

### For Testing on Ubuntu aarch64

If your build system is already aarch64 with musl support:

```bash
./src/strace --version
./src/strace ls -la
```

## Usage Examples

### Basic Tracing
```bash
# Trace a command
strace ls -la

# Save output to file
strace -o trace.log ls -la
```

### Filter System Calls
```bash
# Trace only file operations
strace -e trace=file ls -la

# Trace only open/read/write
strace -e trace=open,read,write cat /etc/hostname

# Trace network operations
strace -e trace=network nc -l 8080
```

### Attach to Running Process
```bash
# Find process ID
ps aux | grep myapp

# Attach to it
strace -p <PID>
```

### Performance Analysis
```bash
# Show time spent in each syscall
strace -T ls -la

# Show relative timestamps
strace -r ls -la

# Show absolute timestamps
strace -tt ls -la

# Summary statistics
strace -c ls -la
```

### Follow Child Processes
```bash
# Trace parent and all children
strace -f bash -c "ls | wc -l"

# Save each process to separate file
strace -ff -o trace.log bash -c "ls | wc -l"
```

## Troubleshooting

### Problem: "No such file or directory" when running binary

**Cause**: The musl dynamic linker is not available on the target system (only affects dynamic binaries).

**Solution**: Build a static binary instead (recommended for custom OS):
```bash
./configure --host=aarch64-linux-musl CC=aarch64-linux-musl-gcc --enable-mpers=no LDFLAGS="-static"
make clean && make -j$(nproc)
```

Or use the automated script:
```bash
./build-aarch64-musl.sh
```

Alternatively, if you prefer a dynamic binary, install musl on the target system:
```bash
ls -l /lib/ld-musl-aarch64.so.1
```

### Problem: Compilation errors about structure redefinitions

**Cause**: Header conflicts between musl and kernel headers (especially on aarch64).

**Solution**: Apply the fix in `src/ptrace.h` as described in Step 2 above.

### Problem: "configure: error: C compiler cannot create executables"

**Cause**: Cross-compiler not found or not in PATH.

**Solution**:
```bash
# Verify compiler location
which aarch64-linux-musl-gcc

# If not found, add to PATH
export PATH="/opt/aarch64-linux-musl-cross/bin:$PATH"
```

## Clean Build

If you need to start over:

```bash
make distclean
./bootstrap
# Then repeat steps 3-4
```

## Additional Resources

- strace homepage: https://strace.io
- strace repository: https://github.com/strace/strace
- musl libc: https://musl.libc.org/

## Build Information

- **strace version**: 6.17.0.32.ffa1
- **Target architecture**: aarch64
- **C library**: musl
- **Compiler**: aarch64-linux-musl-gcc
- **Build date**: 2025-10-31
