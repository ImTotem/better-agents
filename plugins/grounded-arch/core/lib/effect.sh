# grounded-arch G-effect: project file change check. Sourced; bash 3.2 + jq. Only defines functions.
# ga_effect_snapshot ROOT records the project file state; ga_effect_check ROOT compares what changed
# since then with the phase allow-list (spec 5.5). Changes inside the state folder are not judged
# here (the state fingerprint covers them).
# This runs outside the OS sandbox (Stop hook, approvals), so it trusts nothing the agent can write
# (spec 5.5 "격리 밖에서 도는 코드의 원칙", P18): git by absolute path with the repository settings
# that run programs turned off; index flags, .git/info/exclude and a redirected .git are not trusted;
# a git failure is a violation ("결과 확인 불가: ..."), never "no changes".

GA_EFF_STATE_PREFIX="docs/architecture/.state/"
GA_EFF_UNSURE="결과 확인 불가"
# P25: OS metadata files are never changes, wherever they appear (Finder writes .DS_Store into any
# folder the user opens). A fixed list: the global git excludes file is not trusted (the agent can
# write it with the Write tool).
GA_EFF_OS_META='(\.DS_Store|\._[^/]*|\.Spotlight-V100|\.Trashes|Thumbs\.db|desktop\.ini)'

# stdin: paths (git) or "value path" lines (non-git). Drops the ones naming OS metadata files.
_ga_eff_drop_os_meta() { # [--valued]
  if [ "${1:-}" = --valued ]; then
    grep -Ev "^[^ ]+ (.*/)?${GA_EFF_OS_META}(/.*)?\$"
  else
    grep -Ev "^(.*/)?${GA_EFF_OS_META}(/.*)?\$"
  fi
  return 0
}

ga_effect_snapshot_path() { echo "$(ga_state_dir "$1")/snapshot.json"; } # ROOT

# git with nothing from the repository or the system config able to run a program: no fsmonitor, no
# hooks, no untracked cache, no system config, no replace objects, no git variables from the caller.
_ga_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF
  GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 exec "$GA_GIT" -c core.fsmonitor= -c core.hooksPath=/dev/null \
    -c core.untrackedCache=false "$@"
)

_ga_eff_is_git() { [ "$(_ga_git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; } # ROOT

# Non-git projects: "size:mtime path" for every file, skipping build dirs and the state folder.
_ga_eff_files() { # ROOT
  local root=$1
  ( cd "$root" || exit 1
    if stat -c %s / >/dev/null 2>&1; then
      find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -c '%s:%Y %n' {} + 2>/dev/null
    else
      find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -f '%z:%m %N' {} + 2>/dev/null
    fi ) | sed 's# \./# #' | _ga_eff_drop_os_meta --valued
}

# Git projects: paths (newline list) that may differ from the snapshot -- changed against BASE (every
# tracked file without a commit), untracked (only .gitignore files are honored, not the agent-writable
# .git/info/exclude), and files whose index flags hide edits (assume-unchanged, skip-worktree) --
# minus the state folder. rc 2 with the reason on stdout when a git call fails.
_ga_eff_candidates() { # ROOT BASE
  local root=$1 base=$2 t
  t=$(mktemp -d "${TMPDIR:-/tmp}/ga-eff.XXXXXX") || { echo "임시 폴더를 만들 수 없음"; return 2; }
  if { if [ -n "$base" ]; then
         _ga_git -C "$root" diff --name-only --no-renames --relative -z "$base"
       else
         _ga_git -C "$root" ls-files -z
       fi; } >"$t/a" 2>"$t/e" &&
     _ga_git -C "$root" ls-files -o --exclude-per-directory=.gitignore -z >"$t/b" 2>"$t/e" &&
     _ga_git -C "$root" ls-files -v -z >"$t/v" 2>"$t/e"; then
    { tr '\0' '\n' <"$t/a"; tr '\0' '\n' <"$t/b"; tr '\0' '\n' <"$t/v" | sed -n 's/^[a-zS] //p'; } |
      grep -v '^$' | grep -v "^${GA_EFF_STATE_PREFIX}" | _ga_eff_drop_os_meta | sort -u
    rm -rf "$t"
    return 0
  fi
  echo "git 오류: $(head -n 1 "$t/e")"
  rm -rf "$t"
  return 2
}

# stdin: paths. stdout: "hash path" (hash is DELETED for paths that are not regular files). The
# content is hashed as it is (--no-filters: no clean filter runs). rc 2 when git fails.
_ga_eff_hash_paths() { # ROOT
  local root=$1 tmp p
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ga-eff.XXXXXX") || return 2
  : >"$tmp/ex"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$root/$p" ]; then printf '%s\n' "$p" >>"$tmp/ex"; else printf 'DELETED %s\n' "$p"; fi
  done
  if [ -s "$tmp/ex" ]; then
    _ga_git -C "$root" hash-object --no-filters --stdin-paths <"$tmp/ex" >"$tmp/h" 2>/dev/null || { rm -rf "$tmp"; return 2; }
    paste -d ' ' "$tmp/h" "$tmp/ex"
  fi
  rm -rf "$tmp"
}

_ga_eff_to_map() { # stdin "value path" lines -> JSON object path->value
  jq -Rn '[inputs | select(length > 0) | capture("^(?<v>[^ ]+) (?<p>.*)$") | {key: .p, value: .v}] | from_entries'
}

_ga_eff_write() { # ROOT JSON
  local rc
  ga_lock "$1"
  printf '%s\n' "$2" | ga_write_json "$(ga_effect_snapshot_path "$1")"
  rc=$?
  ga_unlock "$1"
  return $rc
}

ga_effect_snapshot() { # ROOT
  local root=$1 base gd cand map out rc=0
  if _ga_eff_is_git "$root"; then
    # No commit yet: rc 1 and no output. Anything else that fails is a broken repository.
    base=$(_ga_git -C "$root" rev-parse --verify -q HEAD 2>/dev/null) || rc=$?
    case "$rc" in 0) ;; 1) base="" ;; *) return 2 ;; esac
    gd=$(_ga_git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || return 2
    cand=$(_ga_eff_candidates "$root" "$base") || return 2
    map=$(printf '%s\n' "$cand" | _ga_eff_hash_paths "$root") || return 2
    map=$(printf '%s\n' "$map" | _ga_eff_to_map) || return 2
    out=$(jq -n --arg b "$base" --arg g "$gd" --argjson d "$map" '{kind:"git", base:$b, gitdir:$g, dirty:$d}') || return 2
  else
    map=$(_ga_eff_files "$root" | _ga_eff_to_map) || return 2
    out=$(jq -n --argjson f "$map" '{kind:"files", files:$f}') || return 2
  fi
  _ga_eff_write "$root" "$out"
}

