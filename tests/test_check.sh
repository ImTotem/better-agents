mk_checked() { r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; echo "$r"; }
LP() { echo "$1/docs/architecture/.state/ledger.json"; }
# edit ROOT JQ_EXPR : modify the ledger in place
edit() { t=$(jq "$2" "$(LP "$1")") && printf "%s\n" "$t" | seed_ledger "$1" -; }
codes() { ga --root "$1" check --json | jq -r '.errors[].code'; }
expect_code() { assert_contains "$(codes "$1")" "$2"; }
item_codes() { # KIND JSON ROOT
  printf '%s' "$2" | ga --root "$3" check --item "$1" --json | jq -r '.errors[].code'; }

test_valid_ledger_passes() { r=$(mk_checked); assert_status 0 ga --root "$r" check
  assert_eq "" "$(ga --root "$r" check)"; assert_eq '{"errors":[]}' "$(ga --root "$r" check --json | jq -c .)"; }
test_text_output_format() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).indirect_evidence=[]'
  assert_status 1 ga --root "$r" check
  assert_contains "$(ga --root "$r" check)" "ASM-1: "
  assert_contains "$(ga --root "$r" check)" "근거 없는 가정은 금지입니다. 질문(question)으로 바꾸세요"; }
test_e_field_missing() { r=$(mk_checked); edit "$r" 'del((.items[]|select(.id=="CON-1")).statement)'
  expect_code "$r" E_FIELD_MISSING; assert_contains "$(ga --root "$r" check --json | jq -r '.errors[].message')" statement; }
test_e_enum() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-1")).horizon="soon"'; expect_code "$r" E_ENUM; }
test_e_enum_unknown_kind() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-1")).kind="widget"'; expect_code "$r" E_ENUM; }
test_e_enum_source_type() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-1")).source.type="rumor"'; expect_code "$r" E_ENUM; }
test_e_source_user_no_quote() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-1")).source.quote=""'; expect_code "$r" E_SOURCE_USER_NO_QUOTE; }
test_e_source_code_ref_bad_format() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source.ref="src/main.c"'; expect_code "$r" E_SOURCE_CODE_REF; }
test_e_source_code_ref_missing_file() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source.ref="src/nope.c:1"'; expect_code "$r" E_SOURCE_CODE_REF; }
test_source_code_ref_line_beyond_eof() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source.ref="src/main.c:99"'; expect_code "$r" E_SOURCE_CODE_REF; }
test_e_source_code_ref_line_zero() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source.ref="src/main.c:0"'; expect_code "$r" E_SOURCE_CODE_REF; }
test_e_quality_no_measure() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-3")).scenario.measure=""'; expect_code "$r" E_QUALITY_NO_MEASURE; }
test_e_high_no_iteration() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DRV-3")).iteration=null'; expect_code "$r" E_HIGH_NO_ITERATION; }
test_nonhigh_driver_null_iteration_ok() { r=$(mk_checked); assert_status 0 ga --root "$r" check; }
test_e_constraint_not_user() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="CON-1")).source={"type":"literature","ref":"doc"}'; expect_code "$r" E_CONSTRAINT_NOT_USER; }
test_e_fact_not_code() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source={"type":"literature","ref":"doc"}'; expect_code "$r" E_FACT_NOT_CODE; }
test_e_decision_in_inputs() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).phase_added="inputs"'; expect_code "$r" E_DECISION_IN_INPUTS
  assert_contains "$(ga --root "$r" check)" "입력 단계에서는 아키텍처 결정을 기록할 수 없습니다"; }
test_e_decision_no_alternatives() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).alternatives=[]'; expect_code "$r" E_DECISION_NO_ALTERNATIVES; }
test_e_alt_none_no_user_source() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).alternatives=[{"none":"user_constraint"}]'; expect_code "$r" E_ALT_NONE_NO_USER_SOURCE; }
test_alt_none_user_constraint_ok() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).alternatives=[{"none":"user_constraint","source":{"type":"user","ref":"대화","quote":"DB는 PostgreSQL"}}]'
  assert_status 0 ga --root "$r" check; }
test_e_decision_unknown_driver() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).drivers=["DRV-99"]'; expect_code "$r" E_DECISION_UNKNOWN_DRIVER; }
test_e_asm_no_indirect() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).indirect_evidence=[]'; expect_code "$r" E_ASM_NO_INDIRECT; }
test_e_searchlog_incomplete() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).search_log.docs=""'; expect_code "$r" E_SEARCHLOG_INCOMPLETE; }
test_searchlog_na_without_reason() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).search_log.web="해당 없음:"'; expect_code "$r" E_SEARCHLOG_INCOMPLETE; }
test_e_asm_no_alternatives() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).alternatives=[]'; expect_code "$r" E_ASM_NO_ALTERNATIVES; }
test_e_q_no_impact() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="Q-1")).impact=""'; expect_code "$r" E_Q_NO_IMPACT; }
test_e_dup_id() { r=$(mk_checked); edit "$r" '.items += [.items[0]]'; expect_code "$r" E_DUP_ID; }
test_resolution_source_validated() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="ASM-1")).resolution={"by":"user","ts":"x","source":{"type":"user","ref":"대화"}}'; expect_code "$r" E_SOURCE_USER_NO_QUOTE; }
test_alt_none_source_validated() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="DEC-1")).alternatives=[{"none":"user_constraint","source":{"type":"user","ref":"대화","quote":""}}]'; expect_code "$r" E_ALT_NONE_NO_USER_SOURCE; }

