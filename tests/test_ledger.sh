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
test_resolve_by_user_fn() { r=$(in_iter); GA_CORE=$CORE; . "$CORE"/lib/common.sh; . "$CORE"/lib/state.sh; . "$CORE"/lib/check.sh; . "$CORE"/lib/ledger.sh; . "$CORE"/lib/fingerprint.sh
  id=$(ga --root "$r" add assumption <"$FIX/asm.json"); ga_ledger_resolve_by_user "$r" "$id" "맞습니다"
  assert_eq "resolved user 맞습니다" "$(jq -r '.items[0]|[.status,.resolution.by,.resolution.quote]|join(" ")' "$(LJ "$r")")"
  qid=$(echo "$QJ" | ga --root "$r" add question)
  rc=0; ga_ledger_resolve_by_user "$r" "$qid" "클라우드" 2>/dev/null || rc=$?; assert_eq 3 "$rc"
  ga_ledger_resolve_by_user "$r" "$qid" "클라우드" "클라우드"; assert_eq "클라우드" "$(jq -r '.items[1].answer' "$(LJ "$r")")"; }
test_update_deviation_forbidden() { r=$(in_iter); id=$(jq ".deviation=true" "$FIX/dec.json" | ga --root "$r" add decision); assert_eq open "$(jq -r ".items[0].status" "$(LJ "$r")")"
  b=$(cat "$(LJ "$r")"); echo "{\"deviation\":false}" | assert_status 3 ga --root "$r" update "$id"; assert_eq "$b" "$(cat "$(LJ "$r")")"; }
