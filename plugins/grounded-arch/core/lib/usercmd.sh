# grounded-arch user commands: ga user-command. Sourced; bash 3.2 + jq. Only defines functions/variables.
# Output: one JSON line {"decision":"allow|block","reason":"...","context":"..."}, exit 0; exit 2 on internal failure.

GA_VERBS="승인 확인 답 기각 판정 일시정지 재개 되돌리기 새라운드 테스트명령 상태승인"

# Per-command accumulators (reset by cmd_user_command).
GA_UC_FAILS=""   # newline-separated failure reasons
GA_UC_SUM=""     # newline-separated "recorded" summaries
GA_UC_CUR=""     # the GA line being applied
GA_UC_NEXT=""    # next-step hint from the last phase transition

_uc_fail() { # MSG -> returns 1
  GA_UC_FAILS=${GA_UC_FAILS}${GA_UC_FAILS:+$'\n'}"[$GA_UC_CUR] $1"
  return 1
}
_uc_sum() { GA_UC_SUM=${GA_UC_SUM}${GA_UC_SUM:+$'\n'}"$1"; }

_uc_trim() { # TEXT -> trimmed
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

_uc_out() { # DECISION REASON CONTEXT
  jq -nc --arg d "$1" --arg r "$2" --arg c "$3" '{decision:$d, reason:$r, context:$c}'
}

# Files under .state that a command may change.
_uc_files() { echo "state.json ledger.json report.json approvals.jsonl test_command PAUSED snapshot.json"; }

_uc_backup() { # ROOT DIR
  local sd f
  sd=$(ga_state_dir "$1")
  for f in $(_uc_files); do
    if [ -f "$sd/$f" ]; then cp -p "$sd/$f" "$2/$f" || return 1; else : >"$2/$f.absent"; fi
  done
}

_uc_restore() { # ROOT DIR
  local sd f
  sd=$(ga_state_dir "$1")
  for f in $(_uc_files); do
    if [ -f "$2/$f.absent" ]; then rm -f "$sd/$f"; else cp -p "$2/$f" "$sd/$f.restore.$$" && mv "$sd/$f.restore.$$" "$sd/$f"; fi
  done
}

# ---- approval preconditions ----

_uc_ids() { # ROOT JQ_FILTER [jq args...] -> comma-joined ids from the ledger (filter yields array of ids)
  local root=$1 f=$2
  shift 2
  # jq failure must not read as "nothing wrong": emit a sentinel so callers fail closed.
  jq -r "$@" "$f | join(\", \")" "$(ga_ledger_path "$root")" 2>/dev/null || echo "(원장을 읽을 수 없습니다)"
}

_uc_isint() { case "$1" in "" | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# No-argument verbs and approval points accept no trailing text.
_uc_noargs() { # VERB REST -> fails when REST is non-empty
  [ -z "$2" ] && return 0
  _uc_fail "'GA $1' 뒤에 다른 글자를 붙일 수 없습니다. 정확히 'GA $1' 형태로만 입력하세요"
}

# Open/asked assumptions and questions from ALL rounds (they block approvals and 새라운드).
_uc_open_aq() { # ROOT
  _uc_ids "$1" '[.items[] | select((.kind == "assumption" or .kind == "question") and (.status == "open" or .status == "asked")) | .id]'
}

# Common preconditions (G-approval). Records every failure; returns 1 if any.
_uc_common() { # ROOT PHASE ROUND ITER
  local root=$1 phase=$2 round=$3 iter=$4 bad=0 chk n ids st rp
  chk=$(GA_ROOT=$root cmd_check --json 2>/dev/null)
  if ! printf '%s' "$chk" | jq -e '.errors | type == "array"' >/dev/null 2>&1; then
    _uc_fail "ga check를 실행할 수 없습니다"; bad=1
  else
    n=$(printf '%s' "$chk" | jq '.errors | length')
    if [ "$n" != 0 ]; then
      ids=$(printf '%s' "$chk" | jq -r '[.errors[] | "\(.id): \(.message)"] | join("; ")')
      _uc_fail "ga check 오류가 ${n}개 남아 있습니다 — $ids"; bad=1
    fi
  fi
  # Assumptions/questions of ANY round, plus open deviation decisions of the current round.
  ids=$(_uc_ids "$root" '[.items[] | select((.status == "open" or .status == "asked") and ((.kind == "assumption" or .kind == "question") or .round == $r)) | .id]' --argjson r "$round")
  if [ -n "$ids" ]; then _uc_fail "아직 해결되지 않은 항목이 있습니다 (open/asked): $ids"; bad=1; fi
  rp=$(ga_report_path "$root")
  st=$(_ga_status_json "$root") || { _uc_fail "상태를 읽을 수 없습니다"; return 1; }
  if [ ! -f "$rp" ]; then
    _uc_fail "검증 보고서가 없습니다. ga_verify를 실행하세요"; bad=1
  else
    if [ "$(printf '%s' "$st" | jq -r .report_fresh)" != true ]; then
      _uc_fail "검증 이후 문서나 원장이 바뀌었습니다. ga_verify를 다시 실행하세요"; bad=1
    elif ! jq -e --arg p "$phase" --argjson r "$round" --argjson i "$iter" \
        '.phase == $p and .round == $r and (if $p == "iterating" then .iteration == $i else true end)' "$rp" >/dev/null 2>&1; then
      _uc_fail "검증 보고서가 다른 단계·라운드·반복의 것입니다 ($(jq -r '"보고서: phase=\(.phase) round=\(.round) iteration=\(.iteration)"' "$rp"); 현재: phase=$phase round=$round iteration=$iter). ga_verify를 다시 실행하세요"; bad=1
    fi
    if [ "$(printf '%s' "$st" | jq -r .panel_ok)" != true ]; then
      _uc_fail "검증 패널이 모두 정상 종료하지 않았습니다 (panel_ok=false). ga_verify를 다시 실행하세요"; bad=1
    fi
    ids=$(jq -r '[.findings[] | select(((.disposition.type == "user_rejected") or (.disposition.type == "disputed" and .disposition.verdict == "accept")) | not) | .id] | join(", ")' "$rp" 2>/dev/null)
    if [ -n "$ids" ]; then _uc_fail "처리되지 않은 검증 지적이 있습니다: $ids (GA 기각 FND-n 또는 ga_dispute 후 GA 판정)"; bad=1; fi
  fi
  [ "$bad" = 0 ]
}

# G-approval additions (spec 5.5): the state fingerprint matches and no file outside the phase
# allow-list changed. Both were measured once before the message's lines ran (_uc_prepass).
_uc_effect_fp() {
  local bad=0
  case "$GA_UC_FP_RC" in
    0) ;;
    1) _uc_fail "$(ga_fp_mismatch_reason)"; bad=1 ;;
    2) _uc_fail "상태 지문 기록이 없어 설계 상태가 ga 밖에서 바뀌지 않았는지 확인할 수 없습니다. docs/architecture/.state/를 확인한 뒤 'GA 상태승인'을 먼저 입력하세요"; bad=1 ;;
    *) _uc_fail "shasum이나 sha256sum이 없어 상태 지문을 확인할 수 없습니다. 둘 중 하나를 설치한 뒤 다시 승인하세요"; bad=1 ;;
  esac
  case "$GA_UC_EFF_RC" in
    0) ;;
    1) _uc_fail "이 단계에서 바뀌면 안 되는 파일이 바뀌었습니다: $(ga_effect_list "$GA_UC_EFF_OUT"). 파일을 되돌린 뒤 다시 승인하거나, 이 변경을 받아들이려면 'GA 상태승인'을 입력하세요"; bad=1 ;;
    *) _uc_fail "바뀐 파일을 확인하지 못했습니다(ga effect check 실패). docs/architecture/.state/snapshot.json을 확인하세요"; bad=1 ;;
  esac
  [ "$bad" = 0 ]
}

