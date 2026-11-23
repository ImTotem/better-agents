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

  root=""
  [ -n "${GA_ROOT_EXPLICIT:-}" ] && root=${GA_ROOT:-}
  [ -n "$root" ] || root=$(ga_canon "$PWD") || exit 2
  sd=$(ga_state_dir "$root")
  # P11: the design's folders must be real directories under ROOT, never links elsewhere.
  local p
  for p in docs docs/architecture docs/architecture/.state; do
    if [ -L "$root/$p" ]; then
      echo "ga: ${root}/${p} 이(가) 심볼릭 링크라서 설계를 시작할 수 없습니다. 실제 디렉터리로 바꾸거나 링크를 지운 뒤 다시 실행하세요" >&2
      exit 3
    fi
  done
  if [ -f "$sd/state.json" ]; then
    echo "ga: 이미 초기화되어 있습니다: $sd/state.json" >&2
    exit 1
  fi
  # R29: never at / or $HOME, and never nested inside a design of the same repository.
  local home anc
  home=$(cd -P "$HOME" 2>/dev/null && pwd -P) || home=""
  if [ "$root" = / ] || { [ -n "$home" ] && [ "$root" = "$home" ]; }; then
    echo "ga: 파일 시스템 루트(/)나 홈 디렉터리($root)에서는 설계를 시작할 수 없습니다. 프로젝트 디렉터리에서 실행하세요" >&2
    exit 3
  fi
  if [ ! -e "$root/.git" ] && anc=$(ga_find_root "$(dirname "$root")"); then
    echo "ga: 상위 디렉터리 $anc 에 이미 설계가 있습니다. 같은 저장소 안에 설계를 겹쳐 만들 수 없습니다. 그 설계를 이어 가세요" >&2
    exit 3
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

  mkdir -p "$root/docs/architecture" "$sd" 2>/dev/null || ga_die "ga: 디렉터리를 만들 수 없습니다. $(ga_mcp_hint)" 2
  ga_lock "$root"
  [ -f "$root/docs/architecture/architecture.md" ] || cp "$GA_CORE/templates/architecture.md" "$root/docs/architecture/architecture.md"
  echo '{"items":[]}' | ga_write_json "$sd/ledger.json"
  [ -f "$sd/approvals.jsonl" ] || : >"$sd/approvals.jsonl"
  jq -n --arg m "$mode" '{version:1,mode:$m,phase:"inputs",paused:false,round:1,iteration:0,iteration_count:0,transcript_path:null}' |
    ga_write_json "$sd/state.json"
  # P1: OS isolation settings go in BEFORE the first snapshot, so the file is part of the baseline.
  local esp eerr
  eerr=$(mktemp "${TMPDIR:-/tmp}/ga-init.XXXXXX") || eerr=/dev/null
  if esp=$(_ga_run_enforce "$root" 2>"$eerr"); then
    echo "격리 설정: ${esp} (이 저장소의 모든 세션에 적용됩니다. 설계가 끝나면 사용자가 'GA 격리해제'로 지웁니다)"
  else
    echo "ga: 경고: OS 격리를 설정하지 못했습니다: $(head -n 1 "$eerr" 2>/dev/null | sed 's/^ga: //'). 셸 명령이 상태 폴더에 쓰는 것을 운영체제가 막지 못합니다 (GA_HARNESS 와 어댑터를 확인한 뒤 ga enforce 를 실행하세요)" >&2
  fi
  [ "$eerr" = /dev/null ] || rm -f "$eerr"
  ga_effect_snapshot "$root" || { ga_unlock "$root"; ga_die "ga: 파일 변경 기준을 기록하지 못했습니다" 2; }
  ga_fp_mark "$root" force   # a fresh design always gets a fresh fingerprint, even over an old record
  ga_unlock "$root"
  echo "초기화: mode=$mode (근거: $reason)"
}

# Builds the status JSON in one place; extend the object here.
_ga_status_json() { # ROOT
  local sd rp extra h
  sd=$(ga_state_dir "$1")
  rp=$sd/report.json
  extra='{"report_fresh":false,"panel_ok":false,"findings_unprocessed":0,"build_ok":null}'
  if [ -f "$rp" ] && jq -e 'type == "object"' "$rp" >/dev/null 2>&1; then
    h=$(ga_doc_hash "$1")
    # A build check skipped for lack of OS isolation (P16) has no result: build_ok stays null.
    extra=$(jq -c --arg h "$h" '{
      report_fresh: (.doc_hash == $h),
      panel_ok: ((.panel | length) > 0 and (.panel | all(.status == "ok"))),
      findings_unprocessed: ([.findings[] | select(((.disposition.type == "user_rejected") or (.disposition.type == "disputed" and .disposition.verdict == "accept")) | not)] | length),
      build_ok: (if .build_check == null or .build_check.skipped != null then null else (.build_check.exit == 0) end)}' "$rp") || extra='{"report_fresh":false,"panel_ok":false,"findings_unprocessed":0,"build_ok":null}'
  fi
  local pm=false
  ga_paused_marker "$1" && pm=true
  # open/asked: assumptions and questions of ALL rounds (they block every approval) plus
  # the other kinds (deviation decisions) of the current round -- the approval rule.
  jq -c --argjson x "$extra" --argjson pm "$pm" --slurpfile l "$(ga_ledger_path "$1")" '
    . as $s
    | ($l[0].items // [] | map(select(.kind == "assumption" or .kind == "question" or .round == $s.round))) as $cur
    | {phase, mode, paused: ((.paused == true) or $pm), round, iteration, iteration_count,
       open: ($cur | map(select(.status == "open")) | length),
       asked: ($cur | map(select(.status == "asked")) | length)} + $x' "$sd/state.json"
}

# ga root [--active]: prints the design root found from the current directory (exit 1 if none).
# --active also exits 1 when the user's PAUSED marker exists. Needs no jq (adapter fail-closed path).
cmd_root() {
  [ $# -eq 0 ] || [ "$*" = --active ] || ga_die "사용법: ga root [--active]" 2
  [ -n "${GA_ROOT:-}" ] && [ -f "$(ga_state_dir "$GA_ROOT")/state.json" ] || exit 1
  if [ "${1:-}" = --active ] && ga_paused_marker "$GA_ROOT"; then exit 1; fi
  echo "$GA_ROOT"
}

cmd_status() {
  local json=0 a
  for a in "$@"; do
    case "$a" in --json) json=1 ;; *) ga_die "사용법: ga status [--json]" 2 ;; esac
  done
  ga_need_state
  if [ "$json" = 1 ]; then
    _ga_status_json "$GA_ROOT"
  else
    _ga_status_json "$GA_ROOT" | jq -r '
      "단계: \(.phase) (mode=\(.mode), round=\(.round), iteration=\(.iteration)/\(.iteration_count))",
      "일시정지: \(.paused)",
      "open=\(.open) asked=\(.asked)"'
  fi
}
