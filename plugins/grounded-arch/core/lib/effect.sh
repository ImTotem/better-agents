# grounded-arch G-effect: project file change check. Sourced; bash 3.2 + jq. Only defines functions.
# ga_effect_snapshot ROOT records the project file state; ga_effect_check ROOT compares what changed
# since then with the phase allow-list (spec 5.5). Changes inside the state folder are not judged
# here (the state fingerprint covers them).
# This runs outside the OS sandbox (Stop hook, approvals), so it trusts nothing the agent can write
# (spec 5.5 "격리 밖에서 도는 코드의 원칙", rule 3, P29). git only lists files and hashes contents as
# they are: ga pins the git layout itself, git runs with no global, system or attributes config and
# with the repository settings that run programs turned off, there is no worktree `git diff` (it runs
# filters) and the index stat cache is never used. ga compares contents itself, with its own stat
# record (size, mtime, ctime, inode). Anything it cannot check is a violation ("결과 확인 불가: ..."),
# never "no changes". File names are filtered in the C locale (P32).
#
# The snapshot is two files in the state folder (so the fingerprint covers both):
#   snapshot.json  {kind:"git", v:2, base, layout:{top,gitdir,common}, t0, n} (or {kind:"git", v:2,
#                  error} when the repository cannot be trusted), {kind:"files", v:2, t0, n} without git
#   snapshot.list  one line per candidate file: "STAT REF PATH". STAT is ga's stat record
#                  (type and mode:size:mtime:ctime:inode, "-" when the file is missing); REF is the
#                  content at snapshot time where it differs from the base commit (blob hash, DELETED,
#                  DIR, LINK:<sha256 of the target>, OTHER), "=" when it equals the base commit (and
#                  always without git, where the stat record alone is compared).

GA_EFF_STATE_PREFIX="docs/architecture/.state/"
GA_EFF_UNSURE="결과 확인 불가"
# P25, P32 (M1): OS metadata names are never changes. A file name matches only as the last path
# component; the two folder names also hide what is below them. A fixed list: the global git excludes
# file is not trusted (the agent can write it).
GA_EFF_OS_META='^(.*/)?(\.DS_Store|\._[^/]*|Thumbs\.db|desktop\.ini)$|^(.*/)?(\.Spotlight-V100|\.Trashes)(/.*)?$'
# A newline inside a file name, once NUL-separated lists become lines.
GA_EFF_NL=$'\001'

# stdin: paths. Drops the state folder and the OS metadata names, sorts, removes duplicates.
_ga_eff_filter() {
  LC_ALL=C grep -v '^$' | LC_ALL=C awk -v p="$GA_EFF_STATE_PREFIX" 'index($0, p) != 1' |
    LC_ALL=C grep -Ev "$GA_EFF_OS_META" | LC_ALL=C sort -u
  return 0
}

ga_effect_snapshot_path() { echo "$(ga_state_dir "$1")/snapshot.json"; } # ROOT
ga_effect_list_path() { echo "$(ga_state_dir "$1")/snapshot.list"; }     # ROOT

# git with nothing but the pinned repository able to steer it: no variables from the caller, no
# system, global or attributes config, no replace objects, no optional locks, the repository
# settings that run programs (fsmonitor, hooks) off, and no network or transport at all (P36: a
# promisor remote in the repository's own config would otherwise lazily fetch a missing object and
# run its upload-pack command): GIT_NO_LAZY_FETCH and protocol.allow=never. GIT_DIR,
# GIT_COMMON_DIR and GIT_WORK_TREE come from _ga_eff_layout, never from git's own reading of .git files.
_ga_git() (
  local v
  for v in $(compgen -e); do case "$v" in GIT_*) unset "$v" ;; esac; done
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    GIT_NO_LAZY_FETCH=1
  if [ -n "${GA_EFL_GITDIR:-}" ]; then
    export GIT_DIR=$GA_EFL_GITDIR GIT_COMMON_DIR=$GA_EFL_COMMON GIT_WORK_TREE=$GA_EFL_TOP
  fi
  [ -n "$GA_GIT" ] || ga_git_resolve || exit 127
  exec "$GA_GIT" --no-pager -c core.fsmonitor= -c core.hooksPath=/dev/null -c core.untrackedCache=false \
    -c core.attributesFile=/dev/null -c protocol.allow=never "$@"
)

