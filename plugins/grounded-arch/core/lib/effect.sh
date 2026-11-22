# grounded-arch G-effect: project file change check. Sourced; bash 3.2 + jq. Only defines functions.
# ga_effect_snapshot ROOT records the project file state; ga_effect_check ROOT compares what changed
# since then with the phase allow-list (spec 5.5). Changes inside the state folder are not judged
# here (the state fingerprint covers them).

GA_EFF_STATE_PREFIX="docs/architecture/.state/"
# Always a violation, whatever the phase (adapter settings the agent must not edit).
GA_EFF_PROTECTED=".claude/settings.json .claude/settings.local.json"

ga_effect_snapshot_path() { echo "$(ga_state_dir "$1")/snapshot.json"; } # ROOT

_ga_eff_is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; } # ROOT

# Prints "size:mtime" of one file (macOS stat -f, Linux stat -c).
_ga_eff_stat1() { # FILE
  if stat -c %s / >/dev/null 2>&1; then stat -c '%s:%Y' "$1"; else stat -f '%z:%m' "$1"; fi
}

# Non-git projects: "size:mtime path" for every file, skipping build dirs and the state folder.
_ga_eff_files() { # ROOT
  local root=$1
  ( cd "$root" || exit 1
    if stat -c %s / >/dev/null 2>&1; then
      find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -c '%s:%Y %n' {} + 2>/dev/null
    else
      find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -f '%z:%m %N' {} + 2>/dev/null
    fi ) | sed 's# \./# #'
}

# Git projects: paths (newline list) that differ from BASE or are untracked, minus the state folder.
_ga_eff_candidates() { # ROOT BASE
  local root=$1 base=$2
  {
    if [ -n "$base" ]; then
      git -C "$root" diff --name-only --no-renames --relative -z "$base" 2>/dev/null
    else
      git -C "$root" ls-files -z 2>/dev/null
    fi
    git -C "$root" ls-files -o --exclude-standard -z 2>/dev/null
  } | tr '\0' '\n' | grep -v '^$' | grep -v "^${GA_EFF_STATE_PREFIX}" | sort -u
}

# stdin: paths. stdout: "hash path" (hash is DELETED for paths that are not regular files).
_ga_eff_hash_paths() { # ROOT
  local root=$1 tmp p
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ga-eff.XXXXXX") || return 1
  : >"$tmp/ex"
  while IFS= read -r p; do
    if [ -f "$root/$p" ]; then printf '%s\n' "$p" >>"$tmp/ex"; else printf 'DELETED %s\n' "$p"; fi
  done
  if [ -s "$tmp/ex" ]; then
    git -C "$root" hash-object --stdin-paths <"$tmp/ex" >"$tmp/h" || { rm -rf "$tmp"; return 1; }
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
  local root=$1 base map out
  if _ga_eff_is_git "$root"; then
    base=$(git -C "$root" rev-parse HEAD 2>/dev/null) || base=""
    map=$(_ga_eff_candidates "$root" "$base" | _ga_eff_hash_paths "$root" | _ga_eff_to_map) || return 2
    out=$(jq -n --arg b "$base" --argjson d "$map" '{kind:"git", base:$b, dirty:$d}') || return 2
  else
    map=$(_ga_eff_files "$root" | _ga_eff_to_map) || return 2
    out=$(jq -n --argjson f "$map" '{kind:"files", files:$f}') || return 2
  fi
  _ga_eff_write "$root" "$out"
}

# Re-records only RELPATH in the existing snapshot (used when ga itself wrote that file).
ga_effect_rebaseline() { # ROOT RELPATH
  local root=$1 rel=$2 sp base val out
  sp=$(ga_effect_snapshot_path "$root")
  [ -f "$sp" ] || return 0
  if [ "$(jq -r .kind "$sp")" = git ]; then
    base=$(jq -r .base "$sp")
    val=$(_ga_eff_candidates "$root" "$base" | grep -Fx -- "$rel" | _ga_eff_hash_paths "$root" | sed 's/ .*//')
    out=$(jq --arg p "$rel" --arg v "$val" 'if $v == "" then del(.dirty[$p]) else .dirty[$p] = $v end' "$sp") || return 2
  else
    val=""
    [ -f "$root/$rel" ] && val=$(_ga_eff_stat1 "$root/$rel")
    out=$(jq --arg p "$rel" --arg v "$val" 'if $v == "" then del(.files[$p]) else .files[$p] = $v end' "$sp") || return 2
  fi
  _ga_eff_write "$root" "$out"
}

