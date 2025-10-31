# System Calls Used by strace

This document lists all system calls that strace itself uses when tracing other processes. These are the syscalls strace makes to perform its tracing operations, not the syscalls it traces in target processes.

## Meta-Tracing: How to Observe strace's Syscalls

To see strace's own syscalls in action, you can use **meta-tracing** - running strace on itself:

```bash
# Basic meta-tracing: strace traces strace tracing a command
./src/strace ./src/strace echo "Hello"

# Save the outer strace output to a file for analysis
./src/strace -o strace_self.log ./src/strace -o inner.log echo "Hello"

# This creates:
# - strace_self.log: Contains all syscalls made by the inner strace
# - inner.log: Contains syscalls made by the echo command
# - Creates a 3-level process tree: outer strace → inner strace → echo
```

**What you'll see:**
- All ptrace() operations strace performs
- wait4() event loop synchronization
- process_vm_readv() memory reading from the tracee
- writev() for output generation
- Complete picture of strace's internal operation

This meta-tracing technique was used to generate the real-world parameter examples throughout this document.

---

## Core Tracing System Calls

### ptrace() - Process Tracing
The primary system call for tracing processes. Strace uses many ptrace operations:

**Attachment Operations:**
- `PTRACE_ATTACH` - Attach to an existing process
- `PTRACE_SEIZE` - Modern attachment method (preferred over ATTACH)
- `PTRACE_INTERRUPT` - Interrupt a running tracee
- `PTRACE_DETACH` - Detach from a traced process
- `PTRACE_TRACEME` - Child requests to be traced by parent

**Control Operations:**
- `PTRACE_SYSCALL` - Continue execution and stop at next syscall entry/exit
- `PTRACE_CONT` - Continue execution
- `PTRACE_SETOPTIONS` - Set ptrace options (follow forks, etc.)

**Information Gathering:**
- `PTRACE_GETSIGINFO` - Get signal information
- `PTRACE_GETEVENTMSG` - Get message about ptrace event (e.g., new child PID)
- `PTRACE_GET_SYSCALL_INFO` - Get detailed syscall information
- `PTRACE_GETREGS` - Get CPU register values
- `PTRACE_SETREGS` - Set CPU register values
- `PTRACE_PEEKUSER` - Read from tracee's user area
- `PTRACE_POKEUSER` - Write to tracee's user area

**Ptrace Options Used:**
- `PTRACE_O_TRACESYSGOOD` - Distinguish syscall stops from signal-delivery stops
- `PTRACE_O_TRACEEXEC` - Trace execve() calls
- `PTRACE_O_TRACEEXIT` - Trace process exit
- `PTRACE_O_TRACECLONE` - Trace clone() calls
- `PTRACE_O_TRACEFORK` - Trace fork() calls
- `PTRACE_O_TRACEVFORK` - Trace vfork() calls
- `PTRACE_O_TRACESECCOMP` - Trace seccomp events
- `PTRACE_O_EXITKILL` - Kill tracee on tracer exit

**Location:** `src/strace.c:573-606`, `src/syscall.c`

**Real-World Parameter Examples (from meta-tracing):**

*Initial Attach:*
```c
ptrace(PTRACE_SEIZE, 457315, NULL, 0)  // Try to attach to existing process
  → Returns -1 EPERM (Operation not permitted)

ptrace(PTRACE_SETOPTIONS, 457316, NULL, PTRACE_O_TRACESYSGOOD)
  → Returns 0 (success)
```

*Getting Syscall Information:*
```c
// Entry into a syscall
ptrace(PTRACE_GET_SYSCALL_INFO, 457316, 88, {
  op=PTRACE_SYSCALL_INFO_ENTRY,
  arch=AUDIT_ARCH_AARCH64,
  instruction_pointer=0x47d560,
  stack_pointer=0xfffff9f21250,
  entry={
    nr=__NR_gettid,
    args=[0xdad0bef0bad0fed0, 0xdad1bef1bad1fed1, ...]
  }
})  → Returns 80 (bytes filled)

// Exit from a syscall
ptrace(PTRACE_GET_SYSCALL_INFO, 457316, 88, {
  op=PTRACE_SYSCALL_INFO_EXIT,
  arch=AUDIT_ARCH_AARCH64,
  instruction_pointer=0x47d560,
  stack_pointer=0xfffff9f21250,
  exit={
    rval=457316,
    is_error=0
  }
})  → Returns 33 (bytes filled)
```

