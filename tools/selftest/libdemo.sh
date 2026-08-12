# libdemo.sh - THROWAWAY sourced-library oracle for the fm-ps-diff self-test.
# Sourced, never executed; mirrors the shape of bin/fm-*-lib.sh.
#
# fm_demo_join <sep> [item...]
#   Prints the items joined by <sep> and returns 0, or returns 3 when there is
#   nothing to join. The distinct non-zero return is the point: contract 1 of
#   docs/powershell-port.md requires the PS twin to reproduce it exactly.

fm_demo_join() {
  local sep=$1
  shift
  local out='' a
  for a in "$@"; do
    if [ -z "$out" ]; then
      out=$a
    else
      out="$out$sep$a"
    fi
  done
  printf '%s\n' "$out"
  [ "$#" -gt 0 ] || return 3
  return 0
}
