# Ledger format checker. Input: {"items":[...]}.
# Args: --arg ledger 1|0 (1 = also apply ledger-level rules), --arg out errors|refs
# out=errors -> {"errors":[{id,code,message}]}
# out=refs   -> [{id,ref}] for every code-type source (file/line check is done by check.sh)

def err($id; $code; $msg): {id: $id, code: $code, message: $msg};
def blank: . == null or (type == "string" and test("^[[:space:]]*$")) or (type == "array" and length == 0) or (type == "object" and length == 0);
def present: blank | not;
def str_ok: type == "string" and test("[^[:space:]]");
def sources: ["user", "code", "literature", "measurement"];

# Errors of one source object. $label names where it was found.
def src_errs($id; $label; $s):
  if ($s | type) != "object" then [err($id; "E_FIELD_MISSING"; "\($label): 출처(source)가 없습니다")]
  else
    ($s.type) as $t
    | ( if ($t | blank) then [err($id; "E_FIELD_MISSING"; "\($label): source.type이 없습니다")]
        elif (sources | index($t)) == null then [err($id; "E_ENUM"; "\($label): source.type은 user|code|literature|measurement 중 하나여야 합니다 (받은 값: \($t))")]
        else [] end )
      + ( if ($s.ref | str_ok | not) then [err($id; "E_FIELD_MISSING"; "\($label): source.ref가 비어 있습니다")] else [] end )
      + ( if $t == "user" and ($s.quote | str_ok | not) then [err($id; "E_SOURCE_USER_NO_QUOTE"; "\($label): 사용자 발언 출처에는 인용(quote)이 필요합니다")] else [] end )
  end;

def req($id; $f): if (.[$f] | blank) then [err($id; "E_FIELD_MISSING"; "필수 필드 \($f)가 없거나 비어 있습니다")] else [] end;
def req_str($id; $f): if (.[$f] | str_ok | not) then [err($id; "E_FIELD_MISSING"; "필수 필드 \($f)가 없거나 비어 있습니다")] else [] end;
def enum($id; $f; $vals):
  .[$f] as $v
  | if ($v | blank) then [err($id; "E_FIELD_MISSING"; "필수 필드 \($f)가 없거나 비어 있습니다")]
  elif ($vals | index($v)) == null then [err($id; "E_ENUM"; "\($f) 값이 허용되지 않습니다: \($v | tostring) (허용: \($vals | join("|")))")]
  else [] end;

def searchlog_errs($id):
  (.search_log) as $l
  | if ($l | type) != "object" then [err($id; "E_SEARCHLOG_INCOMPLETE"; "탐색 기록(search_log)이 없습니다 (code, docs, conversation, web 네 칸 모두 필요)")]
    else
      [ ("code", "docs", "conversation", "web") as $k
        | ($l[$k]) as $v
        | if ($v | str_ok | not) then err($id; "E_SEARCHLOG_INCOMPLETE"; "탐색 기록의 \($k) 칸이 비어 있습니다")
          elif ($v | test("^[[:space:]]*해당 없음")) and ($v | test("^[[:space:]]*해당 없음:[[:space:]]*[^[:space:]]") | not)
          then err($id; "E_SEARCHLOG_INCOMPLETE"; "탐색 기록의 \($k) 칸: '해당 없음:' 뒤에 이유를 적어야 합니다")
          else empty end ]
    end;

