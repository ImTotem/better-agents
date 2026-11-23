# grounded-arch G-effect: state fingerprint. Sourced; bash 3.2 + jq. Only defines functions.
# The fingerprint is the sha256 of the sorted list "relative-path content-sha256" of every file in
# the state folder (the lock dir and temp files excluded). It is stored OUTSIDE the project, so a
# direct edit of a state file (which skips ga) shows up as a mismatch (spec 5.5).
# Recording happens at the outermost ga_unlock, only when the command wrote a state file. The
# "wrote" signal is a marker file inside the lock dir (.lock/dirty), so it survives $(...) subshells.

_ga_fp_sha() { # stdin -> sha256 hex (sha256sum first: a native binary, shasum is a perl script)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

_ga_fp_need_sha() {
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 && return 0
  echo "ga: shasum 또는 sha256sum 이 필요합니다 (둘 다 PATH 에 없어 상태 지문을 계산할 수 없습니다)" >&2
  return 1
}

ga_fp_dir() { echo "${GA_DATA_DIR:-$HOME/.local/state/grounded-arch}"; }

ga_fp_path() { # ROOT -> path of the fingerprint file
  local c
  c=$(ga_canon "$1") || return 1
  echo "$(ga_fp_dir)/$(printf '%s' "$c" | _ga_fp_sha).json"
}

_ga_fp_compute() { # ROOT -> fingerprint hex
  local sd
  sd=$(ga_state_dir "$1")
  ( cd "$sd" 2>/dev/null || exit 1
    LC_ALL=C find . -type f ! -path './.lock/*' ! -path './.lock.stale.*' ! -name '*.tmp.*' ! -name '*.restore.*' 2>/dev/null |
      LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "${f#./}" "$(_ga_fp_sha <"$f")"
      done ) | _ga_fp_sha
}

ga_fp_record() { # ROOT
  local p fp c tmp
  _ga_fp_need_sha || return 3
  p=$(ga_fp_path "$1") || return 1
  c=$(ga_canon "$1") || return 1
  fp=$(_ga_fp_compute "$1") || return 1
  if ! mkdir -p "$(dirname "$p")" 2>/dev/null; then
    echo "ga: 경고: 상태 지문을 기록하지 못했습니다 ($(dirname "$p") 를 만들 수 없음). GA_DATA_DIR 쓰기 권한을 확인하세요" >&2; return 1
  fi
  tmp="$p.tmp.$$"
  if ! { jq -nc --arg r "$c" --arg f "$fp" --arg t "$(ga_now)" '{root:$r, fingerprint:$f, ts:$t}' >"$tmp" && mv "$tmp" "$p"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    echo "ga: 경고: 상태 지문을 기록하지 못했습니다 ($p 에 쓸 수 없음). GA_DATA_DIR 쓰기 권한을 확인하세요" >&2; return 1
  fi
}

# rc 0 match, 1 mismatch, 2 nothing recorded (or unreadable record), 3 no sha256 tool
ga_fp_check() { # ROOT
  local p want got
  _ga_fp_need_sha || return 3
  p=$(ga_fp_path "$1") || return 2
  [ -f "$p" ] || return 2
  want=$(jq -r '.fingerprint // empty' "$p" 2>/dev/null)
  [ -n "$want" ] || return 2
  got=$(_ga_fp_compute "$1") || return 1
  [ "$want" = "$got" ]
}

ga_fp_mismatch_reason() {
  echo "설계 상태가 ga 밖에서 바뀌었습니다(상태 지문 불일치: docs/architecture/.state/). 사용자가 확인할 때까지 상태를 바꾸는 명령, 쓰기, 승인을 막습니다. 에이전트는 이것을 풀 수 없습니다. 사용자에게 알리세요: 사용자가 바뀐 내용을 확인한 뒤 \`GA 상태승인\`을 입력하면 지금 상태(상태 폴더와 프로젝트 파일)가 새 기준이 됩니다"
}

# P3: every state-writing subcommand calls this first (core/bin/ga). While the fingerprint
# mismatches it refuses with exit 3; GA lines (user-command) are not guarded, so GA 상태승인 works.
ga_fp_guard() {
  local rc=0
  [ -n "${GA_ROOT:-}" ] && [ -f "$(ga_state_dir "$GA_ROOT")/state.json" ] || return 0
  ga_fp_check "$GA_ROOT" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 1 ] || ga_die "ga: $(ga_fp_mismatch_reason)" 3
  return 0
}

# Marks the running locked command: dirty = it wrote a state file; force = record even when the
# fingerprint did not match before the command (GA 상태승인); pre-mismatch = set by ga_lock.
ga_fp_mark() { # ROOT [dirty|force]
  : >"$(ga_state_dir "$1")/.lock/${2:-dirty}" 2>/dev/null
  return 0
}

# Called by the outermost ga_unlock while the lock is still held.
_ga_fp_finish() { # ROOT
  local l
  l=$(ga_state_dir "$1")/.lock
  if [ -e "$l/dirty" ] && { [ -e "$l/force" ] || [ ! -e "$l/premismatch" ]; }; then
    ga_fp_record "$1"
  fi
  rm -f "$l/dirty" "$l/force" "$l/premismatch"
  return 0
}

# Called by the outermost ga_lock right after the lock is taken: remember that the state was not
# trusted before this command -- a mismatch, and also a missing or unreadable record (P17: only
# ga init and GA 상태승인, which force, create or replace the record) -- so a later write by this
# command cannot silently re-baseline a direct edit.
_ga_fp_begin() { # ROOT
  local rc=0
  ga_fp_check "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || ga_fp_mark "$1" premismatch
  return 0
}

# Drops this command's pending record (used when its changes are rolled back).
ga_fp_discard() { # ROOT
  rm -f "$(ga_state_dir "$1")/.lock/dirty" "$(ga_state_dir "$1")/.lock/force"
  return 0
}
