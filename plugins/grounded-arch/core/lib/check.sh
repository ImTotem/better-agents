# grounded-arch ga check. Sourced; bash 3.2 compatible.

# Prints an error message and returns 1 when REF is not an existing "path:line" under ROOT.
_ga_coderef_error() { # ROOT REF
  local root=$1 ref=$2 path line total
  if [ -z "$ref" ] || ! [[ "$ref" =~ ^.+:[0-9]+$ ]]; then
    echo "코드 출처 ref는 '경로:줄' 형식이어야 합니다: $ref"
    return 1
  fi
  path=${ref%:*}; line=${ref##*:}
  case "/$path/" in
    */../*) echo "코드 출처 경로에 '..'를 쓸 수 없습니다: $ref"; return 1 ;;
    //*) echo "코드 출처 경로는 루트 기준 상대 경로여야 합니다: $ref"; return 1 ;;
  esac
  if [ -f "$root/$path" ]; then
    local rroot rdir
    rroot=$(cd -P "$root" 2>/dev/null && pwd -P) || rroot=$root
    rdir=$(cd -P "$(dirname "$root/$path")" 2>/dev/null && pwd -P) || rdir=""
    local real n=0 lnk
    real=$rdir/$(basename "$root/$path")
    while [ -L "$real" ]; do
      n=$((n + 1)); [ "$n" -gt 20 ] && { echo "코드 출처의 심볼릭 링크가 너무 깊습니다: $ref"; return 1; }
      lnk=$(readlink "$real")
      case "$lnk" in /*) ;; *) lnk=$(dirname "$real")/$lnk ;; esac
      rdir=$(cd -P "$(dirname "$lnk")" 2>/dev/null && pwd -P) || { echo "코드 출처 링크가 깨졌습니다: $ref"; return 1; }
      real=$rdir/$(basename "$lnk")
    done
    case "$real" in
      "$rroot"/*) ;;
      *) echo "코드 출처가 프로젝트 루트 밖입니다: $ref"; return 1 ;;
    esac
    total=$(awk 'END{print NR}' "$root/$path")
    if [ "$line" -lt 1 ] || [ "$line" -gt "$total" ]; then
      echo "코드 출처의 줄 번호가 파일 범위를 벗어납니다: $ref (파일은 ${total}줄)"
      return 1
    fi
  else
    echo "코드 출처의 파일이 없습니다: $path"
    return 1
  fi
  return 0
}

# Prints {"errors":[...]} for the ledger-shaped JSON in $1 (a file). Arg2: 1 = ledger-level rules.
_ga_check_run() { # INPUT_FILE LEDGER_FLAG ROOT
  local in=$1 lflag=$2 root=$3 res refs id ref path line total
  res=$(jq -c --arg ledger "$lflag" --arg out errors -f "$GA_CORE/lib/check.jq" "$in") || return 2
  refs=$(jq -c --arg ledger "$lflag" --arg out refs -f "$GA_CORE/lib/check.jq" "$in") || return 2
  refs=$(printf '%s' "$refs" | jq -r '.[] | [.id, .ref] | @tsv') || return 2
  local extra="[]" msg
  while IFS="$(printf '\t')" read -r id ref; do
    [ -n "$id" ] || continue
    msg=$(_ga_coderef_error "$root" "$ref")
    if [ -n "$msg" ]; then
      extra=$(printf '%s' "$extra" | jq -c --arg i "$id" --arg m "$msg" '. + [{id:$i,code:"E_SOURCE_CODE_REF",message:$m}]')
    fi
  done <<EOF
$refs
EOF
  printf '%s' "$res" | jq -c --argjson x "$extra" '.errors += $x'
}

cmd_check() {
  local json=0 kind="" root tmp res n
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --item)
        [ $# -ge 2 ] || ga_die "사용법: ga check [--json] [--item KIND]" 2
        kind=$2; shift 2 ;;
      --item=*) kind=${1#--item=}; shift ;;
      *) ga_die "사용법: ga check [--json] [--item KIND]" 2 ;;
    esac
  done
  tmp=$(mktemp) || ga_die "ga: 임시 파일을 만들 수 없습니다" 2
  if [ -n "$kind" ]; then
    root=${GA_ROOT:-$PWD}
    if ! jq -c --arg k "$kind" 'if type == "object" then {items: [. + {kind: $k}]} else error("not object") end' >"$tmp" 2>/dev/null; then
      rm -f "$tmp"; ga_die "ga: stdin은 JSON 객체 하나여야 합니다" 2
    fi
    res=$(_ga_check_run "$tmp" 0 "$root") || { rm -f "$tmp"; ga_die "ga: 검사 실패" 2; }
  else
    [ -n "${GA_ROOT:-}" ] || { rm -f "$tmp"; ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2; }
    if ! jq -e '.items | type == "array"' "$(ga_ledger_path "$GA_ROOT")" >/dev/null 2>&1; then
      rm -f "$tmp"; ga_die "ga: 원장을 읽을 수 없습니다: $(ga_ledger_path "$GA_ROOT")" 2
    fi
    cp "$(ga_ledger_path "$GA_ROOT")" "$tmp"
    res=$(_ga_check_run "$tmp" 1 "$GA_ROOT") || { rm -f "$tmp"; ga_die "ga: 검사 실패" 2; }
  fi
  rm -f "$tmp"
  n=$(printf '%s' "$res" | jq '.errors | length')
  if [ "$json" = 1 ]; then
    printf '%s\n' "$res"
  else
    printf '%s' "$res" | jq -r '.errors[] | "\(.id): \(.message)"'
  fi
  [ "$n" = 0 ]
}
