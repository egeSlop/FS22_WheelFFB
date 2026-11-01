#!/bin/bash
# Installs FS22 force feedback for Linux (Steam + Proton):
#   ~/.local/share/fs22-ffb/   wheelffb-relay.exe, fs22-ffb-launch.sh
#   FS22 mods folder           FS22_WheelFFB.zip
# The FFB server itself comes from V987 Wheel Studio or ffb-server (see README).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

DEST="$HOME/.local/share/fs22-ffb"
MODS="$HOME/.local/share/Steam/steamapps/compatdata/1248130/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2022/mods"

if [ -f relay/target/x86_64-pc-windows-gnu/release/wheelffb-relay.exe ] && [ -z "${REBUILD:-}" ]; then
    echo "==> using the built relay (REBUILD=1 to rebuild)"
else
    echo "==> building the relay (Windows exe, runs inside Proton)"
    (cd relay && cargo build --release -q --target x86_64-pc-windows-gnu)
fi

echo "==> installing to $DEST"
mkdir -p "$DEST"
install -m644 relay/target/x86_64-pc-windows-gnu/release/wheelffb-relay.exe "$DEST/"
install -m755 launch/fs22-ffb-launch.sh "$DEST/"

echo "==> installing the mod"
mkdir -p "$MODS"
rm -f "$MODS/FS22_WheelFFB.zip"
(cd mod/FS22_WheelFFB && zip -q -X "$MODS/FS22_WheelFFB.zip" modDesc.xml WheelFFB.lua icon_wheelFFB.dds)

if ! command -v v987-wheel-studio >/dev/null 2>&1 && ! command -v ffb-server >/dev/null 2>&1 \
    && [ ! -x "$HOME/.local/bin/v987-wheel-studio" ] && [ ! -x "$DEST/ffb-server" ]; then
    cat <<'MSG'

!! No FFB server found. Install one of these:
     V987 Wheel Studio  https://github.com/egeSlop/v987-wheel-studio
     ffb-server         cargo install --git https://github.com/egeSlop/ffb-server
MSG
fi

cat <<EOF2

Done. In Steam, set Farming Simulator 22's launch options to:

  PROTON_ENABLE_HIDRAW=0x11FF/0x2370 $DEST/fs22-ffb-launch.sh %command%

(PROTON_ENABLE_HIDRAW is only for the LiteStar V987.) Then tick "Wheel Force Feedback" in your
savegame's mod list and turn FS22's own force feedback off.
EOF2
