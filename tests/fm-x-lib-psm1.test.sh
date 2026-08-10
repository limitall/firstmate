#!/usr/bin/env bash
# Differential behavior test for bin/fm-x-lib.psm1 against bin/fm-x-lib.sh.
#
# bash is the ORACLE. Every case drives the two implementations with the SAME
# fixtures and asserts they answer identically; nothing here encodes what the
# answer "should" be. That matters most for the private-artifact gates, whose
# correct verdict on THIS filesystem is not the one their scenario names
# suggest: Git Bash mounts its drives and /tmp `noacl,posix=0,usertemp`, so
# chmod is accepted and does nothing, and the bash twin therefore ACCEPTS a
# directory a Linux host would refuse (measured here: fmx_private_artifact_dir_device
# on a chmod-755 directory returns a device and exit 0). A PowerShell twin that
# enforced real NTFS ACLs would refuse it - stronger, and WRONG, because both
# twins are live against the same state/ during the conversion and would then
# disagree about the same file. docs/powershell-port.md ("Things that must NOT
# be improved") and the inventory's R6 name this exact gate, and hardcoding a
# rejection here would quietly certify the forbidden change.
#
# The single most valuable assertion in this file is CROSS-WORLD INTEROP: a
# record written by PowerShell is read correctly by the bash reader, and a
# record written by bash is read correctly by the PowerShell reader, with the
# raw bytes compared as well as the parsed result. That is the property the
# whole transition rests on.
#
# THREE PHASES, NOT INTERLEAVED CALLS. Every bash answer is captured first,
# then ONE pwsh process produces every PowerShell answer and writes the
# PS-authored records, then bash reads those back. A pwsh start costs ~360ms on
# this Defender-protected host and an MSYS `stat` can cost a second under load,
# so per-assertion invocations would dominate the run without buying coverage.
#
# NO `( ... )` SUBSHELLS around anything that asserts. A subshell cannot report
# a failure back to the parent's counters, so a scheme that can LOSE a failure
# is worse than none: the suite would certify work it never checked. The
# assertion COUNT is itself asserted at the end for the same reason.
#
# Every path handed to pwsh, INCLUDING the Import-Module path, goes through
# fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads /tmp/x
# as C:\tmp\x - verified).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the bash oracle needs it)"; exit 0; }

[ -f "$ROOT/bin/fm-x-lib.psm1" ] || fail "bin/fm-x-lib.psm1 is missing"
MOD=$(fm_test_native_path "$ROOT/bin/fm-x-lib.psm1")

# The oracle, loaded the way its own production callers load it.
#
# fm-x-lib.sh's three meta helpers call fm_meta_lock_path, fm_lock_acquire_wait
# and fm_lock_release WITHOUT sourcing the library that defines them: they rely
# on the caller having done it, and both callers do (bin/fm-x-link.sh:47 and
# bin/fm-x-followup.sh:72 each `. fm-wake-lib.sh` right after `. fm-x-lib.sh`).
# Sourcing only fm-x-lib.sh therefore gives a CRIPPLED oracle - every meta
# rewrite refuses on a command-not-found rather than on any rule the function
# actually has - and the interop assertions below already encode the working
# contract ("the PowerShell reader reads a bash-written meta link" expects a
# link the crippled oracle never writes). Same two lines, same order, as the
# callers.
# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-x-lib-psm1)

# --- assertion bookkeeping ----------------------------------------------------

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected> <actual>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  bash    : [${expected}]
  psmodule: [${actual}]
"
  fi
}

# --- host capability probes ---------------------------------------------------
#
# Both are REAL properties of this filesystem, not conveniences, and both change
# which fixtures can even be built. They are probed rather than inferred from
# uname because the same MSYS host answers differently with Developer Mode or
# MSYS=winsymlinks set.

# Whether a chmod sticks. Where it does not, the bash twin's inert-chmod
# acceptance is the path under test and the strict-mode scenarios cannot be
# expressed at all.
MODES_ENFORCED=yes
_mode_probe=$(mktemp "${TMPDIR:-/tmp}/.fmxpsm-modeprobe.XXXXXX")
chmod 0 "$_mode_probe" 2>/dev/null
case "$(stat -c %a "$_mode_probe" 2>/dev/null || stat -f %Lp "$_mode_probe" 2>/dev/null)" in
  0|00|000) MODES_ENFORCED=yes ;;
  *) MODES_ENFORCED=no ;;
esac
rm -f "$_mode_probe"
unset _mode_probe

# Whether `ln -s` produces a real link. Stock Git Bash without Developer Mode
# silently COPIES, which would turn every link-REFUSAL scenario into a false
# pass: both worlds would be asked about a plain file and would agree for the
# wrong reason. Windows can still express a real DIRECTORY link through an NTFS
# junction (MSYS reports one as a symlink, and so does .NET's ReparsePoint
# attribute, which is what fm-common's Test-FmSymlink reads), so directory
# scenarios always run and FILE-link scenarios are gated.
SYMLINK_FILE_FIXTURES=yes
_link_target=$(mktemp "${TMPDIR:-/tmp}/.fmxpsm-linkprobe.XXXXXX")
_link_probe="${_link_target}.lnk"
ln -s "$_link_target" "$_link_probe" 2>/dev/null
[ -L "$_link_probe" ] || SYMLINK_FILE_FIXTURES=no
rm -f "$_link_probe" "$_link_target"
unset _link_probe _link_target

# fixture_symlink <target> <link>: a REAL link or a loud failure - never a
# silent copy. Directories fall back to an NTFS junction. Same approach as
# tests/fm-x-mode.test.sh, which solved this first.
fixture_symlink() {
  local target=$1 link=$2
  ln -s "$target" "$link" 2>/dev/null
  [ -L "$link" ] && return 0
  rm -rf "$link" 2>/dev/null
  if command -v cygpath >/dev/null 2>&1; then
    [ -e "$target" ] || mkdir -p "$target" 2>/dev/null
    if [ -d "$target" ]; then
      # //J (doubled) survives MSYS argument conversion; a single /J is
      # rewritten into a path and cmd rejects it as an invalid switch.
      cmd //c mklink //J "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null 2>&1
      [ -L "$link" ] && return 0
      rm -rf "$link" 2>/dev/null
    fi
  fi
  fail "cannot create a real link fixture ($link -> $target) on this host"
}

# --- the fixture tree ---------------------------------------------------------
#
# ONE builder, called twice, so the bash tree and the PowerShell tree are
# byte-identical before either side touches them. They must be separate trees
# because the publish cases MUTATE, and a shared tree would let one world's
# write decide the other world's verdict.