# Paths changed since the snapshot, as a sorted JSON array. rc 2 with the reason on stdout when the
# repository cannot be checked.
_ga_eff_changed() { # ROOT
  local root=$1 sp kind base want gd cand nd hashes cur bmap
  sp=$(ga_effect_snapshot_path "$root")
  kind=$(jq -r '.kind // ""' "$sp" 2>/dev/null) || kind=""
  case "$kind" in
    git) ;;
    files)
      cur=$(_ga_eff_files "$root" | _ga_eff_to_map) || { echo "파일 목록을 만들 수 없음"; return 2; }
      jq -nc --argjson c "$cur" --slurpfile s "$sp" --arg om "^(.*/)?${GA_EFF_OS_META}(/.*)?\$" '
        $s[0].files as $o | ([$c | keys[]] + [$o | keys[]] | unique)
        | map(select(($c[.] != $o[.]) and (test($om) | not))) | sort'
      return 0 ;;
    *) echo "기준(snapshot.json)을 읽을 수 없음"; return 2 ;;
  esac
  base=$(jq -r '.base // ""' "$sp")
  want=$(jq -r '.gitdir // ""' "$sp")
  if ! gd=$(_ga_git -C "$root" rev-parse --absolute-git-dir 2>/dev/null); then
    gd=$(_ga_git -C "$root" rev-parse --absolute-git-dir 2>&1 >/dev/null)
    echo "git 오류: ${gd%%$'\n'*}"; return 2
  fi
  if [ -n "$want" ] && [ "$gd" != "$want" ]; then
    echo "git 저장소 위치가 기준과 다름 (기준 ${want}, 지금 ${gd})"; return 2
  fi
  if [ -n "$base" ] && ! _ga_git -C "$root" cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "기준 커밋 ${base:0:12}을(를) 저장소에서 찾을 수 없음 (기록을 다시 쓴 경우 등)"; return 2
  fi
  cand=$(_ga_eff_candidates "$root" "$base") || { echo "$cand"; return 2; }
  # Current candidates plus paths dirty at snapshot time (they may have been reverted since).
  cand=$( { printf '%s\n' "$cand"; jq -r '.dirty | keys[]' "$sp"; } | grep -v '^$' | _ga_eff_drop_os_meta | sort -u)
  hashes=$(printf '%s\n' "$cand" | _ga_eff_hash_paths "$root") || { echo "git 오류: hash-object 실패"; return 2; }
  cur=$(printf '%s\n' "$hashes" | _ga_eff_to_map) || { echo "해시 목록을 읽을 수 없음"; return 2; }
  # A candidate that was not dirty at snapshot time is unchanged only when it equals the base commit
  # (an index flag can list a file whose content is still the committed one).
  bmap='{}'
  nd=$(printf '%s' "$cur" | jq -r --slurpfile s "$sp" '$s[0].dirty as $d | keys[] | select($d[.] == null)')
  if [ -n "$base" ] && [ -n "$nd" ]; then
    bmap=$(printf '%s\n' "$nd" | while IFS= read -r p; do printf '%s:./%s\n' "$base" "$p"; done |
      _ga_git -C "$root" cat-file --batch-check='%(objectname)' 2>/dev/null |
      paste -d ' ' - <(printf '%s\n' "$nd") | grep -v ' missing ' | _ga_eff_to_map) || bmap='{}'
  fi
  jq -nc --argjson c "$cur" --argjson b "$bmap" --slurpfile s "$sp" '
    $s[0].dirty as $d | [$c | to_entries[] | select(($d[.key] // $b[.key]) != .value) | .key] | sort'
}

# Prints {"changed":[...],"violations":[...]}; rc 1 on violations (including "결과 확인 불가: ..."
# when the files cannot be checked), 2 when there is no snapshot or the state cannot be read.
ga_effect_check() { # ROOT
  local root=$1 sp phase mode round changed maps out n sset
  sp=$(ga_effect_snapshot_path "$root")
  [ -f "$sp" ] || { echo "ga: 파일 변경 기준(snapshot.json)이 없습니다" >&2; return 2; }
  phase=$(ga_state_get "$root" .phase) || return 2
  mode=$(ga_state_get "$root" .mode) || return 2
  round=$(ga_state_get "$root" .round) || return 2
  if ! changed=$(_ga_eff_changed "$root"); then
    jq -nc --arg v "${GA_EFF_UNSURE}: ${changed:-알 수 없는 오류}" '{changed: [], violations: [$v]}'
    return 1
  fi
  maps=$(jq -c --argjson r "$round" \
    '[.items[]? | select(.kind == "mapping" and .round == $r and (.change == "new" or .change == "changed")) | .path | ltrimstr("./")]' \
    "$(ga_ledger_path "$root")" 2>/dev/null) || maps='[]'
  # The plugin root (contains core/) is protected when it lies inside the project.
  local pd rc_
  pd=$(cd -P "$GA_CORE/.." 2>/dev/null && pwd -P) || pd=""
  rc_=$(ga_canon "$root") || rc_=$root
  case "$pd" in "$rc_"/*) pd=${pd#"$rc_"/} ;; *) pd="" ;; esac
  out=$(jq -nc --argjson ch "$changed" --argjson m "$maps" --arg ph "$phase" --arg mode "$mode" --arg pd "$pd" '
    def inmap: . as $x | any($m[]; . as $p | $x == $p or ($x | startswith(($p | rtrimstr("/")) + "/")));
    def free: ($ph == "implement") or ($ph == "skeleton" and $mode != "brownfield");
    def ok: if $pd != "" and (. == $pd or startswith($pd + "/")) then false
            elif free then true
            elif startswith("docs/architecture/") then true
            elif $ph == "skeleton" then inmap
            else false end;
    {changed: $ch, violations: [$ch[] | select(ok | not)]}') || return 2
  n=$(printf '%s' "$out" | jq '.violations | length')
  if [ "$n" != 0 ]; then
    # P19: the harness's own settings files are never violations (enforce status checks them).
    sset=$(printf '%s' "$out" | jq -r '.violations[]' | ga_enforce_settings_rel "$root" | jq -Rn '[inputs]') || sset='[]'
    out=$(printf '%s' "$out" | jq -c --argjson s "$sset" '.violations -= $s')
    n=$(printf '%s' "$out" | jq '.violations | length')
  fi
  printf '%s\n' "$out"
  [ "$n" = 0 ]
}

# "a, b, c" from a check result's violations (at most 20, then "외 n개").
ga_effect_list() { # CHECK_JSON
  printf '%s' "$1" | jq -r '.violations as $v | ($v[0:20] | join(", ")) + (if ($v | length) > 20 then " 외 \(($v | length) - 20)개" else "" end)' 2>/dev/null
}

# P19: the violation set Stop last reported (state folder, so the agent cannot fake it).
ga_effect_reported_path() { echo "$(ga_state_dir "$1")/effect_reported.json"; } # ROOT

ga_effect_reported_is() { # ROOT CHECK_JSON -> true when Stop already reported exactly this set
  local f
  f=$(ga_effect_reported_path "$1")
  [ -f "$f" ] || return 1
  jq -e --argjson c "$2" '.violations == ($c.violations | sort)' "$f" >/dev/null 2>&1
}

ga_effect_reported_set() { # ROOT CHECK_JSON
  local rc
  ga_lock "$1"
  printf '%s' "$2" | jq -c '{violations: (.violations | sort)}' | ga_write_json "$(ga_effect_reported_path "$1")"
  rc=$?
  ga_unlock "$1"
  return $rc
}

ga_effect_reported_clear() { # ROOT
  [ -e "$(ga_effect_reported_path "$1")" ] || return 0
  ga_lock "$1"
  rm -f "$(ga_effect_reported_path "$1")"
  ga_fp_mark "$1"
  ga_unlock "$1"
}

cmd_effect() {
  local out rc
  { [ $# -eq 1 ] && [ "$1" = check ]; } || ga_die "사용법: ga effect check" 2
  ga_need_state
  out=$(ga_effect_check "$GA_ROOT")
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" = 1 ]; then
    echo "ga: 이 단계에서 바꿀 수 없는 파일이 바뀌었습니다: $(printf '%s' "$out" | jq -r '.violations | join(", ")')" >&2
  fi
  exit "$rc"
}