*Following Process Execution:*
```c
// Seize with multiple options
ptrace(PTRACE_SEIZE, 457317, NULL,
       PTRACE_O_TRACESYSGOOD|PTRACE_O_TRACEEXEC|PTRACE_O_TRACEEXIT)
  → Returns 0

// Interrupt a running tracee
ptrace(PTRACE_INTERRUPT, 457317)  → Returns 0

// Listen for ptrace-stop events
ptrace(PTRACE_LISTEN, 457317)  → Returns 0

// Continue to next syscall
ptrace(PTRACE_SYSCALL, 457317, NULL, 0)  → Returns 0

// Get signal information
ptrace(PTRACE_GETSIGINFO, 457317, NULL, {
  si_signo=SIGCONT,
  si_code=SI_USER,
  si_pid=457315,
  si_uid=501
})  → Returns 0

// Continue and deliver signal
ptrace(PTRACE_SYSCALL, 457317, NULL, SIGCONT)  → Returns 0

// Get event message (e.g., new PID after exec)
ptrace(PTRACE_GETEVENTMSG, 457317, NULL, [457317])  → Returns 0
```

*Handling Various Syscalls:*
```c
// openat() entry
ptrace(PTRACE_GET_SYSCALL_INFO, 457317, 88, {
  entry={
    nr=__NR_openat,
    args=[0xffffffffffffff9c, 0xffff89257328, 0x80000, 0, 0, 0xffffffffffffffff]
  }
})

// openat() exit (successful)
ptrace(PTRACE_GET_SYSCALL_INFO, 457317, 88, {
  exit={rval=3, is_error=0}
})

// faccessat() exit (error)
ptrace(PTRACE_GET_SYSCALL_INFO, 457317, 88, {
  exit={rval=-ENOENT, is_error=1}
})
```

---

## Process Control System Calls

### wait4() - Wait for Process State Changes
Primary system call to wait for traced processes to change state.

**Usage:**
- Wait for processes to stop at syscalls
- Collect resource usage statistics with `-c` flag
- Detect process termination

**Flags Used:**
- `__WALL` - Wait for any child (including cloned threads)
- `WNOHANG` - Non-blocking wait

**Location:** `src/strace.c:3723`, `src/strace.c:3905`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Wait for specific PID - initial stop after PTRACE_SEIZE
wait4(457316, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGSTOP}], 0, NULL)
  → Returns 457316

// Wait for syscall stops (SIGTRAP | 0x80 indicates syscall-stop)
wait4(457316, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGTRAP | 0x80}], 0, NULL)
  → Returns 457316

// Wait for normal exit
wait4(457316, [{WIFEXITED(s) && WEXITSTATUS(s) == 0}], 0, NULL)
  → Returns 457316

// Wait for any child with __WALL flag
wait4(-1, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGSTOP}|PTRACE_EVENT_STOP<<16], __WALL, NULL)
  → Returns 457317

// Non-blocking check with WNOHANG
wait4(-1, 0xfffff9f224cc, WNOHANG|__WALL, NULL)
  → Returns 0 (no child changed state)

// Wait for ptrace events
wait4(-1, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGTRAP}|PTRACE_EVENT_STOP<<16], __WALL, NULL)
  → Returns 457317

wait4(-1, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGTRAP}|PTRACE_EVENT_EXEC<<16], __WALL, NULL)
  → Returns 457317

wait4(-1, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGTRAP}|PTRACE_EVENT_EXIT<<16], __WALL, NULL)
  → Returns 457317

// Wait for signal delivery to tracee
wait4(-1, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGCONT}], __WALL, NULL)
  → Returns 457317

// Wait with WSTOPPED flag (deprecated but still works)
wait4(457317, [{WIFSTOPPED(s) && WSTOPSIG(s) == SIGSTOP}], WSTOPPED, NULL)
  → Returns 457317
