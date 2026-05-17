# Zig Version Requirement

## Current Requirement: Zig 0.15.2

The NanoClaw-Next project has been backported to build and run on Zig 0.15.2.

### Why?

The earlier 0.16-based implementation used APIs that are not available in 0.15.2, including:

- **std.process.Init**: New process initialization API (used in main.zig)
- **std.Io.Dir**: Consolidated filesystem operations
- **std.process.run**: Improved command execution with timeout support
- **std.debug.print**: Replacement for removed std.io module

The project now avoids those 0.16-only APIs so it can compile on Zig 0.15.2.

### Update Zig

**macOS:**
```bash
brew install zig@0.15
```

**Linux:**
Download Zig 0.15.2 from https://ziglang.org/download/

**Verify:**
```bash
zig version
```

Expected output: `0.15.2`

### After Updating

You'll need to update:
1. **scripts/setup.sh** - Keep version check pinned to 0.15.x
2. **README.md** - Update dependency documentation
3. **PHASE0_README.md** - Update dependency section

These files should reference Zig 0.15.2 as the supported baseline.