# Before any line of a message with an approval runs: measure the fingerprint (before anything here
# writes the state folder) and the changed files. P6: a design without a file baseline gets one now,
# kept even when the approval is refused (it is taken before the backup).
_uc_prepass() { # ROOT LINES
  local root=$1
  GA_UC_FP_RC=0; GA_UC_EFF_RC=0; GA_UC_EFF_OUT=""; GA_UC_NOTE=""
  [ "$GA_UC_STATE_OK" = 1 ] || return 0
  printf '%s\n' "$2" | grep -Eq '^GA[[:space:]]+승인([[:space:]]|$)' || return 0
  ga_fp_check "$root" >/dev/null 2>&1 || GA_UC_FP_RC=$?
  GA_UC_EFF_OUT=$(ga_effect_check "$root" 2>/dev/null) || GA_UC_EFF_RC=$?
  if [ "$GA_UC_EFF_RC" = 2 ] && [ ! -f "$(ga_effect_snapshot_path "$root")" ] && ga_effect_snapshot "$root" >/dev/null 2>&1; then
    GA_UC_EFF_RC=0
    GA_UC_NOTE="참고: 파일 변경 기준(snapshot)이 없어서 지금 프로젝트 상태를 기준으로 기록했습니다. 그 전의 변경은 검사하지 않았습니다."
    # The baseline outlives a refused message, whose pending fingerprint record is dropped.
    [ "$GA_UC_FP_RC" != 0 ] || ga_fp_record "$root" >/dev/null 2>&1
  fi
  return 0
}

