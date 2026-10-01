#!/usr/bin/env bats
# Unit tests of packages/keel-web/anubis-front, the state hook keel runs
# as /usr/lib/keel/overlays/anubis/state.d/50keel-web when the anubis
# overlay is turned on or off. It runs against a scratch /etc/nginx named
# by KEEL_NGINX_DIR, with nginx and dpkg-query as stubs first in PATH that
# log their arguments: no root, no Nginx, no dpkg database.

bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../packages/keel-web/anubis-front"
DEBIAN_TEXT="# Debian's default server, as nginx-common ships it"

setup() {
    T=$(mktemp -d)
    N="$T/nginx"
    mkdir -p "$N/sites-available" "$N/sites-enabled" "$T/bin"
    echo "$DEBIAN_TEXT" > "$N/sites-available/default"
    echo "# keel-web's front" > "$N/sites-available/default-anubis"
    ln -s "$N/sites-available/default" "$N/sites-enabled/default"
    export KEEL_NGINX_DIR="$N"
    export KEEL_WEB_STATE_DIR="$T/state"
    export KEEL_NGINX_PID="$T/nginx.pid"
    echo $$ > "$KEEL_NGINX_PID"
    export CALLS="$T/calls"
    : > "$CALLS"
    # nginx: -t fails while $T/t-fails exists, -s reload while
    # $T/reload-fails does; both log what the tree held when called
    cat > "$T/bin/nginx" <<'STUB'
#!/bin/bash
echo "nginx $* [$(cd "$KEEL_NGINX_DIR/sites-enabled" && ls | tr '\n' ' ')]" >> "$CALLS"
[ "$1" = -t ] && [ -e "$STUB_DIR/t-fails" ] && { echo "nginx: [emerg] test failed" >&2; exit 1; }
[ "$1" = -s ] && [ -e "$STUB_DIR/reload-fails" ] && { echo "nginx: [error] reload failed" >&2; exit 1; }
exit 0
STUB
    # dpkg-query: nginx-common's conffiles, the default site with the
    # checksum of DEBIAN_TEXT; fails while $T/no-nginx-common exists
    cat > "$T/bin/dpkg-query" <<STUB
#!/bin/bash
[ -e "\$STUB_DIR/no-nginx-common" ] && { echo "dpkg-query: no packages found matching nginx-common" >&2; exit 1; }
echo " /etc/nginx/nginx.conf 0123456789abcdef0123456789abcdef"
echo " /etc/nginx/sites-available/default $(echo "$DEBIAN_TEXT" | md5sum | cut -d' ' -f1)"
STUB
    chmod +x "$T/bin/nginx" "$T/bin/dpkg-query"
    export STUB_DIR="$T"
    PATH="$T/bin:$PATH"
}

teardown() {
    rm -rf "$T"
}

front_linked() {
    [ "$(readlink "$N/sites-enabled/default-anubis")" = "$N/sites-available/default-anubis" ]
}

debian_linked() {
    [ "$(readlink "$N/sites-enabled/default")" = "$N/sites-available/default" ]
}

recorded() {
    [ -f "$KEEL_WEB_STATE_DIR/debian-default-unlinked" ]
}

# a plain test, not `! recorded`: bats ignores a negation that is not the
# last command of a test
not_recorded() {
    [ ! -e "$KEEL_WEB_STATE_DIR/debian-default-unlinked" ]
}

# usage

@test "no argument is a usage error" {
    run bash "$HOOK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: anubis-front enabled|disabled"* ]]
}

@test "a word other than enabled or disabled is a usage error" {
    run bash "$HOOK" on
    [ "$status" -eq 2 ]
}

# enabled

@test "enabled puts the front in place of Debian's default site, tests and reloads" {
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    [ ! -e "$N/sites-enabled/default" ] && [ ! -L "$N/sites-enabled/default" ]
    recorded
    [ "$(cat "$CALLS")" = $'nginx -t [default-anubis ]\nnginx -s reload [default-anubis ]' ]
    [[ "$output" == *"enabled: the default site goes through Anubis"* ]]
}

@test "enabled twice is unchanged and touches nothing" {
    bash "$HOOK" enabled
    : > "$CALLS"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (enabled)"* ]]
    [ ! -s "$CALLS" ]
}

@test "enabled leaves an edited Debian default site alone and refuses" {
    echo "server { listen 80 default_server; root /srv/mine; }" > "$N/sites-available/default"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"edited"* ]]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
    not_recorded
    [ ! -s "$CALLS" ]
}