build_tree() {  # <root>
  local r=$1
  mkdir -p "$r"

  # A well-formed private artifact directory holding one valid record.
  mkdir -p "$r/ok/state/x-context"
  chmod 700 "$r/ok/state/x-context"
  jq -cn '{request_id:"req-ok",platform:"discord",reply_max_chars:"1900",recorded_at:1700000000}' \
    > "$r/ok/state/x-context/req-ok.json"
  chmod 600 "$r/ok/state/x-context/req-ok.json"

  # A directory left group/world readable. On an inert-chmod filesystem this is
  # indistinguishable from the private one, and the twins must agree on that.
  mkdir -p "$r/public/state/x-context"
  chmod 755 "$r/public/state/x-context"

  # A registry directory that is a LINK to somewhere else - the redirect the
  # gate exists to stop.
  mkdir -p "$r/linkdir/state" "$r/linkdir/external"
  fixture_symlink "$r/linkdir/external" "$r/linkdir/state/x-context"

  # A record with a second hard link: a valid-looking private file that another
  # name also points at.
  mkdir -p "$r/hardlink/state/x-context"
  chmod 700 "$r/hardlink/state/x-context"
  jq -cn '{request_id:"req-hl",platform:"x",reply_max_chars:"280",recorded_at:1700000000}' \
    > "$r/hardlink/state/x-context/req-hl.json"
  chmod 600 "$r/hardlink/state/x-context/req-hl.json"
  ln "$r/hardlink/state/x-context/req-hl.json" "$r/hardlink/state/x-context/req-hl.alias"

  # A record that is a LINK to a file outside the registry.
  if [ "$SYMLINK_FILE_FIXTURES" = yes ]; then
    mkdir -p "$r/linkfile/state/x-context"
    chmod 700 "$r/linkfile/state/x-context"
    jq -cn '{request_id:"req-lf",platform:"discord",reply_max_chars:"1900",recorded_at:1700000000}' \
      > "$r/linkfile/external.json"
    ln -s "$r/linkfile/external.json" "$r/linkfile/state/x-context/req-lf.json"
  fi

  # A record left world-readable.
  mkdir -p "$r/wrongmode/state/x-context"
  chmod 700 "$r/wrongmode/state/x-context"
  jq -cn '{request_id:"req-wm",platform:"x",reply_max_chars:"280",recorded_at:1700000000}' \
    > "$r/wrongmode/state/x-context/req-wm.json"
  chmod 644 "$r/wrongmode/state/x-context/req-wm.json"

  # A DIRECTORY where a record is expected.
  mkdir -p "$r/dirfile/state/x-context/req-df.json"
  chmod 700 "$r/dirfile/state/x-context"

  # Empty trees for the publish and claim cases, so those start from nothing and
  # exercise the create-the-directory path too.
  mkdir -p "$r/publish"
  mkdir -p "$r/claim"
  mkdir -p "$r/interop"

  # Retention fixtures: expired, exactly at the seven-day boundary, legacy (no
  # recorded_at at all), malformed, and an absurd future timestamp.
  mkdir -p "$r/prune/state/x-context"
  chmod 700 "$r/prune/state/x-context"
  jq -cn '{request_id:"req-expired",platform:"x",reply_max_chars:"280",recorded_at:1699395199}' \
    > "$r/prune/state/x-context/req-expired.json"
  jq -cn '{request_id:"req-keep",platform:"discord",reply_max_chars:"1900",recorded_at:1699395200}' \
    > "$r/prune/state/x-context/req-keep.json"
  jq -cn '{request_id:"req-legacy",platform:"discord",reply_max_chars:"1900"}' \
    > "$r/prune/state/x-context/req-legacy.json"
  printf '{not-json\n' > "$r/prune/state/x-context/req-malformed.json"
  jq -cn '{request_id:"req-future",platform:"x",reply_max_chars:"280",recorded_at:"9999999999999999999"}' \
    > "$r/prune/state/x-context/req-future.json"
  chmod 600 "$r/prune/state/x-context/"*.json
  touch -t 202001010000 \
    "$r/prune/state/x-context/req-legacy.json" \
    "$r/prune/state/x-context/req-malformed.json" \
    "$r/prune/state/x-context/req-future.json"

  # A task meta record carrying an existing link, for the rewrite cases.
  mkdir -p "$r/meta"
  printf 'window=firstmate:fm-t1\nharness=claude\nx_request=req-old\nx_request_ts=1600000000\nx_followups=1\nx_platform=x\nx_reply_max_chars=280\nyolo=off\n' \
    > "$r/meta/linked.meta"
  printf 'window=firstmate:fm-t2\nharness=codex\n' > "$r/meta/plain.meta"

  # Payload files for the reply-context extractor, covering each inference path
  # and each malformed shape.
  mkdir -p "$r/payload"
  jq -cn '{request_id:"a",reply_platform:"Discord",reply_max_chars:1500}' > "$r/payload/explicit.json"
  jq -cn '{request_id:"b",tweet_id:"discord:111:222"}' > "$r/payload/discordid.json"
  jq -cn '{request_id:"c",tweet_id:"1234567890",reply_max_chars:"280"}' > "$r/payload/xid.json"
  jq -cn '{request_id:"d",text:"no platform signal at all"}' > "$r/payload/unknown.json"
  jq -cn '{request_id:"e",platform:"TWITTER",message_limit:"777"}' > "$r/payload/twitter.json"
  jq -cn '{request_id:"f",platform:"",provider:"discordapp",max_chars:900}' > "$r/payload/fallthrough.json"
  jq -cn '{request_id:"g",platform:"mastodon",reply_max_chars:280.5}' > "$r/payload/nonint.json"
  printf '{broken\n' > "$r/payload/malformed.json"
  printf '[1,2,3]\n' > "$r/payload/array.json"
  printf 'null\n' > "$r/payload/null.json"

  # .env fixtures. The tricky lines are deliberate: a lowercase key must NOT
  # satisfy an uppercase lookup (grep -E is case-sensitive and PowerShell's
  # -match is not, which is a real way to leak a token), "KEY =" must not match
  # "KEY=", the LAST assignment wins, one layer of matching quotes comes off,
  # a CR from a Windows edit is stripped, and a value may contain '='.
  mkdir -p "$r/env"
  {
    printf 'FMX_PAIRING_TOKEN=first-wins-not\n'
    printf 'fmx_pairing_token=lowercase-must-not-match\n'
    printf 'FMX_PAIRING_TOKEN =spaced-key-must-not-match\n'
    printf '   export FMX_PAIRING_TOKEN="  quoted value  "\n'
    printf "FMX_RELAY_URL='https://relay.example/'\n"
    printf 'FMX_X_REPLY_MAX_CHARS=   40   \n'
    printf 'FMX_EQUALS=a=b=c\n'
    printf 'FMX_EMPTY=\n'
    printf 'FMX_CRLF=windows-edit\r\n'
    printf 'FMX_UNBALANCED="only-one-quote\n'
  } > "$r/env/.env"
}

BASH_TREE="$TMP_ROOT/bash"
PS_TREE="$TMP_ROOT/ps"
build_tree "$BASH_TREE"
build_tree "$PS_TREE"

# Split-thread fixtures live in FILES, one per case, so the text reaches both
# worlds byte-identically: an emoji or a tab passed as an argv element is at the
# mercy of MSYS argument conversion and PowerShell's own -File re-splitting.
SPLIT_DIR="$TMP_ROOT/split"
mkdir -p "$SPLIT_DIR"
printf 'Aye, all shipshape.' > "$SPLIT_DIR/01-short.txt"
printf 'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november' \
  > "$SPLIT_DIR/02-words.txt"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$SPLIT_DIR/03-hardsplit.txt"
printf 'one two three four five six seven eight nine ten' > "$SPLIT_DIR/04-capped.txt"
cat > "$SPLIT_DIR/05-fenced.txt" <<'TXT'
Intro paragraph has enough words to make the reply split before the fenced block.

```bash
printf '%s\n' "hello from a fenced block"
printf '%s\n' "the marker must not land in here"
```

Final paragraph also has enough words to make the reply split after the fenced block.
TXT
printf '' > "$SPLIT_DIR/06-empty.txt"
printf '   \n\n\t  \n' > "$SPLIT_DIR/07-whitespace.txt"
# Codepoints, not UTF-16 code units: each of these emoji is ONE jq codepoint and
# TWO PowerShell chars, so a twin that measured .Length would split at a
# different budget and could slice a surrogate pair in half.
printf 'cafe\xc3\xa9 \xf0\x9f\x98\x80 \xf0\x9f\x9a\xa2 sailing onward with a long tail of words to force a split here' \
  > "$SPLIT_DIR/08-astral.txt"
printf 'First paragraph.\n\nSecond paragraph is a good deal longer so that the packer has to make a real choice.\n\nThird.' \
  > "$SPLIT_DIR/09-paragraphs.txt"
printf 'exactly one unit that is far too long to fit anywhere near the given budget' \
  > "$SPLIT_DIR/10-cap-one.txt"

# <fixture> <limit> <cap>, chosen so each exercises a different branch:
# a within-limit reply, word packing, a hard split, the cap plus ellipsis, the
# fenced-code path, both empty inputs, codepoint arithmetic, paragraph packing,
# and a cap of 1 (the array-of-one edge that unrolls to a bare string in
# PowerShell unless every array return is wrapped).
SPLIT_CASES="01-short 280 25
02-words 30 25
03-hardsplit 20 25
04-capped 20 2
05-fenced 120 25
06-empty 280 25
07-whitespace 280 25
08-astral 40 25
09-paragraphs 60 25
10-cap-one 30 1"

# --- phase 1: the bash oracle -------------------------------------------------
#
# Each verdict becomes a token: "0"/"1" for a predicate, the printed value for a
# producer, and the literal <fail> when the twin returned non-zero with output
# that must not be mistaken for an answer.

