#!/usr/bin/env bash
# ============================================================================
#  TowDownGame headless verification entry point (Linux / macOS / CI).
#
#  Mirror of tools/verify.bat. Keep the two in sync when adding a mode.
#
#  Differences from the Windows script, and why:
#    * Godot is located through $GODOT_EXE (default: `godot` on PATH) instead of
#      a hard-coded Windows install path.
#    * The writable user:// root is redirected with $XDG_DATA_HOME instead of
#      %APPDATA%, because that is what Godot uses on Linux. It is still needed
#      even though --log-file pins the log path: Godot also writes its shader
#      cache and config under user://.
#    * The audit uses grep instead of findstr.
#
#  USAGE
#    tools/verify.sh                    # boot main scene, 300 frames
#    tools/verify.sh 900 game
#    tools/verify.sh 0   all
#    tools/verify.sh 0   coop
#    tools/verify.sh 60  selftest       # must FAIL (proves the audit works)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GODOT_EXE="${GODOT_EXE:-godot}"
if [ ! -x "${GODOT_EXE}" ] && ! command -v "${GODOT_EXE}" >/dev/null 2>&1; then
    echo "RESULT: FAIL - Godot executable not found: ${GODOT_EXE}"
    echo "Set GODOT_EXE to the Godot 4.4 binary, e.g."
    echo "  GODOT_EXE=/opt/godot/godot tools/verify.sh 0 all"
    exit 2
fi