@test "enabled refuses when nginx-common's checksum cannot be read" {
    : > "$T/no-nginx-common"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
}

@test "enabled refuses a default link that points somewhere else" {
    ln -sfn "$N/sites-available/default-anubis" "$N/sites-enabled/default"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"points to"* ]]
    [ ! -L "$N/sites-enabled/default-anubis" ]
}

@test "enabled refuses a default site that is a file, not a link" {
    rm "$N/sites-enabled/default"
    echo "server {}" > "$N/sites-enabled/default"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a link"* ]]
    [ -f "$N/sites-enabled/default" ]
}

@test "enabled refuses a file of the operator's where the front goes" {
    echo "server {}" > "$N/sites-enabled/default-anubis"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a link"* ]]
    debian_linked
}

# Debian's link gone is the operator's choice, and the default server may
# be a site of theirs: the front would take default_server from it
@test "enabled with Debian's default unlinked leaves the default server alone and says so" {
    rm "$N/sites-enabled/default"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"Debian's default site is not enabled"*"left alone"* ]]
    [ ! -e "$N/sites-enabled/default-anubis" ] && [ ! -L "$N/sites-enabled/default-anubis" ]
    not_recorded
    [ ! -s "$CALLS" ]
}

@test "enabled refuses and keeps Debian's link when the record cannot be written" {
    echo "a file where the state directory goes" > "$T/state"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot record"* ]]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
    [ ! -s "$CALLS" ]
}

@test "enabled rolls back when nginx -t refuses the result" {
    : > "$T/t-fails"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused"* ]]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
    not_recorded
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
}

@test "enabled rolls back and reloads again when the reload fails" {
    : > "$T/reload-fails"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"reload failed"* ]]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
    not_recorded
    [ "$(sed -n 3p "$CALLS")" = 'nginx -s reload [default ]' ]
}

@test "enabled with Nginx stopped links and tests, and reloads nothing" {
    rm "$KEEL_NGINX_PID"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
    [[ "$output" == *"nginx is not running"* ]]
}

@test "a pid file naming no process is Nginx stopped" {
    echo 999999999 > "$KEEL_NGINX_PID"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
}

# disabled

@test "disabled puts Debian's default site back, tests and reloads" {
    bash "$HOOK" enabled
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
    not_recorded
    [ "$(cat "$CALLS")" = $'nginx -t [default ]\nnginx -s reload [default ]' ]
    [[ "$output" == *"disabled: the default site is Debian's"* ]]
}

@test "disabled on a tree that never had the front is unchanged" {
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (disabled)"* ]]
    debian_linked
    [ ! -s "$CALLS" ]
}

@test "disabled makes no Debian link that was not there before" {
    rm "$N/sites-enabled/default"
    bash "$HOOK" enabled
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (disabled)"* ]]
    [ ! -e "$N/sites-enabled/default" ] && [ ! -L "$N/sites-enabled/default" ]
}

@test "a rollback of enabled forgets the record it wrote" {
    : > "$T/t-fails"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    debian_linked
    not_recorded
}

@test "disabled keeps a default link the operator made meanwhile" {
    bash "$HOOK" enabled
    ln -s /srv/elsewhere "$N/sites-enabled/default"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [ "$(readlink "$N/sites-enabled/default")" = /srv/elsewhere ]
    not_recorded
}

@test "disabled refuses a file of the operator's where the front was" {
    echo "server {}" > "$N/sites-enabled/default-anubis"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [ -f "$N/sites-enabled/default-anubis" ]
}

@test "disabled puts the front back when nginx -t refuses the result" {
    bash "$HOOK" enabled
    : > "$T/t-fails"
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused"* ]]
    front_linked
    [ ! -L "$N/sites-enabled/default" ]
    recorded
}

@test "disabled says so when the reload fails, and keeps the files disabled" {
    bash "$HOOK" enabled
    : > "$T/reload-fails"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"until Nginx restarts"* ]]
    debian_linked
    [ ! -L "$N/sites-enabled/default-anubis" ]
}

@test "disabled with Nginx stopped unlinks and tests, and reloads nothing" {
    bash "$HOOK" enabled
    rm "$KEEL_NGINX_PID"
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    debian_linked
    [ "$(cat "$CALLS")" = 'nginx -t [default ]' ]
}
