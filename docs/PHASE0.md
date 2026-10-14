# Phase 0: supervised hardware test

Everything in FanPilot's fan control rests on one assumption that only hardware can confirm (SPEC risk
R1): that the Mac honors a write of `F0md = 1` plus `F0Tg = <rpm>` and keeps honoring it, without a
test-mode unlock. The unit tests prove the logic against a simulated SMC; only this test proves the
hardware. Run it on any Mac model you have not tried before, and before relying on fan control.

**Status:** this procedure has been run successfully on a MacBook Pro M5 Pro (`Mac17,8`, macOS 27): manual
mode held without `Ftst`, the fan followed the target, and release returned it to the system. The sample
outputs below come from that machine unless they say otherwise.

The test writes SMC fan keys, so it needs root and a person at the keyboard. Run it yourself, supervised.

## What it does to your Mac

`fanpilotctl selftest` takes **fan 0 (the left fan)** and
1. puts it in manual mode with no target (2 s) and checks that macOS does not take it back,
2. sets a target of minimum + 10 % of the range (about **1750 RPM**) for 15 s and samples the real speed,
3. gives the fan back to the system and checks that it stays there.

Total about 25 s; you will hear the left fan spin up a little. It will not run if the hot set is above
80 C, aborts and releases if it reaches 90 C, and releases on Ctrl-C and on every error path. Fan 1 is
never touched. It uses the same `FanWriter` code the helper uses, so a pass validates the real thing.

## Before you start

1. **Quit any other fan-control utility** (for example Macs Fan Control, smcFanControl, iStat Menus or any
   similar app that can set fan speeds). Two controllers fight over the same keys and the result is
   meaningless. Check:
   ```sh
   pgrep -fli "Macs Fan|smcFanControl|iStat|FanControl" || echo "no other fan tool running"
   ```
2. Let the Mac idle for a minute (nothing heavy running; Xcode builds count) and stay at the machine.
3. Open a **second Terminal window** in the repository root and keep this command ready, it undoes
   everything:
   ```sh
   sudo .build/release/fanpilotctl auto all
   ```

## 1. Build the two binaries

```sh
cd FanPilot        # the repository root; every command below runs from here
swift build -c release --product fanpilotctl --product fanpilotd
```

Expected last line: `Build complete!`

## 2. Look before you touch (no sudo)

```sh
.build/release/fanpilotctl list
```
```
#   Name         Backend          Min   Max   Now    Target Mode
0   Left Side    appleSiliconMd F0md 1350  5349  0      0      auto
1   Right Side   appleSiliconMd F1md 1350  5777  0      0      auto
```
`Now` may show about 1350 if macOS happens to run the fans. If a fan says `monitor only`, stop: the
helper's strict discovery found no safe way to drive it and the reason is printed.

```sh
.build/release/fanpilotctl smc-read FNum F0Tg F0md F0Mn F0Mx DICT Ftst
```
```
FNum  type ui8  (75693820)  size 1  attr 0x80 R-  raw 02  = 2.0
F0Tg  type flt  (666c7420)  size 4  attr 0xd4 RW  raw 00000000  = 0.0
F0md  type ui8  (75693820)  size 1  attr 0xd0 RW  raw 00  = 0.0
F0Mn  type flt  (666c7420)  size 4  attr 0x84 R-  raw 00c0a844  = 1350.0
F0Mx  type flt  (666c7420)  size 4  attr 0x85 R-  raw 0028a745  = 5349.0
DICT  type flag (666c6167)  size 1  attr 0xc0 RW  raw 00  = false
fanpilotctl: SMC key Ftst not found
```
`Ftst` is absent on this Mac (that is expected on M5-class Macs, see SPEC 2.3). `F0Tg`/`F0md` must show `RW`
and `F0Mn`/`F0Mx` must show `R-`; the helper never writes limits.

```sh
.build/release/fanpilotctl watch --count 1
```
```
20:14:15   Highest 45.3 C   CPU 45.3 C (avg 42.8 C)   failsafe hot set 53.6 C
  Left Side  1351 RPM  target  1350  auto  [1350-5349]
  Right Side  1460 RPM  target  1458  auto  [1350-5777]
```
The `failsafe hot set` figure is what the helper's thermal failsafe watches. It must be well under 80 C
(it is about 55 C at idle here).

## 3. The self-test

```sh
sudo .build/release/fanpilotctl selftest
```
It explains itself, then waits: type `yes` to continue (`--yes` skips the question). Expected output on a
Mac that cooperates (shown here from the simulator; your numbers and temperatures will differ, and the
speed climbs over a few seconds instead of jumping):