def item_errs($id):
  . as $it
  | ( (.kind) as $k
      | if ($k | blank) then [err($id; "E_FIELD_MISSING"; "필수 필드 kind가 없거나 비어 있습니다")]
        elif (["driver", "constraint", "fact", "decision", "assumption", "question", "mapping"] | index($k)) == null
        then [err($id; "E_ENUM"; "알 수 없는 kind입니다: \($k | tostring)")]
        else [] end )
  + ( if (.resolution | type) == "object" and (.resolution.source | type) == "object"
      then src_errs($id; "resolution"; .resolution.source) else [] end )
  + ( if .kind == "driver" then
        req_str($id; "statement")
        + enum($id; "driver_type"; ["purpose", "functional", "quality", "concern"])
        + enum($id; "horizon"; ["current", "future"])
        + enum($id; "priority"; ["high", "medium", "low"])
        + src_errs($id; "source"; .source)
        + ( if .priority == "high" and ((.iteration | type) != "number" or .iteration < 1 or .iteration != (.iteration | floor))
            then [err($id; "E_HIGH_NO_ITERATION"; "우선순위가 high인 드라이버에는 1 이상의 정수 반복 번호(iteration)가 필요합니다")] else [] end )
        + ( if .driver_type == "quality" and ((.scenario | type) != "object" or (.scenario.measure | str_ok | not))
            then [err($id; "E_QUALITY_NO_MEASURE"; "품질 드라이버에는 측정 기준(scenario.measure)이 필요합니다")] else [] end )
      elif .kind == "constraint" then
        req_str($id; "statement")
        + src_errs($id; "source"; .source)
        + ( if (.source | type) == "object" and (.source.type as $st | sources | index($st)) != null and .source.type != "user"
            then [err($id; "E_CONSTRAINT_NOT_USER"; "제약의 출처는 사용자 발언(user)이어야 합니다")] else [] end )
      elif .kind == "fact" then
        req_str($id; "statement")
        + src_errs($id; "source"; .source)
        + ( if (.source | type) == "object" and (.source.type as $st | sources | index($st)) != null and .source.type != "code"
            then [err($id; "E_FACT_NOT_CODE"; "현재 구조 사실의 출처는 코드(code)여야 합니다")] else [] end )
      elif .kind == "decision" then
        ( if (.iteration | type) != "number" then [err($id; "E_FIELD_MISSING"; "필수 필드 iteration(숫자)이 없습니다")] else [] end )
        + req_str($id; "element") + req_str($id; "choice")
        + req($id; "drivers")
        + ( if (.rationale | type) != "array" or (.rationale | length) == 0
            then [err($id; "E_FIELD_MISSING"; "필수 필드 rationale(출처 1개 이상)이 없거나 비어 있습니다")]
            else [ .rationale | to_entries[] | src_errs($id; "rationale[\(.key)]"; .value)[] ] end )
        + ( if (.alternatives | type) != "array" or (.alternatives | length) == 0
            then [err($id; "E_DECISION_NO_ALTERNATIVES"; "결정에 버린 대안(alternatives)이 없습니다. 대안이 없다면 사용자 발언 출처가 있는 {\"none\":\"user_constraint\"}로 적으세요")]
            else [ .alternatives[]
                   | select(type == "object" and has("none"))
                   | if .none != "user_constraint" or (.source | type) != "object" or .source.type != "user" or (.source.quote | str_ok | not)
                     then err($id; "E_ALT_NONE_NO_USER_SOURCE"; "'대안 없음'은 사용자 발언(type user, quote 포함) 출처가 있어야 합니다")
                     else empty end ]
                 + [ .alternatives[] | select(type == "object" and has("none") and (.source | type) == "object") | src_errs($id; "alternatives.none"; .source)[] ]
            end )
      elif .kind == "assumption" then
        req_str($id; "statement")
        + ( if (.indirect_evidence | type) != "array" or (.indirect_evidence | length) == 0
            then [err($id; "E_ASM_NO_INDIRECT"; "근거 없는 가정은 금지입니다. 질문(question)으로 바꾸세요")]
            else [ .indirect_evidence[]
                   | ( if (.type | blank) then err($id; "E_FIELD_MISSING"; "indirect_evidence.type이 없습니다")
                       elif (.type as $et | ["code_convention", "framework_default", "literature_norm", "goal_inference"] | index($et)) == null
                       then err($id; "E_ENUM"; "indirect_evidence.type 값이 허용되지 않습니다: \(.type | tostring)")
                       else empty end ),
                     ( if (.ref | str_ok | not) then err($id; "E_FIELD_MISSING"; "indirect_evidence.ref가 비어 있습니다") else empty end ) ] end )
        + searchlog_errs($id)
        + ( if (.alternatives | type) != "array" or (.alternatives | length) == 0
            then [err($id; "E_ASM_NO_ALTERNATIVES"; "가정에는 다른 가능한 가정(alternatives)이 1개 이상 필요합니다")] else [] end )
      elif .kind == "question" then
        req_str($id; "question")
        + searchlog_errs($id)
        + ( if (.impact | str_ok | not) then [err($id; "E_Q_NO_IMPACT"; "질문에는 '답에 따라 바뀌는 것'(impact)이 필요합니다")] else [] end )
      elif .kind == "mapping" then
        req_str($id; "element") + req_str($id; "path")
        + enum($id; "change"; ["new", "changed", "kept"])
      else [] end );

def all_sources:
  [ (.source // empty), ((.rationale // [])[]?), ((.alternatives // [])[]? | .source? // empty), (.resolution.source? // empty) ]
  | map(select(type == "object"));

def idof: (.id // "(new)");

if $out == "refs" then
  [ .items[] | idof as $id | all_sources[] | select(.type == "code") | {id: $id, ref: (.ref // "")} ]
else
  [ .items[] | item_errs(idof)[] ] as $item_errs
  | (if $ledger == "1" then
      ( [ .items[]
          | select((.id | blank))
          | err("(new)"; "E_FIELD_MISSING"; "필수 필드 id가 없거나 비어 있습니다") ]
        + [ .items[] | select(.kind == "decision" and .phase_added == "inputs")
            | err(idof; "E_DECISION_IN_INPUTS"; "입력 단계에서는 아키텍처 결정을 기록할 수 없습니다") ]
        + ( [.items[] | select(.kind == "driver") | .id] as $drv
            | [ .items[] | select(.kind == "decision") | . as $d
                | ($d.drivers // [])[] | select(. as $x | $drv | index($x) | not)
                | err($d | idof; "E_DECISION_UNKNOWN_DRIVER"; "결정이 존재하지 않는 드라이버를 가리킵니다: \(.)") ] )
        + ( [.items[] | .id | select(. != null)] | group_by(.) | map(select(length > 1) | .[0])
            | map(err(.; "E_DUP_ID"; "ID가 중복됩니다: \(.)")) ) )
    else [] end) as $ledger_errs
  | {errors: ($item_errs + $ledger_errs)}
end
