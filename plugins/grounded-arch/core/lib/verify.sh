# grounded-arch verification panel, doc hash, finding dispositions. Sourced; bash 3.2 + jq.

GA_VERIFY_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ga_report_path() { echo "$(ga_state_dir "$1")/report.json"; } # ROOT

# sha256 of architecture.md (ga blocks removed) + ledger items without status/answer and without
# user resolutions. Evidence resolutions stay in (R27a): an agent's ga resolve after verify makes
# the report stale, so the panel checks it. When the ga markers are not perfectly balanced the
# WHOLE document is hashed (R28c): nothing can hide behind an orphan marker.
ga_doc_hash() { # ROOT
  local root=$1 arch lp
  arch=$root/docs/architecture/architecture.md
  lp=$(ga_ledger_path "$root")
  {
    if [ -f "$arch" ]; then
      if [ -n "$(ga_marker_problems "$arch")" ]; then
        cat "$arch"
      else
        awk '
          /^<!-- ga:begin [^ ]+ -->$/ { skip = 1; next }
          /^<!-- ga:end [^ ]+ -->$/ { skip = 0; next }
          !skip { print }' "$arch"
      fi
    fi
    jq -S -c '.items // [] | map(del(.status, .answer)
      | if (.resolution | type) == "object" and .resolution.by == "evidence" then . else del(.resolution) end)' "$lp" 2>/dev/null
  } | shasum -a 256 | awk '{print $1}'
}

_ga_killtree() { # PID
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _ga_killtree "$c"; done
  kill "$1" 2>/dev/null
  return 0
}

# Runs CMD... in the background with a watchdog. Sets GA_WATCH_RC and GA_WATCH_TIMEOUT (1/0).
# ERR: file for stderr, or "&1" to merge into OUT.
_ga_watch() { # SECS OUT ERR CMD...
  local secs=$1 out=$2 err=$3 pid wd mark
  shift 3
  mark=$(mktemp "${TMPDIR:-/tmp}/ga-wd.XXXXXX") || return 2
  rm -f "$mark"
  if [ "$err" = "&1" ]; then
    "$@" >"$out" 2>&1 </dev/null &
  else
    "$@" >"$out" 2>"$err" </dev/null &
  fi
  pid=$!
  ( sleep "$secs"; : >"$mark"; _ga_killtree "$pid"; sleep 1; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  GA_WATCH_RC=0
  wait "$pid" 2>/dev/null || GA_WATCH_RC=$?
  _ga_killtree "$wd"
  wait "$wd" 2>/dev/null
  GA_WATCH_TIMEOUT=0
  if [ -e "$mark" ]; then GA_WATCH_TIMEOUT=1; rm -f "$mark"; fi
  return 0
}

# Prints the cleaned findings object when $1 (a result string) holds a valid findings JSON.
_ga_extract_findings() { # RESULT_STRING
  local r=$1 body
  case "$r" in *"{"*"}"*) ;; *) return 1 ;; esac
  body="{${r#*\{}"
  body="${body%\}*}}"
  printf '%s' "$body" | jq -ce '
    (type == "object") and (.findings | type == "array") and (.findings | all(
      type == "object"
      and (.check | type == "number" and . == floor and . >= 1 and . <= 7)
      and (.target | type == "string" and length > 0)
      and (.claim | type == "string" and length > 0)
      and (.evidence | type == "array" and all(
            type == "object"
            and (.type | type == "string" and (. == "file" or . == "url" or . == "search" or . == "command"))
            and (.ref | type == "string" and length > 0)))))' >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# External text inlined into the prompt never reaches column 0 (R24): a line starting with
# "GA " would otherwise be a user command if a harness ever fed the prompt to the hooks.
_ga_quote_lines() { printf '%s\n' "$1" | sed 's/^/| /'; } # TEXT -> every line prefixed with "| "
_ga_one_line() { printf '%s' "$1" | tr '\r\n' '  '; }      # TEXT -> newlines flattened