```

**Key Patterns:**
- `__WALL`: Wait for all children including clones and threads
- `WNOHANG`: Return immediately if no child has changed state
- `SIGTRAP | 0x80`: Syscall-stop (when PTRACE_O_TRACESYSGOOD is set)
- `PTRACE_EVENT_*<<16`: Upper 16 bits encode ptrace event type

---

### waitpid() - Wait for Specific Process
Wait for specific child process to change state.

**Usage:**
- Wait for specific tracee during attach
- Synchronize with child processes during startup
- Clean up terminated processes

**Location:** `src/strace.c:1336`, `src/strace.c:1810`

---

### fork() / vfork() - Create Child Process
Create new processes for executing traced programs.

**Usage:**
- Fork to execute target program while parent traces
- Create grandchild process for daemonization (`-D` flag)
- On MMU-less systems, uses `vfork()` instead of `fork()`

**Location:** `src/strace.c:1456`, `src/strace.c:1786`, `src/strace.c:708`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Simple fork to create tracee process
clone(child_stack=NULL, flags=SIGCHLD)
  → Returns 457316 (child PID)

// Another fork for the traced program
clone(child_stack=NULL, flags=SIGCHLD)
  → Returns 457317 (child PID)
```

**Note:** Modern strace uses `clone()` instead of traditional `fork()` on most systems.

---

### execve() - Execute Program
Replace current process with target program.

**Usage:**
- Execute the program to be traced
- Child process calls execve() after PTRACE_TRACEME