# P29: the git layout, found by ga itself. From ROOT up to the first .git entry: a .git folder is its
# own common dir and may not hold a commondir file; a .git file is accepted only for a normal linked
# worktree (<main>/.git/worktrees/<name>, whose commondir names <main>/.git). Sets GA_EFL_TOP,
# GA_EFL_GITDIR, GA_EFL_COMMON. rc 0 git, 1 not git, 2 a layout that cannot be trusted (GA_EFL_ERR).
_ga_eff_layout() { # ROOT
  local d line gd wt mg cdir
  GA_EFL_TOP=""; GA_EFL_GITDIR=""; GA_EFL_COMMON=""; GA_EFL_ERR=""
  d=$(ga_phys_dir "$1") || { GA_EFL_ERR="프로젝트 폴더를 찾을 수 없음"; return 2; }
  while :; do
    if [ -L "$d/.git" ]; then
      GA_EFL_ERR="${d}/.git 이 심볼릭 링크임"; return 2
    elif [ -d "$d/.git" ]; then
      if [ -e "$d/.git/commondir" ] || [ -L "$d/.git/commondir" ]; then
        GA_EFL_ERR="${d}/.git 안에 commondir 파일이 있음(저장소 자신의 .git 폴더에는 없어야 함)"; return 2
      fi
      GA_EFL_TOP=$d; GA_EFL_GITDIR=$d/.git; GA_EFL_COMMON=$d/.git
      return 0
    elif [ -e "$d/.git" ]; then
      [ -f "$d/.git" ] || { GA_EFL_ERR="${d}/.git 이 폴더도 파일도 아님"; return 2; }
      line=""; IFS= read -r line <"$d/.git"
      case "$line" in "gitdir: "?*) line=${line#gitdir: } ;; *) GA_EFL_ERR="${d}/.git 에 gitdir 줄이 없음"; return 2 ;; esac
      case "$line" in /*) ;; *) line=$d/$line ;; esac
      gd=$(ga_phys_dir "$line") || { GA_EFL_ERR="${d}/.git 이 가리키는 git 폴더(${line})가 없음"; return 2; }
      wt=${gd%/*}; mg=${wt%/*}
      if [ "${wt##*/}" != worktrees ] || [ "${mg##*/}" != .git ] || [ -L "$mg" ] || [ ! -d "$mg" ] ||
         [ -e "$mg/commondir" ] || [ -L "$mg/commondir" ]; then
        GA_EFL_ERR="${d}/.git 이 가리키는 ${gd} 은(는) 일반 작업 트리의 git 폴더(<본 저장소>/.git/worktrees/<이름>)가 아님"; return 2
      fi
      line=""; IFS= read -r line <"$gd/commondir" 2>/dev/null
      [ -n "$line" ] || { GA_EFL_ERR="${gd}/commondir 을 읽을 수 없음"; return 2; }
      case "$line" in /*) ;; *) line=$gd/$line ;; esac
      cdir=$(ga_phys_dir "$line") || cdir=""
      [ "$cdir" = "$mg" ] || { GA_EFL_ERR="${gd}/commondir 이 본 저장소의 .git(${mg})을 가리키지 않음"; return 2; }
      GA_EFL_TOP=$d; GA_EFL_GITDIR=$gd; GA_EFL_COMMON=$mg
      return 0
    fi
    [ "$d" = / ] && return 1
    d=${d%/*}; [ -n "$d" ] || d=/
  done
}

# stdin: paths (relative to the current directory, one per line). stdout: ga's stat record
# "TYPEMODE:SIZE:MTIME:CTIME:INODE PATH" of each that exists (lstat: a symbolic link is itself),
# sub-second times where stat has them. Missing paths print nothing.
_ga_eff_stat() {
  LC_ALL=C tr '\n' '\0' | {
    if ! stat -c %s / >/dev/null 2>&1; then
      LC_ALL=C xargs -0 -r stat -f '%Sp:%z:%Fm:%Fc:%i %N' -- 2>/dev/null || :     # BSD, macOS
    elif stat -c '%.9Y' / 2>/dev/null | LC_ALL=C grep -q '^[0-9]*\.[0-9]'; then
      LC_ALL=C xargs -0 -r stat -c '%A:%s:%.9Y:%.9Z:%i %n' -- 2>/dev/null || :   # GNU with sub-second times
    else
      LC_ALL=C xargs -0 -r stat -c '%A:%s:%Y:%Z:%i %n' -- 2>/dev/null || :       # whole seconds: see t0
    fi
  }
  return 0
}

# Git projects: the candidate files, relative to ROOT, in T/cand -- every file at the base commit,
# every index entry, every untracked file that is not ignored (only .gitignore files are honored, not
# the agent-writable .git/info/exclude or the global excludes), and every .gitignore file git reads,
# ignored or not -- minus the state folder and the OS metadata names. Also T/base ("BLOB PATH" at the
# base commit). P34: the .gitignore files come from git's own listing, not from walking the tree:
# tracked ones are in the base tree and the index, the others in the untracked listing, and those
# that ignore themselves in the ignored listing (--directory: git does not enter a folder a parent
# .gitignore ignores, and a .gitignore in there cannot change what git lists). rc 2 with the reason.
_ga_eff_git_cands() { # ROOT BASE T
  local root=$1 base=$2 t=$3
  : >"$t/lt.z"
  if ! ( cd "$root" || exit 2
         if [ -n "$base" ]; then _ga_git ls-tree -r -z "$base" >"$t/lt.z" || exit 2; fi
         _ga_git ls-files -z >"$t/idx.z" &&
           _ga_git ls-files -z -o --exclude-per-directory=.gitignore >"$t/oth.z" &&
           _ga_git ls-files -z -o -i --directory --exclude-per-directory=.gitignore >"$t/ign.z" ) 2>"$t/err"; then
    echo "git 오류: $(head -n 1 "$t/err")"
    return 2
  fi
  LC_ALL=C tr '\n\0' "${GA_EFF_NL}\n" <"$t/lt.z" |
    LC_ALL=C awk '{ i = index($0, "\t"); split(substr($0, 1, i - 1), m, " "); print m[3] " " substr($0, i + 1) }' >"$t/base"
  { LC_ALL=C cut -d ' ' -f 2- "$t/base"
    LC_ALL=C tr '\n\0' "${GA_EFF_NL}\n" <"$t/idx.z"
    LC_ALL=C tr '\n\0' "${GA_EFF_NL}\n" <"$t/oth.z"
    LC_ALL=C tr '\n\0' "${GA_EFF_NL}\n" <"$t/ign.z" | { LC_ALL=C grep -E '(^|/)\.gitignore$' || :; }
  } | _ga_eff_filter >"$t/cand"
  return 0
}

# Fails (rc 2, the reason on stdout) when a name in FILE holds a newline: lines cannot name it.
_ga_eff_no_newline_names() { # FILE
  local p
  p=$(LC_ALL=C grep -m 1 "$GA_EFF_NL" "$1") || return 0
  echo "이름에 줄바꿈이 있는 파일은 확인할 수 없음: $(printf '%s' "$p" | LC_ALL=C tr "$GA_EFF_NL" '?')"
  return 2
}

# The content of each path in T/IN (relative to ROOT; their stat records are in T/nstat): "VALUE PATH"
# lines in T/val. VALUE: the blob hash of a regular file (hash-object --no-filters: no filter runs),
# DIR, LINK:<sha256 of the target>, OTHER, or DELETED. rc 2 when hashing fails.
_ga_eff_values() { # ROOT T IN
  local root=$1 t=$2 p h
  : >"$t/v.reg"; : >"$t/v.lnk"
  LC_ALL=C awk -v t="$t" '
    FILENAME == ARGV[1] { i = index($0, " "); ty[substr($0, i + 1)] = substr($0, 1, 1); next }
    { p = $0
      if (!(p in ty)) print "DELETED " p
      else if (ty[p] == "-") print p > (t "/v.reg")
      else if (ty[p] == "l") print p > (t "/v.lnk")
      else if (ty[p] == "d") print "DIR " p
      else print "OTHER " p }' "$t/nstat" "$t/$3" >"$t/val"
  if [ -s "$t/v.reg" ]; then
    GA_EFF_R="$root/" LC_ALL=C awk '{ print ENVIRON["GA_EFF_R"] $0 }' "$t/v.reg" |
      _ga_git hash-object --no-filters --stdin-paths >"$t/v.h" 2>/dev/null || return 2
    [ "$(LC_ALL=C wc -l <"$t/v.h")" = "$(LC_ALL=C wc -l <"$t/v.reg")" ] || return 2
    LC_ALL=C paste -d ' ' "$t/v.h" "$t/v.reg" >>"$t/val"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    h=$(readlink "$root/$p" | _ga_fp_sha) || return 2
    printf 'LINK:%s %s\n' "$h" "$p" >>"$t/val"
  done <"$t/v.lnk"
  return 0
}

_ga_eff_write() { # ROOT META_JSON LIST_FILE
  local rc=0 lp
  lp=$(ga_effect_list_path "$1")
  ga_lock "$1"
  if cp "$3" "$lp.tmp.$$" 2>/dev/null && mv "$lp.tmp.$$" "$lp"; then
    ga_fp_mark "$1"
    printf '%s\n' "$2" | ga_write_json "$(ga_effect_snapshot_path "$1")" || rc=2
  else
    rm -f "$lp.tmp.$$"; rc=2
  fi
  ga_unlock "$1"
  return $rc
}

# Non-git projects: the regular files (relative to ROOT) in T/cand, skipping build folders, git
# folders and the state folder.
_ga_eff_files_cands() { # ROOT T
  { ( cd "$1" && find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist \
        -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -print0 2>/dev/null ) || :; } |
    LC_ALL=C tr '\n\0' "${GA_EFF_NL}\n" | LC_ALL=C sed 's#^\./##' | _ga_eff_filter >"$2/cand"
}

# Records the project file state (see the top of this file). rc 2 when it cannot be recorded.
ga_effect_snapshot() { # ROOT
  local root=$1 t base meta rc=0 t0 n
  t=$(mktemp -d "${TMPDIR:-/tmp}/ga-eff.XXXXXX") || return 2
  : >"$t/list"
  _ga_eff_layout "$root" || rc=$?
  t0=$(date +%s)
  case "$rc" in
    1) # no git: ga's stat record of every file
      _ga_eff_files_cands "$root" "$t"
      if _ga_eff_no_newline_names "$t/cand" >/dev/null; then
        (cd "$root" && _ga_eff_stat <"$t/cand") | LC_ALL=C awk '{ i = index($0, " "); print substr($0, 1, i - 1) " = " substr($0, i + 1) }' >"$t/list"
        meta=$(jq -nc --argjson t0 "$t0" '{kind:"files", v:2, t0:$t0}')
      else
        meta=$(jq -nc --arg e "$(_ga_eff_no_newline_names "$t/cand")" '{kind:"files", v:2, error:$e}')
      fi ;;
    2) meta=$(jq -nc --arg e "git 저장소 구조를 믿을 수 없음: ${GA_EFL_ERR}" '{kind:"git", v:2, error:$e}') ;;
    *)
      if ! ga_git_resolve; then
        meta=$(jq -nc '{kind:"git", v:2, error:"git 없음"}')
      else
        # No commit yet: rc 1 and no output. Anything else that fails is a broken repository.
        rc=0; base=$( cd "$root" && _ga_git rev-parse --verify -q HEAD 2>/dev/null ) || rc=$?
        if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
          meta=$(jq -nc '{kind:"git", v:2, error:"git 오류: 기준 커밋을 읽을 수 없음"}')
        elif ! meta=$(_ga_eff_git_cands "$root" "$base" "$t") || ! meta=$(_ga_eff_no_newline_names "$t/cand"); then
          meta=$(jq -nc --arg e "$meta" '{kind:"git", v:2, error:$e}')
        else
          # Stat first, then hash: a write between the two lands in the next check's record.
          (cd "$root" && _ga_eff_stat <"$t/cand") >"$t/nstat"
          if ! _ga_eff_values "$root" "$t" cand; then
            meta=$(jq -nc '{kind:"git", v:2, error:"git 오류: hash-object 실패"}')
          else
            LC_ALL=C awk '
              FILENAME == ARGV[1] { i = index($0, " "); S[substr($0, i + 1)] = substr($0, 1, i - 1); next }
              FILENAME == ARGV[2] { i = index($0, " "); B[substr($0, i + 1)] = substr($0, 1, i - 1); next }
              FILENAME == ARGV[3] { i = index($0, " "); V[substr($0, i + 1)] = substr($0, 1, i - 1); next }
              { p = $0; s = (p in S) ? S[p] : "-"; v = (p in V) ? V[p] : "DELETED"
                print s " " (((p in B) && B[p] == v) ? "=" : v) " " p }' "$t/nstat" "$t/base" "$t/val" "$t/cand" >"$t/list"
            meta=$(jq -nc --arg b "$base" --arg top "$GA_EFL_TOP" --arg g "$GA_EFL_GITDIR" --arg c "$GA_EFL_COMMON" --argjson t0 "$t0" \
              '{kind:"git", v:2, base:$b, layout:{top:$top, gitdir:$g, common:$c}, t0:$t0}')
          fi
        fi
      fi ;;
  esac
  n=$(LC_ALL=C wc -l <"$t/list" | tr -d ' ')
  meta=$(printf '%s' "$meta" | jq -c --argjson n "$n" '. + {n:$n}') || { rm -rf "$t"; return 2; }
  _ga_eff_write "$root" "$meta" "$t/list"
  rc=$?
  rm -rf "$t"
  return $rc
}

# Paths changed since the snapshot, as a sorted JSON array. rc 2 with the reason on stdout when the
# files cannot be checked.
_ga_eff_changed() { # ROOT
  local root=$1 sp lp t rc=0 out
  sp=$(ga_effect_snapshot_path "$root")
  lp=$(ga_effect_list_path "$root")
  t=$(mktemp -d "${TMPDIR:-/tmp}/ga-eff.XXXXXX") || { echo "임시 폴더를 만들 수 없음"; return 2; }
  out=$(_ga_eff_changed_in "$root" "$sp" "$lp" "$t") || rc=$?
  rm -rf "$t"
  printf '%s\n' "$out"
  return $rc
}

_ga_eff_changed_in() { # ROOT SNAPSHOT LIST T
  local root=$1 sp=$2 lp=$3 t=$4 kind v base t0 err top gd cm n rc=0 cur
  { IFS= read -r kind; IFS= read -r v; IFS= read -r base; IFS= read -r t0; IFS= read -r err
    IFS= read -r top; IFS= read -r gd; IFS= read -r cm; IFS= read -r n; } <<EOF || :
$(jq -r '(.kind // ""), (.v // 1 | tostring), (.base // ""), (.t0 // 0 | tostring), (.error // ""),
  (.layout.top // ""), (.layout.gitdir // .gitdir // ""), (.layout.common // ""), (.n // -1 | tostring)' "$sp" 2>/dev/null)
EOF
  case "$kind:$v" in
    git:2 | files:2)
      [ -z "$err" ] || { echo "$err"; return 2; }
      [ -f "$lp" ] && [ "$(LC_ALL=C wc -l <"$lp" | tr -d ' ')" = "$n" ] ||
        { echo "기준 파일 목록(snapshot.list)이 없거나 snapshot.json과 맞지 않음"; return 2; } ;;
    git:1) : >"$t/v1"; jq -r '.dirty // {} | to_entries[] | "? \(.value) \(.key)"' "$sp" >"$t/v1" 2>/dev/null; lp=$t/v1 ;;
    files:1) _ga_eff_changed_legacy_files "$root" "$sp"; return ;;
    *) echo "기준(snapshot.json)을 읽을 수 없음"; return 2 ;;
  esac
  LC_ALL=C cut -d ' ' -f 3- "$lp" >"$t/snapp"

  if [ "$kind" = files ]; then
    # No git: the stat record alone. A path whose record differs, appeared or went away is a change.
    _ga_eff_files_cands "$root" "$t"
    _ga_eff_no_newline_names "$t/cand" || return 2
    (cd "$root" && _ga_eff_stat <"$t/cand") >"$t/nstat"
    LC_ALL=C awk '
      FILENAME == ARGV[1] { i = index($0, " "); r = substr($0, i + 1); j = index(r, " "); S[substr(r, j + 1)] = substr($0, 1, i - 1); next }
      { i = index($0, " "); p = substr($0, i + 1); N[p] = 1; if (!(p in S) || S[p] != substr($0, 1, i - 1)) print p }
      END { for (p in S) if (!(p in N)) print p }' "$lp" "$t/nstat" | _ga_eff_to_json
    return
  fi

  # Git: the same pinned layout, an existing base commit, then the candidates now plus those of the
  # snapshot. A file whose stat record is unchanged (and not taken in the snapshot's own second) is
  # unchanged; any other is hashed and compared with its snapshot content or its base blob.
  _ga_eff_layout "$root" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "git 저장소가 없어짐 (기준: ${gd})"; return 2 ;;
    *) echo "git 저장소 구조를 믿을 수 없음: ${GA_EFL_ERR}"; return 2 ;;
  esac
  if [ "$GA_EFL_GITDIR" != "$gd" ] || { [ -n "$top" ] && { [ "$GA_EFL_TOP" != "$top" ] || [ "$GA_EFL_COMMON" != "$cm" ]; }; }; then
    echo "git 저장소 위치가 기준과 다름 (기준 ${gd}, 지금 ${GA_EFL_GITDIR})"; return 2
  fi
  ga_git_resolve || { echo "git 없음"; return 2; }
  if [ -n "$base" ] && ! _ga_git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "기준 커밋 ${base:0:12}을(를) 저장소에서 찾을 수 없음 (기록을 다시 쓴 경우 등)"; return 2
  fi
  _ga_eff_git_cands "$root" "$base" "$t" || return 2
  LC_ALL=C sort -u "$t/cand" "$t/snapp" | { LC_ALL=C grep -v '^$' || :; } >"$t/all"
  _ga_eff_no_newline_names "$t/all" || return 2
  (cd "$root" && _ga_eff_stat <"$t/all") >"$t/nstat"
  LC_ALL=C awk -v t0="$t0" '
    FILENAME == ARGV[1] { i = index($0, " "); r = substr($0, i + 1); j = index(r, " "); S[substr(r, j + 1)] = substr($0, 1, i - 1); next }
    FILENAME == ARGV[2] { i = index($0, " "); N[substr($0, i + 1)] = substr($0, 1, i - 1); next }
    { p = $0; now = (p in N) ? N[p] : "-"
      if (!(p in S) || S[p] != now) { print p; next }
      if (now != "-") { split(now, f, ":"); c = f[4]; sub(/\..*/, "", c); if (c + 0 >= t0 + 0) print p } }' \
    "$lp" "$t/nstat" "$t/all" >"$t/verify"
  _ga_eff_values "$root" "$t" verify || { echo "git 오류: hash-object 실패"; return 2; }
  LC_ALL=C awk '
    FILENAME == ARGV[1] { i = index($0, " "); r = substr($0, i + 1); j = index(r, " "); R[substr(r, j + 1)] = substr(r, 1, j - 1); next }
    FILENAME == ARGV[2] { i = index($0, " "); B[substr($0, i + 1)] = substr($0, 1, i - 1); next }
    { i = index($0, " "); v = substr($0, 1, i - 1); p = substr($0, i + 1)
      if (p in R) ref = (R[p] == "=") ? B[p] : R[p]; else ref = (p in B) ? B[p] : "DELETED"
      if (v != ref) print p }' "$lp" "$t/base" "$t/val" | _ga_eff_to_json
}

