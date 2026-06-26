#!/usr/bin/env bash
# new-mixin.sh — scaffold a new mixin module.
#
# Usage:
#   scripts/new-mixin.sh <MixinName> [--compose=Leaf1,Leaf2,...]
#
# - Default: leaf mixin (plain local table with init stub).
# - --compose: an orchestrating mixin built from leaf mixins via
#   `mixin({}, A, B)`. Each composed leaf is required at the top, and the
#   generated init wakes each leaf explicitly. Existence of each leaf is
#   checked before generation.
#
# Mixins are plain tables of methods plus an optional init; see
# src/classes.lua and AGENTS.md (law 2) for the conventions.
#
# Examples:
#   scripts/new-mixin.sh Health
#   scripts/new-mixin.sh Burning --compose=Flammable,Soakable

set -euo pipefail

mixins_dir="src/mixins"

die() { echo "new-mixin: $*" >&2; exit 1; }

# snake_case a PascalCase identifier: "MovementController" -> "movement_controller"
snake() {
    sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' <<<"$1" | tr '[:upper:]' '[:lower:]'
}

usage() {
    cat >&2 <<'USAGE'
usage: new-mixin.sh <MixinName> [--compose=Leaf1,Leaf2,...]

  MixinName                PascalCase, e.g. Health
  --compose=LEAF1,LEAF2    Optional comma-separated leaf mixins (PascalCase).
                           With --compose, generates an orchestrating mixin
                           via `mixin({}, A, B)`; without, a leaf mixin.

examples:
  new-mixin.sh Health
  new-mixin.sh Burning --compose=Flammable,Soakable
USAGE
}

# --- Parse args --------------------------------------------------------------

if [ $# -lt 1 ]; then
    usage
    die "mixin name is required"
fi

name="$1"; shift
[ "$name" = "-h" ] || [ "$name" = "--help" ] && { usage; exit 0; }

compose_csv=""
while [ $# -gt 0 ]; do
    case "$1" in
        --compose=*)
            compose_csv="${1#--compose=}"
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            die "unknown argument: '$1' (expected --compose=N1,N2,...)"
            ;;
    esac
    shift
done

# --- Validate inputs --------------------------------------------------------

[[ "$name" =~ ^[A-Z][A-Za-z0-9]*$ ]] || die "mixin name must be PascalCase (e.g. Health, MovementController)"

# Split the compose list into an array (may be empty).
compose=()
if [ -n "$compose_csv" ]; then
    IFS=',' read -r -a compose <<<"$compose_csv"
fi

for leaf in "${compose[@]+"${compose[@]}"}"; do
    [[ "$leaf" =~ ^[A-Z][A-Za-z0-9]*$ ]] || die "compose leaf '$leaf' must be PascalCase (e.g. Flammable, Soakable)"
    lfile="$mixins_dir/$(snake "$leaf").lua"
    [ -f "$lfile" ] || die "leaf mixin not found: $lfile (create it first: 'just new-mixin $leaf')"
done

mkdir -p "$mixins_dir"
file="$mixins_dir/$(snake "$name").lua"
[ -e "$file" ] && die "refusing to overwrite existing file: $file"

# --- Generate ----------------------------------------------------------------

if [ ${#compose[@]} -gt 0 ]; then
    # Composed/orchestrating mixin (law 2): `mixin({}, Leaf1, Leaf2, ...)`.
    {
        echo "--- ${name} mixin (composed: ${compose_csv})."
        echo "---"
        echo "--- TODO: document the emergent behavior this mixin orchestrates."
        echo

        for leaf in "${compose[@]}"; do
            printf 'local %s = require("mixins.%s")\n' "$leaf" "$(snake "$leaf")"
        done
        echo

        local_list=""
        for leaf in "${compose[@]}"; do
            [ -n "$local_list" ] && local_list+=", "
            local_list+="$leaf"
        done
        printf 'local %s = mixin({}, %s)\n\n' "$name" "$local_list"

        echo "function ${name}:init()"
        for leaf in "${compose[@]}"; do
            printf '    %s.init(self)\n' "$leaf"
        done
        echo "end"
        echo

        echo "-- TODO: override leaf methods here to orchestrate emergent behavior."
        echo "-- Delegate to a leaf by name, e.g.:"
        echo "--     function ${name}:light()"
        echo "--         if self.wet then return end   -- read a sibling leaf's state"
        echo "--         Flammable.light(self)          -- delegate to the leaf"
        echo "--     end"

        echo
        echo "return ${name}"
    } > "$file"
else
    # Leaf mixin: plain local table with init stub.
    cat > "$file" <<EOF
--- ${name} mixin.
---
--- TODO: document what this mixin provides.

local ${name} = {}

function ${name}:init()
    -- TODO
end

return ${name}
EOF
fi

echo "created $file"
stylua "$file" 2>/dev/null || true
