# Passes when repro.sh produced a result for every tool in tools.list.
for t in $(cat scenarios/27-oncall-tools-handson/tools.list); do [ -s "${OUT:-out}/$t/result.json" ] || exit 1; done
