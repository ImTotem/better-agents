#!/bin/bash
# grounded-arch MCP server (stdio): the ga subcommands the agent needs, as MCP tools.
# Claude Code starts it from the plugin's .mcp.json outside the OS sandbox, so these tools can
# write docs/architecture/.state while the agent's own shell cannot. The tool table below is the
# whole surface: the approval path (ga user-command) and ga gate are never reachable from here.
#
# Wire: one JSON-RPC 2.0 message per line on stdin and stdout; stdout carries nothing else, and
# diagnostics go to stderr. Era: the initialize handshake (revisions 2024-11-05 .. 2025-11-25,
# https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle). The current revision
# 2026-07-28 drops initialize for per-request _meta; a dual-era client probes with server/discover,
# gets -32601 here and falls back to initialize
# (https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio).
# Requests are served one at a time, in arrival order. bash 3.2 + jq.

# The server runs outside the OS sandbox (spec 5.5, P28): it and the ga it starts run only system
# tools. The caller's PATH is kept as GA_USER_PATH for the verifier runners and the sandboxed build.
GA_USER_PATH=${GA_USER_PATH:-$PATH}
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GA_USER_PATH PATH
_d=${0%/*}
[ "$_d" = "$0" ] && _d=.
GA_MCP_CORE=$(cd -P "$_d/.." && pwd) || exit 2
unset _d
GA_MCP_GA=$GA_MCP_CORE/bin/ga
# ga_find_root, ga_canon and GA_VERSION: the root rules must be ga's own.
. "$GA_MCP_CORE/lib/common.sh" || { echo "ga-mcp: core/lib/common.sh를 읽을 수 없습니다" >&2; exit 2; }
GA_MCP_VERSIONS="2025-11-25 2025-06-18 2025-03-26 2024-11-05" # newest first
GA_MCP_TICK=60 # seconds between progress notifications while a tool runs
if [ "${GA_TEST_MODE:-}" = 1 ]; then
  case "${GA_MCP_PROGRESS_SEC:-}" in
    "" | *[!0-9]*) ;;
    *) [ "$GA_MCP_PROGRESS_SEC" -gt 0 ] && GA_MCP_TICK=$GA_MCP_PROGRESS_SEC ;;
  esac
fi
GA_MCP_INSTRUCTIONS="grounded-arch 설계 원장과 검증을 다루는 ga 명령 도구다. 각 도구는 같은 이름의 ga 하위 명령을 프로젝트 루트(인자 root, 없으면 CLAUDE_PROJECT_DIR)에서 실행하고 출력과 종료 코드를 돌려준다. 사용자 승인(GA 명령)은 이 서버로 기록할 수 없다."

[ -x "$GA_JQ" ] || { echo "ga-mcp: jq(${GA_JQ})가 없어 시작할 수 없습니다" >&2; exit 2; }
GA_MCP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ga-mcp.XXXXXX") || { echo "ga-mcp: 임시 디렉터리를 만들 수 없습니다" >&2; exit 2; }
GA_MCP_MSG=$GA_MCP_TMP/msg.json   # the request being served
GA_MCP_ARGS=$GA_MCP_TMP/args.json # its tool arguments
GA_MCP_IN=$GA_MCP_TMP/in.json     # JSON payload for ga's stdin
GA_MCP_OUT=$GA_MCP_TMP/out.txt    # ga's stdout + stderr
GA_MCP_TOOLS=$GA_MCP_TMP/tools.json
GA_MCP_CHILD=""
GA_MCP_TICKER=""

# Freezes PID before listing its children, so nothing in the tree can fork or react while the
# tree is taken down; each process gets TERM (delivered on CONT).
_mcp_killtree() { # PID
  local c
  kill -STOP "$1" 2>/dev/null
  for c in $(pgrep -P "$1" 2>/dev/null); do _mcp_killtree "$c"; done
  kill -TERM "$1" 2>/dev/null
  kill -CONT "$1" 2>/dev/null
  return 0
}
_mcp_stop() { # TERM/INT/HUP: take the running ga command down with the server
  [ -z "$GA_MCP_TICKER" ] || _mcp_killtree "$GA_MCP_TICKER"
  [ -z "$GA_MCP_CHILD" ] || _mcp_killtree "$GA_MCP_CHILD"
  exit 143
}
trap _mcp_stop TERM INT HUP
trap 'rm -rf "$GA_MCP_TMP"' EXIT

# ---- tools ----
# Each tool's inputSchema mirrors its ga subcommand's arguments; every tool also takes root.
jq -c --argjson root '{"type":"string","description":"프로젝트 루트의 절대 경로. 없으면 CLAUDE_PROJECT_DIR"}' '
  {tools: map({name, description,
    inputSchema: ({type: "object", properties: ((.props // {}) + {root: $root}), additionalProperties: false}
      + (if (.required // []) == [] then {} else {required} end))})}' >"$GA_MCP_TOOLS" <<'EOF' || { echo "ga-mcp: 도구 목록을 만들 수 없습니다" >&2; exit 2; }
[
 {"name":"ga_init","description":"설계를 시작한다 (ga init). 출력: 정한 모드와 그 근거. 이미 초기화된 프로젝트면 실패한다.",
  "props":{"mode":{"type":"string","enum":["greenfield","brownfield"],"description":"없으면 기존 파일 유무로 정한다"}}},
 {"name":"ga_add","description":"원장에 항목 하나를 추가한다 (ga add KIND, item은 표준 입력 JSON). 출력: 새 ID. 규칙 위반이면 isError와 이유.",
  "props":{"kind":{"type":"string","enum":["driver","constraint","fact","decision","assumption","question","mapping"],"description":"항목 종류"},
           "item":{"type":"object","description":"항목 내용 JSON 객체"}},
  "required":["kind","item"]},
 {"name":"ga_update","description":"항목의 최상위 필드를 바꾼다 (ga update ID, patch는 표준 입력 JSON). id, kind, status, resolution, resolution_history, round, phase_added, answer, deviation은 바꿀 수 없다. 객체 필드는 통째로 다시 준다.",
  "props":{"id":{"type":"string","minLength":1,"description":"항목 ID (예: ASM-1)"},
           "patch":{"type":"object","description":"바꿀 최상위 필드만 담은 JSON 객체"}},
  "required":["id","patch"]},
 {"name":"ga_ask","description":"질문을 물은 상태(asked)로 바꾼다 (ga ask Q-n).",
  "props":{"id":{"type":"string","minLength":1,"description":"질문 ID (예: Q-1)"}},
  "required":["id"]},
 {"name":"ga_resolve","description":"직접 근거로 가정이나 질문을 해결한다 (ga resolve ID --source-type T --ref REF). 결정에는 쓸 수 없다.",
  "props":{"id":{"type":"string","minLength":1,"description":"가정 또는 질문 ID"},
           "source_type":{"type":"string","enum":["code","literature","measurement"],"description":"근거 종류"},
           "ref":{"type":"string","minLength":1,"description":"근거 위치. code는 경로:줄, literature는 URL, doi:, isbn:"}},
  "required":["id","source_type","ref"]},
 {"name":"ga_render","description":"원장을 architecture.md의 ga 블록에 반영한다 (ga render)."},
 {"name":"ga_check","description":"원장 전체의 형식을 검사한다 (ga check). kind와 item을 함께 주면 그 항목 하나만 검사한다 (ga check --item KIND).",
  "props":{"json":{"type":"boolean","description":"true면 JSON으로 출력"},
           "kind":{"type":"string","enum":["driver","constraint","fact","decision","assumption","question","mapping"],"description":"item의 항목 종류"},
           "item":{"type":"object","description":"검사할 항목 하나"}}},
 {"name":"ga_status","description":"단계, 모드, 라운드, 반복, 미해결 수, 검증 보고서 상태를 보여 준다 (ga status).",
  "props":{"json":{"type":"boolean","description":"true면 JSON으로 출력 (report_fresh, panel_ok, findings_unprocessed, build_ok 포함)"}}},
 {"name":"ga_verify","description":"검증 패널을 돌리고 보고서를 쓴다 (ga verify). 15분까지 걸릴 수 있다. 종료 코드 4는 과금 점검 실패, 5는 일부 모델 실패."},
 {"name":"ga_rule","description":"짧은 근거 규칙을 출력한다 (ga rule)."},
 {"name":"ga_enforce","description":"이 프로젝트의 격리 설정(설계 상태 폴더 쓰기 금지)을 다시 설치한다 (ga enforce)."},
 {"name":"ga_dispute","description":"검증 지적에 증거를 붙여 반박한다 (ga dispute FND-ID --evidence TEXT).",
  "props":{"id":{"type":"string","minLength":1,"description":"지적 ID (예: FND-1)"},
           "evidence":{"type":"string","minLength":1,"description":"반박 증거"}},
  "required":["id","evidence"]}
]
EOF

# Checks the arguments object (input) against tool $n's inputSchema: required, unknown keys,
# type, enum, minLength. Prints one Korean line per problem.
_MCP_VALIDATE='
def tyok($ty): ($ty == null) or (type == $ty);
. as $a
| ($t[0].tools[] | select(.name == $n) | .inputSchema) as $s
| (($s.required // [])[] | select(. as $k | $a | has($k) | not) | "필수 인자가 없습니다: \(.)"),
  ($a | keys[] | select(. as $k | $s.properties | has($k) | not) | "알 수 없는 인자입니다: \(.)"),
  ($a | to_entries[] | select($s.properties[.key] != null) | . as $e | $s.properties[$e.key] as $ps
   | if ($e.value | tyok($ps.type) | not) then "인자 형식이 틀렸습니다: \($e.key) (\($ps.type) 필요)"
     elif $ps.enum != null and ([$ps.enum[] | select(. == $e.value)] | length) == 0 then "인자 값이 틀렸습니다: \($e.key) (\($ps.enum | join(", ")) 중 하나)"
     elif ($ps.minLength // 0) > 0 and ($e.value | length) < $ps.minLength then "인자가 비어 있습니다: \($e.key)"
     else empty end)'

# Classifies one parsed line (slurped): prints cls, id (JSON), method (control chars masked).
_MCP_CLASSIFY='
def okid: type == "string" or type == "number";
(if length != 1 then {cls: "invalid", id: null}
 else .[0]
 | if type != "object" then {cls: "invalid", id: null}
   elif (.method | type) == "string" and (has("id") | not) then {cls: "notification", id: null, method}
   elif (.method | type) == "string" and .jsonrpc == "2.0" and (.id | okid) then {cls: "request", id, method}
   elif (has("method") | not) and (has("result") or has("error")) then {cls: "response", id: null}
   else {cls: "invalid", id: (if (.id | okid) then .id else null end)}
   end
 end)
| .cls, (.id | tojson), (.method // "" | gsub("[[:cntrl:]]"; "?"))'

# ---- output ----
# Builds a message with jq (-n, $id bound) and writes it as one line; if jq fails, the request
# still gets an answer (Internal error).
_mcp_emit() { # ID_JSON JQ_ARGS...
  local id=$1 msg
  shift
  if msg=$(jq -nc --argjson id "$id" "$@"); then
    printf '%s\n' "$msg"
  else
    echo "ga-mcp: 응답을 만들지 못했습니다 (id $id)" >&2
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Internal error"}}\n' "$id"
  fi
}
_mcp_reply() { _mcp_emit "$1" --argjson r "$2" '{jsonrpc: "2.0", id: $id, result: $r}'; } # ID_JSON RESULT_JSON
_mcp_fail() { # ID_JSON CODE MESSAGE
  _mcp_emit "$1" --argjson c "$2" --arg m "$3" '{jsonrpc: "2.0", id: $id, error: {code: $c, message: $m}}'
}
_mcp_tool_error() { # ID_JSON TEXT   (a tool execution error the model can act on)
  _mcp_emit "$1" --arg t "$2" '{jsonrpc: "2.0", id: $id, result: {content: [{type: "text", text: $t}], isError: true}}'
}

# ---- arguments ----
_mcp_get() { # KEY -> GA_MCP_V: string argument KEY, exactly ("" when absent)
  GA_MCP_V=$(jq -j --arg k "$1" '(.[$k] | strings), "."' "$GA_MCP_ARGS")
  GA_MCP_V=${GA_MCP_V%.}
}
_mcp_flag() { [ "$(jq -r --arg k "$1" '.[$k] == true' "$GA_MCP_ARGS")" = true ]; } # KEY
_mcp_payload() { jq -c --arg k "$1" '.[$k]' "$GA_MCP_ARGS" >"$GA_MCP_IN"; }   # KEY -> GA_MCP_IN

# The project root for this call -> GA_MCP_ROOT, or returns 1 with a Korean GA_MCP_ERR.
# P10: with CLAUDE_PROJECT_DIR (Claude Code) the root is the design found walking up from it, like
# the hooks find it, else that directory; a root argument must canonicalize to that same path.
# Without it (other harnesses) the root argument is required and used as given.
_mcp_root() {
  local arg base
  GA_MCP_ROOT=""
  _mcp_get root; arg=$GA_MCP_V
  case "$arg" in "" | /*) ;; *) GA_MCP_ERR="root는 절대 경로여야 합니다: ${arg}"; return 1 ;; esac
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "$CLAUDE_PROJECT_DIR" in
      /*) ;;
      *) GA_MCP_ERR="CLAUDE_PROJECT_DIR가 절대 경로가 아닙니다: ${CLAUDE_PROJECT_DIR}"; return 1 ;;
    esac
    base=$(ga_find_root "$CLAUDE_PROJECT_DIR") || base=$(ga_canon "$CLAUDE_PROJECT_DIR") || base=""
    [ -n "$base" ] || { GA_MCP_ERR="CLAUDE_PROJECT_DIR를 해석할 수 없습니다: ${CLAUDE_PROJECT_DIR}"; return 1; }
    if [ -n "$arg" ] && [ "$(ga_canon "$arg")" != "$base" ]; then
      GA_MCP_ERR="root 인자는 이 세션의 프로젝트 루트와 같아야 합니다 (세션 루트: ${base}, 받은 root: ${arg}). root를 빼고 다시 호출하세요"
      return 1
    fi
    GA_MCP_ROOT=$base
  elif [ -n "$arg" ]; then
    GA_MCP_ROOT=$arg
  else
    GA_MCP_ERR="프로젝트 루트를 알 수 없습니다. 인자 root에 절대 경로를 주거나, CLAUDE_PROJECT_DIR가 설정된 환경(Claude Code)에서 서버를 실행하세요"
    return 1
  fi
  [ -d "$GA_MCP_ROOT" ] || { GA_MCP_ERR="root 디렉터리가 없습니다: ${GA_MCP_ROOT}"; return 1; }
}

# ---- running ga ----
# Background subshell: one progress notification every GA_MCP_TICK seconds until killed.
_mcp_ticker() { # TOKEN_JSON
  local n=0 sp=""
  trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; exit 0' TERM
  while :; do
    sleep "$GA_MCP_TICK" </dev/null >/dev/null 2>&1 &
    sp=$!
    wait "$sp"
    sp=""
    n=$((n + GA_MCP_TICK))
    printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":%d,"message":"ga 실행 중 (%d초 경과)"}}\n' "$1" "$n" "$n"
  done
}

# Runs ga --root ROOT ARGV... in ROOT with STDIN, output to GA_MCP_OUT; sets GA_MCP_RC. The
# child runs in the background so a signal reaches _mcp_stop at once; with a progress token the
# ticker writes notifications meanwhile and is stopped before the caller writes the response.
_mcp_run() { # ROOT STDIN TOKEN_JSON ARGV...
  local root=$1 in=$2 tok=$3
  shift 3
  (cd "$root" || exit 2; exec "$GA_MCP_GA" --root "$root" "$@") <"$in" >"$GA_MCP_OUT" 2>&1 &
  GA_MCP_CHILD=$!
  if [ "$tok" != null ]; then
    _mcp_ticker "$tok" &
    GA_MCP_TICKER=$!
  fi
  GA_MCP_RC=0
  wait "$GA_MCP_CHILD" || GA_MCP_RC=$?
  GA_MCP_CHILD=""
  if [ -n "$GA_MCP_TICKER" ]; then
    kill -TERM "$GA_MCP_TICKER" 2>/dev/null
    wait "$GA_MCP_TICKER" 2>/dev/null
    GA_MCP_TICKER=""
  fi
}

# ---- methods ----
_mcp_initialize() { # ID_JSON
  local want s v=${GA_MCP_VERSIONS%% *}
  # Version negotiation (2025-11-25 lifecycle): the requested version if supported, else our latest.
  want=$(jq -r '.params.protocolVersion | strings' "$GA_MCP_MSG" 2>/dev/null)
  for s in $GA_MCP_VERSIONS; do [ "$want" = "$s" ] && v=$s; done
  _mcp_emit "$1" --arg v "$v" --arg sv "${GA_VERSION:-unknown}" --arg ins "$GA_MCP_INSTRUCTIONS" '
    {jsonrpc: "2.0", id: $id, result: {protocolVersion: $v, capabilities: {tools: {}},
      serverInfo: {name: "grounded-arch-ga", version: $sv}, instructions: $ins}}'
}

_mcp_tools_call() { # ID_JSON
  local id=$1 st name errs root tok in=/dev/null e
  st=$(jq -r --slurpfile t "$GA_MCP_TOOLS" '
    .params as $p
    | if ($p | type) != "object" or ($p.name | type) != "string" then "bad"
      elif $p.arguments != null and ($p.arguments | type) != "object" then "bad"
      elif any($t[0].tools[]; .name == $p.name) | not then "unknown"
      else "ok" end' "$GA_MCP_MSG" 2>/dev/null) || st=bad
  case "$st" in
    ok) ;;
    unknown) _mcp_fail "$id" -32602 "Unknown tool: $(jq -r '.params.name | gsub("[[:cntrl:]]"; "?")' "$GA_MCP_MSG")"; return 0 ;;
    *) _mcp_fail "$id" -32602 "Invalid params: tools/call에는 name(문자열)과 객체 arguments가 필요합니다"; return 0 ;;
  esac
  name=$(jq -r '.params.name' "$GA_MCP_MSG")
  jq -c '.params.arguments // {}' "$GA_MCP_MSG" >"$GA_MCP_ARGS" || { _mcp_fail "$id" -32603 "Internal error"; return 0; }
  tok=$(jq -c '.params._meta.progressToken // null | if type == "string" or type == "number" then . else null end' "$GA_MCP_MSG" 2>/dev/null) || tok=null
  [ -n "$tok" ] || tok=null

  errs=$(jq -r --slurpfile t "$GA_MCP_TOOLS" --arg n "$name" "$_MCP_VALIDATE" "$GA_MCP_ARGS") || errs="인자를 검사하지 못했습니다"
  if [ -z "$errs" ] && [ "$name" = ga_check ] &&
     [ "$(jq -r 'has("kind") != has("item")' "$GA_MCP_ARGS")" = true ]; then
    errs="kind와 item은 함께 주어야 합니다"
  fi
  if [ -n "$errs" ]; then _mcp_tool_error "$id" "인자 오류:
$errs"; return 0; fi

  _mcp_root || { _mcp_tool_error "$id" "$GA_MCP_ERR"; return 0; }
  root=$GA_MCP_ROOT

  # Tool -> ga argv. Argument values are passed as separate words, never through a shell.
  set --
  case "$name" in
    ga_init) set -- init; _mcp_get mode; [ -z "$GA_MCP_V" ] || set -- "$@" --mode "$GA_MCP_V" ;;
    ga_add) _mcp_get kind; set -- add "$GA_MCP_V"; _mcp_payload item; in=$GA_MCP_IN ;;
    ga_update) _mcp_get id; set -- update "$GA_MCP_V"; _mcp_payload patch; in=$GA_MCP_IN ;;
    ga_ask) _mcp_get id; set -- ask "$GA_MCP_V" ;;
    ga_resolve)
      _mcp_get id; set -- resolve "$GA_MCP_V"
      _mcp_get source_type; set -- "$@" --source-type "$GA_MCP_V"
      _mcp_get ref; set -- "$@" --ref "$GA_MCP_V" ;;
    ga_render) set -- render ;;
    ga_check)
      set -- check
      _mcp_flag json && set -- "$@" --json
      _mcp_get kind
      if [ -n "$GA_MCP_V" ]; then set -- "$@" --item "$GA_MCP_V"; _mcp_payload item; in=$GA_MCP_IN; fi ;;
    ga_status) set -- status; _mcp_flag json && set -- "$@" --json ;;
    ga_verify) set -- verify ;;
    ga_rule) set -- rule ;;
    ga_enforce) set -- enforce ;;
    ga_dispute) _mcp_get id; set -- dispute "$GA_MCP_V"; _mcp_get evidence; set -- "$@" --evidence "$GA_MCP_V" ;;
    *) _mcp_fail "$id" -32603 "Internal error: no ga mapping for $name"; return 0 ;;
  esac

  _mcp_run "$root" "$in" "$tok" "$@"
  if [ "$GA_MCP_RC" = 0 ]; then e=false; else e=true; fi
  _mcp_emit "$id" --argjson e "$e" --argjson rc "$GA_MCP_RC" --rawfile t "$GA_MCP_OUT" '
    ($t | sub("[[:space:]]+\\z"; "")) as $o
    | (if $rc == 0 then (if $o == "" then "완료 (출력 없음)" else $o end)
       else $o + (if $o == "" then "" else "\n" end) + "(ga 종료 코드 \($rc))" end) as $text
    | {jsonrpc: "2.0", id: $id, result: {content: [{type: "text", text: $text}], isError: $e}}'
}

_mcp_handle() { # LINE
  local cl cls id method
  case "$1" in *[![:space:]]*) ;; *) return 0 ;; esac
  printf '%s\n' "$1" >"$GA_MCP_MSG"
  if ! cl=$(jq -r -s "$_MCP_CLASSIFY" "$GA_MCP_MSG" 2>/dev/null); then
    _mcp_fail null -32700 "Parse error"
    return 0
  fi
  { IFS= read -r cls; IFS= read -r id; IFS= read -r method; } <<EOF
$cl
EOF
  case "$cls" in
    notification | response) return 0 ;; # never answered
    request) ;;
    *) _mcp_fail "$id" -32600 "Invalid Request"; return 0 ;;
  esac
  case "$method" in
    initialize) _mcp_initialize "$id" ;;
    ping) _mcp_reply "$id" '{}' ;;
    tools/list) _mcp_emit "$id" --slurpfile t "$GA_MCP_TOOLS" '{jsonrpc: "2.0", id: $id, result: $t[0]}' ;;
    tools/call) _mcp_tools_call "$id" ;;
    *) _mcp_fail "$id" -32601 "Method not found: $method" ;;
  esac
  return 0
}

while IFS= read -r line || [ -n "$line" ]; do
  _mcp_handle "$line"
done
exit 0