_ga_eff_to_json() { LC_ALL=C sort -u | jq -Rnc '[inputs | select(length > 0)]'; } # stdin paths -> sorted JSON array

# Snapshots written before P29 (no "v"): "size:mtime" per file, compared the old way.
_ga_eff_changed_legacy_files() { # ROOT SNAPSHOT
  local cur
  cur=$( (cd "$1" || exit 1
          if stat -c %s / >/dev/null 2>&1; then
            find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -c '%s:%Y %n' {} + 2>/dev/null
          else
            find . \( -name node_modules -o -name .git -o -name target -o -name build -o -name dist -o -path "./${GA_EFF_STATE_PREFIX%/}" \) -prune -o -type f -exec stat -f '%z:%m %N' {} + 2>/dev/null
          fi ) | LC_ALL=C sed 's# \./# #' |
         jq -Rn '[inputs | select(length > 0) | capture("^(?<v>[^ ]+) (?<p>.*)$") | {key: .p, value: .v}] | from_entries') ||
    { echo "파일 목록을 만들 수 없음"; return 2; }
  jq -nc --argjson c "$cur" --slurpfile s "$2" --arg om "$GA_EFF_OS_META" '
    $s[0].files as $o | ([$c | keys[]] + [$o | keys[]] | unique)
    | map(select(($c[.] != $o[.]) and (test($om) | not))) | sort'
}