_ga_verify_prompt() { # ROOT BUILD_TEXT
  local root=$1 build=$2 p tr
  p=$(cat "$GA_VERIFY_DIR/verifier/prompt.md") || return 1
  tr=$(ga_state_get "$root" '.transcript_path // empty')
  [ -n "$tr" ] || tr="없음"
  p=${p//"{{ROOT}}"/"$(_ga_one_line "$root")"}
  p=${p//"{{PHASE}}"/"$(_ga_one_line "$(ga_state_get "$root" .phase)")"}
  p=${p//"{{MODE}}"/"$(_ga_one_line "$(ga_state_get "$root" .mode)")"}
  p=${p//"{{ROUND}}"/"$(_ga_one_line "$(ga_state_get "$root" .round)")"}
  p=${p//"{{ITERATION}}"/"$(_ga_one_line "$(ga_state_get "$root" .iteration)")"}
  p=${p//"{{ARCH}}"/"$(_ga_one_line "$root/docs/architecture/architecture.md")"}
  p=${p//"{{LEDGER}}"/"$(_ga_one_line "$(ga_ledger_path "$root")")"}
  p=${p//"{{TRANSCRIPT}}"/"$(_ga_one_line "$tr")"}
  p=${p//"{{BUILD}}"/"$(_ga_quote_lines "$build")"}
  printf '%s' "$p"
}

_ga_member_run() { # ROOT RUNNER ARGV...  (runs in a background subshell)
  cd "$1" || exit 99
  shift
  ga_runner_exec "$@"
}

cmd_verify() {
  local root=${GA_ROOT:-} sd panel_file panel timeout n i m runner model rec tmp mdir
  local mode phase hash prompt build_json="null" build_text="없음" status kept dropped
  [ $# -eq 0 ] || ga_die "사용법: ga verify" 2
  [ -n "$root" ] || ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
  sd=$(ga_state_dir "$root")
  panel_file=$sd/panel.json
  [ -f "$panel_file" ] || panel_file=$GA_VERIFY_DIR/verifier/panel.json
  panel=$(jq -c 'if (.members|type=="array" and length>0 and all(type=="object" and (.runner|type=="string") and (.model|type=="string"))) and (.timeout_sec|type=="number" and .>0) then . else error("bad panel") end' "$panel_file" 2>/dev/null) \
    || ga_die "ga: 패널 설정이 올바르지 않습니다: $panel_file" 2
  timeout=$(printf '%s' "$panel" | jq -r '.timeout_sec')
  n=$(printf '%s' "$panel" | jq '.members | length')

  # 1. Billing: every distinct runner, before anything runs.
  for runner in $(printf '%s' "$panel" | jq -r '[.members[].runner] | unique[]'); do
    ga_billing_check "$runner" >/dev/null || { echo "ga verify: 과금 점검에 실패해 검증을 중단합니다 (실행기: $runner). 보고서를 쓰지 않았습니다." >&2; exit 4; }
  done

  mode=$(ga_state_get "$root" .mode)
  phase=$(ga_state_get "$root" .phase)
  hash=$(ga_doc_hash "$root")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ga-verify.XXXXXX") || ga_die "ga: 임시 디렉터리를 만들 수 없습니다" 2

  # 2. Build check (brownfield + skeleton only).
  if [ "$mode" = brownfield ] && [ "$phase" = skeleton ] && [ -f "$sd/test_command" ]; then
    local cmdline bexit btail
    cmdline=$(cat "$sd/test_command")
    _ga_watch "$timeout" "$tmp/build.out" "&1" bash -c 'cd "$1" && bash -c "$2"' _ "$root" "$cmdline"
    bexit=$GA_WATCH_RC
    [ "$GA_WATCH_TIMEOUT" = 1 ] && bexit=124
    btail=$(tail -n 40 "$tmp/build.out")
    build_json=$(jq -nc --arg c "$cmdline" --argjson e "$bexit" --arg t "$btail" '{command:$c, exit:$e, tail:$t}')
    build_text=$(printf '명령: %s\nexit: %s\n출력 마지막 40줄:\n%s' "$cmdline" "$bexit" "$btail")
  fi

  # 3. Prompt.
  prompt=$(_ga_verify_prompt "$root" "$build_text") || { rm -rf "$tmp"; ga_die "ga: 프롬프트를 만들 수 없습니다" 2; }

  # 4-5. Run each member.
  mdir=$tmp/members
  mkdir -p "$mdir"
  local panel_out="[]" all_ok=1 resultpath rc outtxt ext res nfind bad refs ref msg badjson cpath
  i=0
  while [ "$i" -lt "$n" ]; do
    m=$(printf '%s' "$panel" | jq -c ".members[$i]")
    runner=$(printf '%s' "$m" | jq -r .runner)
    model=$(printf '%s' "$m" | jq -r .model)
    rec=$(ga_billing_record "$runner")
    resultpath=$(jq -r '.result_path' "$rec" 2>/dev/null)
    # R34c: the exact binary this member runs (resolved in the root, like ga_runner_exec does).
    cpath=$(cd "$root" && ga_runner_command_path "$(jq -r '.command' "$rec" 2>/dev/null)") || cpath=""
    local -a argv=()
    local tok
    while IFS= read -r tok; do
      case "$tok" in
        "{{PROMPT}}") argv+=("$prompt") ;;
        "{{MODEL}}") argv+=("$model") ;;
        *) argv+=("$tok") ;;
      esac
    done <<EOF
$(jq -r '.invoke[]' "$rec")
EOF
    _ga_watch "$timeout" "$tmp/out.$i" "$tmp/err.$i" _ga_member_run "$root" "$runner" ${argv[@]+"${argv[@]}"}
    rc=$GA_WATCH_RC
    status=ok; kept=0; dropped=0
    printf '[]' >"$mdir/$i.json"
    if [ "$GA_WATCH_TIMEOUT" = 1 ]; then
      status=timeout
    elif [ "$rc" = 4 ]; then
      cat "$tmp/err.$i" >&2
      rm -rf "$tmp"
      echo "ga verify: 과금 점검 거부로 검증을 중단합니다. 보고서를 쓰지 않았습니다." >&2
      exit 4
    elif [ "$rc" != 0 ]; then
      status=failed
    else
      # result_path is a jq path (e.g. ".result"); evaluate it as such.
      outtxt=$(jq -er "if (type == \"object\") and (.is_error != true) then ($resultpath | select(type == \"string\")) else empty end" "$tmp/out.$i" 2>/dev/null) || outtxt=""
      if [ -z "$outtxt" ] || ! ext=$(_ga_extract_findings "$outtxt"); then
        status=invalid_output
      else
        nfind=$(printf '%s' "$ext" | jq '.findings | length')
        refs=$(printf '%s' "$ext" | jq -r '[.findings[].evidence[] | select(.type == "file") | .ref] | unique[]')
        badjson="[]"
        while IFS= read -r ref; do
          [ -n "$ref" ] || continue
          if ! _ga_coderef_error "$root" "$ref" >/dev/null; then
            badjson=$(printf '%s' "$badjson" | jq -c --arg r "$ref" '. + [$r]')
          fi
        done <<EOF
$refs
EOF
        printf '%s' "$ext" | jq -c --arg m "$model" --argjson bad "$badjson" '
          [.findings[] | select((.evidence | length) > 0 and ([.evidence[] | select(.type == "file" and (.ref as $r | $bad | index($r) != null))] | length) == 0)
           | {check, target, claim, evidence: [.evidence[] | {type, ref}], model: $m}]' >"$mdir/$i.json"
        kept=$(jq 'length' "$mdir/$i.json")
        dropped=$((nfind - kept))
      fi
    fi
    [ "$status" = ok ] || all_ok=0
    panel_out=$(printf '%s' "$panel_out" | jq -c --arg r "$runner" --arg m "$model" --arg s "$status" --argjson k "$kept" --argjson d "$dropped" --arg cp "$cpath" \
      '. + [{runner:$r, model:$m, status:$s, kept:$k, dropped:$d, command_path:$cp}]')
    i=$((i + 1))
  done

  # 6. Merge.
  local findings report
  findings=$(jq -sc '
    [.[][]] | group_by([.check, .target])
    | map({check: .[0].check, target: .[0].target, claims: (map(.claim) | unique), evidence: (map(.evidence[]) | unique), models: (map(.model) | unique), disposition: null})
    | sort_by([.check, .target]) | to_entries | map({id: "FND-\(.key + 1)"} + .value)' "$mdir"/*.json) \
    || { rm -rf "$tmp"; ga_die "ga: 지적 통합 실패" 2; }

  # 7. Report.
  report=$(jq -nc --arg h "$hash" --arg ph "$phase" --argjson rd "$(ga_state_get "$root" .round)" --argjson it "$(ga_state_get "$root" .iteration)" \
    --arg ts "$(ga_now)" --argjson panel "$panel_out" --argjson bc "$build_json" --argjson f "$findings" \
    '{doc_hash:$h, phase:$ph, round:$rd, iteration:$it, ts:$ts, panel:$panel, build_check:$bc, findings:$f}') \
    || { rm -rf "$tmp"; ga_die "ga: 보고서를 만들 수 없습니다" 2; }
  ga_lock "$root"
  printf '%s\n' "$report" | ga_write_json "$(ga_report_path "$root")"
  ga_unlock "$root"
  rm -rf "$tmp"

  echo "검증 패널 결과:"
  printf '%s' "$panel_out" | jq -r '.[] | "  \(.runner)/\(.model): \(.status) (지적 \(.kept)개 유지, \(.dropped)개 버림, 실행 파일 \(.command_path))"'
  echo "합친 지적: $(printf '%s' "$findings" | jq 'length')개"
  if [ -n "$build_json" ] && [ "$build_json" != null ]; then
    echo "빌드 확인: exit $(printf '%s' "$build_json" | jq -r .exit)"
  fi
  [ "$all_ok" = 1 ] || { echo "일부 구성원이 정상 종료하지 않았습니다. 다시 실행하거나 패널 설정을 확인하세요." >&2; exit 5; }
  exit 0
}

# Sets a finding's disposition. JQ_ARGS... are passed to jq; FILTER runs on the finding.
# Returns 3 when the report/finding is missing or GUARD (jq boolean on the finding) is false.
_ga_finding_update() { # ROOT FND GUARD FILTER [jq args...]
  local root=$1 fnd=$2 guard=$3 filter=$4 rp out
  shift 4
  rp=$(ga_report_path "$root")
  [ -f "$rp" ] || { echo "ga: 검증 보고서가 없습니다" >&2; return 3; }
  ga_lock "$root"
  if ! jq -e --arg id "$fnd" '.findings | map(select(.id == $id)) | length == 1' "$rp" >/dev/null 2>&1; then
    ga_unlock "$root"; echo "ga: 지적을 찾을 수 없습니다: $fnd" >&2; return 3
  fi
  if ! jq -e --arg id "$fnd" ".findings[] | select(.id == \$id) | $guard" "$rp" >/dev/null 2>&1; then
    ga_unlock "$root"; echo "ga: 이 지적에는 지금 이 처리를 할 수 없습니다: $fnd" >&2; return 3
  fi
  out=$(jq -c --arg id "$fnd" "$@" ".findings |= map(if .id == \$id then $filter else . end)" "$rp") \
    || { ga_unlock "$root"; return 2; }
  printf '%s\n' "$out" | ga_write_json "$rp"
  ga_unlock "$root"
}

ga_finding_user_reject() { # ROOT FND QUOTE
  [ -n "${3:-}" ] || { echo "ga: 사용자 인용(quote)이 비어 있습니다" >&2; return 3; }
  _ga_finding_update "$1" "$2" 'true' '.disposition = {type:"user_rejected", quote:$q, ts:$ts}' --arg q "$3" --arg ts "$(ga_now)"
}

ga_finding_verdict() { # ROOT FND accept|reject QUOTE
  case "${3:-}" in accept | reject) ;; *) echo "ga: 판정은 accept 또는 reject여야 합니다" >&2; return 3 ;; esac
  [ -n "${4:-}" ] || { echo "ga: 사용자 인용(quote)이 비어 있습니다" >&2; return 3; }
  _ga_finding_update "$1" "$2" '.disposition.type == "disputed"' '.disposition.verdict = $v | .disposition.verdict_quote = $q' --arg v "$3" --arg q "$4"
}

cmd_dispute() {
  local fnd="" ev="" have=0
  [ -n "${GA_ROOT:-}" ] || ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) [ $# -ge 2 ] || ga_die "사용법: ga dispute FND-ID --evidence TEXT" 2; ev=$2; have=1; shift 2 ;;
      --evidence=*) ev=${1#--evidence=}; have=1; shift ;;
      -*) ga_die "사용법: ga dispute FND-ID --evidence TEXT" 2 ;;
      *) [ -z "$fnd" ] || ga_die "사용법: ga dispute FND-ID --evidence TEXT" 2; fnd=$1; shift ;;
    esac
  done
  [ -n "$fnd" ] && [ "$have" = 1 ] || ga_die "사용법: ga dispute FND-ID --evidence TEXT" 2
  [ -n "$ev" ] || ga_die "ga: 반박 증거가 비어 있습니다" 3
  _ga_finding_update "$GA_ROOT" "$fnd" '.disposition.type != "user_rejected"' '.disposition = {type:"disputed", evidence:$e, ts:$ts, verdict:null}' --arg e "$ev" --arg ts "$(ga_now)"
  exit $?
}
