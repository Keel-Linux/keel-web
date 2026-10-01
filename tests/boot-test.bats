#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh: argument parsing, address
# discovery from lxc-info, waiting with a deadline, verdicts. Nothing here
# needs root, a network or LXC: lxc-info is a stub first in PATH, the clock
# and sleep are functions.

bats_require_minimum_version 1.5.0

setup() {
    load lib/boot-test-lib.sh
    STUBS=$(mktemp -d)
    PATH=$STUBS:$PATH
}

teardown() {
    rm -rf "$STUBS"
}

stub_lxc_info() {
    # stub_lxc_info OUTPUT: lxc-info prints OUTPUT and records its arguments
    printf '#!/bin/bash\necho "$*" >> "%s/lxc-info.calls"\ncat <<"OUT"\n%s\nOUT\n' "$STUBS" "$1" > "$STUBS/lxc-info"
    chmod +x "$STUBS/lxc-info"
}

# argument parsing

@test "parse_args: the appliance alone takes every default" {
    bt_parse_args core
    [ "$BT_APPLIANCE" = core ]
    [ "$BT_TIMEOUT" = 900 ]
    [ "$BT_INTERVAL" = 5 ]
    [ "$BT_BRIDGE" = br0 ]
    [ "$BT_LAYERS_DIR" = /mnt/builds/layers ]
    [ "$BT_CACHE_DIR" = /var/cache/keel/layers ]
    [ "$BT_LXC_PATH" = /var/lib/lxc ]
    [ -z "$BT_SPEC" ]
    [ "$BT_KEEP" = 0 ]
    [ "$BT_NAME" = keel-core-boot-test ]
    [ "$BT_ROOTFS" = /var/lib/lxc/keel-core-boot-test/rootfs ]
}

@test "parse_args: every option is read" {
    bt_parse_args --timeout 60 --interval 2 --bridge lxcbr0 --layers-dir /l \
        --cache-dir /c --lxc-path /x --name lamp-run-7 --spec /s.yaml --keep lamp
    [ "$BT_APPLIANCE" = lamp ]
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = lxcbr0 ]
    [ "$BT_LAYERS_DIR" = /l ]
    [ "$BT_CACHE_DIR" = /c ]
    [ "$BT_LXC_PATH" = /x ]
    [ "$BT_SPEC" = /s.yaml ]
    [ "$BT_KEEP" = 1 ]
    [ "$BT_NAME" = lamp-run-7 ]
    [ "$BT_ROOTFS" = /x/lamp-run-7/rootfs ]
}

@test "parse_args: --name is checked as a container name" {
    run bt_parse_args core --name "Run 7"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a container name"* ]]
    run bt_parse_args core --name -lead
    [ "$status" -eq 1 ]
}

@test "is_container_name" {
    bt_is_container_name keel-core-boot-test-36255612491-1
    bt_is_container_name 7
    run ! bt_is_container_name "keel core"
    run ! bt_is_container_name -x
    run ! bt_is_container_name ""
}

@test "parse_args: the appliance is required" {
    run bt_parse_args --keep
    [ "$status" -eq 1 ]
    [[ $output == *"APPLIANCE is required"* ]]
}

@test "parse_args: one appliance at a time" {
    run bt_parse_args core lamp
    [ "$status" -eq 1 ]
    [[ $output == *"one appliance at a time"* ]]
}

@test "parse_args: the keel- prefix and upper case are rejected" {
    run bt_parse_args keel-core
    [ "$status" -eq 1 ]
    [[ $output == *"not an appliance name"* ]]
    run bt_parse_args Core
    [ "$status" -eq 1 ]
}

@test "parse_args: an unknown option fails" {
    run bt_parse_args core --verbose
    [ "$status" -eq 1 ]
    [[ $output == *"unknown option --verbose"* ]]
}

@test "parse_args: timeout and interval must be positive integers" {
    run bt_parse_args core --timeout 0
    [ "$status" -eq 1 ]
    [[ $output == *"--timeout needs a positive number"* ]]
    run bt_parse_args core --interval abc
    [ "$status" -eq 1 ]
    run bt_parse_args core --timeout
    [ "$status" -eq 1 ]
}