# Values are ENCODED as they are recorded, not at comparison time: several
# records are genuinely multi-line (the poll shim, a meta body, a published
# record), and a raw newline inside a TSV store would split one record into two
# and make every later lookup find the wrong half - a silent false pass.
FM_ENC=
encode() {  # <value> -> FM_ENC
  local v=$1
  v=${v//$'\r'/$'\n'}
  v=${v//$'\n'/\\n}
  v=${v//$'\t'/\\t}
  FM_ENC=$v
}

# An indexed array with an in-shell lookup, NOT a `$(...)` scan: every command
# substitution is a fork, MSYS forks cost on the order of a second on this host
# under load, and this file looks a value up once per assertion.
B_KEYS=()
B_RECS=()
bash_record() {  # <key> <value>
  encode "$2"
  B_KEYS+=("$1")
  B_RECS+=("$1"$'\t'"$FM_ENC")
}

bash_rc() {  # <key> <command...>
  local key=$1; shift
  "$@" >/dev/null 2>&1
  bash_record "$key" "$?"
}

bash_out() {  # <key> <command...>
  local key=$1 out rc; shift
  out=$("$@" 2>/dev/null); rc=$?
  # The refusal marker is carried into the comparison rather than flattened to
  # an empty string, so "both refused" can never read as "both answered with
  # nothing".
  if [ "$rc" -ne 0 ]; then bash_record "$key" "<fail>"; else bash_record "$key" "$out"; fi
}

FM_BV=
bval() {  # <key> -> FM_BV
  local key=$1 rec
  FM_BV='<missing>'
  for rec in ${B_RECS+"${B_RECS[@]}"}; do
    case "$rec" in "$key"$'\t'*) FM_BV=${rec#*$'\t'}; return 0 ;; esac
  done
}

BT="$BASH_TREE"

# 1a. Directory gates.
bash_out dir.ok        fmx_private_artifact_dir_device "$BT/ok/state/x-context"
bash_out dir.public    fmx_private_artifact_dir_device "$BT/public/state/x-context"
bash_out dir.linkdir   fmx_private_artifact_dir_device "$BT/linkdir/state/x-context"
bash_out dir.missing   fmx_private_artifact_dir_device "$BT/ok/state/nope"
bash_out dir.isfile    fmx_private_artifact_dir_device "$BT/ok/state/x-context/req-ok.json"
bash_out dir.tmproot   fmx_private_artifact_dir_device "$TMP_ROOT"
bash_out prepare.new   fmx_private_artifact_dir_prepare "$BT/publish/state/x-context"
bash_out prepare.link  fmx_private_artifact_dir_prepare "$BT/linkdir/state/x-context"

# 1b. File gates. The device argument is supplied explicitly so the same-device
# comparison is exercised in both directions without needing a second volume.
OK_DEV=$(fmx_private_artifact_dir_device "$BT/ok/state/x-context" 2>/dev/null)
bash_rc file.ok         fmx_single_link_file_valid "$BT/ok/state/x-context/req-ok.json" "$OK_DEV"
bash_rc file.ok.nodev   fmx_single_link_file_valid "$BT/ok/state/x-context/req-ok.json" ""
bash_rc file.wrongdev   fmx_single_link_file_valid "$BT/ok/state/x-context/req-ok.json" 4294967295
bash_rc file.hardlink   fmx_single_link_file_valid "$BT/hardlink/state/x-context/req-hl.json" ""
bash_rc file.missing    fmx_single_link_file_valid "$BT/ok/state/x-context/absent.json" ""
bash_rc file.isdir      fmx_single_link_file_valid "$BT/dirfile/state/x-context/req-df.json" ""
bash_rc mode.ok         fmx_single_link_file_mode_valid "$BT/ok/state/x-context/req-ok.json" 600 "$OK_DEV"
bash_rc mode.wrongmode  fmx_single_link_file_mode_valid "$BT/wrongmode/state/x-context/req-wm.json" 600 ""
bash_rc mode.hardlink   fmx_single_link_file_mode_valid "$BT/hardlink/state/x-context/req-hl.json" 600 ""
bash_rc mode.wrongdev   fmx_single_link_file_mode_valid "$BT/ok/state/x-context/req-ok.json" 600 4294967295
bash_rc inert.ok        fmx_mode_enforcement_inert "$BT/ok/state/x-context"
bash_rc inert.missing   fmx_mode_enforcement_inert "$BT/ok/state/nowhere"
bash_rc artifact.ok     fmx_private_artifact_file_valid "$BT/ok/state/x-context" req-ok.json 600
bash_rc artifact.linkdir fmx_private_artifact_file_valid "$BT/linkdir/state/x-context" req-lf.json 600
bash_rc artifact.hardlink fmx_private_artifact_file_valid "$BT/hardlink/state/x-context" req-hl.json 600
bash_rc artifact.dotbase  fmx_private_artifact_file_valid "$BT/ok/state/x-context" .hidden.json 600
bash_rc artifact.slashbase fmx_private_artifact_file_valid "$BT/ok/state/x-context" sub/req.json 600
bash_rc artifact.badmode  fmx_private_artifact_file_valid "$BT/ok/state/x-context" req-ok.json 644
if [ "$SYMLINK_FILE_FIXTURES" = yes ]; then
  bash_rc file.linkfile  fmx_single_link_file_valid "$BT/linkfile/state/x-context/req-lf.json" ""
  bash_rc artifact.linkfile fmx_private_artifact_file_valid "$BT/linkfile/state/x-context" req-lf.json 600
fi

# 1c. Publication.
printf '{"request_id":"req-pub","note":"published"}\n' \
  | fmx_private_artifact_publish_stdin "$BT/publish/state/x-outbox" req-pub.json 600 >/dev/null 2>&1
bash_record publish.ok "$?"
bash_record publish.content "$(cat "$BT/publish/state/x-outbox/req-pub.json" 2>/dev/null)"
printf '{"request_id":"req-pub","note":"replaced"}\n' \
  | fmx_private_artifact_publish_stdin "$BT/publish/state/x-outbox" req-pub.json 600 >/dev/null 2>&1
bash_record publish.replace "$?"
bash_record publish.replaced "$(cat "$BT/publish/state/x-outbox/req-pub.json" 2>/dev/null)"
printf 'x\n' | fmx_private_artifact_publish_stdin "$BT/publish/state/x-outbox" .dot.json 600 >/dev/null 2>&1
bash_record publish.dotbase "$?"
printf 'x\n' | fmx_private_artifact_publish_stdin "$BT/publish/state/x-outbox" sub/x.json 600 >/dev/null 2>&1
bash_record publish.slashbase "$?"
printf 'x\n' | fmx_private_artifact_publish_stdin "$BT/publish/state/x-outbox" ok.json 644 >/dev/null 2>&1
bash_record publish.badmode "$?"
printf 'x\n' | fmx_private_artifact_publish_stdin "$BT/linkdir/state/x-context" req.json 600 >/dev/null 2>&1
bash_record publish.linkdir "$?"
printf 'x\n' | fmx_private_artifact_publish_stdin "$BT/hardlink/state/x-context" req-hl.json 600 >/dev/null 2>&1
bash_record publish.overhardlink "$?"
bash_record publish.hardlinkkept "$(jq -r .platform "$BT/hardlink/state/x-context/req-hl.json" 2>/dev/null)"
> "$TMP_ROOT/temps.txt"
find "$BT/publish" "$BT/hardlink" -name '*.fm-x.*' -print > "$TMP_ROOT/temps.txt" 2>/dev/null
bash_record publish.temps "$(wc -l < "$TMP_ROOT/temps.txt" | tr -d ' ')"

printf '{"request_id":"req-once"}\n' \
  | fmx_private_artifact_publish_stdin_once "$BT/claim/state/x-context" req-once.json 600 >/dev/null 2>&1
bash_record once.first "$?"
printf '{"request_id":"req-once","second":true}\n' \
  | fmx_private_artifact_publish_stdin_once "$BT/claim/state/x-context" req-once.json 600 >/dev/null 2>&1
bash_record once.second "$?"
bash_record once.content "$(cat "$BT/claim/state/x-context/req-once.json" 2>/dev/null)"
printf 'x\n' | fmx_private_artifact_publish_stdin_once "$BT/claim/state/x-context" .dot.json 600 >/dev/null 2>&1
bash_record once.dotbase "$?"

# 1d. The reply-context extractor, over every payload shape.
for p in explicit discordid xid unknown twitter fallthrough nonint malformed array null; do
  bash_out "extract.$p" fmx_extract_reply_context "$BT/payload/$p.json"
done
bash_out extract.missing fmx_extract_reply_context "$BT/payload/absent.json"

# 1e. Registry read/write, retention, and the offer claim. FMX_NOW_OVERRIDE
# pins every timestamp so the two worlds produce byte-comparable records.
export FMX_NOW_OVERRIDE=1700000000
bash_out registry.get.ok      fmx_context_registry_get "$BT/ok/state" req-ok
bash_out registry.get.linkdir fmx_context_registry_get "$BT/linkdir/state" req-lf
bash_out registry.get.hardlink fmx_context_registry_get "$BT/hardlink/state" req-hl
bash_out registry.get.wrongmode fmx_context_registry_get "$BT/wrongmode/state" req-wm
bash_out registry.get.absent  fmx_context_registry_get "$BT/ok/state" req-nothere
bash_out registry.get.badid   fmx_context_registry_get "$BT/ok/state" ../escape
bash_out registry.get.dotid   fmx_context_registry_get "$BT/ok/state" .hidden
bash_rc  registry.set.new     fmx_context_registry_set "$BT/interop/state" req-interop x 280
bash_record registry.set.raw  "$(cat "$BT/interop/state/x-context/req-interop.json" 2>/dev/null)"
bash_rc  registry.set.noaxis  fmx_context_registry_set "$BT/interop/state" req-empty "" ""
bash_record registry.set.noaxis.file "$([ -e "$BT/interop/state/x-context/req-empty.json" ] && echo present || echo absent)"
bash_rc  registry.set.linkdir fmx_context_registry_set "$BT/linkdir/state" req-x x 280
bash_rc  registry.set.hardlink fmx_context_registry_set "$BT/hardlink/state" req-hl discord 1900
bash_rc  registry.set.badid   fmx_context_registry_set "$BT/interop/state" "bad id" x 280
bash_out registry.recordedat  fmx_context_registry_recorded_at "$BT/ok/state/x-context/req-ok.json" 1700000000
bash_rc  registry.claim.first fmx_offer_registry_claim "$BT/interop/state" req-offer
bash_rc  registry.claim.again fmx_offer_registry_claim "$BT/interop/state" req-offer
bash_record registry.claim.raw "$(cat "$BT/interop/state/x-context/req-offer.offered.json" 2>/dev/null)"
bash_rc  registry.claim.badid fmx_offer_registry_claim "$BT/interop/state" "bad/id"
fmx_context_registry_prune "$BT/prune/state" >/dev/null 2>&1
bash_record prune.rc "$?"
# LC_ALL=C so the ordering is BYTE order, which the PowerShell side reproduces
# with an ordinal sort. A locale-collating sort ignores punctuation in its
# primary weight and would order req-keep/req-legacy differently from either.
bash_record prune.survivors "$(cd "$BT/prune/state/x-context" 2>/dev/null && ls | LC_ALL=C sort | tr '\n' ',')"
bash_out registry.resolve.ok   fmx_resolve_reply_context "$BT/ok/state" req-ok 0
bash_out registry.resolve.none fmx_resolve_reply_context "$BT/ok/state" req-nothere 0
unset FMX_NOW_OVERRIDE

# 1f. Reply budgets, thread splitting, and the payload builders.
bash_out limit.explicit  fmx_reply_limit_for_platform x 500
bash_out limit.toosmall  fmx_reply_limit_for_platform discord 12
bash_out limit.discord   fmx_reply_limit_for_platform discord ""
bash_out limit.x         fmx_reply_limit_for_platform x ""
bash_out limit.unknown   fmx_reply_limit_for_platform "" ""
bash_out limit.nonnum    fmx_reply_limit_for_platform discord abc

printf '%s\n' "$SPLIT_CASES" | while IFS=' ' read -r name limit cap; do
  [ -n "$name" ] || continue
  printf 'split.%s\t%s\n' "$name" "$(fmx_split_thread "$limit" "$cap" < "$SPLIT_DIR/$name.txt" 2>/dev/null)"
done > "$TMP_ROOT/bash-split.tsv"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  bash_record "${line%%$'\t'*}" "${line#*$'\t'}"
done < "$TMP_ROOT/bash-split.tsv"

CHUNKS_MULTI=$(fmx_split_thread 30 25 < "$SPLIT_DIR/02-words.txt")
CHUNKS_ONE=$(fmx_split_thread 280 25 < "$SPLIT_DIR/01-short.txt")
N_MULTI=$(printf '%s' "$CHUNKS_MULTI" | jq 'length')
bash_record payload.multi "$(fmx_reply_payload_json req-p "$CHUNKS_MULTI" "$N_MULTI")"
bash_record payload.single "$(fmx_reply_payload_json req-p "$CHUNKS_ONE" 1)"
bash_record outbox.multi "$(fmx_reply_outbox_json req-p "$CHUNKS_MULTI" "$N_MULTI" 0)"
bash_record outbox.followup "$(fmx_reply_outbox_json req-p "$CHUNKS_ONE" 1 1)"
bash_record outbox.image "$(fmx_reply_outbox_json req-p "$CHUNKS_ONE" 1 1 '{"media_type":"image/png","bytes":42,"source_path":"/tmp/a.png"}')"

# 1g. .env reading and config resolution.
for k in FMX_PAIRING_TOKEN FMX_RELAY_URL FMX_X_REPLY_MAX_CHARS FMX_EQUALS FMX_EMPTY FMX_CRLF FMX_UNBALANCED FMX_ABSENT; do
  bash_record "env.$k" "$(fmx_env_get "$k" "$BT/env/.env")"
done
bash_record env.nofile "$(fmx_env_get FMX_PAIRING_TOKEN "$BT/env/none.env")"

# Six configuration scenarios, each a documented branch of fmx_load_config:
# the .env alone, an explicit override, an explicitly EMPTY override (which must
# beat the .env - the `${VAR+x}` vs `${VAR:-}` distinction), truthiness of
# FMX_DRY_RUN, the numeric floors and ceiling, and a value too large for the
# shell's own arithmetic.
# All seven cases in ONE bash process. Each needs a different environment, which
# reads naturally as seven `env ... bash -c` invocations - but each of those is a
# fresh shell that re-sources fm-x-lib.sh, and an MSYS process start costs on the
# order of a second on this host under load. Setting and unsetting inside one
# shell is the same coverage for one seventh of the cost, and every case still
# records under its own key so a failure stays attributable.
bash -c '
    . "$1/bin/fm-x-lib.sh"
    export FM_HOME="$2"
    emit() { printf "config.%s\t%s|%s|%s|%s|%s|%s\n" "$1" "$FMX_TOKEN" "$FMX_RELAY" "$FMX_DRY" "$FMX_MAX" "$FMX_DISCORD_MAX" "$FMX_THREAD_MAX"; }
    clear_cfg() { unset FMX_PAIRING_TOKEN FMX_RELAY_URL FMX_DRY_RUN FMX_X_REPLY_MAX_CHARS FMX_DISCORD_REPLY_MAX_CHARS FMX_X_THREAD_MAX FMX_ENV_FILE; }
    clear_cfg; fmx_load_config; emit envfile
    clear_cfg; export FMX_PAIRING_TOKEN=explicit FMX_RELAY_URL=https://other.example/; fmx_load_config; emit override
    clear_cfg; export FMX_PAIRING_TOKEN=; fmx_load_config; emit emptytoken
    clear_cfg; export FMX_DRY_RUN=YES; fmx_load_config; emit dry
    clear_cfg; export FMX_DRY_RUN=Off; fmx_load_config; emit dryoff
    clear_cfg; export FMX_X_REPLY_MAX_CHARS=3 FMX_DISCORD_REPLY_MAX_CHARS=5000 FMX_X_THREAD_MAX=0; fmx_load_config; emit floors
    clear_cfg; export FMX_X_REPLY_MAX_CHARS=99999999999999999999999 FMX_DISCORD_REPLY_MAX_CHARS=99999999999999999999999; fmx_load_config; emit huge
  ' _ "$ROOT" "$BT/env" > "$TMP_ROOT/bash-config.tsv" 2>/dev/null
while IFS= read -r line; do
  [ -n "$line" ] || continue
  bash_record "${line%%$'\t'*}" "${line#*$'\t'}"
done < "$TMP_ROOT/bash-config.tsv"

# 1h. printf %q, through the poll-shim content the watcher byte-compares.
bash_record shim.plain "$(fmx_poll_shim_content /f/home /f/root)"
bash_record shim.space "$(fmx_poll_shim_content '/f/my home' /f/root)"
bash_record shim.meta "$(fmx_poll_shim_content '/f/a$b`c(d)e{f}' '/f/r&t')"
bash_record shim.tilde "$(fmx_poll_shim_content '~/home' '/f/r~t')"
# $'...' so the é reaches printf %q as real UTF-8 BYTES; in plain single quotes
# the escape would stay a literal backslash-x sequence and the case would test
# backslash quoting instead of the locale-dependent non-ASCII path it is for.
bash_record shim.utf8 "$(fmx_poll_shim_content $'/f/caf\xc3\xa9' /f/root)"
bash_record shimv1.plain "$(fmx_poll_shim_v1_content /f/home /f/root)"

# 1i. Meta link rewriting.
bash_record meta.link.rc "$(fmx_meta_link_set "$BT/meta/linked.meta" req-new 1700000000 3 discord 1900 >/dev/null 2>&1; echo $?)"
bash_record meta.link.body "$(cat "$BT/meta/linked.meta")"
bash_record meta.followups.rc "$(fmx_meta_followups_set "$BT/meta/linked.meta" 4 >/dev/null 2>&1; echo $?)"
bash_record meta.followups.body "$(cat "$BT/meta/linked.meta")"
bash_record meta.get "$(fmx_meta_get "$BT/meta/linked.meta" x_platform)"
bash_record meta.clear.rc "$(fmx_meta_link_clear "$BT/meta/linked.meta" >/dev/null 2>&1; echo $?)"
bash_record meta.clear.body "$(cat "$BT/meta/linked.meta")"
bash_record meta.plain.rc "$(fmx_meta_link_set "$BT/meta/plain.meta" req-p 1700000000 >/dev/null 2>&1; echo $?)"
bash_record meta.plain.body "$(cat "$BT/meta/plain.meta")"
bash_record meta.missing.rc "$(fmx_meta_link_set "$BT/meta/absent.meta" req-p 1700000000 >/dev/null 2>&1; echo $?)"
bash_record meta.clearmissing.rc "$(fmx_meta_link_clear "$BT/meta/absent.meta" >/dev/null 2>&1; echo $?)"

# --- phase 2: the PowerShell module, in ONE process ---------------------------

QUERY="$TMP_ROOT/query.ps1"
cat > "$QUERY" <<'PS1'
#Requires -Version 7.0
# Emits "<key><TAB><value>" for every case, with LF newlines and no CRLF, so the
# bash side can compare tokens without re-parsing. A value's own newlines are
# encoded as \n rather than stripped, because several records (the shim, a meta
# body) are multi-line and their line structure is exactly what is under test.
param(
    [Parameter(Mandatory)][string]$Module,
    [Parameter(Mandatory)][string]$Common,
    [Parameter(Mandatory)][string]$Tree,
    [Parameter(Mandatory)][string]$BashTree,
    [Parameter(Mandatory)][string]$SplitDir,
    [Parameter(Mandatory)][string]$SplitCases,
    [Parameter(Mandatory)][string]$TmpRoot,
    [Parameter(Mandatory)][string]$SymlinkFileFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# fm-common FIRST, and only then the module under test. The module imports
# fm-common as a NESTED import without -Force, so fm-common's own functions are
# not re-exported through it and this harness has to ask for them itself. The
# order is load-bearing: importing fm-common with -Force AFTER fm-x-lib would
# REMOVE the loaded instance and re-import it globally, which is exactly the
# breakage bin/fm-composer-lib.psm1's header documents.
Import-Module $Common -Force
Import-Module $Module -Force

function Write-Case {
    param([Parameter(Mandatory)][string]$Key, [Parameter()]$Value)
    if ($null -eq $Value) { $Value = '' }
    $text = ([string]$Value) -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    $text = $text -replace "`n", '\n'
    $text = $text -replace "`t", '\t'
    [Console]::Out.Write($Key + "`t" + $text + "`n")
}

# Every case runs inside a try. The catch matters as much as the value: under
# $ErrorActionPreference = 'Stop' a helper that forgot to guard a .NET call
# THROWS, and that must surface as an attributable case rather than as a
# silently missing line or a dead process.
function Invoke-Case {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        Write-Case -Key $Key -Value (& $Body)
    } catch {
        Write-Case -Key $Key -Value '<threw>'
        Write-Case -Key "$Key.error" -Value $_.Exception.Message
    }
}

# bash prints 0 for success and non-zero for a refusal; these predicates return
# $true/$false. Mapped here, at the boundary, rather than in the module.
function Get-Rc { param([Parameter(Mandatory)][bool]$Ok) if ($Ok) { '0' } else { '1' } }
# A producer that fails prints nothing and returns non-zero; bash_out records
# that as the literal <fail>.
function Get-Value { param([Parameter()]$Value) if ($null -eq $Value) { '<fail>' } else { [string]$Value } }
# Every bash file-content record went through `$(cat ...)`, which strips TRAILING
# newlines. These functions return the file's real bytes, so the same trailing
# newline is dropped here - at the comparison boundary, not in the module.
function Get-Trimmed { param([Parameter(Mandatory)][string]$Path) (Get-FmFileText $Path).TrimEnd("`n") }

$T = $Tree

# --- directory gates ---
Invoke-Case 'dir.ok'      { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory "$T/ok/state/x-context") }
Invoke-Case 'dir.public'  { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory "$T/public/state/x-context") }
Invoke-Case 'dir.linkdir' { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory "$T/linkdir/state/x-context") }
Invoke-Case 'dir.missing' { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory "$T/ok/state/nope") }
Invoke-Case 'dir.isfile'  { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory "$T/ok/state/x-context/req-ok.json") }
Invoke-Case 'dir.tmproot' { Get-Value (Get-FmxPrivateArtifactDirDevice -Directory $TmpRoot) }
Invoke-Case 'prepare.new'  { Get-Value (Initialize-FmxPrivateArtifactDir -Directory "$T/publish/state/x-context") }
Invoke-Case 'prepare.link' { Get-Value (Initialize-FmxPrivateArtifactDir -Directory "$T/linkdir/state/x-context") }