# Paths changed since the snapshot, as a sorted JSON array.
_ga_eff_changed() { # ROOT
  local root=$1 sp base cur
  sp=$(ga_effect_snapshot_path "$root")
  if [ "$(jq -r .kind "$sp")" = git ]; then
    base=$(jq -r .base "$sp")
    # Current candidates plus paths dirty at snapshot time (they may have been reverted since).
    cur=$( { _ga_eff_candidates "$root" "$base"; jq -r '.dirty | keys[]' "$sp"; } | sort -u | _ga_eff_hash_paths "$root" | _ga_eff_to_map) || return 2
    jq -nc --argjson c "$cur" --slurpfile s "$sp" '
      $s[0].dirty as $d | [$c | to_entries[] | select($d[.key] != .value) | .key] | sort'
  else
    cur=$(_ga_eff_files "$root" | _ga_eff_to_map) || return 2
    jq -nc --argjson c "$cur" --slurpfile s "$sp" '
      $s[0].files as $o | ([$c | keys[]] + [$o | keys[]] | unique) | map(select($c[.] != $o[.])) | sort'
  fi
}

# Prints {"changed":[...],"violations":[...]}; rc 1 on violations, 2 when it cannot check.
ga_effect_check() { # ROOT
  local root=$1 sp phase mode round changed maps prot out n
  sp=$(ga_effect_snapshot_path "$root")
  [ -f "$sp" ] || { echo "ga: 파일 변경 기준(snapshot.json)이 없습니다" >&2; return 2; }
  phase=$(ga_state_get "$root" .phase) || return 2
  mode=$(ga_state_get "$root" .mode) || return 2
  round=$(ga_state_get "$root" .round) || return 2
  changed=$(_ga_eff_changed "$root") || return 2
  maps=$(jq -c --argjson r "$round" \
    '[.items[]? | select(.kind == "mapping" and .round == $r and (.change == "new" or .change == "changed")) | .path | ltrimstr("./")]' \
    "$(ga_ledger_path "$root")" 2>/dev/null) || maps='[]'
  prot=$(printf '%s\n' $GA_EFF_PROTECTED | jq -Rn '[inputs]')
  # The plugin root (contains core/) is protected too when it lies inside the project.
  local pd rc_
  pd=$(cd -P "$GA_CORE/.." 2>/dev/null && pwd -P) || pd=""
  rc_=$(ga_canon "$root") || rc_=$root
  case "$pd" in "$rc_"/*) pd=${pd#"$rc_"/} ;; *) pd="" ;; esac
  out=$(jq -nc --argjson ch "$changed" --argjson m "$maps" --argjson pr "$prot" --arg ph "$phase" --arg mode "$mode" --arg pd "$pd" '
    def inmap: . as $x | any($m[]; . as $p | $x == $p or ($x | startswith(($p | rtrimstr("/")) + "/")));
    def free: ($ph == "implement") or ($ph == "skeleton" and $mode != "brownfield");
    def ok: if (. as $x | $pr | index($x)) != null then false
            elif $pd != "" and (. == $pd or startswith($pd + "/")) then false
            elif free then true
            elif startswith("docs/architecture/") then true
            elif $ph == "skeleton" then inmap
            else false end;
    {changed: $ch, violations: [$ch[] | select(ok | not)]}') || return 2
  printf '%s\n' "$out"
  n=$(printf '%s' "$out" | jq '.violations | length')
  [ "$n" = 0 ]
}

cmd_effect() {
  local out rc
  { [ $# -eq 1 ] && [ "$1" = check ]; } || ga_die "사용법: ga effect check" 2
  [ -n "${GA_ROOT:-}" ] || ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
  out=$(ga_effect_check "$GA_ROOT")
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" = 1 ]; then
    echo "ga: 이 단계에서 바꿀 수 없는 파일이 바뀌었습니다: $(printf '%s' "$out" | jq -r '.violations | join(", ")')" >&2
  fi
  exit "$rc"
}
