# FS22_WheelFFB

[Türkçe](README.tr.md)

Force feedback for Farming Simulator 22 on Linux. FS22's own force feedback doesn't work under
Proton, and on Windows it is little more than a centering spring. This mod sends what your tractor
is doing to an FFB server, and you feel it in the wheel:

| You feel | From |
|---|---|
| centering that builds with speed | vehicle speed, weaker on fields and snow where tyres grip less |
| steering weight | heavier with the engine off, because there's no power steering |
| bumps | the left and right front wheels moving differently over ruts and kerbs |
| impacts | sudden stops and hard landings |
| surface texture | road, gravel, soft ground, field and snow feel different, faster with speed |
| engine vibration | follows the rpm, strongest when you're slow |

```
FS22_WheelFFB (Lua mod) ──named pipe──► wheelffb-relay.exe ──WebSocket──► FFB server ──► wheel
   inside the game           \\.\pipe\WheelFFB    next to the game      ws://127.0.0.1:47820
```

FS22's Lua has `require`, `package` and sockets removed. A test mod confirmed this in game. The
only way out is `io`, which can open a Windows named pipe, and a small relay turns that pipe into a
WebSocket. The FFB server is [ffb-server](https://github.com/egeSlop/ffb-server), either inside
[V987 Wheel Studio](https://github.com/egeSlop/v987-wheel-studio) or on its own.

## Install (Linux, Steam + Proton)

1. Install an FFB server. [V987 Wheel Studio](https://github.com/egeSlop/v987-wheel-studio) has
   one built in and shows the game live while you drive. For a server without a window, run
   `cargo install --git https://github.com/egeSlop/ffb-server`.
2. Run `./install.sh`. It builds the relay (needs Rust with the `x86_64-pc-windows-gnu` target and
   `mingw64-gcc`), copies the mod into FS22's mods folder and puts the launch script in
   `~/.local/share/fs22-ffb/`.
3. In Steam, set FS22's launch options to

   ```
   PROTON_ENABLE_HIDRAW=0x11FF/0x2370 ~/.local/share/fs22-ffb/fs22-ffb-launch.sh %command%
   ```

   The `PROTON_ENABLE_HIDRAW` part is only for the LiteStar / Rampage Pace V987. Leave it out for
   other wheels.
4. Tick **Wheel Force Feedback** in your savegame's mod list, and turn FS22's own force feedback off.

When you start the game, the launch script uses Wheel Studio's server if the app is open.
Otherwise it starts one in the background and stops it when the game closes.

## Windows (untested)

The relay is a Windows program, so the same pieces should work on Windows, but nobody has tried
it yet. Copy the mod zip into your mods folder, open Wheel Studio (or run `ffb-server.exe`), run
`start-relay-windows.bat`, then start FS22. Reports are welcome.

## Tuning

Use the FFB server page in Wheel Studio. Every slider applies while you drive. Without the app,
edit `~/.config/v987-wheel-studio/ffb-server.toml`; the server reloads it by itself.

## Layout

| Path | |
|---|---|
| `mod/FS22_WheelFFB/` | the mod: reads vehicle data, writes JSON lines to the pipe |
| `relay/` | `wheelffb-relay.exe` (Rust): pipe to WebSocket, can also start the game |
| `launch/` | Steam launch wrapper (Linux) and a starter for Windows |

The mod only reads values FS22's own scripts use. Each one was checked against the game's Lua
source from the GIANTS SDK (`sdk/debugger/gameSource.zip`), which isn't included here.

## Writing a mod for another game

The FFB server isn't tied to FS22. The protocol and examples are in
[ffb-server/docs/FFB-SERVER.md](https://github.com/egeSlop/ffb-server/blob/main/docs/FFB-SERVER.md).
If your game also can't open sockets, this relay works for it too: write JSON lines to
`\\.\pipe\WheelFFB`.

## License

MIT. The code was vibecoded with Claude (Anthropic) and tested on one wheel and one PC.