```
== (a) read-only state ==
[info ] topology: FNum 2, Ftst absent, DICT present
[info ] fan 0: appleSiliconMd mode key F0md limits 1350...5349 RPM
[info ] current: actual 0 RPM, target 0, auto
[info ] hot set: hottest 54.4 C over 79 sensors (TVD0)
== (b) manual mode ==
[PASS ] mode right after the write: reads 1
[PASS ] mode after 2.0 s: still manual: the OS did not revert it
== (c) spin up ==
[info ] target: 1750 RPM (minimum + 10 % of the range)
  t= 0.0 s  actual     0 RPM  target  1750  mode 1  hot set 54.4 C
  t= 0.5 s  actual   310 RPM  target  1750  mode 1  hot set 54.4 C
  ...
  t=15.0 s  actual  1748 RPM  target  1750  mode 1  hot set 54.9 C
[PASS ] peak actual speed: 1752 RPM against a target of 1750
== (d) release ==
[PASS ] mode after release: reads 0 (auto)
[PASS ] mode 2.0 s later: reads 0
[info ] actual speed afterwards: 1190 RPM (the system takes over from here)
[PASS ] verdict: PASS: manual mode holds, the fan follows the target, and release returns it to the system

Verdict: PASS: manual mode holds, the fan follows the target, and release returns it to the system
```

What each step settles:

| Step | Question | Why it matters |
|---|---|---|
| (b) right after | Does the SMC accept `F0md = 1` at all, without `Ftst`? | SPEC R1 |
| (b) after 2 s | Does `thermalmonitord` take manual mode away again? | SPEC R1/R2 |
| (c) peak speed | Does `F0Tg` actually move the fan in manual mode? | whole product |
| (c) `OS interference` line (if any) | Does anything change mode or target behind our back? | sizes the 1 Hz reassertion loop |
| (d) | Does `md = 0` hand control back, and does it stay? | safety |

### If it does not pass

| You see | Meaning | What to do |
|---|---|---|
| `refusing ... above the 80 C limit` / `let it cool down` | Precondition, nothing was written | Wait, retry |
| `the fan is already in manual ...` | Another tool or an earlier run holds the fan | `sudo fanpilotctl auto all`, then retry |
| `the SMC rejected manual mode: ...` | The write was refused; the message carries the SMC result byte | Keep the transcript. Control would be monitor-only |
| `RISK R1 confirmed: ... takes manual mode away again` | macOS reverts `F0md`. The app can still monitor; control needs another unlock | Keep the transcript, tell the team |
| `the fan never responded to the target` | Mode accepted but the speed never rose (R1/R2) | Keep the transcript; try once more after a cool-down |
| `aborted: the machine got too hot` / `lost sight of the temperatures` | Safety stop; the fan was released | Check `fanpilotctl watch --count 1`, retry when cool |
| `FAIL: the fan could not be returned to auto` / `the fan is STILL in mode 1` | **Release failed** | Immediately `sudo fanpilotctl auto all`. If that also fails, restart the Mac: the SMC resets fan control at boot |

After any run, check the fans are back with the system:
```sh
.build/release/fanpilotctl list      # Mode must say "auto" for both fans
```

## 4. Record the outcome

Paste the transcript below (or attach it) and fill in the table. This is the evidence needed to decide
between full control and monitor-only on a given Mac (SPEC 2.10, R1). The `Mac17,8` run passed.

| | |
|---|---|
| Date | |
| Mac / macOS | model from `sysctl -n hw.model`, macOS version from `sw_vers` (verified: Mac17,8 / macOS 27) |
| `selftest` verdict | PASS / FAIL (which step) |
| Mode held after 2 s | yes / no |
| Peak RPM vs target | |
| OS interference lines | none / n of 31 samples |
| Anything odd (fan noise, DICT value, Ac > 0 in auto before the test) | |

## 5. End-to-end test of the helper (only after PASS)

Install the daemon (this is the only step that changes the system beyond the test):
```sh
sudo scripts/install_helper.sh        # from the repository root
```
Expected tail:
```
==> checking install locations
==> writing the helper config
    wrote /Library/Application Support/FanPilot/helper.json (uid 501, failsafe 95 C, lease max 30 s, auth uid)
==> installing .../.build/release/fanpilotd -> /Library/PrivilegedHelperTools/com.fanpilot.helper
==> installing .../.build/release/fanpilotctl -> /Library/PrivilegedHelperTools/fanpilotctl
==> writing /Library/LaunchDaemons/com.fanpilot.helper.plist
==> starting the helper
==> waiting for the socket (the helper scans about 3600 SMC keys at start)
fanpilotd 1.0.0 answered in 1.9 ms (protocol 1, 2 fan(s), failsafe 95 C, lease max 30 s)

FanPilot helper installed and running.
```
Then, as your normal user (no sudo):
```sh
fanpilotctl daemon-ping                 # "answered in N ms"
fanpilotctl status                      # both fans: Held "no", Mode auto, Failsafe: inactive
fanpilotctl set 0 50% --hold 30         # terminal 1: holds fan 0 at 50 % of its range for 30 s
fanpilotctl watch                       # terminal 2: Left Side speeds up, Mode manual; after 30 s back to auto
```
`set` prints `fan 0: 3350 RPM` and `Fans returned to automatic control.` at the end. `status` while it holds
shows `Held yes` and a lease of about 15 s that the CLI renews every 5 s. Log: `tail -f /var/log/fanpilot.log`.

