#!/usr/bin/env bash
set -euo pipefail

# tools/ralph/run.sh - Single entrypoint for Ralph in monorepo
#
# Usage:
#   bash tools/ralph/run.sh --workspace apps/brain
#   bash tools/ralph/run.sh --workspace apps/brain --workspace-id brain-v2
#   bash tools/ralph/run.sh --workspace apps/brain --disable
#
# Inputs:
#   --workspace <path>    Required. Relative path from monorepo root.
#   --workspace-id <id>   Optional. Override derived workspace id.
#   --tools <string>      Optional. Allowed tools (default: minimal safe set).
#   --monitor             Optional. Enable Ralph monitor mode.
#   --calls <N>           Optional. Max API calls.
#   --timeout <minutes>   Optional. Max runtime.
#   --force               Optional. Allow rebinding workspace id.
#   --disable             Optional. Create kill switch and exit.

# --- Argument Parsing ---
WORKSPACE=""
WORKSPACE_ID=""
TOOLS=""
MONITOR=""
CALLS=""
TIMEOUT=""
FORCE=""
DISABLE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --workspace-id)
      WORKSPACE_ID="$2"
      shift 2
      ;;
    --tools)
      TOOLS="$2"
      shift 2
      ;;
    --monitor)
      MONITOR="1"
      shift
      ;;
    --calls)
      CALLS="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --force)
      FORCE="1"
      shift
      ;;
    --disable)
      DISABLE="1"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Determine Repo Root ---
REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Normalize Workspace Path ---
# Strip leading ./ and trailing /
WORKSPACE="${WORKSPACE#./}"
WORKSPACE="${WORKSPACE%/}"

# Validate workspace
if [ -z "$WORKSPACE" ]; then
  echo "Error: --workspace is required"
  exit 1
fi