@test "parse_args: an option with a value refuses an empty one" {
    run bt_parse_args core --bridge
    [ "$status" -eq 1 ]
    [[ $output == *"--bridge needs a value"* ]]
    run bt_parse_args core --spec ""
    [ "$status" -eq 1 ]
}

@test "parse_args: --help prints the usage and returns 2" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    [[ $output == *"--keep"* ]]
    run bt_parse_args -h
    [ "$status" -eq 2 ]
}

@test "is_positive_int and is_appliance_name" {
    bt_is_positive_int 1
    bt_is_positive_int 900
    run ! bt_is_positive_int 0
    run ! bt_is_positive_int 07
    run ! bt_is_positive_int -5
    run ! bt_is_positive_int ""
    bt_is_appliance_name nginx-php-fastcgi
    run ! bt_is_appliance_name keel-core
    run ! bt_is_appliance_name 9core
    run ! bt_is_appliance_name ""
}

# address discovery

@test "is_global_ipv6: global and ULA yes, link local, loopback, multicast, IPv4 no" {
    bt_is_global_ipv6 2001:db8:1::10
    bt_is_global_ipv6 fd00:1::10
    bt_is_global_ipv6 2001:DB8::1
    run ! bt_is_global_ipv6 fe80::216:3eff:fe00:1
    run ! bt_is_global_ipv6 FEBF::1
    run ! bt_is_global_ipv6 ::1
    run ! bt_is_global_ipv6 ff02::1
    run ! bt_is_global_ipv6 192.0.2.10
    run ! bt_is_global_ipv6 ""
}

@test "global_ipv6: picks the first global address out of lxc-info output" {
    output=$(printf 'IP:             fe80::216:3eff:fe00:1\nIP:             192.0.2.10\nIP:             2001:db8:1::10\nIP:             2001:db8:1::11\n' | bt_global_ipv6)
    [ "$output" = 2001:db8:1::10 ]
}

@test "global_ipv6: ignores lines that are not addresses" {
    output=$(printf 'Name:           keel-core-boot-test\nState:          RUNNING\nPID:            4242\nIP:             fd00::10\nLink:           veth0\n' | bt_global_ipv6)
    [ "$output" = fd00::10 ]
}

@test "global_ipv6: returns 1 while only link local or IPv4 addresses exist" {
    run bt_global_ipv6 <<< $'IP:             fe80::1\nIP:             192.0.2.10'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_global_ipv6 < /dev/null
    [ "$status" -eq 1 ]
}

@test "container_ipv6: calls lxc-info with the lxcpath and the name" {
    stub_lxc_info $'Name:           keel-core-boot-test\nIP:             fe80::1\nIP:             2001:db8:1::10'
    output=$(bt_container_ipv6 keel-core-boot-test /var/lib/lxc)
    [ "$output" = 2001:db8:1::10 ]
    [ "$(cat "$STUBS/lxc-info.calls")" = "-P /var/lib/lxc -n keel-core-boot-test -i" ]
}

@test "container_ipv6: fails when lxc-info has no global address yet" {
    stub_lxc_info $'Name:           keel-core-boot-test\nState:          RUNNING'
    run bt_container_ipv6 keel-core-boot-test /var/lib/lxc
    [ "$status" -eq 1 ]
}

# timeouts

fake_clock() { echo "$FAKE_NOW"; }
fake_sleep() { FAKE_NOW=$(( FAKE_NOW + $1 )); echo "sleep $1" >> "$STUBS/sleeps"; }
succeed_on_third() { CALLS=$(( CALLS + 1 )); [ "$CALLS" -ge 3 ]; }
never() { return 1; }

@test "deadline_passed" {
    run ! bt_deadline_passed 100 30 129
    bt_deadline_passed 100 30 130
    bt_deadline_passed 100 30 500
}

