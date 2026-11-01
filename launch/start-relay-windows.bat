@echo off
rem FS22 force feedback on Windows (UNTESTED).
rem 1. Open V987 Wheel Studio (its FFB server must be running) or run ffb-server.exe.
rem 2. Run this file, then start Farming Simulator 22 with the Wheel Force Feedback mod enabled.
rem    Turn FS22's own force feedback off.
"%~dp0wheelffb-relay.exe"
