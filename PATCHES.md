# Local Patches

This branch contains patches for monorepo integration.

## Patches

| Patch | Description | Status |
| ----- | ----------- | ------ |
| --state-dir | Relocate all state files under configurable directory | Complete |
| --fix-plan | Configurable fix plan path | Complete |
| Tool scoping | Support Write(<glob>), Edit(<glob>) tokens | Complete |

## Patch Details

### --state-dir flag
All state files (logs, status.json, session files, etc.) are now prefixed with `$STATE_DIR/`.
Default is `.` (current directory) to preserve backward compatibility.

### --fix-plan flag
The fix plan file path can now be configured via `--fix-plan`.
Default is `@fix_plan.md` to preserve backward compatibility.

### Tool Scoping
Extended `--allowed-tools` validation to support:
- Scoped file tools: `Read(<glob>)`, `Write(<glob>)`, `Edit(<glob>)`
- Bash patterns restricted to allowlist: `git *`, `npx nx *`
- Empty globs are rejected (e.g., `Write()` fails)