test_item_mode_ok() { r=$(mk_checked)
  assert_eq "" "$(item_codes question '{"question":"무엇?","impact":"구조가 바뀜","search_log":{"code":"a","docs":"b","conversation":"c","web":"해당 없음: 이유"}}' "$r")"; }
test_item_mode_uses_new_id() { r=$(mk_checked)
  assert_eq "(new)" "$(printf '%s' '{"question":"x"}' | ga --root "$r" check --item question --json | jq -r '.errors[0].id')"
  assert_eq "Q-7" "$(printf '%s' '{"id":"Q-7","question":"x"}' | ga --root "$r" check --item question --json | jq -r '.errors[0].id')"; }
test_item_mode_sets_kind() { r=$(mk_checked)
  assert_contains "$(item_codes assumption '{"statement":"a","kind":"question"}' "$r")" E_ASM_NO_INDIRECT; }
test_item_mode_skips_ledger_rules() { r=$(mk_checked)
  j='{"phase_added":"inputs","iteration":1,"element":"e","choice":"c","rationale":[{"type":"user","ref":"대화","quote":"q"}],"alternatives":[{"option":"o","reason":"r"}],"drivers":["DRV-99"]}'
  assert_eq "" "$(item_codes decision "$j" "$r")"; }
fact_ref_codes() { item_codes fact "$(jq -nc --arg r "$2" '{statement:"s",source:{type:"code",ref:$r}}')" "$1"; }
test_code_ref_dotdot_outside_rejected() { r=$(mk_checked); o=$(mktemp -d); echo x >"$o/outside.txt"
  assert_contains "$(fact_ref_codes "$r" "../$(basename "$o")/outside.txt:1")" E_SOURCE_CODE_REF
  assert_contains "$(fact_ref_codes "$r" "src/../../$(basename "$o")/outside.txt:1")" E_SOURCE_CODE_REF; }
test_code_ref_dotdot_inside_also_rejected() { r=$(mk_checked); assert_contains "$(fact_ref_codes "$r" "src/../src/main.c:1")" E_SOURCE_CODE_REF; }
test_code_ref_symlink_outside_rejected() { r=$(mk_checked); o=$(mktemp -d); echo x >"$o/outside.txt"; ln -s "$o/outside.txt" "$r/src/link.txt"; ln -s "$o" "$r/src/linkdir"
  assert_contains "$(fact_ref_codes "$r" "src/link.txt:1")" E_SOURCE_CODE_REF
  assert_contains "$(fact_ref_codes "$r" "src/linkdir/outside.txt:1")" E_SOURCE_CODE_REF; }
test_code_ref_normal_still_ok() { r=$(mk_checked); assert_eq "" "$(fact_ref_codes "$r" "src/main.c:2")"; }
test_item_mode_code_ref_checked() { r=$(mk_checked)
  assert_contains "$(item_codes fact '{"statement":"s","source":{"type":"code","ref":"src/main.c:99"}}' "$r")" E_SOURCE_CODE_REF
  assert_eq "" "$(item_codes fact '{"statement":"s","source":{"type":"code","ref":"src/main.c:3"}}' "$r")"; }
test_item_mode_without_root_uses_pwd() { r=$(mk_project brownfield)
  out=$( cd "$r" && printf '%s' '{"statement":"s","source":{"type":"code","ref":"src/main.c:2"}}' | ga check --item fact --json | jq -r '.errors[].code' )
  assert_eq "" "$out"; }
test_seed_ledger_same_file_pipe_is_safe() { r=$(mk_checked); i=0
  while [ $i -lt 20 ]; do
    jq '(.items[]|select(.id=="Q-1")).impact="x"' "$(LP "$r")" | seed_ledger "$r" -
    i=$((i+1))
  done
  assert_eq x "$(jq -r '.items[]|select(.id=="Q-1")|.impact' "$(LP "$r")")"; }
# Simulates the refs-extraction jq failing (e.g. crash); must exit 2, not pass silently.
test_refs_stage_jq_failure_is_not_silent() { r=$(mk_checked); edit "$r" '(.items[]|select(.id=="FACT-1")).source.ref="src/main.c:99"'
  fk=$(mktemp -d); printf '%s\n' '#!/bin/bash' 'for a in "$@"; do [ "$a" = refs ] && exit 5; done' 'exec /usr/bin/jq "$@"' >"$fk/jq"
  chmod +x "$fk/jq"
  assert_status 2 env PATH="$fk:$PATH" "$CORE/bin/ga" --root "$r" check; }
test_exit_codes_json() { r=$(mk_checked); assert_status 0 ga --root "$r" check --json
  edit "$r" '(.items[]|select(.id=="Q-1")).impact=""'; assert_status 1 ga --root "$r" check --json; }
test_e_decision_deviation_status_inconsistent() { r=$(mk_checked)
  edit "$r" "(.items[]|select(.id==\"DEC-1\")).deviation=true"; expect_code "$r" E_ENUM
  edit "$r" "(.items[]|select(.id==\"DEC-1\"))|=(.deviation=false|.status=\"open\")"; expect_code "$r" E_ENUM
  edit "$r" "(.items[]|select(.id==\"DEC-1\"))|=(.deviation=\"true\"|.status=null)"; expect_code "$r" E_ENUM; }
