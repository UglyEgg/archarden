#!/usr/bin/env bats

@test "ERR trap prints file/line/command" {
  run bash -c '
    set -eEuo pipefail
    source lib/utils.sh
    utils::install_err_trap
    false
  ' 2>&1

  [ "$status" -ne 0 ]
  [[ "$output" =~ "ERROR: rc=" ]]
  [[ "$output" =~ "cmd: false" ]]
  [[ "$output" =~ "stack:" ]]
  [[ "$output" =~ "lib/utils.sh" ]]
}
