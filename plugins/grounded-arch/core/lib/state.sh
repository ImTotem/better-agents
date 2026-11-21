# grounded-arch state helpers, ga init, ga status. Sourced; bash 3.2 compatible.

ga_state_dir() { echo "$1/docs/architecture/.state"; } # ROOT
ga_ledger_path() { echo "$(ga_state_dir "$1")/ledger.json"; } # ROOT

ga_state_get() { # ROOT JQ_FILTER
  jq -r "$2" "$(ga_state_dir "$1")/state.json"
}

# Atomic update of state.json under the lock. JQ_EXPR is a jq program: state -> state.
ga_state_set() { # ROOT JQ_EXPR
  local root=$1 f out rc
  f=$(ga_state_dir "$root")/state.json
  [ -f "$f" ] || ga_die "ga: state.json 없음: $f" 2
  ga_lock "$root"
  out=$(jq "$2" "$f") || { ga_unlock "$root"; ga_die "ga: state.json 갱신 실패" 2; }
  printf '%s\n' "$out" | ga_write_json "$f"
  rc=$?
  ga_unlock "$root"
  return $rc
}

# Prints the first non-ignorable file path under ROOT, if any.
_ga_first_project_file() { # ROOT
  local root=$1 f rel
  find "$root" -mindepth 1 \( -path "$root/docs" -o -path "$root/.git" -o -path "$root/.claude" \) -prune -o ! -type d -print 2>/dev/null |
    while IFS= read -r f; do
      rel=${f#"$root"/}
      case "$rel" in
        */*) echo "$rel"; break ;;
        README*|LICENSE*|.gitignore) ;;
        *) echo "$rel"; break ;;
      esac
    done
}

cmd_init() {
  local mode="" root sd first reason
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        [ $# -ge 2 ] || ga_die "사용법: ga init [--mode greenfield|brownfield]" 2
        mode=$2; shift 2 ;;
      --mode=*) mode=${1#--mode=}; shift ;;
      *) ga_die "사용법: ga init [--mode greenfield|brownfield]" 2 ;;
    esac
  done
  case "$mode" in ""|greenfield|brownfield) ;; *) ga_die "ga: --mode는 greenfield 또는 brownfield여야 합니다" 2 ;; esac

  root=${GA_ROOT:-}
  [ -n "$root" ] || root=$(ga_canon "$PWD") || exit 2
  sd=$(ga_state_dir "$root")
  if [ -f "$sd/state.json" ]; then
    echo "ga: 이미 초기화되어 있습니다: $sd/state.json" >&2
    exit 1
  fi

  if [ -n "$mode" ]; then
    reason="--mode 지정"
  else
    first=$(_ga_first_project_file "$root")
    if [ -n "$first" ]; then
      mode=brownfield; reason="기존 파일 있음: $first"
    else
      mode=greenfield; reason="docs/ .git/ .claude/ README LICENSE .gitignore 외 파일 없음"
    fi
  fi

  mkdir -p "$root/docs/architecture" "$sd" || ga_die "ga: 디렉터리를 만들 수 없습니다" 2
  ga_lock "$root"
  [ -f "$root/docs/architecture/architecture.md" ] || cp "$GA_CORE/templates/architecture.md" "$root/docs/architecture/architecture.md"
  echo '{"items":[]}' | ga_write_json "$sd/ledger.json"
  [ -f "$sd/approvals.jsonl" ] || : >"$sd/approvals.jsonl"
  jq -n --arg m "$mode" '{version:1,mode:$m,phase:"inputs",paused:false,round:1,iteration:0,iteration_count:0,transcript_path:null}' |
    ga_write_json "$sd/state.json"
  ga_unlock "$root"
  echo "초기화: mode=$mode (근거: $reason)"
}

# Builds the status JSON in one place; extend the object here.
_ga_status_json() { # ROOT
  local sd
  sd=$(ga_state_dir "$1")
  jq -c --slurpfile l "$(ga_ledger_path "$1")" '
    . as $s
    | ($l[0].items // [] | map(select(.round == $s.round))) as $cur
    | {phase, mode, paused, round, iteration, iteration_count,
       open: ($cur | map(select(.status == "open")) | length),
       asked: ($cur | map(select(.status == "asked")) | length)}' "$sd/state.json"
}

cmd_status() {
  local json=0 a
  for a in "$@"; do
    case "$a" in --json) json=1 ;; *) ga_die "사용법: ga status [--json]" 2 ;; esac
  done
  [ -n "${GA_ROOT:-}" ] || ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
  if [ "$json" = 1 ]; then
    _ga_status_json "$GA_ROOT"
  else
    _ga_status_json "$GA_ROOT" | jq -r '
      "단계: \(.phase) (mode=\(.mode), round=\(.round), iteration=\(.iteration)/\(.iteration_count))",
      "일시정지: \(.paused)",
      "open=\(.open) asked=\(.asked)"'
  fi
}