_uc_append_approval() { # ROOT POINT FROM TO ROUND ITER QUOTE
  local f line
  f=$(ga_state_dir "$1")/approvals.jsonl
  line=$(jq -nc --arg ts "$(ga_now)" --arg p "$2" --arg f "$3" --arg t "$4" --argjson r "$5" --argjson i "$6" --arg q "$7" \
    '{ts:$ts, point:$p, phase_from:$f, phase_to:$t, round:$r, iteration:$i, quote:$q}') || return 2
  { [ -f "$f" ] && cat "$f"; printf '%s\n' "$line"; } >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" || return 2
  ga_fp_mark "$1"
}

_uc_approve() { # ROOT POINT QUOTE
  local root=$1 point=$2 quote=$3 want phase round iter icount mode bad=0 ids n to next_iter newcount ldg rec_iter hi
  case "$point" in
    입력) want=inputs ;; 반복) want=iterating ;; 설계) want=design-review ;; 뼈대) want=skeleton ;;
    *) _uc_fail "승인 지점은 입력, 반복, 설계, 뼈대 중 하나여야 합니다 (예: GA 승인 입력)"; return 1 ;;
  esac
  phase=$(ga_state_get "$root" .phase) || return 2
  round=$(ga_state_get "$root" .round) || return 2
  iter=$(ga_state_get "$root" .iteration) || return 2
  icount=$(ga_state_get "$root" .iteration_count) || return 2
  mode=$(ga_state_get "$root" .mode) || return 2
  ldg=$(ga_ledger_path "$root")
  if [ "$phase" != "$want" ]; then
    _uc_fail "현재 단계는 ${phase}입니다. 'GA 승인 $point'는 ${want} 단계에서만 쓸 수 있습니다"; return 1
  fi
  if ! _uc_isint "$round" || ! _uc_isint "$iter" || ! _uc_isint "$icount"; then
    _uc_fail "state.json의 round/iteration/iteration_count가 정수가 아닙니다 (round=$round iteration=$iter iteration_count=$icount). 파일을 고치세요"; return 1
  fi
  rec_iter=$iter
  _uc_common "$root" "$phase" "$round" "$iter" || bad=1
  _uc_effect_fp || bad=1
  case "$point" in
    입력)
      ids=$(_uc_ids "$root" '[.items[] | select(.round == $r and .kind == "decision") | .id]' --argjson r "$round")
      if [ -n "$ids" ]; then _uc_fail "입력 단계에는 결정이 없어야 합니다: $ids"; bad=1; fi
      n=$(jq --argjson r "$round" '[.items[] | select(.round == $r and .kind == "driver" and .driver_type == "purpose")] | length' "$ldg" 2>/dev/null)
      if ! _uc_isint "$n" || [ "$n" -lt 1 ]; then _uc_fail "목적(purpose) 드라이버가 1개 이상 있어야 합니다"; bad=1; fi
      # R18: at least one high driver, iteration numbers exactly 1..N without gaps.
      hi=$(jq -c --argjson r "$round" '[.items[] | select(.round == $r and .kind == "driver" and .priority == "high" and (.iteration | type) == "number") | .iteration] | unique' "$ldg" 2>/dev/null)
      if [ -z "$hi" ] || [ "$hi" = "[]" ]; then
        _uc_fail "high 우선순위 드라이버가 1개 이상 있어야 합니다 (반복 계획이 비어 있습니다)"; bad=1
      else
        ids=$(printf '%s' "$hi" | jq -r '. as $h | ($h | max) as $m | [range(1; $m + 1) | select(. as $k | $h | index($k) | not)] | map(tostring) | join(", ")' 2>/dev/null) || ids="?"
        if [ -n "$ids" ]; then _uc_fail "high 드라이버의 반복 번호가 1부터 빠짐없이 이어지지 않습니다. 빠진 반복: $ids (현재: $hi)"; bad=1; fi
      fi
      ids=$(_uc_ids "$root" '[.items[] | select(.round == $r and .kind == "driver" and .priority == "high" and ((.iteration | type) != "number" or .iteration < 1)) | .id]' --argjson r "$round")
      if [ -n "$ids" ]; then _uc_fail "high 드라이버에 반복(iteration ≥ 1)이 지정되지 않았습니다: $ids"; bad=1; fi
      ;;
    반복)
      ids=$(_uc_ids "$root" '[ .items as $all | $all[] | select(.round == $r and .kind == "driver" and .priority == "high" and .iteration == $i) as $d
        | select(([$all[] | select(.round == $r and .kind == "decision" and .iteration == $i and ((.drivers // []) | index($d.id) != null))] | length) == 0) | .id]' --argjson r "$round" --argjson i "$iter")
      if [ -n "$ids" ]; then _uc_fail "반복 ${iter}의 드라이버가 같은 반복의 결정에 연결되지 않았습니다: $ids"; bad=1; fi
      n=$(jq --argjson r "$round" --argjson i "$iter" '[.items[] | select(.round == $r and .kind == "decision" and .iteration == $i)] | length' "$ldg" 2>/dev/null)
      if ! _uc_isint "$n" || [ "$n" -lt 1 ]; then _uc_fail "반복 ${iter}에 기록된 결정이 1개 이상 있어야 합니다"; bad=1; fi
      ;;
    설계)
      ids=$(_uc_ids "$root" '[ .items as $all | $all[] | select(.round == $r and .kind == "driver" and .priority == "high") as $d
        | select(([$all[] | select(.round == $r and .kind == "decision" and ((.drivers // []) | index($d.id) != null))] | length) == 0) | .id]' --argjson r "$round")
      if [ -n "$ids" ]; then _uc_fail "결정에 연결되지 않은 high 드라이버가 있습니다: $ids"; bad=1; fi
      ;;
    뼈대)
      if [ "$mode" = brownfield ]; then
        n=$(jq --argjson r "$round" '[.items[] | select(.round == $r and .kind == "mapping")] | length' "$ldg" 2>/dev/null)
        if ! _uc_isint "$n" || [ "$n" -lt 1 ]; then _uc_fail "기존 코드 대응표(mapping)가 1개 이상 있어야 합니다"; bad=1; fi
        case "$(_ga_status_json "$root" | jq -r .build_ok)" in
          true) ;;
          false) _uc_fail "빌드 확인이 실패했습니다. 'GA 테스트명령 <명령>'을 확인하거나 고친 뒤 ga_verify를 다시 실행하세요"; bad=1 ;;
          *) _uc_fail "빌드 확인 결과가 없습니다. 'GA 테스트명령 <명령>'으로 빌드·테스트 명령을 지정한 뒤 ga_verify를 실행하세요"; bad=1 ;;
        esac
      fi
      ;;
  esac
  [ "$bad" = 0 ] || return 1

  case "$point" in
    입력)
      to=iterating
      newcount=$(printf '%s' "$hi" | jq 'max') || return 2
      _uc_isint "$newcount" || return 2
      ga_state_set "$root" ".phase = \"iterating\" | .iteration = 1 | .iteration_count = $newcount" || return 2
      iter=1; icount=$newcount
      next="반복 1의 드라이버별로 결정을 기록하고 ga_verify를 실행한 뒤 'GA 승인 반복'을 입력하세요."
      ;;
    반복)
      if [ "$iter" -lt "$icount" ]; then
        to=iterating; next_iter=$((iter + 1))
        ga_state_set "$root" ".iteration = $next_iter" || return 2
        iter=$next_iter
        next="반복 ${iter}의 결정을 기록하고 ga_verify를 실행한 뒤 'GA 승인 반복'을 입력하세요."
      else
        to=design-review
        ga_state_set "$root" '.phase = "design-review"' || return 2
        next="설계 전체를 검토하고 ga_verify를 실행한 뒤 'GA 승인 설계'를 입력하세요."
      fi
      ;;
    설계)
      to=skeleton
      ga_state_set "$root" '.phase = "skeleton"' || return 2
      next="코드 대응표를 기록하고 뼈대를 만든 뒤 ga_verify를 실행하고 'GA 승인 뼈대'를 입력하세요."
      ;;
    뼈대)
      to=implement
      ga_state_set "$root" '.phase = "implement"' || return 2
      next="이제 구현할 수 있습니다. 대응표에 없는 경로는 쓰기 전에 ga_add(kind mapping)로 기록하세요."
      ;;
  esac
  ga_effect_snapshot "$root" || return 2
  _uc_append_approval "$root" "$point" "$phase" "$to" "$round" "$rec_iter" "$quote" || return 2
  _uc_sum "기록됨: 승인($point) / 단계 ${phase}→${to} (반복 $iter/$icount)"
  # R34c: show the user which binaries produced the report this approval relied on.
  local runners
  runners=$(jq -r '[.panel[]? | "\(.runner)/\(.model)=\(.command_path // "?")"] | join(", ")' "$(ga_report_path "$root")" 2>/dev/null)
  [ -n "$runners" ] && _uc_sum "검증 실행기: $runners"
  GA_UC_NEXT=$next
  return 0
}

# Runs a ledger/report helper that reports problems on stderr (rc 3 = rule violation).
_uc_run() { # cmd args... -> returns 1 and records the message on failure
  local err rc
  err=$("$@" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" != 0 ]; then
    _uc_fail "${err:-처리하지 못했습니다 (rc=$rc)}"
    return 1
  fi
  return 0
}

_uc_item_kind() { jq -r --arg id "$2" '[.items[] | select(.id == $id) | .kind] | first // ""' "$(ga_ledger_path "$1")"; } # ROOT ID

_uc_split() { # REST -> sets _UC_A (first word) and _UC_B (trimmed remainder)
  local rest
  rest=$(_uc_trim "$1")
  _UC_A=${rest%%[[:space:]]*}
  if [ "$_UC_A" = "$rest" ]; then _UC_B=""; else _UC_B=$(_uc_trim "${rest#"$_UC_A"}"); fi
}

# Applies one command. ROOT VERB REST QUOTE
_uc_apply() {
  local root=$1 verb=$2 rest=$3 quote=$4 phase kind v ic dv
  # R31: with an unreadable state.json only the pause commands can run; say how to recover.
  if [ "$GA_UC_STATE_OK" != 1 ]; then
    case "$verb" in
      일시정지 | 재개) ;;
      *) _uc_fail "docs/architecture/.state/state.json을 읽을 수 없어 이 명령을 적용할 수 없습니다. 'GA 일시정지'로 게이트를 끄거나, state.json을 고치거나 복원한 뒤 다시 입력하세요"; return 1 ;;
    esac
  fi
  case "$verb" in
    승인)
      _uc_split "$rest"
      if [ -n "$_UC_B" ]; then
        _uc_fail "승인 문구 뒤에 다른 글자를 붙일 수 없습니다. 정확히 'GA 승인 $_UC_A' 형태로만 입력하세요"; return 1
      fi
      _uc_approve "$root" "$_UC_A" "$quote"
      ;;
    확인)
      _uc_split "$rest"
      [ -n "$_UC_A" ] || { _uc_fail "사용법: GA 확인 ASM-n [메모]"; return 1; }
      kind=$(_uc_item_kind "$root" "$_UC_A")
      case "$kind" in
        assumption | decision) ;;
        question) _uc_fail "질문은 'GA 답 $_UC_A 답변'으로 답하세요"; return 1 ;;
        "") _uc_fail "항목이 없습니다: $_UC_A"; return 1 ;;
        *) _uc_fail "확인은 가정(ASM)이나 이탈 결정(DEC)에만 쓸 수 있습니다: $_UC_A"; return 1 ;;
      esac
      _uc_run ga_ledger_resolve_by_user "$root" "$_UC_A" "$quote" || return 1
      _uc_sum "기록됨: $_UC_A 사용자 확인"
      ;;
    답)
      _uc_split "$rest"
      [ -n "$_UC_A" ] && [ -n "$_UC_B" ] || { _uc_fail "사용법: GA 답 Q-n 답변 (답변이 비어 있으면 안 됩니다)"; return 1; }
      kind=$(_uc_item_kind "$root" "$_UC_A")
      [ "$kind" = question ] || { _uc_fail "질문(Q-n)이 아닙니다: $_UC_A"; return 1; }
      _uc_run ga_ledger_resolve_by_user "$root" "$_UC_A" "$quote" "$_UC_B" || return 1
      _uc_sum "기록됨: $_UC_A 사용자 답변"
      ;;
    기각)
      _uc_split "$rest"
      [ -n "$_UC_A" ] || { _uc_fail "사용법: GA 기각 FND-n [사유]"; return 1; }
      _uc_run ga_finding_user_reject "$root" "$_UC_A" "$quote" || return 1
      _uc_sum "기록됨: $_UC_A 사용자 기각"
      ;;
    판정)
      _uc_split "$rest"
      case "$_UC_B" in
        반박인정) v=accept ;;
        반박기각) v=reject ;;
        *) _uc_fail "사용법: GA 판정 FND-n 반박인정|반박기각"; return 1 ;;
      esac
      [ -n "$_UC_A" ] || { _uc_fail "사용법: GA 판정 FND-n 반박인정|반박기각"; return 1; }
      _uc_run ga_finding_verdict "$root" "$_UC_A" "$v" "$quote" || return 1
      _uc_sum "기록됨: $_UC_A 반박 판정($_UC_B)"
      ;;
    일시정지)
      # R31a: the PAUSED marker works even when state.json is unreadable.
      _uc_noargs 일시정지 "$rest" || return 1
      : >"$(ga_state_dir "$root")/PAUSED" || return 2
      ga_fp_mark "$root"
      if [ "$GA_UC_STATE_OK" = 1 ]; then ga_state_set "$root" '.paused = true' || return 2; fi
      _uc_sum "기록됨: 일시정지 (게이트가 모두 통과합니다. 'GA 재개'로 되돌립니다)"
      ;;
    재개)
      _uc_noargs 재개 "$rest" || return 1
      rm -f "$(ga_state_dir "$root")/PAUSED" || return 2
      ga_fp_mark "$root"
      if [ "$GA_UC_STATE_OK" = 1 ]; then ga_state_set "$root" '.paused = false' || return 2; fi
      # P12: what changed while paused is the user's -- the file baseline is taken again.
      ga_effect_snapshot "$root" || return 2
      GA_UC_EFF_RC=0
      _uc_sum "기록됨: 재개 (지금 프로젝트 파일 상태를 변경 검사의 새 기준으로 기록했습니다)"
      [ "$GA_UC_STATE_OK" = 1 ] || _uc_sum "주의: state.json을 읽을 수 없어 게이트가 다시 막습니다. docs/architecture/.state/state.json을 고치거나 복원하세요"
      ;;
    되돌리기)
      _uc_noargs 되돌리기 "$rest" || return 1
      phase=$(ga_state_get "$root" .phase) || return 2
      case "$phase" in
        design-review | skeleton) ;;
        *) _uc_fail "되돌리기는 design-review 또는 skeleton 단계에서만 쓸 수 있습니다 (현재: ${phase})"; return 1 ;;
      esac
      ic=$(ga_state_get "$root" .iteration_count) || return 2
      _uc_isint "$ic" || { _uc_fail "state.json의 iteration_count가 정수가 아닙니다 ($ic). 파일을 고치세요"; return 1; }
      ic=$((ic + 1))
      ga_state_set "$root" ".phase = \"iterating\" | .iteration_count = $ic | .iteration = $ic" || return 2
      ga_effect_snapshot "$root" || return 2
      _uc_sum "기록됨: 되돌리기 / 단계 ${phase}→iterating (반복 $ic/$ic)"
      GA_UC_NEXT="새 반복의 드라이버를 high로 지정하고 결정을 기록한 뒤 ga_verify, 'GA 승인 반복'을 진행하세요."
      ;;
    새라운드)
      _uc_noargs 새라운드 "$rest" || return 1
      phase=$(ga_state_get "$root" .phase) || return 2
      [ "$phase" = implement ] || { _uc_fail "새라운드는 implement 단계에서만 쓸 수 있습니다 (현재: ${phase})"; return 1; }
      v=$(_uc_open_aq "$root")
      if [ -n "$v" ]; then _uc_fail "해결되지 않은 가정/질문이 남아 있어 새 라운드를 시작할 수 없습니다: $v"; fi
      dv=$(_uc_ids "$root" '[.items[] | select(.kind == "decision" and .deviation == true and (.status == "open" or .status == "asked")) | .id]')
      if [ -n "$dv" ]; then _uc_fail "사용자가 확인하지 않은 이탈 결정이 남아 있어 새 라운드를 시작할 수 없습니다: $dv (GA 확인 DEC-n)"; fi
      [ -z "$v$dv" ] || return 1
      ga_state_set "$root" '.phase = "inputs" | .round += 1 | .iteration = 0 | .iteration_count = 0' || return 2
      ga_effect_snapshot "$root" || return 2
      _uc_sum "기록됨: 새 라운드 $(ga_state_get "$root" .round) / 단계 implement→inputs"
      GA_UC_NEXT="새 라운드의 입력(드라이버, 제약, 가정)을 정리하고 ga_verify, 'GA 승인 입력'을 진행하세요."
      ;;
    상태승인)
      _uc_noargs 상태승인 "$rest" || return 1
      # P12: the user accepts the whole current state -- the project files (a new file baseline)
      # and the state folder (the fingerprint, recorded at the final unlock, so it covers both).
      ga_effect_snapshot "$root" || return 2
      _uc_append_approval "$root" 상태승인 "" "" 0 0 "$quote" || return 2
      ga_fp_mark "$root" force
      # A later GA 승인 in the same message sees the accepted state.
      [ "$GA_UC_FP_RC" = 3 ] || GA_UC_FP_RC=0
      GA_UC_EFF_RC=0
      _uc_sum "기록됨: 지금 상태를 받아들였습니다 (상태 지문을 다시 기록하고, 지금 프로젝트 파일 상태를 변경 검사의 새 기준으로 기록했습니다)"
      ;;
    테스트명령)
      [ -n "$rest" ] || { _uc_fail "사용법: GA 테스트명령 <빌드·테스트 명령> (명령이 비어 있으면 안 됩니다)"; return 1; }
      local f
      f=$(ga_state_dir "$root")/test_command
      printf '%s\n' "$(_uc_trim "$rest")" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" || return 2
      ga_fp_mark "$root"
      _uc_sum "기록됨: 테스트 명령 = $(_uc_trim "$rest")"
      ;;
    *)
      _uc_fail "알 수 없는 명령: GA $verb. 사용할 수 있는 명령: $GA_VERBS"
      return 1
      ;;
  esac
}

