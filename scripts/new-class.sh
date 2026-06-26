#!/usr/bin/env bash
# new-class.sh — scaffold a new game class module.
#
# Usage:
#   scripts/new-class.sh <ClassName> [--parent=ParentClass] [--mixins=M1,M2,...]
#
# Parent (if given) and mixins are PascalCase names; require paths and
# on-disk filenames are derived from them:
#   Parent  Entity            -> require("entity")         src/entity.lua
#   Mixin   Health            -> require("mixins.health") src/mixins/health.lua
#
# Validates that the parent class file and each mixin file exist before
# generating. Refuses to overwrite an existing file.
#
# Examples:
#   scripts/new-class.sh Entity                                # base class
#   scripts/new-class.sh Enemy --parent=Entity                # subclass
#   scripts/new-class.sh Enemy --parent=Entity --mixins=Health
#   scripts/new-class.sh Enemy --parent=Entity --mixins=Health,Drawable

set -euo pipefail

src_dir="src"
mixins_dir="$src_dir/mixins"

die() { echo "new-class: $*" >&2; exit 1; }

# snake_case a PascalCase identifier: "MovementController" -> "movement_controller"
snake() {
    sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' <<<"$1" | tr '[:upper:]' '[:lower:]'
}

# Assert an arg is a PascalCase identifier.
assert_pascal() {
    local label="$1" v="$2"
    [[ "$v" =~ ^[A-Z][A-Za-z0-9]*$ ]] || die "$label '$v' must be PascalCase (e.g. Enemy, MovementController)"
}

usage() {
    cat >&2 <<'USAGE'
usage: new-class.sh <ClassName> [--parent=ParentClass] [--mixins=M1,M2,...]

  ClassName              PascalCase, e.g. Enemy
  --parent=PARENT        Optional parent class (PascalCase), e.g. Entity
  --mixins=M1,M2,...     Optional comma-separated mixins (PascalCase), e.g. Health,Drawable

examples:
  new-class.sh Entity                                # base class
  new-class.sh Enemy --parent=Entity
  new-class.sh Enemy --parent=Entity --mixins=Health,Drawable
USAGE
}

# --- Parse args --------------------------------------------------------------

if [ $# -lt 1 ]; then
    usage
    die "class name is required"
fi

name="$1"; shift
[ "$name" = "-h" ] || [ "$name" = "--help" ] && { usage; exit 0; }

parent=""
mixins=()
while [ $# -gt 0 ]; do
    case "$1" in
        --parent=*)
            parent="${1#--parent=}"
            ;;
        --mixins=*)
            csv="${1#--mixins=}"
            [ -n "$csv" ] && IFS=',' read -r -a mixins <<<"$csv"
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            die "unknown argument: '$1' (expected --parent=NAME or --mixins=N1,N2,...)"
            ;;
    esac
    shift
done

# --- Validate inputs ---------------------------------------------------------

assert_pascal "class name" "$name"

file="$src_dir/$(snake "$name").lua"
[ -e "$file" ] && die "refusing to overwrite existing file: $file"

if [ -n "$parent" ]; then
    assert_pascal "parent" "$parent"
    pfile="$src_dir/$(snake "$parent").lua"
    [ -f "$pfile" ] || die "parent class not found: $pfile (define it first, e.g. 'just new-class $parent')"
fi

for m in "${mixins[@]+"${mixins[@]}"}"; do
    assert_pascal "mixin" "$m"
    mfile="$mixins_dir/$(snake "$m").lua"
    [ -f "$mfile" ] || die "mixin not found: $mfile (create it first: 'just new-mixin $m')"
done

# --- Generate ----------------------------------------------------------------

{
    echo "--- ${name} class."
    echo "---"
    echo "--- TODO: document responsibility."
    echo

    # Requires: parent + mixins. Local var name == the PascalCase name.
    [ -n "$parent" ] && printf 'local %s = require("%s")\n' "$parent" "$(snake "$parent")"
    for m in "${mixins[@]+"${mixins[@]}"}"; do
        printf 'local %s = require("mixins.%s")\n' "$m" "$(snake "$m")"
    done
    echo

    if [ -n "$parent" ]; then
        if [ ${#mixins[@]} -gt 0 ]; then
            mixin_vars=""
            for m in "${mixins[@]}"; do
                [ -n "$mixin_vars" ] && mixin_vars+=", "
                mixin_vars+="$m"
            done
            printf 'local %s, super = class("%s", %s):mixin(%s)\n' \
                "$name" "$name" "$parent" "$mixin_vars"
        else
            printf 'local %s, super = class("%s", %s)\n' "$name" "$name" "$parent"
        fi

        echo
        echo "function ${name}:init(...)"
        echo "    super.init(self, ...)"
        for m in "${mixins[@]+"${mixins[@]}"}"; do
            printf '    %s.init(self)\n' "$m"
        done
        echo "end"
    else
        # Base class: no parent, no super.
        printf 'local %s = class "%s"\n' "$name" "$name"
        echo
        echo "function ${name}:init(...)"
        echo "    -- TODO"
        echo "end"
    fi

    echo
    echo "return ${name}"
} > "$file"

echo "created $file"
stylua "$file" 2>/dev/null || true