WORK_DIR="${PROJECT_DIR}/_userdata"
RUN_LOG="${WORK_DIR}/logs/run.log"
REPORT_DIR="${WORK_DIR}/reports"
mkdir -p "${WORK_DIR}/logs"
rm -f "${RUN_LOG}"
rm -f "${REPORT_DIR}"/*.log 2>/dev/null

export XDG_DATA_HOME="${WORK_DIR}/xdg"
mkdir -p "${XDG_DATA_HOME}"

FRAMES="${1:-300}"
MODE="${2:-driver}"

if [ "${MODE}" = "all" ]; then
    for suite in compile net coop lobby coopgame steam; do
        # Invoke through bash explicitly: on Windows checkouts and in CI the
        # executable bit on this file is not guaranteed to survive.
        if ! bash "${BASH_SOURCE[0]}" 0 "${suite}"; then
            echo "RESULT: FAIL - suite ${suite} failed"
            exit 1
        fi
    done
    echo "RESULT: PASS - all headless suites passed"
    exit 0
fi

# --log-file must come BEFORE the "--" separator: anything after it is handed to
# the script as a user argument instead of being consumed by the engine.
BASE_ARGS=(--headless --path "${PROJECT_DIR}" --log-file "${RUN_LOG}")
AUDIT_EXTRA=""

case "${MODE}" in
    import)
        ARGS=("${BASE_ARGS[@]}" --import)
        ;;
    game)
        ARGS=("${BASE_ARGS[@]}" --quit-after "${FRAMES}")
        ;;
    compile)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/compile_check.gd)
        AUDIT_EXTRA="${REPORT_DIR}/compile_check.log"
        ;;
    net)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/net_selftest.gd)
        AUDIT_EXTRA="${REPORT_DIR}/net_selftest.log"
        ;;
    coop)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/coop_selftest.gd)
        AUDIT_EXTRA="${REPORT_DIR}/coop_selftest.log"
        ;;
    lobby)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/lobby_selftest.gd)
        AUDIT_EXTRA="${REPORT_DIR}/lobby_selftest.log"
        ;;
    coopgame)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/coop_game_selftest.gd)
        AUDIT_EXTRA="${REPORT_DIR}/coop_game_selftest.log"
        ;;
    steam)
        ARGS=("${BASE_ARGS[@]}" --script res://tools/steam_selftest.gd)
        AUDIT_EXTRA="${REPORT_DIR}/steam_selftest.log"
        ;;
    *)
        # Default: driver mode. It quits itself, so no --quit-after.
        #
        # Each user argument must be its own array element. Passing
        # "--frames=60 --fail-test" as one string makes Godot hand the script a
        # single argv entry, so `args.has("--fail-test")` is false, no error gets
        # injected, and this mode wrongly reports PASS -- which would silently
        # turn the audit self-check into a rubber stamp.
        ARGS=("${BASE_ARGS[@]}" --script res://tools/headless_verify.gd -- "--frames=${FRAMES}")
        if [ "${MODE}" = "selftest" ]; then
            ARGS+=("--fail-test")
        fi
        ;;
esac

echo "==> ${GODOT_EXE} ${ARGS[*]}"
"${GODOT_EXE}" "${ARGS[@]}"
GODOT_RC=$?

echo
if [ ! -f "${RUN_LOG}" ]; then
    echo "RESULT: FAIL - Godot produced no log at ${RUN_LOG} (crashed before logging)"
    exit 1
fi

echo "--- ${RUN_LOG} ---"
cat "${RUN_LOG}"
echo "--- end log ---"

# Lines that are known-benign and must NOT fail the build are dropped first:
#   * root certificate store    -> CI containers have no OS cert store
#   * ObjectDB / resource leaks -> Godot's usual at-exit chatter
#   * custom_samplers           -> pre-existing engine shader condition
#   * backtrace frames          -> emitted together with CrashHandlerException,
#                                  which IS still checked below
#   * "No loader found"         -> res://shader/*.shader are Godot 3 leftovers
# NOTE: patterns that begin with dashes still go through -e so grep never has to
# guess whether an argument is a flag, a pattern or a file. Do NOT write
# `-e -- "-- END OF BACKTRACE --"`: grep takes `--` as the pattern, the dashed
# string as a FILE name, the whole command errors out, and $FILTERED ends up
# empty -- which silently disables the entire audit.
FILTERED="${WORK_DIR}/logs/filtered.log"
grep -v \
    -e "Failed to read the root certificate store" \
    -e "get_system_ca_certificates" \
    -e "os_windows.cpp:2289" \
    -e "ObjectDB instances leaked" \
    -e "resources still in use at exit" \
    -e "custom_samplers" \
    -e "no debug info in PE/COFF executable" \
    -e "-- END OF BACKTRACE --" \
    -e "Dumping the backtrace" \
    -e "Engine version: Godot Engine" \
    -e "ERROR: No loader found for resource" \
    "${RUN_LOG}" > "${FILTERED}" 2>/dev/null || true

# A missing/empty filter output means the audit is dead, not that the run was
# clean. Refuse to report PASS in that case.
if [ ! -s "${FILTERED}" ]; then
    echo
    echo "RESULT: FAIL - audit filter produced no output; the harness is broken"
    exit 1
fi

FOUND=0
check() {
    if grep -q -F -e "$1" "${FILTERED}" 2>/dev/null; then
        echo
        echo "MATCHED $1"
        grep -F -e "$1" "${FILTERED}"
        FOUND=1
    fi
}

check "SCRIPT ERROR"
check "Parse Error"
# Crucial: a crash must fail the run. Otherwise a suite that dies half-way
# through reports PASS simply because it never printed any failure marker.
check "CrashHandlerException"
check "Program crashed with signal"
check "ERROR:"

# Audit the report the suite driver wrote, too.
if [ -n "${AUDIT_EXTRA}" ]; then
    if [ -f "${AUDIT_EXTRA}" ]; then
        echo
        echo "--- ${AUDIT_EXTRA} ---"
        cat "${AUDIT_EXTRA}"
        echo "--- end report ---"
        if grep -q -F -e "[FAIL]" -e "[compile] FAIL" -e "RESULT: FAIL" "${AUDIT_EXTRA}" 2>/dev/null; then
            echo
            echo "MATCHED report failure marker"
            grep -F -e "[FAIL]" -e "[compile] FAIL" -e "RESULT: FAIL" "${AUDIT_EXTRA}"
            FOUND=1
        fi
    elif [ "${MODE}" != "import" ]; then
        echo
        echo "RESULT: FAIL - test report not produced: ${AUDIT_EXTRA}"
        exit 1
    fi
fi

# --import crashes at exit on the dev box even though the import itself
# succeeds, so its exit code is not meaningful there.
if [ "${MODE}" != "import" ] && [ "${GODOT_RC}" -ne 0 ]; then
    echo
    echo "MATCHED nonzero godot exit code: ${GODOT_RC}"
    FOUND=1
fi

echo
if [ "${FOUND}" -eq 1 ]; then
    echo "RESULT: FAIL - errors found"
    exit 1
fi

echo "RESULT: PASS - no script/engine errors"
exit 0
