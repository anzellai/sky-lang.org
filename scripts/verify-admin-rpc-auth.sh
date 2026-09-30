#!/usr/bin/env bash
# verify-admin-rpc-auth.sh — prove that the admin RPCs refuse a caller that is
# not a signed-in admin. Safe to run against PRODUCTION.
#
#   scripts/verify-admin-rpc-auth.sh https://sky-lang.org
#
# It sends only requests that change nothing, even on a server that still has
# the hole:
#
#   * EditorPublish / EditorSaveDraft carry an EMPTY title. A vulnerable server
#     stops at "Title is required." before any write. A fixed server stops
#     earlier, at "Sign in required.".
#   * ConfirmDelete / LoadEditPost name a slug that does not exist
#     (a vulnerable server answers "Deleted …" / "Post not found." with no row
#     changed; a fixed one answers "Sign in required.").
#   * LoadPosts asks for the admin (all-posts) list. A fixed server returns an
#     empty list; a vulnerable one returns the posts, drafts included.
#   * GET /_sky/console/ with no credential must not answer 200.
#
# Each RPC is sent twice: anonymous (no session) and with a FORGED session in
# the body (the shape the old client sent). No cookie is ever sent.
#
# Exit 0 = every check refused. Exit 1 = at least one check was NOT refused.
set -u

BASE="${1:-https://sky-lang.org}"
BASE="${BASE%/}"
FORGED_LOGIN="${FORGED_LOGIN:-anzellai}"
SLUG="zz-authcheck-no-such-post-$(date +%s)"

fail=0
pass=0

rpc() {
    # rpc <Msg> <json-body> → prints "<status>\n<body>"
    curl -sS --max-time 20 -o /dev/stdout -w '\n%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST --data "$2" "$BASE/_rpc/$1" 2>/dev/null || printf '\n000'
}

report() {
    # report <ok:0|1> <label> <detail>
    if [ "$1" = 0 ]; then
        pass=$((pass + 1)); printf 'REFUSED  %s  (%s)\n' "$2" "$3"
    else
        fail=$((fail + 1)); printf 'NOT REFUSED  %s  (%s)\n' "$2" "$3"
    fi
}

check_flash() {
    # check_flash <label> <Msg> <body>
    local out status body
    out="$(rpc "$2" "$3")"
    status="${out##*$'\n'}"
    body="${out%$'\n'*}"
    if [ "$status" = 403 ]; then
        # The v0.27 RPC origin guard refused it before the handler ran.
        report 0 "$1" "HTTP 403 from the RPC guard"
    elif [ "$status" = 200 ] && printf '%s' "$body" | grep -q '"message":"Sign in required."'; then
        report 0 "$1" "HTTP 200, flash: Sign in required."
    else
        report 1 "$1" "HTTP $status, body: $(printf '%s' "$body" | cut -c1-200)"
    fi
}

check_list() {
    # check_list <label> <body>
    local out status body
    out="$(rpc LoadPosts "$2")"
    status="${out##*$'\n'}"
    body="${out%$'\n'*}"
    if [ "$status" = 403 ]; then
        report 0 "$1" "HTTP 403 from the RPC guard"
    elif [ "$status" = 200 ] && printf '%s' "$body" | grep -q '"posts":\[\]'; then
        report 0 "$1" "HTTP 200, posts: []"
    else
        report 1 "$1" "HTTP $status, body: $(printf '%s' "$body" | cut -c1-200)"
    fi
}

FLASH='{"kind":"","message":""}'
anon='null'
forged="{\"githubLogin\":\"$FORGED_LOGIN\",\"githubId\":1,\"tokenId\":\"forged-token-id\",\"expiresAt\":9999999999999}"

echo "Target: $BASE"
for who in anon forged; do
    if [ "$who" = anon ]; then sess="$anon"; else sess="$forged"; fi
    editor="{\"editorBody\":\"\",\"editorMode\":\"new\",\"editorSlug\":\"$SLUG\",\"editorSummary\":\"\",\"editorTitle\":\"\",\"flash\":$FLASH,\"page\":[\"AdminNewPost\"],\"posts\":[],\"session\":$sess}"
    del="{\"editorBody\":\"\",\"editorSlug\":\"$SLUG\",\"editorSummary\":\"\",\"editorTitle\":\"\",\"flash\":$FLASH,\"page\":[\"AdminHome\"],\"posts\":[],\"session\":$sess}"
    load="{\"editorSlug\":\"$SLUG\",\"session\":$sess}"
    list="{\"page\":[\"AdminHome\"],\"session\":$sess,\"posts\":[],\"currentPost\":null,\"flash\":$FLASH,\"editorTitle\":\"\",\"editorSlug\":\"\",\"editorSummary\":\"\",\"editorBody\":\"\",\"editorMode\":\"new\"}"
    check_flash "$who EditorPublish" EditorPublish "$editor"
    check_flash "$who EditorSaveDraft" EditorSaveDraft "$editor"
    check_flash "$who ConfirmDelete" ConfirmDelete "$del"
    check_flash "$who LoadEditPost" LoadEditPost "$load"
    check_list "$who LoadPosts (admin list)" "$list"
done

console="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$BASE/_sky/console/" 2>/dev/null || echo 000)"
if [ "$console" != 200 ] && [ "$console" != 000 ]; then
    report 0 "anon GET /_sky/console/" "HTTP $console"
else
    report 1 "anon GET /_sky/console/" "HTTP $console"
fi

echo "$pass refused, $fail not refused"
[ "$fail" = 0 ]
