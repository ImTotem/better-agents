# grounded-arch ledger operations: ga add/update/ask/resolve/render. Sourced; bash 3.2 compatible.
# Exit codes: 0 ok, 3 rule violation (Korean message on stderr), 2 internal error.

_ga_viol() { echo "$1" >&2; return 3; } # MSG -> returns 3

_ga_need_root() {
  [ -n "${GA_ROOT:-}" ] && [ -f "$(ga_state_dir "$GA_ROOT")/state.json" ] ||
    ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
}

# Runs ga check --item KIND on JSON ITEM; prints checker lines to stderr; returns 0 / 3 / 2.
_ga_check_item() { # ROOT KIND ITEM
  local root=$1 kind=$2 out rc
  out=$( GA_ROOT=$root; printf '%s' "$3" | cmd_check --item "$kind" )
  rc=$?
  case $rc in
    0) return 0 ;;
    1) printf '%s\n' "$out" >&2; return 3 ;;
    *) return 2 ;;
  esac
}

_ga_stdin_object() { # -> prints stdin JSON object compact; returns 3 if not an object
  local in
  in=$(cat)
  printf '%s' "$in" | jq -ce 'select(type == "object")' 2>/dev/null && return 0
  _ga_viol "ga: stdin은 JSON 객체 하나여야 합니다"
}

_ga_write_ledger() { # ROOT JSON
  printf '%s\n' "$2" | ga_write_json "$(ga_ledger_path "$1")"
}