Failure-path checks (SPEC 8.3). In each case the fan must be back to `auto` afterwards; verify with
`fanpilotctl list`.

| Test | Command | Expected |
|---|---|---|
| Client crashes | start `fanpilotctl set 0 50% --hold 60`, then `kill -9 <its pid>` in another terminal | fan 0 back to auto within a second (connection closed) |
| Client hangs (lease watchdog) | start the same, then `kill -STOP <pid>` | fan 0 back to auto 15-20 s later: `lease expired` in the log. Then `kill -9 <pid>` |
| Daemon crashes | start the same, then `sudo pkill -9 fanpilotd` | launchd restarts it within about 10 s; `smc-read F0md` shows `raw 00`; log shows `startup` release |
| Stop/uninstall | `sudo launchctl bootout system/com.fanpilot.helper` while a hold is running | fan back to auto immediately (`received signal 15` in the log) |
| Sleep | start `set 0 50% --hold 300`, then `pmset sleepnow`, wake the Mac | log shows `system will sleep` + release; the hold ends with "lost control"; fans are in auto |

**Thermal failsafe on real hardware.** The configured trigger cannot go below 85 C (a damaged config
must not weaken it), and nothing heats this Mac to 85 C on demand, so the helper has a foreground test
switch that lowers the trigger. The failsafe always errs towards cooling: it forces BOTH fans to
maximum, so expect it to get loud.

```sh
sudo launchctl bootout system/com.fanpilot.helper            # stop the installed daemon (fans go to auto)
fanpilotctl watch --count 1                                   # note "failsafe hot set", e.g. 54 C
sudo .build/release/fanpilotd --failsafe-test 50 --verbose    # terminal 1, foreground; 50 = about 4 C below that figure
```
The failsafe needs two hot samples in a row (a one-sample sensor spike is ignored on purpose), so the
first `set` is accepted: its own look at the hot set is only the first sample. About a second later the
helper takes the second one and forces both fans to maximum. In terminal 2:
```sh
fanpilotctl set 0 30% --hold 20      # accepted at first; within seconds both fans jump to maximum and the
                                     # command may end early with "lost control ... the failsafe tripped"
fanpilotctl status                   # THERMAL FAILSAFE ACTIVE (hot_sensor, ...) and both fans near their maximum
fanpilotctl set 0 30% --hold 20      # now refused: failsafe_active ... fans are forced to maximum
```
(`status` and `hello` do not sample the hot set, so a plain `status` alone does not start the
confirmation; a `set` does.)

Back in terminal 1, press **Ctrl-C**: the log shows `received signal 2: releasing all fans and exiting`
and both fans return to auto. (Clearing needs the hot set 7 C below the trigger for 10 s; the unit tests
cover that path.) Finally restart the real daemon:
```sh
sudo scripts/install_helper.sh
```

## Recovery and removal

| Situation | Command |
|---|---|
| Any fan looks stuck or loud and you want the system back in charge | `sudo fanpilotctl auto all` (talks to the helper; if the helper is not running it writes the fan modes itself) |
| Same, but the helper misbehaves | `sudo fanpilotctl auto all --direct` |
| Remove FanPilot's helper completely | `sudo scripts/uninstall_helper.sh` (from the repository root) (stops the daemon, which releases the fans; then runs `fanpilotctl auto all --direct` as a second check; add `--purge` to delete config and log too) |
| Nothing else works | Restart the Mac. The SMC resets fan control at boot, and every helper start returns all fans to auto before serving anyone |

`fanpilotctl` is installed to `/Library/PrivilegedHelperTools/fanpilotctl` (and linked as
`/usr/local/bin/fanpilotctl` when that directory is root-protected). Before the helper is installed use
`.build/release/fanpilotctl`.

The daemon itself never leaves fans in manual mode on purpose: it releases on client disconnect, lease
expiry (15 s default, 30 s max), SIGTERM/SIGINT/SIGHUP/SIGQUIT, system sleep, ten seconds without a
readable temperature, and at every start.