GA_UC_BDIR=""; GA_UC_ROOT=""; GA_UC_LOCKED=0; GA_UC_RESTORE=0; GA_UC_STATE_OK=1
GA_UC_FP_RC=0; GA_UC_EFF_RC=0; GA_UC_EFF_OUT=""; GA_UC_NOTE="" # set by _uc_prepass

# Restores the backup (when GA_UC_RESTORE=1), fully releases the lock, removes the backup dir.
# Safe to call more than once; used both on exit paths and for the normal finish.
_uc_abort() {
  if [ -n "$GA_UC_BDIR" ] && [ -d "$GA_UC_BDIR" ]; then
    [ "$GA_UC_RESTORE" = 1 ] && { _uc_restore "$GA_UC_ROOT" "$GA_UC_BDIR"; ga_fp_discard "$GA_UC_ROOT"; }
    rm -rf "$GA_UC_BDIR"
  fi
  GA_UC_BDIR=""; GA_UC_RESTORE=0
  if [ "$GA_UC_LOCKED" = 1 ]; then
    GA_LOCK_DEPTH=1
    ga_unlock "$GA_UC_ROOT"
    GA_UC_LOCKED=0
  fi
  return 0
}

cmd_user_command() {
  local tf="" tp="" root bdir line verb rest lines="" rc nl=0 ctx
  while [ $# -gt 0 ]; do
    case "$1" in
      --text-file) [ $# -ge 2 ] || ga_die "사용법: ga user-command --text-file F [--transcript P]" 2; tf=$2; shift 2 ;;
      --text-file=*) tf=${1#--text-file=}; shift ;;
      --transcript) [ $# -ge 2 ] || ga_die "사용법: ga user-command --text-file F [--transcript P]" 2; tp=$2; shift 2 ;;
      --transcript=*) tp=${1#--transcript=}; shift ;;
      *) ga_die "사용법: ga user-command --text-file F [--transcript P]" 2 ;;
    esac
  done
  [ -n "$tf" ] && [ -f "$tf" ] || ga_die "ga: --text-file이 필요합니다" 2
  root=${GA_ROOT:-}

  # R24: a verifier runner's own prompt (it can quote build output) is never a user command,
  # and it must not move the recorded transcript.
  if [ "${GA_IN_RUNNER:-}" = 1 ]; then _uc_out allow "" ""; return 0; fi
  # R30: without a design, GA lines are ordinary text.
  if [ -z "$root" ] || [ ! -f "$(ga_state_dir "$root")/state.json" ]; then
    _uc_out allow "" ""
    return 0
  fi

  # Collect command lines (column 0 "GA <verb>").
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^GA[[:space:]]+([^[:space:]]+)(.*)$ ]]; then
      lines=${lines}${lines:+$'\n'}$line
      nl=$((nl + 1))
    fi
  done <"$tf"

  # R31: an unreadable state.json must not swallow the user's GA 일시정지.
  GA_UC_STATE_OK=1
  jq -e 'type == "object"' "$(ga_state_dir "$root")/state.json" >/dev/null 2>&1 || GA_UC_STATE_OK=0
  if [ -n "$tp" ] && [ "$GA_UC_STATE_OK" = 1 ]; then
    ga_state_set "$root" ".transcript_path = $(jq -nc --arg p "$tp" '$p')" || ga_die "ga: transcript_path 기록 실패" 2
  fi
  if [ "$nl" = 0 ]; then _uc_out allow "" ""; return 0; fi

  GA_UC_FAILS=""; GA_UC_SUM=""; GA_UC_NEXT=""
  bdir=$(mktemp -d "${TMPDIR:-/tmp}/ga-uc.XXXXXX") || ga_die "ga: 임시 디렉터리를 만들 수 없습니다" 2
  GA_UC_BDIR=$bdir; GA_UC_ROOT=$root; GA_UC_LOCKED=0
  # Any exit before a clean finish (ga_die from a helper, signal) restores the backup,
  # releases the lock and removes the backup dir.
  trap '_uc_abort' EXIT
  ga_lock "$root"
  GA_UC_LOCKED=1
  _uc_prepass "$root" "$lines"
  if ! _uc_backup "$root" "$bdir"; then
    ga_die "ga: 상태 백업 실패" 2
  fi
  GA_UC_RESTORE=1
  rc=0
  while IFS= read -r line; do
    [[ "$line" =~ ^GA[[:space:]]+([^[:space:]]+)(.*)$ ]]
    verb=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    GA_UC_CUR=$line
    _uc_apply "$root" "$verb" "$(_uc_trim "$rest")" "$line"
    case $? in
      0) ;;
      1) ;; # reason recorded; keep going to collect all reasons
      *) rc=2; break ;;
    esac
  done <<EOF
$lines
EOF
  if [ "$rc" != 0 ]; then
    ga_die "ga: user-command 내부 오류로 변경을 되돌렸습니다" 2   # EXIT trap restores + unlocks
  fi
  if [ -n "$GA_UC_FAILS" ]; then
    _uc_abort
    trap - EXIT
    _uc_out block "명령을 적용하지 않았습니다 (아무것도 바뀌지 않았습니다):"$'\n'"$GA_UC_FAILS${GA_UC_NOTE:+$'\n'$GA_UC_NOTE}" ""
    return 0
  fi
  GA_UC_RESTORE=0
  _uc_abort
  trap - EXIT
  ctx=${GA_UC_NOTE:+$GA_UC_NOTE$'\n'}$GA_UC_SUM
  [ -n "$GA_UC_NEXT" ] && ctx=$ctx$'\n'"다음: $GA_UC_NEXT"
  _uc_out allow "" "$ctx"
  return 0
}