_ga_add_locked() { # ROOT KIND INPUT_JSON -> prints id
  local root=$1 kind=$2 in=$3 prefix phase round iter lp n id item new
  case "$kind" in
    driver) prefix=DRV ;; constraint) prefix=CON ;; fact) prefix=FACT ;; decision) prefix=DEC ;;
    assumption) prefix=ASM ;; question) prefix=Q ;; mapping) prefix=MAP ;;
    *) _ga_viol "ga: 알 수 없는 항목 종류: $kind (driver|constraint|fact|decision|assumption|question|mapping)"; return 3 ;;
  esac
  phase=$(ga_state_get "$root" .phase) || return 2
  round=$(ga_state_get "$root" .round) || return 2
  iter=$(ga_state_get "$root" .iteration) || return 2
  if [ "$kind" = decision ] && [ "$phase" = inputs ]; then
    _ga_viol "입력 단계에서는 아키텍처 결정을 기록할 수 없습니다"; return 3
  fi
  if [ "$kind" = mapping ] && { [ "$phase" = inputs ] || [ "$phase" = iterating ]; }; then
    _ga_viol "코드 대응표는 반복 단계가 끝난 뒤에 기록합니다 (현재 단계: $phase)"; return 3
  fi
  lp=$(ga_ledger_path "$root")
  n=$(jq -r --arg p "$prefix-" '[.items[] | select(.id | startswith($p)) | (.id[($p | length):] | tonumber? // 0)] | (max // 0) + 1' "$lp") || return 2
  id=$prefix-$n
  item=$(printf '%s' "$in" | jq -c --arg id "$id" --arg kind "$kind" --arg phase "$phase" \
    --argjson round "$round" --argjson iter "$iter" '
    (if $kind == "decision" and (has("deviation") | not) then .deviation = false else . end) as $i
    | $i + {id: $id, kind: $kind, round: $round, phase_added: $phase,
            iteration: (if $kind == "driver" then ($i.iteration // null) else $iter end),
            status: (if $kind == "assumption" or $kind == "question" then "open"
                     elif $kind == "decision" and $i.deviation == true then "open" else null end),
            resolution: null}') || return 2
  _ga_check_item "$root" "$kind" "$item" || return $?
  new=$(jq -c --argjson i "$item" '.items += [$i]' "$lp") || return 2
  _ga_write_ledger "$root" "$new" || return 2
  echo "$id"
}

cmd_add() {
  local kind in id rc
  [ $# -eq 1 ] || ga_die "사용법: ga add KIND  (stdin: JSON 객체)" 2
  _ga_need_root
  kind=$1
  in=$(_ga_stdin_object) || exit 3
  ga_lock "$GA_ROOT"
  id=$(_ga_add_locked "$GA_ROOT" "$kind" "$in")
  rc=$?
  ga_unlock "$GA_ROOT"
  [ $rc -eq 0 ] || exit $rc
  echo "$id"
}

# Sets GA_UPDATE_REOPENED=1 when the change reopened a resolved item (R25): a resolution
# (by the user or by evidence) was given for the old content, so it no longer counts.
GA_UPDATE_REOPENED=0
_ga_update_locked() { # ROOT ID PATCH
  local root=$1 id=$2 patch=$3 lp item old kind new
  GA_UPDATE_REOPENED=0
  lp=$(ga_ledger_path "$root")
  old=$(jq -c --arg id "$id" '.items[] | select(.id == $id)' "$lp") || return 2
  [ -n "$old" ] || { _ga_viol "ga: 항목이 없습니다: $id"; return 3; }
  item=$(printf '%s' "$old" | jq -c --argjson p "$patch" '. + $p') || return 2
  [ "$(printf '%s' "$old" | jq -S -c .)" = "$(printf '%s' "$item" | jq -S -c .)" ] && return 0
  if [ "$(printf '%s' "$item" | jq -r .status)" = resolved ]; then
    item=$(printf '%s' "$item" | jq -c --arg ts "$(ga_now)" '
      .resolution_history = ((.resolution_history // [])
        + [{resolution: .resolution, reopened_ts: $ts} + (if has("answer") then {answer: .answer} else {} end)])
      | .status = "open" | .resolution = null | del(.answer)') || return 2
    GA_UPDATE_REOPENED=1
  fi
  kind=$(printf '%s' "$item" | jq -r .kind)
  _ga_check_item "$root" "$kind" "$item" || return $?
  new=$(jq -c --argjson i "$item" --arg id "$id" '.items |= map(if .id == $id then $i else . end)' "$lp") || return 2
  _ga_write_ledger "$root" "$new"
}

cmd_update() {
  local id patch bad rc how
  [ $# -eq 1 ] || ga_die "사용법: ga update ID  (stdin: JSON 객체)" 2
  _ga_need_root
  id=$1
  patch=$(_ga_stdin_object) || exit 3
  bad=$(printf '%s' "$patch" | jq -r '[keys[] | select(. as $k | ["id","kind","status","resolution","resolution_history","round","phase_added","answer","deviation"] | index($k))] | join(", ")')
  if [ -n "$bad" ]; then
    _ga_viol "다음 필드는 고칠 수 없습니다: $bad (상태와 해결 기록은 ga ask/resolve 또는 사용자 명령으로만 바뀝니다)"
    exit 3
  fi
  ga_lock "$GA_ROOT"
  _ga_update_locked "$GA_ROOT" "$id" "$patch"
  rc=$?
  ga_unlock "$GA_ROOT"
  if [ $rc -eq 0 ] && [ "$GA_UPDATE_REOPENED" = 1 ]; then
    case "$id" in
      Q-*) how="사용자에게 'GA 답 $id 답변'을 다시 요청하거나, 직접 근거가 있으면 ga resolve로 해결하세요" ;;
      DEC-*) how="사용자에게 바뀐 이탈 내용을 보여 주고 'GA 확인 $id'를 다시 요청하세요" ;;
      *) how="사용자에게 'GA 확인 $id'를 다시 요청하거나, 직접 근거가 있으면 ga resolve로 해결하세요" ;;
    esac
    echo "ga: ${id}는 해결된 뒤 내용이 바뀌어 다시 open 상태가 되었습니다 (이전 해결 기록은 resolution_history에 남았습니다). $how"
  fi
  exit $rc
}

_ga_ask_locked() { # ROOT ID
  local root=$1 id=$2 lp item new
  lp=$(ga_ledger_path "$root")
  item=$(jq -c --arg id "$id" '.items[] | select(.id == $id)' "$lp") || return 2
  [ -n "$item" ] || { _ga_viol "ga: 항목이 없습니다: $id"; return 3; }
  if [ "$(printf '%s' "$item" | jq -r '.kind')" != question ]; then
    _ga_viol "ga ask는 질문(Q-n)에만 쓸 수 있습니다: $id"; return 3
  fi
  if [ "$(printf '%s' "$item" | jq -r '.status')" != open ]; then
    _ga_viol "상태가 open인 질문만 asked로 바꿀 수 있습니다: $id"; return 3
  fi
  new=$(jq -c --arg id "$id" '.items |= map(if .id == $id then .status = "asked" else . end)' "$lp") || return 2
  _ga_write_ledger "$root" "$new"
}

cmd_ask() {
  local rc
  [ $# -eq 1 ] || ga_die "사용법: ga ask Q-ID" 2
  _ga_need_root
  ga_lock "$GA_ROOT"
  _ga_ask_locked "$GA_ROOT" "$1"
  rc=$?
  ga_unlock "$GA_ROOT"
  exit $rc
}

# Shared resolve core. RES = resolution JSON; ANSWER used only for questions (BY_USER=1 requires it).
_ga_resolve_locked() { # ROOT ID RES ANSWER BY_USER
  local root=$1 id=$2 res=$3 answer=$4 by_user=$5 lp item kind new
  lp=$(ga_ledger_path "$root")
  item=$(jq -c --arg id "$id" '.items[] | select(.id == $id)' "$lp") || return 2
  [ -n "$item" ] || { _ga_viol "ga: 항목이 없습니다: $id"; return 3; }
  kind=$(printf '%s' "$item" | jq -r .kind)
  if [ "$kind" = decision ] && [ "$by_user" != 1 ]; then
    _ga_viol "이탈 승인은 사용자의 GA 확인 DEC-n으로만 기록됩니다: $id"; return 3
  fi
  if ! printf '%s' "$item" | jq -e '.kind == "assumption" or .kind == "question" or (.kind == "decision" and .deviation == true)' >/dev/null; then
    _ga_viol "해결 처리는 가정, 질문, 이탈 결정에만 쓸 수 있습니다: $id"; return 3
  fi
  if ! printf '%s' "$item" | jq -e '.status == "open" or .status == "asked"' >/dev/null; then
    _ga_viol "상태가 open 또는 asked인 항목만 해결할 수 있습니다: $id"; return 3
  fi
  if [ "$kind" = question ] && [ "$by_user" = 1 ] && [ -z "$answer" ]; then
    _ga_viol "질문을 해결하려면 답(answer)이 필요합니다: $id"; return 3
  fi
  item=$(printf '%s' "$item" | jq -c --argjson r "$res" --arg a "$answer" '
    .status = "resolved" | .resolution = $r
    | if .kind == "question" and $a != "" then .answer = $a else . end') || return 2
  if [ "$by_user" != 1 ]; then
    _ga_check_item "$root" "$kind" "$item" || return $?
  fi
  new=$(jq -c --argjson i "$item" --arg id "$id" '.items |= map(if .id == $id then $i else . end)' "$lp") || return 2
  _ga_write_ledger "$root" "$new"
}

_ga_resolve_core() { # ROOT ID RES ANSWER BY_USER
  local rc
  ga_lock "$1"
  _ga_resolve_locked "$@"
  rc=$?
  ga_unlock "$1"
  return $rc
}

cmd_resolve() {
  local id="" st="" ref="" res
  while [ $# -gt 0 ]; do
    case "$1" in
      --source-type) [ $# -ge 2 ] || ga_die "사용법: ga resolve ID --source-type code|literature|measurement --ref REF" 2; st=$2; shift 2 ;;
      --source-type=*) st=${1#--source-type=}; shift ;;
      --ref) [ $# -ge 2 ] || ga_die "사용법: ga resolve ID --source-type code|literature|measurement --ref REF" 2; ref=$2; shift 2 ;;
      --ref=*) ref=${1#--ref=}; shift ;;
      -*) ga_die "사용법: ga resolve ID --source-type code|literature|measurement --ref REF" 2 ;;
      *) [ -z "$id" ] || ga_die "사용법: ga resolve ID --source-type ... --ref REF" 2; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || ga_die "사용법: ga resolve ID --source-type code|literature|measurement --ref REF" 2
  _ga_need_root
  case "$st" in
    user) _ga_viol "사용자 확인은 사용자의 GA 명령으로만 기록됩니다"; exit 3 ;;
    code|literature|measurement) ;;
    *) _ga_viol "--source-type은 code, literature, measurement 중 하나여야 합니다"; exit 3 ;;
  esac
  [ -n "$ref" ] || { _ga_viol "--ref가 필요합니다"; exit 3; }
  res=$(jq -nc --arg ts "$(ga_now)" --arg t "$st" --arg r "$ref" '{by:"evidence", ts:$ts, source:{type:$t, ref:$r}}')
  _ga_resolve_core "$GA_ROOT" "$id" "$res" "" 0
  exit $?
}

# Internal (no CLI subcommand): called by the user-command handler.
ga_ledger_resolve_by_user() { # ROOT ID QUOTE [ANSWER]
  local root=$1 id=$2 quote=${3:-} answer=${4:-} res
  [ -n "$quote" ] || { _ga_viol "사용자 인용(quote)이 비어 있습니다"; return 3; }
  res=$(jq -nc --arg ts "$(ga_now)" --arg q "$quote" '{by:"user", ts:$ts, quote:$q}') || return 2
  _ga_resolve_core "$root" "$id" "$res" "$answer" 1
}

# ---- render ----

_GA_RENDER_JQ='
def esc: if . == null then "" else tostring | gsub("\\|"; "\\|") | gsub("\r?\n"; "<br>") end;
def src: if type == "object" then (if .type == "user" then "user: \"\(.quote // "")\"" else "\(.type):\(.ref // "")" end) else "" end;
def row(cells): "| " + (cells | map(esc) | join(" | ")) + " |";
def table($head; $rows):
  [ row($head), ("|" + ($head | map("---") | join("|")) + "|") ] + ($rows | map(row(.))) | join("\n");
def items($k): [.items[] | select(.kind == $k)];
def lst: if . == null then "" else map(tostring) | join("; ") end;
def block:
  if $blk == "drivers" then
    table(["ID","유형","내용","시점","우선순위","반복","측정 기준","출처"];
      items("driver") | map([.id, .driver_type, .statement, .horizon, .priority, .iteration, (.scenario.measure // null), (.source | src)]))
  elif $blk == "context" then
    "**제약**\n\n" + table(["ID","내용","출처"]; items("constraint") | map([.id, .statement, (.source | src)]))
    + "\n\n**현재 구조**\n\n" + table(["ID","내용","출처"]; items("fact") | map([.id, .statement, (.source | src)]))
  elif $blk == "plan" then
    table(["반복","드라이버"];
      [ items("driver")[] | select(.priority == "high" and .iteration != null and .round == $rd) ]
      | group_by(.iteration) | map([.[0].iteration, (map(.id) | join(", "))]))
  elif $blk == "ledger" then
    "**결정**\n\n" + table(["ID","반복","요소","선택","근거","버린 대안","드라이버","이탈"];
      items("decision") | map([.id, .iteration, .element, .choice,
        ((.rationale // []) | map(src) | lst),
        ((.alternatives // []) | map(if .none then "없음(\(.none)) \(.source | src)" else "\(.option) (\(.reason))" end) | lst),
        ((.drivers // []) | join(", ")),
        (if .deviation == true then (if .status == "resolved" then "승인된 이탈" else "미승인 이탈" end) else "" end)]))
    + "\n\n**가정**\n\n" + table(["ID","가정","간접 근거","탐색 기록","다른 가정","상태"];
      items("assumption") | map([.id, .statement,
        ((.indirect_evidence // []) | map("\(.type):\(.ref)") | lst),
        (if .search_log then (.search_log | "코드: \(.code); 문서: \(.docs); 대화: \(.conversation); 웹: \(.web)") else "" end),
        ((.alternatives // []) | map("\(.assumption) (\(.reason))") | lst),
        .status]))
    + "\n\n**질문**\n\n" + table(["ID","질문","영향","상태","답"];
      items("question") | map([.id, .question, .impact, .status, .answer]))
  else
    table(["ID","요소","경로","구분"]; items("mapping") | map([.id, .element, .path, .change]))
  end;
block'

# Prints one line per ga marker problem in FILE ("블록 NAME: ..."); prints nothing when every
# <!-- ga:begin NAME --> / <!-- ga:end NAME --> pair is complete, unique, in order, not nested,
# and each marker stands alone on its line. Used by render (refuse), check (E_MARKERS) and the
# doc hash (whole document when unbalanced), so all three agree on what a block is (R28).
ga_marker_problems() { # FILE
  [ -f "$1" ] || return 0
  awk '
    function prob(n, m) { print "블록 " n ": " m }
    {
      rest = $0; cnt = 0
      while (match(rest, /<!-- ga:(begin|end) [^ ]+ -->/)) {
        m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH); cnt++
        kind = (m ~ /^<!-- ga:begin /) ? "begin" : "end"
        n = m; sub(/^<!-- ga:(begin|end) /, "", n); sub(/ -->$/, "", n)
        if (cnt > 1 || $0 != m) prob(n, NR "번째 줄: 표시는 한 줄에 단독으로 있어야 합니다")
        if (kind == "begin") {
          if (n in seenb) prob(n, "begin 표시가 두 번 이상 있습니다")
          if (open != "") prob(n, "블록 " open " 이 끝나기 전에 시작합니다")
          seenb[n] = 1; open = n
        } else {
          if (n in seene) prob(n, "end 표시가 두 번 이상 있습니다")
          else if (open != n) prob(n, (n in seenb) ? "end 표시의 순서가 맞지 않습니다" : "begin 표시 없이 end 표시가 있습니다")
          seene[n] = 1
          if (open == n) open = ""
        }
      }
    }
    END { for (n in seenb) if (!(n in seene)) prob(n, "end 표시(<!-- ga:end " n " -->)가 없습니다") }' "$1"
}

# Replace (or append) the ga:begin/ga:end block NAME in FILE with BODY text; writes via temp file + mv.
# Callers check ga_marker_problems first; a block with only one of its markers is refused (3).
_ga_replace_block() { # FILE NAME BODY
  local f=$1 name=$2 body=$3 tmp bf hb=0 he=0
  tmp=$f.tmp.$$
  bf=$f.body.$$
  grep -qx "<!-- ga:begin $name -->" "$f" && hb=1
  grep -qx "<!-- ga:end $name -->" "$f" && he=1
  [ "$hb" = "$he" ] || return 3
  printf '%s\n' "$body" >"$bf"
  if [ "$hb" = 1 ]; then
    awk -v b="<!-- ga:begin $name -->" -v e="<!-- ga:end $name -->" -v bf="$bf" '
      $0 == b && !skip { print; while ((getline l < bf) > 0) print l; close(bf); skip = 1; next }
      skip && $0 == e { print; skip = 0; next }
      skip { next }
      { print }' "$f" >"$tmp" || { rm -f "$tmp" "$bf"; return 2; }
  else
    { cat "$f"; printf '\n<!-- ga:begin %s -->\n' "$name"; cat "$bf"; printf '<!-- ga:end %s -->\n' "$name"; } >"$tmp" || { rm -f "$tmp" "$bf"; return 2; }
  fi
  rm -f "$bf"
  mv "$tmp" "$f"
}

cmd_render() {
  local f lp name body rd rc=0 probs
  [ $# -eq 0 ] || ga_die "사용법: ga render" 2
  _ga_need_root
  f=$GA_ROOT/docs/architecture/architecture.md
  [ -f "$f" ] || cp "$GA_CORE/templates/architecture.md" "$f" || ga_die "ga: architecture.md를 만들 수 없습니다" 2
  probs=$(ga_marker_problems "$f")
  if [ -n "$probs" ]; then
    _ga_viol "ga render: architecture.md의 ga 블록 표시가 맞지 않아 아무것도 바꾸지 않았습니다. 블록마다 '<!-- ga:begin 이름 -->'과 '<!-- ga:end 이름 -->'이 한 줄씩, 이 순서로 한 쌍만 있도록 고친 뒤 다시 실행하세요 (두 표시를 모두 지우면 render가 문서 끝에 새 블록을 만듭니다):
$probs"
    exit 3
  fi
  lp=$(ga_ledger_path "$GA_ROOT")
  rd=$(ga_state_get "$GA_ROOT" '.round | numbers') && [ -n "$rd" ] || ga_die "ga: state.json의 round를 읽을 수 없습니다" 2
  ga_lock "$GA_ROOT"
  for name in drivers context plan ledger mapping; do
    body=$(jq -r --arg blk "$name" --argjson rd "$rd" "$_GA_RENDER_JQ" "$lp") || { rc=2; break; }
    _ga_replace_block "$f" "$name" "$body" || { rc=2; break; }
  done
  ga_unlock "$GA_ROOT"
  [ $rc -eq 0 ] || ga_die "ga: render 실패" 2
}