test_add_deviation_non_boolean_exit3() { r=$(in_iter); jq ".deviation=\"true\"" "$FIX/dec.json" | assert_status 3 ga --root "$r" add decision; }
# R21(a): deviation approval is the user's (GA 확인 DEC-n); ga resolve must not record it.
test_resolve_deviation_decision_exit3() { local r id b err rc=0
  r=$(in_iter); id=$(jq '.deviation=true' "$FIX/dec.json" | ga --root "$r" add decision); b=$(cat "$(LJ "$r")")
  err=$(ga --root "$r" resolve "$id" --source-type literature --ref https://example.org/x 2>&1 >/dev/null) || rc=$?
  assert_eq 3 "$rc"; assert_contains "$err" "이탈 승인은 사용자의 GA 확인 DEC-n으로만 기록됩니다"; assert_eq "$b" "$(cat "$(LJ "$r")")"; }
# R21b: the plan block lists only the current round's high drivers.
test_render_plan_current_round_only() { local r plan
  r=$(in_iter); set_state "$r" '.round=2'
  seed_ledger "$r" - <<'JSON'
{"items":[
 {"id":"DRV-1","kind":"driver","round":1,"phase_added":"inputs","iteration":1,"status":null,"resolution":null,"driver_type":"quality","statement":"옛 라운드","horizon":"current","priority":"high","scenario":{"stimulus":"s","response":"r","measure":"m"},"source":{"type":"user","ref":"대화","quote":"q"}},
 {"id":"DRV-2","kind":"driver","round":2,"phase_added":"inputs","iteration":1,"status":null,"resolution":null,"driver_type":"quality","statement":"새 라운드","horizon":"current","priority":"high","scenario":{"stimulus":"s","response":"r","measure":"m"},"source":{"type":"user","ref":"대화","quote":"q"}}]}
JSON
  ga --root "$r" render
  plan=$(awk '/^<!-- ga:begin plan -->$/{f=1;next} /^<!-- ga:end plan -->$/{f=0} f' "$r/docs/architecture/architecture.md")
  assert_contains "$plan" "DRV-2"; assert_not_contains "$plan" "DRV-1"; }

# --- final review fixes ---
ucmd() { local f; f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }
item() { jq -c --arg i "$2" '.items[] | select(.id == $i)' "$(LJ "$1")"; }
# C2 (R25): updating a resolved item reopens it, keeps the old resolution in resolution_history.
test_c2_update_reopens_user_confirmed_assumption() { local r id out it
  r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  ucmd "$r" "GA 확인 $id 맞음" >/dev/null; assert_eq resolved "$(item "$r" "$id" | jq -r .status)"
  out=$(echo '{"statement":"DB는 MongoDB 샤드 클러스터다"}' | ga --root "$r" update "$id" 2>&1)
  it=$(item "$r" "$id")
  assert_eq "open null" "$(jq -r '[.status, (.resolution|tostring)] | join(" ")' <<<"$it")"
  assert_eq 1 "$(jq '.resolution_history | length' <<<"$it")"
  assert_eq "user GA 확인 $id 맞음" "$(jq -r '.resolution_history[0].resolution | "\(.by) \(.quote)"' <<<"$it")"
  assert_contains "$out" "$id"; assert_contains "$out" "open"
  assert_status 0 ga --root "$r" check; }
test_c2_update_reopens_answered_question() { local r id it
  r=$(in_iter); id=$(echo "$QJ" | ga --root "$r" add question)
  ucmd "$r" "GA 답 $id 30일 보관" >/dev/null; assert_eq "30일 보관" "$(item "$r" "$id" | jq -r .answer)"
  echo '{"question":"모든 데이터를 영구 보관해도 되나요?"}' | ga --root "$r" update "$id" >/dev/null 2>&1
  it=$(item "$r" "$id")
  assert_eq "open null false" "$(jq -r '[.status, (.resolution|tostring), has("answer")] | map(tostring) | join(" ")' <<<"$it")"
  assert_eq "30일 보관 user" "$(jq -r '.resolution_history[0] | "\(.answer) \(.resolution.by)"' <<<"$it")"
  assert_status 0 ga --root "$r" check; }
test_c2_update_reopens_confirmed_deviation() { local r id it
  r=$(in_iter); id=$(jq '.deviation=true' "$FIX/dec.json" | ga --root "$r" add decision)
  ucmd "$r" "GA 확인 $id" >/dev/null; assert_eq resolved "$(item "$r" "$id" | jq -r .status)"
  echo '{"choice":"다른 선택"}' | ga --root "$r" update "$id" >/dev/null 2>&1
  it=$(item "$r" "$id")
  assert_eq "open null 1" "$(jq -r '[.status, (.resolution|tostring), (.resolution_history|length)] | map(tostring) | join(" ")' <<<"$it")"
  # (the fixture's DRV-3 is not in this ledger; only the status/resolution shape matters here)
  assert_eq "" "$(ga --root "$r" check --json | jq -r '.errors[] | select(.code != "E_DECISION_UNKNOWN_DRIVER") | .code')"; }
test_c2_update_reopens_evidence_resolution() { local r id
  r=$(in_iter); mkdir -p "$r/src"; printf 'a\nb\n' >"$r/src/x.c"; id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  ga --root "$r" resolve "$id" --source-type code --ref src/x.c:2
  echo '{"statement":"바뀐 가정"}' | ga --root "$r" update "$id" >/dev/null 2>&1
  assert_eq "open evidence" "$(item "$r" "$id" | jq -r '"\(.status) \(.resolution_history[0].resolution.by)"')"; }
test_c2_update_cannot_patch_history() { local r id
  r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  echo '{"resolution_history":[]}' | assert_status 3 ga --root "$r" update "$id"; }
# I2 (R27b): a literature reference must be a URL, doi: or isbn:.
test_i2_resolve_literature_free_text_refused() { local r id
  r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  assert_status 3 ga --root "$r" resolve "$id" --source-type literature --ref "일반 상식"
  assert_eq open "$(item "$r" "$id" | jq -r .status)"
  ga --root "$r" resolve "$id" --source-type literature --ref "doi:10.1145/3368089"; assert_eq resolved "$(item "$r" "$id" | jq -r .status)"; }
# I3 (R28a): render refuses unbalanced ga markers instead of appending a second block.
arch() { echo "$1/docs/architecture/architecture.md"; }
render_refused() { # ROOT BLOCKNAME : render exits 3 naming the block and leaves the file unchanged
  local f err rc=0; f=$(arch "$1"); cp "$f" "$f.before"
  err=$(ga --root "$1" render 2>&1 >/dev/null) || rc=$?
  assert_eq 3 "$rc"; assert_contains "$err" "$2"; cmp -s "$f" "$f.before" || _fail "render changed the file"; }
test_i3_render_refuses_missing_end_marker() { local r
  r=$(in_iter); ga --root "$r" render; sed -i.bak '/^<!-- ga:end drivers -->$/d' "$(arch "$r")"; render_refused "$r" drivers; }
test_i3_render_refuses_missing_begin_marker() { local r
  r=$(in_iter); ga --root "$r" render; sed -i.bak '/^<!-- ga:begin plan -->$/d' "$(arch "$r")"; render_refused "$r" plan; }
test_i3_render_refuses_duplicate_marker() { local r
  r=$(in_iter); ga --root "$r" render; printf '<!-- ga:begin ledger -->\n<!-- ga:end ledger -->\n' >>"$(arch "$r")"; render_refused "$r" ledger; }
test_i3_render_refuses_out_of_order() { local r f
  r=$(in_iter); f=$(arch "$r")   # swap: end marker first, then begin
  sed -i.bak -e 's/^<!-- ga:begin mapping -->$/@@B/' -e 's/^<!-- ga:end mapping -->$/<!-- ga:begin mapping -->/' -e 's/^@@B$/<!-- ga:end mapping -->/' "$f"
  render_refused "$r" mapping; }
test_i3_render_appends_when_both_markers_absent() { local r f
  r=$(in_iter); f=$(arch "$r"); sed -i.bak -e '/^<!-- ga:begin mapping -->$/d' -e '/^<!-- ga:end mapping -->$/d' "$f"
  ga --root "$r" render
  assert_eq "1 1" "$(grep -c '^<!-- ga:begin mapping -->$' "$f") $(grep -c '^<!-- ga:end mapping -->$' "$f")"; }
