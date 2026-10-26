// Kernel-level isolation (Landlock filesystem rules, seccomp-bpf syscall
// filter, PR_SET_NO_NEW_PRIVS) is planned in docs/PLAN.md milestone M3 and
// must be tested on Linux before it is claimed anywhere. Until then this
// module only reports the truth.

pub fn isolationStatus() []const u8 {
    return "none: executable allowlist + hard timeout only (Landlock/seccomp planned, M3)";
}
