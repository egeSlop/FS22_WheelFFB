#!/bin/bash
# Steam launch wrapper for FS22 force feedback on Linux.
#
# Steam > Farming Simulator 22 > Properties > Launch options:
#   PROTON_ENABLE_HIDRAW=0x11FF/0x2370 ~/.local/share/fs22-ffb/fs22-ffb-launch.sh %command%
# (the PROTON_ENABLE_HIDRAW part is only needed for the LiteStar V987; drop it for other wheels)
#
# 1. If nothing answers on 127.0.0.1:47820 yet, starts a headless FFB server: V987 Wheel Studio's
#    (v987-wheel-studio --ffb-server) if it's installed, otherwise ffb-server. When Wheel Studio
#    is already open, its own server is used and you see the game live in the app.
# 2. Puts wheelffb-relay.exe in front of the game inside Proton, so the mod's named pipe
#    \\.\pipe\WheelFFB exists in the same Wine prefix.
# 3. Stops the headless server again when the game exits.

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RELAY="$DIR/wheelffb-relay.exe"
LOG="$DIR/server.log"
export PATH="$HOME/.local/bin:$PATH"

server_up() { (exec 3<>/dev/tcp/127.0.0.1/47820) 2>/dev/null; }

SERVER_PID=""
if ! server_up; then
    echo "=== $(date '+%F %T') game launch" >>"$LOG"
    if command -v v987-wheel-studio >/dev/null 2>&1; then
        v987-wheel-studio --ffb-server run >>"$LOG" 2>&1 &
        SERVER_PID=$!
    elif [ -x "$DIR/ffb-server" ]; then
        "$DIR/ffb-server" run >>"$LOG" 2>&1 &
        SERVER_PID=$!
    elif command -v ffb-server >/dev/null 2>&1; then
        ffb-server run >>"$LOG" 2>&1 &
        SERVER_PID=$!
    else
        echo "no FFB server found: install V987 Wheel Studio or ffb-server" >>"$LOG"
    fi
fi

args=()
for a in "$@"; do
    case "$a" in
        *FarmingSimulator2022Game.exe|*FarmingSimulator2022.exe)
            # Inside Wine the relay starts the game itself; give it a Windows path (Z: is /).
            args+=("$RELAY" "--exec" "Z:${a//\//\\}")
            ;;
        *)
            args+=("$a")
            ;;
    esac
done

"${args[@]}"
rc=$?

[ -n "$SERVER_PID" ] && kill -INT "$SERVER_PID" 2>/dev/null
exit $rc