**Location:** `src/strace.c:1643`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Strace executing itself to trace the echo command
execve("./src/strace",
       ["./src/strace", "-o", "inner.log", "echo", "Hello"],
       0xffffc90e3eb0 /* 47 vars */)
  → Returns 0 (on success, doesn't return to caller)
```

**Traced execve() call:**
```c
// The inner strace executes echo
ptrace(PTRACE_GET_SYSCALL_INFO, 457317, 88, {
  entry={
    nr=__NR_execve,
    args=[0xfffff9f215e0,     // pathname
          0xfffff9f226e0,     // argv
          0xfffff9f226f8,     // envp
          0, 0, 0]
  }
})
```

---

### _exit() - Terminate Process
Exit without cleanup (direct syscall).

**Usage:**
- Child process exits after errors
- Immediate termination in failure cases

**Location:** `src/strace.c:553`, `src/exitkill.c:39`

---

## Signal & Process Management

### kill() - Send Signal to Process
Send signals to processes.

**Usage:**
- Send SIGKILL to terminate tracees
- Send SIGCONT to continue stopped processes
- Send SIGSTOP to stop processes

**Location:** `src/strace.c:1526`, `src/strace.c:1833`, `src/strace.c:3281-3282`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Send SIGCONT to continue a stopped tracee
kill(457317, SIGCONT)
  → Returns 0
```

**Common Signal Patterns:**
- `kill(pid, SIGKILL)` - Force terminate tracee
- `kill(pid, SIGCONT)` - Continue stopped tracee
- `kill(pid, SIGSTOP)` - Stop tracee
- `kill(pid, 0)` - Check if process exists (doesn't send signal)

---

### tkill() - Send Signal to Thread
Send signal to specific thread (via syscall wrapper).

**Usage:**
- Send signals to specific threads in multi-threaded programs
- Check if thread is alive (signal 0)
- Send SIGSTOP to threads

**Implementation:** `#define my_tkill(tid, sig) syscall(__NR_tkill, (tid), (sig))`

**Location:** `src/strace.c:57`, `src/strace.c:1217`, `src/strace.c:1239`

---

### sigaction() - Install Signal Handler
Set up signal handlers for strace itself.

**Usage:**
- Handle SIGCHLD for child process management
- Install cleanup handlers
- Set up interrupt handlers

**Location:** `src/strace.c:1586`, `src/strace.c:1638`, `src/strace.c:1946`

---

### sigprocmask() - Block/Unblock Signals
Manipulate signal mask.

**Usage:**
- Block signals during critical sections
- Unblock signals after wait operations
- Manage timer signal delivery

**Location:** `src/strace.c:3171`, `src/strace.c:3711`, `src/strace.c:3734`

---

## Memory Access System Calls

### process_vm_readv() - Read Tracee Memory
Read memory from traced process address space efficiently.

**Usage:**
- Read strings from tracee memory
- Read structures and data from tracee
- Preferred method (faster than PTRACE_PEEKDATA)
- Falls back to ptrace if not available

**Location:** `src/ucopy.c:77` (via syscall wrapper)

**Syscall:** `syscall(__NR_process_vm_readv, pid, lvec, liovcnt, rvec, riovcnt, flags)`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Read 4KB from tracee's stack
process_vm_readv(457317,
  [{iov_base="\0\0\0\0\0\0\0\0...", iov_len=4096}], 1,  // Local buffer
  [{iov_base=0xfffff9f21000, iov_len=4096}], 1,          // Remote address
  0)
  → Returns 4096 (bytes read)

// Read string data from tracee memory
process_vm_readv(457317,
  [{iov_base="l_next == GL(dl_rtld_map).l_next"..., iov_len=4096}], 1,
  [{iov_base=0xffff89259000, iov_len=4096}], 1,
  0)
  → Returns 4096

// Read from tracee's heap
process_vm_readv(457317,
  [{iov_base="\247\0\0\0\0\0\0\0\2\0\0\0..."..., iov_len=4096}], 1,
  [{iov_base=0xaaaaef446000, iov_len=4096}], 1,
  0)
  → Returns 4096
```

**Key Features:**
- Reads from remote process's address space efficiently
- Uses iovec structures for scatter-gather I/O
- Much faster than PTRACE_PEEKDATA (reads words one at a time)
- Returns number of bytes successfully read
- Local buffer (lvec) receives data from remote address (rvec)

---

### process_vm_writev() - Write Tracee Memory
Write memory to traced process address space.

**Usage:**
- Inject data into tracee for fault injection
- Modify tracee memory for testing
- Less commonly used than readv

**Location:** `src/ucopy.c:219` (via syscall wrapper)

**Syscall:** `syscall(__NR_process_vm_writev, pid, lvec, liovcnt, rvec, riovcnt, flags)`

---

## File & I/O Operations

### open() / openat() - Open Files
Open files (implicitly used via libc functions like fopen).

**Usage:**
- Open /proc files for reading process information
- Open output files for logging (`-o` flag)
- Access /proc/$pid/comm, /proc/$pid/maps, etc.

**Location:** Via fopen() and other libc wrappers

**Real-World Parameter Examples (from meta-tracing):**

```c
// Open /proc file to read system configuration
openat(AT_FDCWD, "/proc/sys/kernel/pid_max", O_RDONLY|O_LARGEFILE)
  → Returns 3

// Create output file for trace log
openat(AT_FDCWD, "inner.log", O_WRONLY|O_CREAT|O_TRUNC|O_LARGEFILE, 0666)
  → Returns 3

// Search for executable in PATH (multiple attempts)
newfstatat(AT_FDCWD, "/opt/aarch64-linux-musl-cross/bin/echo", 0xfffff9f213a0, 0)
  → Returns -1 ENOENT (No such file or directory)

newfstatat(AT_FDCWD, "/usr/bin/echo", {st_mode=S_IFREG|0755, st_size=67792, ...}, 0)
  → Returns 0
```

**Common Patterns:**
- `AT_FDCWD` constant indicates relative path from current directory
- `O_LARGEFILE` flag for 64-bit file offsets on 32-bit systems
- Multiple stat attempts when searching for executables in PATH

---

### close() - Close File Descriptors
Close file descriptors.

**Usage:**
- Close pipe ends after fork
- Clean up file descriptors
- Close /proc file descriptors

**Location:** `src/strace.c:714`, `src/strace.c:1582`, `src/strace.c:1687`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Close various file descriptors during setup
close(3)  → Returns 0
close(4)  → Returns 0
close(0)  → Returns 0  // Close stdin
close(1)  → Returns 0  // Close stdout
```

---

### read() / write() - File I/O
Read from and write to file descriptors (via libc).

**Usage:**
- Read /proc files
- Write trace output
- Read/write pipes

**Location:** Via fopen/fprintf/fread wrappers

**Real-World Parameter Examples (from meta-tracing):**

```c
// writev() - Vectored write for incremental output construction
// Writing syscall trace output to file descriptor 3

// Write syscall entry
writev(3, [{iov_base="execve(\"/usr/bin/echo\", [\"echo\","..., iov_len=71},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 71

// Write syscall result
writev(3, [{iov_base=") = 0\n", iov_len=6},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 6

// Write brk syscall entry
writev(3, [{iov_base="brk(NULL", iov_len=8},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 8

// Write detailed result with padding
writev(3, [{iov_base=")                               "..., iov_len=49},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 49

// Write mmap with parameters
writev(3, [{iov_base="mmap(NULL, 8192, PROT_READ|PROT_"..., iov_len=71},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 71

// Write return value
writev(3, [{iov_base=") = 0xffff8926d000\n", iov_len=19},
           {iov_base=NULL, iov_len=0}], 2)
  → Returns 19
```

**Why writev()?**
- Atomic writes of multiple buffers
- Efficient for constructing output incrementally
- Avoids string concatenation overhead
- Each write contains syscall name, parameters, and result separately

---

### pipe() - Create Pipe
Create inter-process communication pipes.

**Usage:**
- Communication between parent and child during startup
- Synchronization during attach operations

**Location:** `src/strace.c:703`, `src/strace.c:1658`

---

### dup2() - Duplicate File Descriptor
Duplicate file descriptor to specific number.

**Usage:**
- Redirect child's stdin/stdout/stderr
- Set up pipe communication

**Location:** `src/strace.c:716`

---

### opendir() / readdir() / closedir() - Directory Operations
Read directory contents (via libc).

**Usage:**
- Read /proc/$pid/task to find all threads
- List processes in /proc
- Auto-attach to process threads (`-p` with threads)

**Location:** `src/strace.c:1410`, `src/pidns.c:391`

---

## Process Information

### getpid() - Get Process ID
Get current process ID.

**Usage:**
- Record strace's own PID
- Identify tracer process
- Test ptrace functionality

**Location:** `src/strace.c:548`, `src/strace.c:1472`, `src/strace.c:1843`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Get strace's own PID
getpid()
  → Returns 457315

// Used multiple times during initialization and for logging
getpid()
  → Returns 457315
```

**Tracee's gettid() call:**
```c
// When tracing gettid() in the tracee
ptrace(PTRACE_GET_SYSCALL_INFO, 457316, 88, {
  entry={
    nr=__NR_gettid,
    args=[0xdad0bef0bad0fed0, ...]  // Uninitialized registers
  }
})

ptrace(PTRACE_GET_SYSCALL_INFO, 457316, 88, {
  exit={
    rval=457316,  // Returns tracee's thread ID
    is_error=0
  }
})
```

---

### gettid() - Get Thread ID
Get current thread ID (via syscall).

**Usage:**
- Identify specific threads
- Test seccomp filters

**Implementation:** `syscall(__NR_gettid)`

**Location:** `src/filter_seccomp.c:99`

---

## Privilege & Security

### prctl() - Process Control Operations
Various process control operations.

**Usage:**
- `PR_SET_PTRACER` - Allow specific process to ptrace (Yama security)
- `PR_SET_NO_NEW_PRIVS` - Prevent privilege escalation (for seccomp)
- `PR_SET_SECCOMP` - Enable seccomp filtering

**Location:** `src/strace.c:1784`, `src/filter_seccomp.c:85-88`, `src/disable_ptrace_request.c:104`

---

## Time & Statistics

### clock_gettime() - Get High-Resolution Time
Get current time with nanosecond precision.

**Clocks Used:**
- `CLOCK_REALTIME` - Wall-clock time for timestamps
- `CLOCK_MONOTONIC` - Monotonic time for relative timing
- `CLOCK_BOOTTIME` - Time since boot (for BPF timestamps)

**Usage:**
- Timestamp syscalls (`-t`, `-tt`, `-ttt` flags)
- Measure syscall duration (`-T` flag)
- Relative timestamps (`-r` flag)
- Syscall counting statistics

**Location:** `src/strace.c:910`, `src/strace.c:929`, `src/syscall.c:687`

---

### gettimeofday() - Get Time of Day
Get current time (lower precision than clock_gettime).

**Usage:**
- Legacy time retrieval
- Some timestamp operations

**Location:** `src/strauss.c:375`

---

## /proc Filesystem Access

While not syscalls themselves, strace heavily relies on reading `/proc` filesystem:

**Files Read:**
- `/proc/$pid/comm` - Process name
- `/proc/$pid/maps` - Memory mappings (for stack traces)
- `/proc/$pid/task` - Thread list
- `/proc/$pid/ns/pid` - PID namespace information
- `/proc/$pid/fd/$fd` - File descriptor paths (for path tracing)
- `/proc/sys/kernel/pid_max` - Maximum PID value
- `/proc/sys/net/core/optmem_max` - Socket option memory limit

**Syscalls Used for /proc:**
- `open()/openat()` - Open /proc files
- `read()` - Read /proc contents
- `readlink()` - Read symbolic links in /proc
- `stat()/fstat()` - Get file information
- `opendir()/readdir()` - List /proc directories

**Location:** `src/strace.c:1017-1021`, `src/pidns.c`, `src/mmap_cache.c:80-81`

**Real-World Parameter Examples (from meta-tracing):**

```c
// Read maximum PID value from kernel
openat(AT_FDCWD, "/proc/sys/kernel/pid_max", O_RDONLY|O_LARGEFILE)
  → Returns 3

// Would also access other /proc files like:
// - /proc/$pid/comm (process name)
// - /proc/$pid/maps (memory regions)
// - /proc/$pid/task (thread list)
// - /proc/$pid/fd/$fd (file descriptor paths)
```

**Note:** In the meta-trace, we see opening `/proc/sys/kernel/pid_max` to determine the system's maximum PID value, which helps strace allocate appropriately-sized data structures.

---

## Summary Statistics

### Total System Calls Used by strace:

**Core Tracing (ptrace):**
- 1 main syscall (`ptrace`) with 15+ operations

**Process Control:**
- `wait4`, `waitpid`, `fork`, `vfork`, `execve`, `_exit`

**Signals:**
- `kill`, `tkill`, `sigaction`, `sigprocmask`

**Memory Access:**
- `process_vm_readv`, `process_vm_writev`

**File I/O:**
- `open`, `openat`, `close`, `read`, `write`, `pipe`, `dup2`
- `opendir`, `readdir`, `closedir`, `readlink`

**Process Info:**
- `getpid`, `gettid`

**Security:**
- `prctl`

**Timing:**
- `clock_gettime`, `gettimeofday`

**Estimated Total: ~25-30 unique syscalls** (excluding ptrace variants)

---

## Key Observations

1. **ptrace() is the workhorse** - Most tracing logic happens through ptrace operations
2. **Memory access optimization** - Uses `process_vm_readv()` for efficiency, falls back to `PTRACE_PEEKDATA`
3. **Heavy /proc usage** - Reads many /proc files for process information
4. **Signal handling** - Careful signal management to avoid interfering with traced processes
5. **Multi-process coordination** - Uses fork/wait extensively to manage tracees
6. **High-precision timing** - Uses `clock_gettime(CLOCK_MONOTONIC)` for accurate syscall timing

---

## Source Code Locations

Main files containing syscall usage:
- `src/strace.c` - Main tracing loop and process management
- `src/syscall.c` - Syscall handling and decoding
- `src/ucopy.c` - Memory access (process_vm_readv/writev)
- `src/ptrace_syscall_info.c` - Ptrace syscall info handling
- `src/filter_seccomp.c` - Seccomp filtering support
- `src/pidns.c` - PID namespace handling
- `src/mmap_cache.c` - Memory mapping cache (/proc/maps)

---

## Meta-Tracing Analysis

### Observed Execution Flow (strace tracing strace tracing echo)

When running `./src/strace ./src/strace echo "Hello"`, we observe a three-level process tree:

```
Outer strace (PID 457315)
  └─> Inner strace (PID 457316)
       └─> echo "Hello" (PID 457317)
```

**Key Execution Patterns:**

1. **Process Creation & Attachment:**
   - Outer strace forks twice using `clone(flags=SIGCHLD)`
   - First child (457316) becomes inner strace
   - Second child (457317) will execute echo
   - Initial attachment uses `PTRACE_SEIZE` with comprehensive options
   - Immediately sets `PTRACE_SETOPTIONS` for event tracking

2. **Main Event Loop Pattern:**
   ```
   wait4() → Returns with event/status
   ↓
   ptrace(PTRACE_GET_SYSCALL_INFO) → Get syscall entry
   ↓
   process_vm_readv() → Read parameters from tracee memory (multiple calls)
   ↓
   writev() → Output formatted syscall entry
   ↓
   ptrace(PTRACE_SYSCALL) → Continue to syscall exit
   ↓
   wait4() → Wait for syscall exit
   ↓
   ptrace(PTRACE_GET_SYSCALL_INFO) → Get syscall exit info
   ↓
   writev() → Output return value
   ↓
   ptrace(PTRACE_SYSCALL) → Continue to next syscall
   ↓
   [Loop repeats]
   ```

3. **Syscall Information Gathering:**
   - Always uses `PTRACE_GET_SYSCALL_INFO` with 88-byte buffer
   - Captures both ENTRY (80 bytes returned) and EXIT (33 bytes returned)
   - Architecture field always shows `AUDIT_ARCH_AARCH64`
   - Instruction pointer and stack pointer captured on every stop

4. **Memory Reading Strategy:**
   - Heavy use of `process_vm_readv()` with 4KB chunks
   - Reads strings, structures, and stack data from tracee
   - Always uses single iovec pair (local buffer, remote address)
   - Consistently returns 4096 bytes (full page reads)

5. **Output Generation:**
   - Uses `writev()` with 2-element iovec arrays
   - First element contains actual content, second is often NULL
   - Writes syscall name, parameters, and results incrementally
   - Each output operation is atomic via writev()

6. **Signal and Event Handling:**
   - Distinguishes syscall-stops via `SIGTRAP | 0x80`
   - Tracks ptrace events: `PTRACE_EVENT_STOP`, `PTRACE_EVENT_EXEC`, `PTRACE_EVENT_EXIT`
   - Uses `PTRACE_GETSIGINFO` to inspect signals delivered to tracee
   - Forwards signals via `ptrace(PTRACE_SYSCALL, pid, NULL, signal)`

7. **Performance Characteristics:**
   - Non-blocking checks with `wait4(-1, ..., WNOHANG|__WALL, NULL)`
   - Returns 0 when no child has changed state (prevents blocking)
   - Alternates between blocking and non-blocking waits
   - Minimal overhead between syscall entry and exit

**Interesting Observations:**

- **Uninitialized Register Values**: When capturing syscall arguments, unused registers contain distinctive poison values like `0xdad0bef0bad0fed0`, `0xdad1bef1bad1fed1`, etc. These are likely deliberately set patterns to detect use of uninitialized values.

- **Process Hierarchy**: The outer strace can see ALL syscalls made by the inner strace, including its own ptrace calls. This creates a complete picture of how strace operates internally.

- **File Descriptor Management**: Extensive `close()` operations during initialization, closing inherited descriptors (stdin, stdout, pipes) to isolate the traced process.

- **PATH Search**: When executing commands, strace performs `newfstatat()` calls across the entire PATH, showing each failed attempt until finding the executable.

- **Event Encoding**: Wait status encoding packs multiple pieces of information:
  - Lower 8 bits: Signal number
  - Upper bits: Event type (shifted left by 16)
  - Special marker bits: 0x80 for syscall-stops

### Syscall Frequency in Meta-Tracing

From the meta-trace log, approximate syscall counts:

| Syscall | Approximate Count | Purpose |
|---------|------------------|---------|
| `ptrace()` | 200+ | Core tracing operations |
| `wait4()` | 100+ | Event loop synchronization |
| `process_vm_readv()` | 80+ | Reading tracee memory |
| `writev()` | 150+ | Output generation |
| `close()` | 10-20 | FD cleanup |
| `openat()` | 5-10 | Opening /proc and output files |
| `newfstatat()` | 10-15 | PATH search and file checks |
| `clone()` | 2 | Process creation |
| `execve()` | 1 | Execute traced program |
| `getpid()` | 2-3 | PID identification |
| `kill()` | 1-2 | Signal delivery |

**Total syscalls by outer strace**: ~500-700 syscalls to trace a simple `echo "Hello"` command

---

Generated: 2025-10-31
strace version: 6.17.0.32.ffa1
Architecture: aarch64
Updated: 2025-10-31 (Added meta-tracing parameter analysis)