if [[ "$WORKSPACE" == /* ]]; then
  echo "Error: --workspace must be relative (got absolute path)"
  exit 1
fi

if [[ "$WORKSPACE" == *..* ]]; then
  echo "Error: --workspace must not contain '..'"
  exit 1
fi

if [ ! -d "$REPO_ROOT/$WORKSPACE" ]; then
  echo "Error: workspace directory does not exist: $REPO_ROOT/$WORKSPACE"
  exit 1
fi

# --- Validate Workspace ID (if provided) ---
if [ -n "$WORKSPACE_ID" ]; then
  if [ -z "$WORKSPACE_ID" ]; then
    echo "Error: --workspace-id cannot be empty"
    exit 1
  fi
  if [[ "$WORKSPACE_ID" == */* ]] || [[ "$WORKSPACE_ID" == *\\* ]]; then
    echo "Error: --workspace-id cannot contain / or \\"
    exit 1
  fi
  if [[ "$WORKSPACE_ID" == "." ]] || [[ "$WORKSPACE_ID" == ".." ]]; then
    echo "Error: --workspace-id cannot be . or .."
    exit 1
  fi
  if [[ ! "$WORKSPACE_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: --workspace-id must contain only [A-Za-z0-9._-]"
    exit 1
  fi
fi

# --- Derive Workspace ID (if not provided) ---
if [ -z "$WORKSPACE_ID" ]; then
  WORKSPACE_ID="$WORKSPACE"
  # Replace / with __
  WORKSPACE_ID="${WORKSPACE_ID//\//__}"
  # Replace non-allowed chars with _
  WORKSPACE_ID=$(echo "$WORKSPACE_ID" | sed 's/[^A-Za-z0-9._-]/_/g')
  # Collapse consecutive underscores
  WORKSPACE_ID=$(echo "$WORKSPACE_ID" | sed 's/__*/_/g')

  if [ -z "$WORKSPACE_ID" ]; then
    echo "Error: derived workspace-id is empty"
    exit 1
  fi
fi

# --- Set Derived Paths ---
WORKSPACE_DIR="$REPO_ROOT/$WORKSPACE"
RALPH_ROOT="$REPO_ROOT/.ralph/$WORKSPACE_ID"
STATE_DIR="$RALPH_ROOT/state"
PROMPT_FILE="$RALPH_ROOT/PROMPT.md"
FIX_PLAN_FILE="$RALPH_ROOT/@fix_plan.md"
WORKSPACE_BINDING_FILE="$RALPH_ROOT/WORKSPACE"
DISABLED_FILE="$RALPH_ROOT/DISABLED"

# --- Handle --disable ---
if [ -n "$DISABLE" ]; then
  mkdir -p "$RALPH_ROOT"
  touch "$DISABLED_FILE"
  echo "Kill switch created: $DISABLED_FILE"
  echo "Ralph is now disabled for workspace '$WORKSPACE_ID'"
  echo "Remove $DISABLED_FILE to re-enable."
  exit 0
fi

# --- Check Kill Switch ---
if [ -f "$DISABLED_FILE" ]; then
  echo "Error: Ralph is disabled for workspace '$WORKSPACE_ID'"
  echo "Kill switch file: $DISABLED_FILE"
  echo "Remove this file to re-enable Ralph for this workspace."
  exit 1
fi

# --- Workspace Binding Check ---
if [ -f "$WORKSPACE_BINDING_FILE" ]; then
  BOUND_WORKSPACE=$(cat "$WORKSPACE_BINDING_FILE")
  if [ "$BOUND_WORKSPACE" != "$WORKSPACE" ]; then
    if [ -n "$FORCE" ]; then
      # Move old state aside
      ORPHAN_DIR="$REPO_ROOT/.ralph/_orphaned/${WORKSPACE_ID}.$(date +%Y%m%d%H%M%S)"
      echo "Warning: Force rebinding workspace-id '$WORKSPACE_ID'"
      echo "  Old workspace: $BOUND_WORKSPACE"
      echo "  New workspace: $WORKSPACE"
      echo "  Moving old state to: $ORPHAN_DIR"
      mkdir -p "$REPO_ROOT/.ralph/_orphaned"
      mv "$RALPH_ROOT" "$ORPHAN_DIR"
    else
      echo "Error: workspace-id '$WORKSPACE_ID' is already bound to '$BOUND_WORKSPACE'"
      echo "Current request is for workspace '$WORKSPACE'"
      echo ""
      echo "Options:"
      echo "  1. Use --workspace-id to specify a different id"
      echo "  2. Use --force to rebind (old state will be preserved in .ralph/_orphaned/)"
      echo "  3. Delete $RALPH_ROOT to start fresh"
      exit 1
    fi
  fi
fi

# --- Create State Directory Structure ---
mkdir -p "$STATE_DIR"

# --- Write Workspace Binding ---
echo "$WORKSPACE" > "$WORKSPACE_BINDING_FILE"

# --- Create PROMPT.md Template (if missing) ---
if [ ! -f "$PROMPT_FILE" ]; then
  cat > "$PROMPT_FILE" << 'PROMPT_EOF'
# Ralph Autonomous Loop Prompt

You are running in an autonomous loop managed by Ralph.

## Workflow

Follow the AI Toolkit workflow without relying on slash-command parsing:

**Why**: Ralph invokes Claude via the CLI with a prompt file; it does not automatically execute Claude Code's interactive slash-command handler.

1. Read and follow `.claude/commands/explore.md` to understand context
2. Read and follow `.claude/commands/plan.md` to create implementation plan
3. Read and follow `.claude/commands/review-plan.md` to validate the plan
4. Read and follow `.claude/commands/execute-plan.md` to implement

For Bob Party changes, also follow these governance procedures:
- `.claude/commands/create-cp.md` - Create Change Proposals
- `.claude/commands/review-cp.md` - Review CPs
- `.claude/commands/implement-cp.md` - Implement CP tasks
- `.claude/commands/validate-tenets.md` - Validate tenet compliance

## Rules

1. Never ask to commit or push code
2. Never request interactive approval
3. Always validate changes before marking tasks complete
4. Focus on the current @fix_plan.md tasks

## Status Block (Required)

You MUST end every response with:

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary of what to do next>
---END_RALPH_STATUS---
```

PROMPT_EOF
  echo "Created: $PROMPT_FILE"
fi

# --- Create @fix_plan.md Template (if missing) ---
if [ ! -f "$FIX_PLAN_FILE" ]; then
  cat > "$FIX_PLAN_FILE" << 'FIXPLAN_EOF'
# Fix Plan

## Tasks

- [ ] Task 1: Description here
- [ ] Task 2: Description here

## Notes

Add implementation notes here.

FIXPLAN_EOF
  echo "Created: $FIX_PLAN_FILE"
fi

# --- Set Default Tools (Minimal Safe Set) ---
if [ -z "$TOOLS" ]; then
  TOOLS="Read,Glob,Grep,TodoWrite,Task,Write(.ralph/**),Edit(.ralph/**),Bash(npx nx *)"
fi

# --- Compatibility Check for --tools ---
# Validate the tool string using Ralph's own argument validation without starting the loop.
# This prevents silently widening permissions when scoped tokens are not supported.
if ! bash "$REPO_ROOT/tools/ralph/ralph_loop.sh" --allowed-tools "$TOOLS" --help >/dev/null 2>&1; then
  echo "Error: Ralph rejected --tools string (likely missing Phase 6.5.3.4 tool-scoping patches)"
  echo "Current --tools: $TOOLS"
  echo ""
  echo "Either:"
  echo "  1. Apply the tool scoping patches to Ralph"
  echo "  2. Use non-scoped tools: Read,Glob,Grep,TodoWrite,Task"
  exit 1
fi

# --- Change to Repo Root ---
cd "$REPO_ROOT"

# --- Invoke Ralph ---
echo "=========================================="
echo "Ralph Autonomous Loop"
echo "=========================================="
echo "Workspace:    $WORKSPACE"
echo "Workspace ID: $WORKSPACE_ID"
echo "State Dir:    $STATE_DIR"
echo "Prompt:       $PROMPT_FILE"
echo "Fix Plan:     $FIX_PLAN_FILE"
echo "Tools:        $TOOLS"
echo "=========================================="
echo ""

exec bash tools/ralph/ralph_loop.sh \
  --output-format json \
  --state-dir "$STATE_DIR" \
  --prompt "$PROMPT_FILE" \
  --fix-plan "$FIX_PLAN_FILE" \
  --allowed-tools "$TOOLS" \
  ${MONITOR:+--monitor} \
  ${CALLS:+--calls "$CALLS"} \
  ${TIMEOUT:+--timeout "$TIMEOUT"}