$okDev = Get-FmxPrivateArtifactDirDevice -Directory "$T/ok/state/x-context"
if ($null -eq $okDev) { $okDev = '' }

# --- file gates ---
Invoke-Case 'file.ok'        { Get-Rc (Test-FmxSingleLinkFile -Path "$T/ok/state/x-context/req-ok.json" -Device $okDev) }
Invoke-Case 'file.ok.nodev'  { Get-Rc (Test-FmxSingleLinkFile -Path "$T/ok/state/x-context/req-ok.json" -Device '') }
Invoke-Case 'file.wrongdev'  { Get-Rc (Test-FmxSingleLinkFile -Path "$T/ok/state/x-context/req-ok.json" -Device '4294967295') }
Invoke-Case 'file.hardlink'  { Get-Rc (Test-FmxSingleLinkFile -Path "$T/hardlink/state/x-context/req-hl.json" -Device '') }
Invoke-Case 'file.missing'   { Get-Rc (Test-FmxSingleLinkFile -Path "$T/ok/state/x-context/absent.json" -Device '') }
Invoke-Case 'file.isdir'     { Get-Rc (Test-FmxSingleLinkFile -Path "$T/dirfile/state/x-context/req-df.json" -Device '') }
Invoke-Case 'mode.ok'        { Get-Rc (Test-FmxSingleLinkFileMode -Path "$T/ok/state/x-context/req-ok.json" -Mode '600' -Device $okDev) }
Invoke-Case 'mode.wrongmode' { Get-Rc (Test-FmxSingleLinkFileMode -Path "$T/wrongmode/state/x-context/req-wm.json" -Mode '600' -Device '') }
Invoke-Case 'mode.hardlink'  { Get-Rc (Test-FmxSingleLinkFileMode -Path "$T/hardlink/state/x-context/req-hl.json" -Mode '600' -Device '') }
Invoke-Case 'mode.wrongdev'  { Get-Rc (Test-FmxSingleLinkFileMode -Path "$T/ok/state/x-context/req-ok.json" -Mode '600' -Device '4294967295') }
Invoke-Case 'inert.ok'       { Get-Rc (Test-FmxModeEnforcementInert -Directory "$T/ok/state/x-context") }
Invoke-Case 'inert.missing'  { Get-Rc (Test-FmxModeEnforcementInert -Directory "$T/ok/state/nowhere") }
Invoke-Case 'artifact.ok'         { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/ok/state/x-context" -BaseName 'req-ok.json' -Mode '600') }
Invoke-Case 'artifact.linkdir'    { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/linkdir/state/x-context" -BaseName 'req-lf.json' -Mode '600') }
Invoke-Case 'artifact.hardlink'   { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/hardlink/state/x-context" -BaseName 'req-hl.json' -Mode '600') }
Invoke-Case 'artifact.dotbase'    { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/ok/state/x-context" -BaseName '.hidden.json' -Mode '600') }
Invoke-Case 'artifact.slashbase'  { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/ok/state/x-context" -BaseName 'sub/req.json' -Mode '600') }
Invoke-Case 'artifact.badmode'    { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/ok/state/x-context" -BaseName 'req-ok.json' -Mode '644') }
if ($SymlinkFileFixtures -eq 'yes') {
    Invoke-Case 'file.linkfile'     { Get-Rc (Test-FmxSingleLinkFile -Path "$T/linkfile/state/x-context/req-lf.json" -Device '') }
    Invoke-Case 'artifact.linkfile' { Get-Rc (Test-FmxPrivateArtifactFile -Directory "$T/linkfile/state/x-context" -BaseName 'req-lf.json' -Mode '600') }
}

# --- publication ---
# Record bodies are built by CONCATENATING single-quoted JSON with an explicit
# newline. Spelling them as escaped double-quoted strings inside a "$( ... )"
# subexpression is where PowerShell's quoting rules actually bite: the nested
# quotes re-tokenize and the argument arrives split across positional
# parameters (observed here as "A positional parameter cannot be found that
# accepts argument 'request_id:req-once}'").
$publishText = '{"request_id":"req-pub","note":"published"}' + "`n"
$replaceText = '{"request_id":"req-pub","note":"replaced"}' + "`n"
$onceText = '{"request_id":"req-once"}' + "`n"
$onceText2 = '{"request_id":"req-once","second":true}' + "`n"
Invoke-Case 'publish.ok' { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/publish/state/x-outbox" -BaseName 'req-pub.json' -Mode '600' -Text $publishText) }
Invoke-Case 'publish.content' { Get-Trimmed "$T/publish/state/x-outbox/req-pub.json" }
Invoke-Case 'publish.replace' { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/publish/state/x-outbox" -BaseName 'req-pub.json' -Mode '600' -Text $replaceText) }
Invoke-Case 'publish.replaced' { Get-Trimmed "$T/publish/state/x-outbox/req-pub.json" }
Invoke-Case 'publish.dotbase'   { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/publish/state/x-outbox" -BaseName '.dot.json' -Mode '600' -Text "x`n") }
Invoke-Case 'publish.slashbase' { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/publish/state/x-outbox" -BaseName 'sub/x.json' -Mode '600' -Text "x`n") }
Invoke-Case 'publish.badmode'   { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/publish/state/x-outbox" -BaseName 'ok.json' -Mode '644' -Text "x`n") }
Invoke-Case 'publish.linkdir'   { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/linkdir/state/x-context" -BaseName 'req.json' -Mode '600' -Text "x`n") }
Invoke-Case 'publish.overhardlink' { Get-Rc (Publish-FmxPrivateArtifact -Directory "$T/hardlink/state/x-context" -BaseName 'req-hl.json' -Mode '600' -Text "x`n") }
Invoke-Case 'publish.hardlinkkept' {
    $r = Get-FmFileText "$T/hardlink/state/x-context/req-hl.json" | ConvertFrom-Json -AsHashtable
    $r['platform']
}
Invoke-Case 'publish.temps' {
    $n = 0
    foreach ($d in @("$T/publish", "$T/hardlink")) {
        $native = ConvertTo-FmNativePath $d
        if ([System.IO.Directory]::Exists($native)) {
            # Enumerate everything and filter with -like: .NET's own wildcard
            # matching carries DOS 8.3 legacy quirks around '.' that would not
            # agree with find -name here.
            $n += @([System.IO.Directory]::EnumerateFiles($native, '*', [System.IO.SearchOption]::AllDirectories) |
                    Where-Object { [System.IO.Path]::GetFileName($_) -like '*.fm-x.*' }).Count
        }
    }
    "$n"
}
Invoke-Case 'once.first'  { "$(Publish-FmxPrivateArtifactOnce -Directory "$T/claim/state/x-context" -BaseName 'req-once.json' -Mode '600' -Text $onceText)" }
Invoke-Case 'once.second' { "$(Publish-FmxPrivateArtifactOnce -Directory "$T/claim/state/x-context" -BaseName 'req-once.json' -Mode '600' -Text $onceText2)" }
Invoke-Case 'once.content' { Get-Trimmed "$T/claim/state/x-context/req-once.json" }
Invoke-Case 'once.dotbase' { "$(Publish-FmxPrivateArtifactOnce -Directory "$T/claim/state/x-context" -BaseName '.dot.json' -Mode '600' -Text "x`n")" }

# --- reply-context extraction ---
foreach ($p in @('explicit', 'discordid', 'xid', 'unknown', 'twitter', 'fallthrough', 'nonint', 'malformed', 'array', 'null')) {
    Invoke-Case "extract.$p" { Get-Value (Get-FmxReplyContextFromPayload -Path "$T/payload/$p.json") }
}
Invoke-Case 'extract.missing' { Get-Value (Get-FmxReplyContextFromPayload -Path "$T/payload/absent.json") }

# --- registry ---
$env:FMX_NOW_OVERRIDE = '1700000000'
Invoke-Case 'registry.get.ok'        { Get-FmxContextRegistryRecord -State "$T/ok/state" -RequestId 'req-ok' }
Invoke-Case 'registry.get.linkdir'   { Get-FmxContextRegistryRecord -State "$T/linkdir/state" -RequestId 'req-lf' }
Invoke-Case 'registry.get.hardlink'  { Get-FmxContextRegistryRecord -State "$T/hardlink/state" -RequestId 'req-hl' }
Invoke-Case 'registry.get.wrongmode' { Get-FmxContextRegistryRecord -State "$T/wrongmode/state" -RequestId 'req-wm' }
Invoke-Case 'registry.get.absent'    { Get-FmxContextRegistryRecord -State "$T/ok/state" -RequestId 'req-nothere' }
Invoke-Case 'registry.get.badid'     { Get-FmxContextRegistryRecord -State "$T/ok/state" -RequestId '../escape' }
Invoke-Case 'registry.get.dotid'     { Get-FmxContextRegistryRecord -State "$T/ok/state" -RequestId '.hidden' }
Invoke-Case 'registry.set.new'       { Get-Rc (Set-FmxContextRegistryRecord -State "$T/interop/state" -RequestId 'req-interop' -Platform 'x' -ReplyMax '280') }
Invoke-Case 'registry.set.raw'       { Get-Trimmed "$T/interop/state/x-context/req-interop.json" }
Invoke-Case 'registry.set.noaxis'    { Get-Rc (Set-FmxContextRegistryRecord -State "$T/interop/state" -RequestId 'req-empty' -Platform '' -ReplyMax '') }
Invoke-Case 'registry.set.noaxis.file' {
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath "$T/interop/state/x-context/req-empty.json"))) { 'present' } else { 'absent' }
}
Invoke-Case 'registry.set.linkdir'   { Get-Rc (Set-FmxContextRegistryRecord -State "$T/linkdir/state" -RequestId 'req-x' -Platform 'x' -ReplyMax '280') }
Invoke-Case 'registry.set.hardlink'  { Get-Rc (Set-FmxContextRegistryRecord -State "$T/hardlink/state" -RequestId 'req-hl' -Platform 'discord' -ReplyMax '1900') }
Invoke-Case 'registry.set.badid'     { Get-Rc (Set-FmxContextRegistryRecord -State "$T/interop/state" -RequestId 'bad id' -Platform 'x' -ReplyMax '280') }
Invoke-Case 'registry.recordedat'    { Get-Value (Get-FmxContextRegistryRecordedAt -Path "$T/ok/state/x-context/req-ok.json" -Now '1700000000') }
Invoke-Case 'registry.claim.first'   { "$(Request-FmxOfferRegistryClaim -State "$T/interop/state" -RequestId 'req-offer')" }
Invoke-Case 'registry.claim.again'   { "$(Request-FmxOfferRegistryClaim -State "$T/interop/state" -RequestId 'req-offer')" }
Invoke-Case 'registry.claim.raw'     { Get-Trimmed "$T/interop/state/x-context/req-offer.offered.json" }
Invoke-Case 'registry.claim.badid'   { "$(Request-FmxOfferRegistryClaim -State "$T/interop/state" -RequestId 'bad/id')" }
Invoke-Case 'prune.rc' { Clear-FmxExpiredContextRegistryRecord -State "$T/prune/state"; '0' }
Invoke-Case 'prune.survivors' {
    $native = ConvertTo-FmNativePath "$T/prune/state/x-context"
    $names = @()
    if ([System.IO.Directory]::Exists($native)) {
        $names = [string[]]@([System.IO.Directory]::EnumerateFiles($native) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        # Ordinal, i.e. BYTE order, matching the bash side's LC_ALL=C sort.
        # Sort-Object is culture-aware and orders punctuation differently.
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
    }
    if ($names.Count -eq 0) { '' } else { ($names -join ',') + ',' }
}
Invoke-Case 'registry.resolve.ok'   { Resolve-FmxReplyContext -State "$T/ok/state" -RequestId 'req-ok' }
Invoke-Case 'registry.resolve.none' { Resolve-FmxReplyContext -State "$T/ok/state" -RequestId 'req-nothere' }

# --- CROSS-WORLD INTEROP: read the record the BASH tree authored -------------
# The registry writer and reader are different languages here on purpose: this
# is the property the whole transition rests on, and it is asserted on the raw
# bytes as well as on the parsed result.
#
# STILL INSIDE the FMX_NOW_OVERRIDE window, and that is not tidiness. Every
# registry read runs the retention sweep first, so with the real clock the bash
# record's recorded_at of 1700000000 is years past the seven-day window and the
# reader would correctly DELETE it and then answer "no context" - destroying the
# fixture and reporting a false divergence.
Invoke-Case 'interop.ps.reads.bash'     { Get-FmxContextRegistryRecord -State "$BashTree/interop/state" -RequestId 'req-interop' }
Invoke-Case 'interop.ps.reads.bash.raw' { Get-Trimmed "$BashTree/interop/state/x-context/req-interop.json" }
Invoke-Case 'interop.ps.reads.bash.recordedat' { Get-Value (Get-FmxContextRegistryRecordedAt -Path "$BashTree/interop/state/x-context/req-interop.json" -Now '1700000000') }
Invoke-Case 'interop.ps.reads.bash.offer' { Get-Trimmed "$BashTree/interop/state/x-context/req-offer.offered.json" }
Invoke-Case 'interop.ps.reads.bash.meta'  { Get-FmxMetaValue -MetaPath "$BashTree/meta/plain.meta" -Key 'x_request' }
[Environment]::SetEnvironmentVariable('FMX_NOW_OVERRIDE', [NullString]::Value)

# --- reply budgets, thread splitting, payload builders ---
Invoke-Case 'limit.explicit' { Get-FmxReplyLimit -Platform 'x' -Explicit '500' }
Invoke-Case 'limit.toosmall' { Get-FmxReplyLimit -Platform 'discord' -Explicit '12' }
Invoke-Case 'limit.discord'  { Get-FmxReplyLimit -Platform 'discord' -Explicit '' }
Invoke-Case 'limit.x'        { Get-FmxReplyLimit -Platform 'x' -Explicit '' }
Invoke-Case 'limit.unknown'  { Get-FmxReplyLimit -Platform '' -Explicit '' }
Invoke-Case 'limit.nonnum'   { Get-FmxReplyLimit -Platform 'discord' -Explicit 'abc' }

foreach ($case in ($SplitCases -split "`n")) {
    $parts = $case.Trim() -split ' '
    if ($parts.Count -ne 3) { continue }
    $name = $parts[0]; $limit = [int]$parts[1]; $cap = [int]$parts[2]
    Invoke-Case "split.$name" {
        $text = [System.IO.File]::ReadAllText((ConvertTo-FmNativePath "$SplitDir/$name.txt"))
        # ConvertTo-Json -InputObject, never through the pipeline: the pipeline
        # UNROLLS a one-element array to a scalar and would emit "a" where jq
        # emits ["a"].
        ConvertTo-Json -InputObject @(Split-FmxThread -Text $text -Limit $limit -Cap $cap) -Depth 20 -Compress
    }
}

# Guarded because these two run OUTSIDE Invoke-Case: an unhandled terminating
# error here kills the process and takes every remaining case's output with it,
# which reads to the bash side as a wholesale harness failure rather than as the
# one broken fixture it is. (Observed: a missing fm-common import made this line
# throw and silently cost ~40 later cases.)
$multi = @()
$single = @()
try {
    $multi = @(Split-FmxThread -Text ([System.IO.File]::ReadAllText((ConvertTo-FmNativePath "$SplitDir/02-words.txt"))) -Limit 30 -Cap 25)
    $single = @(Split-FmxThread -Text ([System.IO.File]::ReadAllText((ConvertTo-FmNativePath "$SplitDir/01-short.txt"))) -Limit 280 -Cap 25)
} catch {
    Write-Case -Key 'splitfixture.error' -Value $_.Exception.Message
}
Invoke-Case 'payload.multi'   { Get-FmxReplyPayloadJson -RequestId 'req-p' -Chunk $multi -Count $multi.Count }
Invoke-Case 'payload.single'  { Get-FmxReplyPayloadJson -RequestId 'req-p' -Chunk $single -Count 1 }
Invoke-Case 'outbox.multi'    { Get-FmxReplyOutboxJson -RequestId 'req-p' -Chunk $multi -Count $multi.Count -Followup $false }
Invoke-Case 'outbox.followup' { Get-FmxReplyOutboxJson -RequestId 'req-p' -Chunk $single -Count 1 -Followup $true }
Invoke-Case 'outbox.image'    { Get-FmxReplyOutboxJson -RequestId 'req-p' -Chunk $single -Count 1 -Followup $true -ImagePreviewJson '{"media_type":"image/png","bytes":42,"source_path":"/tmp/a.png"}' }

# --- .env and config ---
foreach ($k in @('FMX_PAIRING_TOKEN', 'FMX_RELAY_URL', 'FMX_X_REPLY_MAX_CHARS', 'FMX_EQUALS', 'FMX_EMPTY', 'FMX_CRLF', 'FMX_UNBALANCED', 'FMX_ABSENT')) {
    Invoke-Case "env.$k" { Get-FmxEnvValue -Key $k -File "$T/env/.env" }
}
Invoke-Case 'env.nofile' { Get-FmxEnvValue -Key 'FMX_PAIRING_TOKEN' -File "$T/env/none.env" }

# Each config case sets exactly the variables its bash twin was given and clears
# them afterwards, so one case can never leak into the next.
$configKeys = @('FMX_PAIRING_TOKEN', 'FMX_RELAY_URL', 'FMX_DRY_RUN',
    'FMX_X_REPLY_MAX_CHARS', 'FMX_DISCORD_REPLY_MAX_CHARS', 'FMX_X_THREAD_MAX', 'FMX_ENV_FILE')
function Invoke-ConfigCase {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][hashtable]$Assign, [Parameter(Mandatory)][string]$HomeDir)
    # [NullString]::Value, NOT $null: PowerShell binds a bare $null to a .NET
    # STRING parameter as the EMPTY STRING, so SetEnvironmentVariable($k, $null)
    # SETS the variable to '' instead of removing it. That is not cosmetic here -
    # fmx_load_config distinguishes "set to empty" from "unset" (bash ${VAR+x}
    # vs ${VAR:-}), so a variable left set-but-empty by one case makes every
    # LATER case skip the .env file entirely and report the built-in defaults.
    # Observed exactly that: config.envfile came back with an empty token and the
    # default relay. (Same trap as File.Replace's backup path in fm-common.)
    foreach ($k in $configKeys) { [Environment]::SetEnvironmentVariable($k, [NullString]::Value) }
    foreach ($k in $Assign.Keys) { [Environment]::SetEnvironmentVariable($k, $Assign[$k]) }
    Invoke-Case "config.$Label" {
        $c = Get-FmxConfig -HomePath $HomeDir
        # FMX_DRY is "" or "1" in bash; the module returns a real boolean, so it
        # is rendered here at the comparison boundary rather than in the module.
        $dry = if ($c.DryRun) { '1' } else { '' }
        "$($c.Token)|$($c.Relay)|$dry|$($c.Max)|$($c.DiscordMax)|$($c.ThreadMax)"
    }
    foreach ($k in $configKeys) { [Environment]::SetEnvironmentVariable($k, [NullString]::Value) }
}
Invoke-ConfigCase -Label 'envfile' -HomeDir "$T/env" -Assign @{}
Invoke-ConfigCase -Label 'override' -HomeDir "$T/env" -Assign @{ FMX_PAIRING_TOKEN = 'explicit'; FMX_RELAY_URL = 'https://other.example/' }
Invoke-ConfigCase -Label 'emptytoken' -HomeDir "$T/env" -Assign @{ FMX_PAIRING_TOKEN = '' }
Invoke-ConfigCase -Label 'dry' -HomeDir "$T/env" -Assign @{ FMX_DRY_RUN = 'YES' }
Invoke-ConfigCase -Label 'dryoff' -HomeDir "$T/env" -Assign @{ FMX_DRY_RUN = 'Off' }
Invoke-ConfigCase -Label 'floors' -HomeDir "$T/env" -Assign @{ FMX_X_REPLY_MAX_CHARS = '3'; FMX_DISCORD_REPLY_MAX_CHARS = '5000'; FMX_X_THREAD_MAX = '0' }
Invoke-ConfigCase -Label 'huge' -HomeDir "$T/env" -Assign @{ FMX_X_REPLY_MAX_CHARS = '99999999999999999999999'; FMX_DISCORD_REPLY_MAX_CHARS = '99999999999999999999999' }

# --- printf %q, through the shim content ---
Invoke-Case 'shim.plain'   { (Get-FmxPollShimContent -HomePath '/f/home' -Root '/f/root').TrimEnd("`n") }
Invoke-Case 'shim.space'   { (Get-FmxPollShimContent -HomePath '/f/my home' -Root '/f/root').TrimEnd("`n") }
Invoke-Case 'shim.meta'    { (Get-FmxPollShimContent -HomePath '/f/a$b`c(d)e{f}' -Root '/f/r&t').TrimEnd("`n") }
Invoke-Case 'shim.tilde'   { (Get-FmxPollShimContent -HomePath '~/home' -Root '/f/r~t').TrimEnd("`n") }
Invoke-Case 'shim.utf8'    { (Get-FmxPollShimContent -HomePath "/f/caf`u{00e9}" -Root '/f/root').TrimEnd("`n") }
Invoke-Case 'shimv1.plain' { (Get-FmxPollShimV1Content -HomePath '/f/home' -Root '/f/root').TrimEnd("`n") }

# --- meta link rewriting ---
Invoke-Case 'meta.link.rc'        { Get-Rc (Set-FmxMetaLink -MetaPath "$T/meta/linked.meta" -RequestId 'req-new' -Timestamp '1700000000' -Followups '3' -Platform 'discord' -ReplyMax '1900') }
Invoke-Case 'meta.link.body'      { (Get-FmFileText "$T/meta/linked.meta").TrimEnd("`n") }
Invoke-Case 'meta.followups.rc'   { Get-Rc (Set-FmxMetaFollowupCount -MetaPath "$T/meta/linked.meta" -Count '4') }
Invoke-Case 'meta.followups.body' { (Get-FmFileText "$T/meta/linked.meta").TrimEnd("`n") }
Invoke-Case 'meta.get'            { Get-FmxMetaValue -MetaPath "$T/meta/linked.meta" -Key 'x_platform' }
Invoke-Case 'meta.clear.rc'       { Get-Rc (Clear-FmxMetaLink -MetaPath "$T/meta/linked.meta") }
Invoke-Case 'meta.clear.body'     { (Get-FmFileText "$T/meta/linked.meta").TrimEnd("`n") }
Invoke-Case 'meta.plain.rc'       { Get-Rc (Set-FmxMetaLink -MetaPath "$T/meta/plain.meta" -RequestId 'req-p' -Timestamp '1700000000') }
Invoke-Case 'meta.plain.body'     { (Get-FmFileText "$T/meta/plain.meta").TrimEnd("`n") }
Invoke-Case 'meta.missing.rc'     { Get-Rc (Set-FmxMetaLink -MetaPath "$T/meta/absent.meta" -RequestId 'req-p' -Timestamp '1700000000') }
Invoke-Case 'meta.clearmissing.rc' { Get-Rc (Clear-FmxMetaLink -MetaPath "$T/meta/absent.meta") }
PS1

QUERY_N=$(fm_test_native_path "$QUERY")
PS_OUT=$(pwsh -NoProfile -File "$QUERY_N" \
  -Module "$MOD" \
  -Common "$(fm_test_native_path "$ROOT/bin/fm-common.psm1")" \
  -Tree "$(fm_test_native_path "$PS_TREE")" \
  -BashTree "$(fm_test_native_path "$BASH_TREE")" \
  -SplitDir "$(fm_test_native_path "$SPLIT_DIR")" \
  -SplitCases "$SPLIT_CASES" \
  -TmpRoot "$(fm_test_native_path "$TMP_ROOT")" \
  -SymlinkFileFixtures "$SYMLINK_FILE_FIXTURES" 2>&1) \
  || fail "the PowerShell query script failed:"$'\n'"$PS_OUT"

PS_LINES=()
while IFS= read -r ps_line; do
  [ -n "$ps_line" ] && PS_LINES+=("$ps_line")
done <<PSOUT
$PS_OUT
PSOUT

FM_PSV=
psv() {  # <key> -> FM_PSV, or the literal <missing>
  local key=$1 line
  FM_PSV='<missing>'
  for line in ${PS_LINES+"${PS_LINES[@]}"}; do
    case "$line" in
      "$key"$'\t'*) FM_PSV=${line#*$'\t'}; return 0 ;;
    esac
  done
}

# Both sides are already ENCODED - bash at record time, PowerShell as it emits -
# so the comparison is plain string equality. Encoding rather than decoding is
# deliberate: a stray CR on either side survives as a visible difference instead
# of being normalized away, which is exactly the class of bug contract 2 exists
# to catch.
compare() {  # <key>   (the bash record and the PowerShell record for one case)
  local key=$1 expected
  bval "$key"; expected=$FM_BV
  psv "$key"
  assert_same "$key" "$expected" "$FM_PSV"
}

# --- 0. no case may throw -----------------------------------------------------
#
# One .error line means an exception escaped a helper - exactly the failure
# $ErrorActionPreference = 'Stop' makes the DEFAULT for an unguarded .NET call
# on a missing path, and the reason every probe in the module pins its own
# guard.
ps_errors=''
for ps_line in ${PS_LINES+"${PS_LINES[@]}"}; do
  case "$ps_line" in
    *.error$'\t'*) ps_errors="$ps_errors ${ps_line%%$'\t'*}" ;;
  esac
done
assert_same "no case throws in the PowerShell module" "" "${ps_errors# }"

# --- 1..n. every recorded case, compared key by key ---------------------------
#
# Driven off the bash record list, so a case the PowerShell side FORGOT to emit
# fails as <missing> rather than silently shrinking the run.
# "${B_KEYS[@]}", not $B_KEYS: a bare array reference expands to element ZERO
# only, which would silently compare one case and skip the other ~128. The
# MIN_ASSERTIONS floor at the end is what caught exactly that.
for key in ${B_KEYS+"${B_KEYS[@]}"}; do
  compare "$key"
done

# --- cross-world interop: bash reads what PowerShell wrote --------------------
#
# The other direction of the highest-value assertion. The PowerShell run above
# wrote req-interop.json, req-offer.offered.json and the meta bodies into the
# PowerShell tree with FMX_NOW_OVERRIDE pinned to the same instant the bash side
# used, so the records are directly comparable AND directly readable.
# Same request id in two SEPARATE trees, same inputs, same pinned clock - so the
# two records must be byte-identical with nothing normalized away. Named as its
# own assertion rather than left to the generic loop because this specific
# equality is the contract: a record either language writes has to be one the
# other can read, and identical bytes is the strongest form of that.
psv registry.set.raw
PS_RAW=$FM_PSV
bval registry.set.raw
BASH_RAW=$FM_BV
assert_same "a PowerShell-written registry record is byte-identical to the bash one" \
  "$BASH_RAW" "$PS_RAW"

BACK=$(FMX_NOW_OVERRIDE=1700000000 fmx_context_registry_get "$PS_TREE/interop/state" req-interop 2>/dev/null)
assert_same "the bash reader reads a PowerShell-written registry record" \
  '{"platform":"x","reply_max_chars":"280"}' "$BACK"

BACK=$(FMX_NOW_OVERRIDE=1700000000 fmx_context_registry_recorded_at "$PS_TREE/interop/state/x-context/req-interop.json" 1700000000 2>/dev/null)
assert_same "the bash reader reads a PowerShell-written retention timestamp" "1700000000" "$BACK"

# A second claim against the PowerShell-authored marker must be refused by the
# BASH claimer: the one-wake guarantee has to hold across the language boundary,
# not just within one of them.
FMX_NOW_OVERRIDE=1700000000 fmx_offer_registry_claim "$PS_TREE/interop/state" req-offer >/dev/null 2>&1
assert_same "the bash claimer refuses a PowerShell-authored offer marker" "1" "$?"

# And the reverse: the PowerShell claimer already refused the bash-authored one
# in its own tree, so this pins the bash-authored marker's bytes as readable.
psv interop.ps.reads.bash
assert_same "the PowerShell reader reads a bash-written registry record" \
  '{"platform":"x","reply_max_chars":"280"}' "$FM_PSV"
psv interop.ps.reads.bash.recordedat
assert_same "the PowerShell reader reads a bash-written retention timestamp" "1700000000" "$FM_PSV"
psv interop.ps.reads.bash.raw
encode "$(cat "$BASH_TREE/interop/state/x-context/req-interop.json" 2>/dev/null)"
assert_same "the PowerShell reader sees the bash record's exact bytes" "$FM_ENC" "$FM_PSV"
psv interop.ps.reads.bash.offer
encode "$(cat "$BASH_TREE/interop/state/x-context/req-offer.offered.json" 2>/dev/null)"
assert_same "the PowerShell reader sees the bash offer marker's exact bytes" "$FM_ENC" "$FM_PSV"
psv interop.ps.reads.bash.meta
assert_same "the PowerShell reader reads a bash-written meta link" "req-p" "$FM_PSV"

# The meta record written by PowerShell must read back through the BASH
# accessor, key for key.
assert_same "the bash reader reads a PowerShell-written meta link" \
  "req-p" "$(fmx_meta_get "$PS_TREE/meta/plain.meta" x_request)"
assert_same "the bash reader reads a PowerShell-written follow-up count" \
  "0" "$(fmx_meta_get "$PS_TREE/meta/plain.meta" x_followups)"

# The published outbox record has to survive the bash validator, which is what
# fm-x-reply.sh applies before it trusts one.
PUB_DEV=$(fmx_private_artifact_dir_device "$PS_TREE/publish/state/x-outbox" 2>/dev/null)
fmx_single_link_file_mode_valid "$PS_TREE/publish/state/x-outbox/req-pub.json" 600 "$PUB_DEV" >/dev/null 2>&1
assert_same "the bash gate accepts a PowerShell-published private artifact" "0" "$?"

# --- the device token is MEASURED, not fabricated -----------------------------
#
# Every same-device comparison above would pass vacuously if both worlds simply
# returned a constant, so the token is checked against a THIRD, independent
# source: `stat` itself. On this host both worlds report the NTFS volume serial
# number (MSYS stat -c %d and GetFileInformationByHandle's
# dwVolumeSerialNumber are the same number - 1324268815 for /tmp here), which is
# what makes the two implementations' device values directly comparable rather
# than merely internally consistent.
#
# stat is asked directly rather than through a second private directory on
# another volume, because the gate's own probe WRITES a throwaway file into the
# directory it inspects, and pointing it at the firstmate checkout would put
# that file in the primary working tree.
DEV_STAT=$(stat -c %d "$TMP_ROOT" 2>/dev/null || stat -f %d "$TMP_ROOT" 2>/dev/null)
bval dir.tmproot
assert_same "the bash device token is the filesystem's own device id" "$DEV_STAT" "$FM_BV"
psv dir.tmproot
assert_same "the PowerShell device token is the same filesystem device id" "$DEV_STAT" "$FM_PSV"

# --- module hygiene -----------------------------------------------------------

import_noise=$(pwsh -NoProfile -Command "Import-Module '$MOD' -Force" 2>&1)
assert_same "importing the module emits nothing" "" "$import_noise"

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-x-lib.psm1 differs from bin/fm-x-lib.sh (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The floor is built from the fixtures that were
# actually available, which means a fixture that failed to materialize cannot
# quietly shrink the run into a green one.
# 129 recorded differential cases, plus the no-throw sweep, the twelve explicit
# cross-world interop assertions, the two device-reality assertions and the
# import-hygiene one. An EXACT total rather than a loose floor, so dropping a
# single case fails the run instead of quietly shrinking it.
MIN_ASSERTIONS=145
[ "$SYMLINK_FILE_FIXTURES" = yes ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 2))
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-x-lib.psm1 matches bin/fm-x-lib.sh across %d assertions\n' "$ASSERTIONS"
printf '# fm-x-lib-psm1.test.sh: all assertions passed\n'