@test "now: the default clock is epoch seconds and BT_CLOCK replaces it" {
    [[ $(bt_now) =~ ^[0-9]{10}$ ]]
    BT_CLOCK=fake_clock FAKE_NOW=42
    [ "$(bt_now)" = 42 ]
}

@test "wait_for: polls at the interval until the command succeeds" {
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000 CALLS=0
    bt_wait_for 60 5 "three calls" succeed_on_third
    [ "$CALLS" -eq 3 ]
    [ "$(cat "$STUBS/sleeps")" = $'sleep 5\nsleep 5' ]
}

@test "wait_for: gives up with a message once the timeout has passed" {
    # shellcheck disable=SC2034  # read by bt_now and bt_wait_for
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000
    run bt_wait_for 12 5 "something that never happens" never
    [ "$status" -eq 1 ]
    [[ $output == *"timeout after 12s waiting for something that never happens"* ]]
    [ "$(wc -l < "$STUBS/sleeps")" -eq 3 ]
}

# readiness and verdicts

@test "is_ssh_banner" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-7"
    run ! bt_is_ssh_banner "HTTP/1.1 400 Bad Request"
    run ! bt_is_ssh_banner ""
}

@test "firstboot_done_in: RUN_FIRSTBOOT=false in the rootfs copy of /etc/default/inithooks" {
    printf 'INITHOOKS_CONF=/etc/inithooks.conf\nRUN_FIRSTBOOT=false\n' > "$STUBS/done"
    printf 'RUN_FIRSTBOOT=true\n' > "$STUBS/pending"
    bt_firstboot_done_in "$STUBS/done"
    run ! bt_firstboot_done_in "$STUBS/pending"
    run ! bt_firstboot_done_in "$STUBS/missing"
}

@test "lxc_config: names the container, the rootfs and the bridge" {
    output=$(bt_lxc_config keel-core-boot-test /var/lib/lxc/keel-core-boot-test/rootfs br0)
    [[ $output == *"lxc.uts.name = keel-core-boot-test"* ]]
    [[ $output == *"lxc.rootfs.path = dir:/var/lib/lxc/keel-core-boot-test/rootfs"* ]]
    [[ $output == *"lxc.net.0.link = br0"* ]]
    [[ $output == *"lxc.net.0.type = veth"* ]]
}

@test "spec_targets: both paths the first boot reads, under the rootfs" {
    output=$(bt_spec_targets /r)
    [ "$output" = $'/r/etc/keel/instance.yaml\n/r/etc/inithooks.yaml' ]
}

@test "spec_in_rootfs: secret references are pointed inside the rootfs" {
    printf 'secrets:\n  root_password:\n    file: /etc/keel/secrets/root_password\ntls:\n  acme:\n    enabled: false\n' > "$STUBS/spec"
    output=$(bt_spec_in_rootfs "$STUBS/spec" /r/rootfs)
    [[ $output == *"file: /r/rootfs/etc/keel/secrets/root_password"* ]]
    [[ $output == *"enabled: false"* ]]
    [[ $output != *"file: /etc/keel"* ]]
}

@test "random_password: 24 alphanumeric characters from the random source" {
    output=$(bt_random_password)
    [[ $output =~ ^[A-Za-z0-9]{24}$ ]]
    printf 'ab!!cd%%%%efghijklmnopqrstuvwxyz0123456789' > "$STUBS/random"
    output=$(BT_RANDOM_SOURCE=$STUBS/random bt_random_password)
    [ "$output" = abcdefghijklmnopqrstuvwx ]
}

@test "random_password: a source too poor to fill the password fails loudly" {
    printf '!!!!short!!!!' > "$STUBS/poor"
    BT_RANDOM_SOURCE="$STUBS/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ $output == *"gave only 5 usable characters"* ]]
}

@test "diff_verdict: 0 and 13 pass, everything else fails with a message" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [ "$output" = "keel diff: no drift" ]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ $output == *"could not be observed offline"* ]]
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ $output == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ $output == *"unreadable or invalid (exit 2)"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 127
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 127"* ]]
}
