#!/usr/bin/env bash
# Sandbox: run "$@" detached in its own session under the thermal watchdog (>80 C kills it).
#   M=<dir for logs> scripts/launch.sh <command...>   -> M/job.log, M/job.rc, M/driver.sid, M/thermal.log
set -eu
: "${M:?set M to a log directory}"
mkdir -p "$M"; rm -f "$M/job.rc"
cat > "$M/driver.sh" <<DRV
#!/usr/bin/env bash
ps -o sid= -p \$\$ | tr -d ' ' > "$M/driver.sid"
cd "$PWD"
"\$@" > "$M/job.log" 2>&1 < /dev/null
echo \$? > "$M/job.rc"
DRV
chmod +x "$M/driver.sh"
export M
setsid nohup "$M/driver.sh" "$@" > /dev/null 2>&1 < /dev/null &
M=$M setsid nohup bash ~/regr/thermal-watch.sh > "$M/tw.out" 2>&1 < /dev/null &
echo "launched; poll $M/job.rc"
