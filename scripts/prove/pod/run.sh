#!/usr/bin/env bash
# Makes TCP and PostgreSQL attempts inside the disposable pod and labels successful logins.
# Usage: run.sh HOST:PORT ['lb HOST:PORT'] ['nodeport HOST:PORT'] ...
# Exit: 0 with one result line per target; unexpected shell errors are nonzero.
set -euo pipefail
shopt -s inherit_errexit

for target in "$@"; do
  case $target in
    "lb "* | "nodeport "*)
      address=${target#* }
      if result=$(PGCONNECT_TIMEOUT=3 psql -w -X -At -c 'select 1' \
          "host=${address%:*} port=${address##*:} dbname=postgres user=postgres sslmode=require" 2>&1); then
        result="succeeded: $result"
      fi
      result=${result//$'\n'/ }
      result="$result "
      ;;
    *)
      # shellcheck disable=SC2016
      if output=$(timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' probe \
          "${target%:*}" "${target##*:}" 2>&1); then
        result=connected
      elif [[ $? == 124 ]]; then
        result=timeout
      else
        result=${output##*: }
      fi
      ;;
  esac
  echo "$target $result"
done
