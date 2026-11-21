in_iter() { r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; echo "$r"; }
LJ() { echo "$1/docs/architecture/.state/ledger.json"; }
QJ='{"question":"배포는?","impact":"구조","search_log":{"code":"없음","docs":"없음","conversation":"없음","web":"해당 없음: 고유"}}'
test_add_assigns_sequential_ids() { r=$(in_iter); a=$(ga --root "$r" add assumption <"$FIX/asm.json"); b=$(ga --root "$r" add assumption <"$FIX/asm.json"); assert_eq "ASM-1 ASM-2" "$a $b"; }
test_add_decision_in_inputs_exit3() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_status 3 ga --root "$r" add decision <"$FIX/dec.json"; }
test_add_invalid_assumption_exit3() { r=$(in_iter); jq '.indirect_evidence=[]' "$FIX/asm.json" | assert_status 3 ga --root "$r" add assumption; }
test_update_forbidden_key_exit3() { r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json"); echo '{"status":"resolved"}' | assert_status 3 ga --root "$r" update "$id"; }
test_resolve_user_source_exit3() { r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json"); assert_status 3 ga --root "$r" resolve "$id" --source-type user --ref x; }
test_resolve_by_code_ok() { r=$(in_iter); mkdir -p "$r/src"; printf 'a\nb\n' >"$r/src/x.c"; id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  ga --root "$r" resolve "$id" --source-type code --ref src/x.c:2; assert_eq resolved "$(jq -r ".items[]|select(.id==\"$id\").status" "$(LJ "$r")")"; }
test_render_idempotent_and_escapes_pipe() { r=$(in_iter); jq '.statement="a|b"' "$FIX/asm.json" | ga --root "$r" add assumption >/dev/null
  ga --root "$r" render; h1=$(shasum "$r/docs/architecture/architecture.md"); ga --root "$r" render; assert_eq "$h1" "$(shasum "$r/docs/architecture/architecture.md")"
  assert_contains "$(cat "$r/docs/architecture/architecture.md")" 'a\|b'; }
test_parallel_add_keeps_both() { r=$(in_iter); ga --root "$r" add assumption <"$FIX/asm.json" & ga --root "$r" add assumption <"$FIX/asm.json" & wait
  assert_eq 2 "$(jq '.items|length' "$(LJ "$r")")"; }
test_add_fills_common_fields() { r=$(in_iter); ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null
  assert_eq "assumption open 1 1 iterating null" "$(jq -r '.items[0]|[.kind,.status,.round,.iteration,.phase_added,.resolution]|map(tostring)|join(" ")' "$(LJ "$r")")"; }
test_add_decision_ok_in_iterating() { r=$(in_iter); id=$(ga --root "$r" add decision <"$FIX/dec.json"); assert_eq DEC-1 "$id"
  assert_eq "null false" "$(jq -r '.items[0]|[.status,.deviation]|map(tostring)|join(" ")' "$(LJ "$r")")"; }
test_add_mapping_in_iterating_exit3() { r=$(in_iter); echo '{"element":"a","path":"src/a","change":"new"}' | assert_status 3 ga --root "$r" add mapping; }
test_add_non_object_exit3() { r=$(in_iter); echo '[1]' | assert_status 3 ga --root "$r" add assumption; }
test_update_merges_and_validates() { r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  echo '{"statement":"새 문장"}' | ga --root "$r" update "$id"; assert_eq "새 문장" "$(jq -r '.items[0].statement' "$(LJ "$r")")"
  echo '{"indirect_evidence":[]}' | assert_status 3 ga --root "$r" update "$id"
  echo '{"statement":"x"}' | assert_status 3 ga --root "$r" update ASM-99; }
test_ask_question() { r=$(in_iter); id=$(echo "$QJ" | ga --root "$r" add question); ga --root "$r" ask "$id"; assert_eq asked "$(jq -r '.items[0].status' "$(LJ "$r")")"
  assert_status 3 ga --root "$r" ask "$id"
  a=$(ga --root "$r" add assumption <"$FIX/asm.json"); assert_status 3 ga --root "$r" ask "$a"; }
test_resolve_by_user_fn() { r=$(in_iter); GA_CORE=$CORE; . "$CORE"/lib/common.sh; . "$CORE"/lib/state.sh; . "$CORE"/lib/check.sh; . "$CORE"/lib/ledger.sh
  id=$(ga --root "$r" add assumption <"$FIX/asm.json"); ga_ledger_resolve_by_user "$r" "$id" "맞습니다"
  assert_eq "resolved user 맞습니다" "$(jq -r '.items[0]|[.status,.resolution.by,.resolution.quote]|join(" ")' "$(LJ "$r")")"
  qid=$(echo "$QJ" | ga --root "$r" add question)
  rc=0; ga_ledger_resolve_by_user "$r" "$qid" "클라우드" 2>/dev/null || rc=$?; assert_eq 3 "$rc"
  ga_ledger_resolve_by_user "$r" "$qid" "클라우드" "클라우드"; assert_eq "클라우드" "$(jq -r '.items[1].answer' "$(LJ "$r")")"; }
test_update_deviation_forbidden() { r=$(in_iter); id=$(jq ".deviation=true" "$FIX/dec.json" | ga --root "$r" add decision); assert_eq open "$(jq -r ".items[0].status" "$(LJ "$r")")"
  b=$(cat "$(LJ "$r")"); echo "{\"deviation\":false}" | assert_status 3 ga --root "$r" update "$id"; assert_eq "$b" "$(cat "$(LJ "$r")")"; }
test_add_deviation_non_boolean_exit3() { r=$(in_iter); jq ".deviation=\"true\"" "$FIX/dec.json" | assert_status 3 ga --root "$r" add decision; }