# Prints {"changed":[...],"violations":[...]}; rc 1 on violations (including "결과 확인 불가: ..."
# when the files cannot be checked), 2 when there is no snapshot or the state cannot be read.
ga_effect_check() { # ROOT
  local root=$1 sp phase mode round changed maps out n sset
  sp=$(ga_effect_snapshot_path "$root")
  [ -f "$sp" ] || { echo "ga: 파일 변경 기준(snapshot.json)이 없습니다" >&2; return 2; }
  phase=$(ga_state_get "$root" .phase) || return 2
  mode=$(ga_state_get "$root" .mode) || return 2
  round=$(ga_state_get "$root" .round) || return 2
  if ! changed=$(_ga_eff_changed "$root") || ! printf '%s' "$changed" | jq -e 'type == "array"' >/dev/null 2>&1; then
    jq -nc --arg v "${GA_EFF_UNSURE}: ${changed:-알 수 없는 오류}" '{changed: [], violations: [$v]}'
    return 1
  fi
  maps=$(jq -c --argjson r "$round" \
    '[.items[]? | select(.kind == "mapping" and .round == $r and (.change == "new" or .change == "changed")) | .path | ltrimstr("./")]' \
    "$(ga_ledger_path "$root")" 2>/dev/null) || maps='[]'
  # The plugin root (contains core/) is protected when it lies inside the project.
  local pd rc_
  pd=$(ga_phys_dir "$GA_CORE/..") || pd=""
  rc_=$(ga_canon "$root") || rc_=$root
  case "$pd" in "$rc_"/*) pd=${pd#"$rc_"/} ;; *) pd="" ;; esac
  out=$(jq -nc --argjson ch "$changed" --argjson m "$maps" --arg ph "$phase" --arg mode "$mode" --arg pd "$pd" '
    def inmap: . as $x | any($m[]; . as $p | $x == $p or ($x | startswith(($p | rtrimstr("/")) + "/")));
    def free: ($ph == "implement") or ($ph == "skeleton" and $mode != "brownfield");
    def ok: if $pd != "" and (. == $pd or startswith($pd + "/")) then false
            elif free then true
            elif startswith("docs/architecture/") then true
            elif $ph == "skeleton" then inmap
            else false end;
    {changed: $ch, violations: [$ch[] | select(ok | not)]}') || return 2
  n=$(printf '%s' "$out" | jq '.violations | length')
  if [ "$n" != 0 ]; then
    # P19: the harness's own settings files are never violations (enforce status checks them).
    sset=$(printf '%s' "$out" | jq -r '.violations[]' | ga_enforce_settings_rel "$root" | jq -Rn '[inputs]') || sset='[]'
    out=$(printf '%s' "$out" | jq -c --argjson s "$sset" '.violations -= $s')
    n=$(printf '%s' "$out" | jq '.violations | length')
  fi
  printf '%s\n' "$out"
  [ "$n" = 0 ]
}

# "a, b, c" from a check result's violations (at most 20, then "외 n개").
ga_effect_list() { # CHECK_JSON
  printf '%s' "$1" | jq -r '.violations as $v | ($v[0:20] | join(", ")) + (if ($v | length) > 20 then " 외 \(($v | length) - 20)개" else "" end)' 2>/dev/null
}

# P19: the violation set Stop last reported (state folder, so the agent cannot fake it).
ga_effect_reported_path() { echo "$(ga_state_dir "$1")/effect_reported.json"; } # ROOT

ga_effect_reported_is() { # ROOT CHECK_JSON -> true when Stop already reported exactly this set
  local f
  f=$(ga_effect_reported_path "$1")
  [ -f "$f" ] || return 1
  jq -e --argjson c "$2" '.violations == ($c.violations | sort)' "$f" >/dev/null 2>&1
}

ga_effect_reported_set() { # ROOT CHECK_JSON
  local rc
  ga_lock "$1"
  printf '%s' "$2" | jq -c '{violations: (.violations | sort)}' | ga_write_json "$(ga_effect_reported_path "$1")"
  rc=$?
  ga_unlock "$1"
  return $rc
}

ga_effect_reported_clear() { # ROOT
  [ -e "$(ga_effect_reported_path "$1")" ] || return 0
  ga_lock "$1"
  rm -f "$(ga_effect_reported_path "$1")"
  ga_fp_mark "$1"
  ga_unlock "$1"
}

cmd_effect() {
  local out rc
  { [ $# -eq 1 ] && [ "$1" = check ]; } || ga_die "사용법: ga effect check" 2
  ga_need_state
  out=$(ga_effect_check "$GA_ROOT")
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" = 1 ]; then
    echo "ga: 이 단계에서 바꿀 수 없는 파일이 바뀌었습니다: $(printf '%s' "$out" | jq -r '.violations | join(", ")')" >&2
  fi
  exit "$rc"
}
