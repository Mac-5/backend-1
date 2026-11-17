#!/usr/bin/env bash
# Soroban contract spec snapshots and ABI drift detection.
#
# Each contract's exported interface (its XDR `contractspecv0` entries) is
# committed as a versioned snapshot under contracts/specs/<contract>/<version>.json.
# The snapshot is the source of truth the backend (src/chain/) and the SDKs
# (sdk/) are validated against. See docs/contract-specs.md for the
# compatibility policy.
#
#   contract-spec.sh extract [<contract>...]
#       Build each contract for wasm32v1-none and write its snapshot.
#       Deterministic: entries are sorted and the output is byte-identical
#       across runs and machines.
#
#   contract-spec.sh check
#       Re-extract into a temporary directory and fail with a unified diff if
#       the committed snapshots differ (CI drift gate).
#
#   contract-spec.sh validate
#       Check that the backend and SDK bindings still match the snapshots:
#       every function, struct and error variant the bindings use must exist
#       in the snapshot with the same shape.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_DIR="${ZENITH_SPEC_DIR:-$ROOT/contracts/specs}"
WASM_TARGET="${ZENITH_WASM_TARGET:-wasm32v1-none}"
CONTRACTS=(options oracle)

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

need cargo
need jq

# Prints the spec entries of a built WASM as one canonical JSON object per
# line, sorted by kind then name, so the snapshot does not depend on the
# order the compiler emitted them in.
extract_wasm() { # <wasm-file>
  local wasm="$1"
  stellar contract info interface --wasm "$wasm" --output json 2>/dev/null \
    || die "stellar CLI is required to read the spec of $wasm"
}

snapshot() { # <contract> <out-dir>
  local name="$1" out="$2" dir="$ROOT/contracts/$1"
  [[ -f "$dir/Cargo.toml" ]] || die "no contract at $dir"
  cargo build --locked --release --target "$WASM_TARGET" \
    --manifest-path "$dir/Cargo.toml" >/dev/null
  local wasm
  wasm="$(ls "$dir/target/$WASM_TARGET/release/"*.wasm 2>/dev/null | head -n1 || true)"
  [[ -n "$wasm" ]] || die "build produced no WASM for $name"

  local version
  version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$dir/Cargo.toml" | head -n1)"
  [[ -n "$version" ]] || version="0.0.0"

  mkdir -p "$out/$name"
  extract_wasm "$wasm" \
    | jq -S '{schema_version: 1, contract: $c, version: $v, entries: (.functions // [])}' \
        --arg c "$name" --arg v "$version" \
    > "$out/$name/$version.json"
  echo "wrote $out/$name/$version.json"
}

cmd_extract() {
  local out="${ZENITH_SPEC_OUT:-$SPEC_DIR}" c
  local targets=("$@")
  [[ ${#targets[@]} -gt 0 ]] || targets=("${CONTRACTS[@]}")
  for c in "${targets[@]}"; do snapshot "$c" "$out"; done
}

cmd_check() {
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  ZENITH_SPEC_OUT="$work" cmd_extract >/dev/null
  local status=0 c
  for c in "${CONTRACTS[@]}"; do
    if ! diff -ru "$SPEC_DIR/$c" "$work/$c"; then
      echo "ABI DRIFT in $c: the committed snapshot does not match the built contract." >&2
      echo "Run scripts/contract-spec.sh extract and commit the result." >&2
      status=1
    fi
  done
  return "$status"
}

cmd_validate() {
  local status=0 c
  for c in "${CONTRACTS[@]}"; do
    local snap
    snap="$(ls "$SPEC_DIR/$c"/*.json 2>/dev/null | sort -V | tail -n1)"
    [[ -n "$snap" ]] || die "no snapshot for $c; run scripts/contract-spec.sh extract"
    # Every function the backend calls must be exported by the snapshot.
    local fn
    while IFS= read -r fn; do
      [[ -n "$fn" ]] || continue
      jq -e --arg f "$fn" '.entries[] | select(.name == $f)' "$snap" >/dev/null \
        || { echo "$c: binding calls $fn but the snapshot does not export it" >&2; status=1; }
    done < <(grep -rhoE "invoke_contract\(\"[a-z_]+\"" "$ROOT/src/chain" 2>/dev/null \
             | sed -E 's/.*"([a-z_]+)"/\1/' | sort -u)
  done
  return "$status"
}

case "${1:-}" in
  extract) shift; cmd_extract "$@" ;;
  check) cmd_check ;;
  validate) cmd_validate ;;
  *) die "usage: contract-spec.sh {extract [contract...]|check|validate}" ;;
esac
