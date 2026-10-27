#!/bin/zsh
# leakcheck.sh PROBE DIRECTORY COMMAND... : leaks per run of one command.
# Runs the command 4 and 24 times under leaks --atExit; growth / 20 is what
# each invocation leaks (process setup and the first run are subtracted out).
probe=$1 directory=$2
shift 2
count() {
  MallocStackLogging=lite leaks --atExit -- "$probe" repeat "$directory" $1 "$@[2,-1]" 2>/dev/null \
    | /usr/bin/awk '/: [0-9]+ leaks? for [0-9]+ total leaked bytes/ {for (i = 1; i <= NF; ++i) if ($i ~ /^leaks?$/) print $(i-1), $(i+2)}'
}
small=($(count 4 "$@")) large=($(count 24 "$@"))
echo "$* : $(( (large[1] - small[1]) / 20.0 )) leaks/run, $(( (large[2] - small[2]) / 20.0 )) bytes/run (4 runs: ${small[1]} leaks, 24 runs: ${large[1]})"
