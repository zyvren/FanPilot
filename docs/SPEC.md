# FanPilot - Design and Specification

A menu-bar fan and temperature monitor for Apple Silicon Macs, with a small root helper that is the only component allowed to write fan keys.

Target: Apple Silicon Macs on macOS 14 or later. Developed and verified on a MacBook Pro M5 Pro (`Mac17,8`) running macOS 27. Other Apple Silicon models use the same code paths but are not verified. Intel Macs are a secondary target and untested.

Conventions: "measured" means read from a live machine, always the MacBook Pro M5 Pro (`Mac17,8`) unless stated otherwise. Anything that could not be checked is marked UNKNOWN or UNTESTED. Section numbers in this document are cited from the source code (`docs/SPEC.md N.N`); keep them stable.

---------------------------------------------------------------------------
## 1. Goals and non-goals

Goals
1. Menu-bar app showing temperatures and fan RPM, with per-fan adjustable speed (Auto / Manual RPM or % / Max / Auto Boost rules / Curve).
2. Safe by construction: a root helper is the only SMC writer, clamps every target, leases every claim, and restores automatic control on every failure path.
3. Pure SwiftPM build (`swift build`), `.app` bundle assembled by script, ad-hoc signing only.

Non-goals (v1): Developer ID signing, SMJobBless/SMAppService daemons, SMART disk temperatures, CPU-throttle "fixes", Intel Power Gadget, licensing or activation.

---------------------------------------------------------------------------
## 2. SMC protocol

### 2.1 Access path
- `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))`, then `IOServiceOpen(svc, mach_task_self(), 0, &conn)`.
- All operations: `IOConnectCallStructMethod(conn, 2, &in, 80, &out, &80)` with the same 80-byte struct for input and output.
- Reads work unprivileged. Writes are only ever sent by the root helper (and by `fanpilotctl` when run as root for recovery and the hardware self-test). A connection opened read-only can never send the write command: the C layer's read entry point refuses it.
- Struct `SMCKeyData_t` (size 80, offsets static-asserted in the C target):

| off | size | field |
|---|---|---|
| 0 | 4 | key, big-endian packed 4CC (`'F'<<24 \| '0'<<16 \| 'T'<<8 \| 'g'`) |
| 4 | 6(+pad) | vers (unused) |
| 12 | 16 | pLimitData (unused) |
| 28 | 4 | keyInfo.dataSize |
| 32 | 4 | keyInfo.dataType (big-endian 4CC) |
| 36 | 1 | keyInfo.dataAttributes (0x80 readable, 0x40 writable) |
| 40 | 1 | result (0 = ok; non-zero = SMC error, e.g. 0x82, 0x85, 0x89 seen on unreadable keys) |
| 41 | 1 | status |
| 42 | 1 | data8 = command |
| 44 | 4 | data32 (key index for command 8) |
| 48 | 32 | bytes (payload) |

- Commands: 9 = keyInfo, 5 = read, 6 = write, 8 = key by index (data32 = index). `#KEY` (ui32, big-endian) gives the key count (3626 on the measured machine).
- READ(key): zero the struct; set the key; command 9 gives size, type and attributes; set dataSize from the keyInfo; command 5 returns bytes[0..size). keyInfo is cached per key for reads (halves the number of calls). Both the IOReturn and `result == 0` are checked; on failure the read reports an error.
- WRITE(key, bytes): zero the struct; re-read keyInfo live (never from the cache); REFUSE if the live `dataSize != bytes.count` or the attributes lack 0x40; copy the bytes; set dataSize; command 6. The dataType field is left zero in write requests. Both the IOReturn and the `result` byte are checked, and `FanWriter` then reads the value back and compares it. A mis-sized write, or a write to a missing key, is otherwise a silent no-op on this interface, which is why the explicit guards exist.
- All SMC calls on one connection are serialized on one serial queue.

### 2.2 Type encodings
| type | decode | notes |
|---|---|---|
| `flt ` | float32, little-endian | all `T*` temperatures and `F*Ac/Mn/Mx/Tg` on Apple Silicon |
| `ui8 ` | 1 byte | `FNum`, `F*md`, `F*St`, `Ftst` |
| `ui32` | big-endian for `#KEY` | integer endianness is not uniform across keys; only `#KEY` (BE), `flt ` (LE), `sp78` and `fpe2` (BE) are decoded. Other integers are treated as opaque |
| `sp78` | BE int16 / 256 | Intel temperatures |
| `fpe2` | BE uint16 / 4 (RPM) | Intel fans; encode `(rpm<<2)&0xffff` big-endian |
| `ioft`, `si32`, others | not usable as temperature | |

Fan RPM write for `flt `: `Float(rpm)` bit pattern, little-endian, 4 bytes. Client-supplied values are rounded to whole RPM before they are clamped and written.

### 2.3 Fan keys measured on a MacBook Pro M5 Pro (`Mac17,8`)
| key | type/size | attr | role | notes |
|---|---|---|---|---|
| `FNum` | ui8 = 2 | 0x80 | fan count | |
| `F0Ac`/`F1Ac` | flt | 0x84 ro | actual RPM | 0.0 at idle is legitimate: the fans stop on this model |
| `F0Mn`/`F1Mn` | flt 1350 | 0x84 ro | minimum RPM | not writable here. FanPilot never writes `Mn` |
| `F0Mx`/`F1Mx` | flt 5349 / 5777 | 0x85 ro | maximum RPM | hidden-but-readable attribute |
| `F0Tg`/`F1Tg` | flt | 0xd4 rw | target RPM | written as `flt ` because the key type is `flt ` |
| `F0md`/`F1md` | ui8 | 0xd0 rw | fan mode, 0 = auto, 1 = manual | lowercase `md` is the mode key on this machine |
| `F0St`/`F1St` | ui8 = 3 | 0x80 ro | UNKNOWN meaning | never written |
| `Ftst`, `F0Md`, `FS! `, `F%dID`, `F%dSf` | absent | - | legacy, T2 and Intel keys | their absence selects Backend A without the test-mode step (2.6) |
| `DICT` | flag, value 0 | 0xc0 rw | believed to mean "the OS is temporarily backing the fans off" | exact semantics unconfirmed; FanPilot does not reassert while it reads 1 (2.9) |
| `FBAD` | hex_ = 0 | - | bad-fan bitmask | |

### 2.4 Ambiguities and design decisions
1. **CPU key roles.** Guessing roles from key-name prefixes is unreliable. On the `Mac17,6-9` generation the measured topology is 6 "Super" cores and 12 "Performance" cores (`sysctl hw.perflevel*`), and the sensor table (3.2) assigns `Tp04, Tp0G, Tp0R, Tp0a, Tp0j, Tp0u` to Super cores 1-6 and `Tm04 ... Tm2P` to Performance cores 1-12. The `Tm` keys track CPU load strongly. `Ts0P`/`Ts1P` are palm-rest sensors; the other `Ts00..Ts0a` keys stay in "Other".
2. **Mode key case.** The mode key is `F<n>md` (lowercase) on this machine; the uppercase `F<n>Md` is absent. FanPilot reads back exactly the key it writes, so verification cannot silently look at a different key. `F<n>Md` is accepted as a fallback mode key when `F<n>md` is missing (2.6).
3. **`F<n>Mn` is not writable** (attribute 0x84) and FanPilot never tries; minimum speed is enforced by clamping targets.
4. **Valid temperature range.** A temperature reading is valid iff its type is `flt `, `10 <= v < 125`, and its key is not in the exclusion list (2.5). Values at or above 125 are "invalid" for display (shown as N/A) but are treated as failsafe-triggering when they come from a classified hot-set sensor: the helper errs towards cooling.
5. **Invalid readings are shown as N/A.** FanPilot never substitutes a made-up value for a sensor that returns nothing usable.
6. **HID duplicates.** Each PMU `tdie` service appears three times with a 0.1 to 0.8 C spread. FanPilot dedupes by (Product, LocationID) and keeps the maximum.
7. **Under load nothing spins.** Measured: the hottest sensor reached 69-71 C under a sustained load while the fans stayed at 0 RPM, so the system's own curve is lazy on this model. FanPilot's default rules therefore start well below 70 C (5.3).
8. **`F0St = 3`** is read-only and its meaning is unknown. FanPilot only ever writes 0 and 1 to the mode key.
9. **Float versus fixed-point targets.** The target encoding (`flt ` or `fpe2`) is decided per fan from the live key type at takeover time, and the size is re-validated on every write.

### 2.5 Unusable / excluded keys (measured)
`ioft` keys (`TG0B`, `TR0Z`, `TR1d`, `TR2d`, ...), `TV?i` (si32), `TTPD` (garbage), `TVMD` (constant 4.0), `Tz11..Tz1j`, `TfCB` (zero). `Ta00, Ta04, Ta08, Ta0K, Ta0O, Ta0R` all report the same value (43.39 at the time of measurement); they are kept, grouped under "Other", and collapsed in the UI.

### 2.6 Backends (the helper selects one per fan)
Discovery runs once at helper start and again after wake; no key enumeration is needed. It reads `FNum`, then for each fan `i` in `0..<min(FNum, 10)` (the fan number is a single digit in the key name) the keyInfo of `F{i}Tg`, `F{i}Mn`, `F{i}Mx`, `F{i}Ac`, `F{i}md`, `F{i}Md`, plus the globals `Ftst`, `FS! ` and `DICT`.

**Backend A: AppleSilicon-md (the measured machine).** Condition: `F{i}Tg` has type `flt ` and size 4, AND either `F{i}md` is ui8, size 1, read-write (then modeKey = `F{i}md`) or `F{i}Md` is ui8, size 1, read-write (then modeKey = `F{i}Md`).

**Backend B: Intel-forced (secondary, UNTESTED).** Condition: `F{i}Tg` has type `fpe2` (size 2) and `FS! ` is a ui16. Takeover: read `FS! ` big-endian, set bit `i`, write it back; write `F{i}Tg` as `fpe2`. Release: clear bit `i` (read-modify-write). T2 Intel Macs that expose `F{i}Md` use Backend A semantics with the `fpe2` target encoding.

If no backend matches, fan control is disabled and the app runs in monitor-only mode and says why.

### 2.7 Takeover sequence (Backend A)
Order: unlock (if the Mac needs it), manual mode, then target. All limits come from the SMC, never from the client.
```
takeover(fan i, rpm):
  0. orig = {md: read modeKey, tg: read F{i}Tg}   // captured ONCE per ownership, for restore
  1. rpm = clamp(round(rpm), Mn_i, Mx_i)          // Mn/Mx read live from the SMC
  2. if Ftst exists (older Apple Silicon Macs need test mode first): write Ftst=1 (ui8)
  3. write modeKey = 1 (ui8); read back; retry up to 8x with 250 ms backoff until readback == 1
       if still != 1 and Ftst exists: re-write Ftst=1 and retry (thermalmonitord may reclaim the fan)
       if still != 1: release(i), return error "mode_rejected" (include the SMC result byte)
  4. write F{i}Tg = Float32 LE(rpm); read back; |read - rpm| <= 1.0 required (3 attempts, 100 ms apart), else error "target_rejected"
  5. owned[i] = {rpm, since}; start/keep the 1 Hz maintenance loop
set_target(i, rpm): clamp -> write F{i}Tg (mode must already be 1) -> read back
```
Idempotence: if `md` already reads 1 and FanPilot owns the fan, step 3 is skipped. If the fan is owned, the new target equals the last applied one, the mode reads 1 and the target reads back within 1 RPM, nothing at all is written. The app re-sends its target with every heartbeat to renew the lease, and rewriting an unchanged value would only add SMC traffic and a log line every 5 s for as long as a fixed speed is held.

A fan that was switched to manual mode but whose target could not be written is switched back to auto immediately: manual mode with a zero target would stop the fan.

### 2.8 Restore-to-auto sequence
```
release(i):
  1. if modeKey already reads 0: nothing to undo, skip the write
     else write modeKey = 0 (ui8); read back == 0   // FIRST: this is the safety-critical write
        up to 5 attempts, 200 ms apart
  2. best effort: write F{i}Tg = orig.tg (0.0 here), only if a target was written - failure ignored (the firmware ignores it in auto)
  3. if no fan is owned any more AND Ftst=1 was written: write Ftst=0
  4. Backend B: the bit in FS! is cleared by step 1
  5. owned[i] = nil
```
The mode byte goes back to auto before anything else, and every write is verified. If the readback still is not 0 after the attempts, the release stays "pending": a CRITICAL log line is written once, and the release is retried every tick (1 s) until it sticks. A fan with a pending release must be released successfully before it can be taken again.

Recovery: at startup, on wake and on `auto all`, every fan that has a writable mode key and is not in auto is released, whatever discovery concluded (writing mode 0 is always safe). A leftover `Ftst = 1` is cleared when no fan is owned.

### 2.9 Reassertion
The helper's loop runs at 1 Hz while any fan is owned: it reads `modeKey` and `F{i}Tg`. If `DICT` exists and reads 1, the check is skipped (logged once). If `md != 1` or `|Tg - rpm| > 2`, the values are rewritten (steps 3-4 of 2.7, 3 attempts 100 ms apart) and a correction is counted. If 10 corrections happen inside 60 s, the fan is released and `os_override` is reported to clients; new takeovers of that fan are refused for 60 s (do not fight the OS indefinitely). While the thermal failsafe is active the helper never gives up, because holding maximum is the point. A `0` RPM `Ac` is not a fault on the Mac17,6-9 generation.

### 2.10 Phase 0 hardware validation
Whether a given macOS / firmware combination honors a manual-mode write without `Ftst` cannot be derived from documentation; it has to be tested on the machine. `fanpilotctl selftest` (root, supervised) does so with the same `FanWriter` the helper uses. It refuses to start if the hot set is above 80 C, aborts and releases at 90 C, and releases on every exit path:
(a) read-only dump of the fan keys and the hot set;
(b) write `F0md=1` only, read back, wait 2 s, read back again (does the OS revert it?);
(c) set `F0Tg = Mn + 10 %` of the range and sample `F0Ac` every 500 ms for 15 s (it must rise above 0);
(d) release; verify `md == 0` and that it stays there.
The procedure is in `docs/PHASE0.md`. If (b) fails with `Ftst` absent, the fallback is monitor-only mode (risk R1).

Result: the self-test passes on a MacBook Pro M5 Pro (`Mac17,8`, macOS 27): manual mode holds without `Ftst`, the fan follows `F0Tg`, and release returns it to the system. Manual mode, Max and the thermal failsafe (run with a lowered trigger, 8.3) have been exercised on that machine, with the failsafe driving both fans to their maximum.

---------------------------------------------------------------------------
## 3. Temperatures

### 3.1 Sources (all unprivileged)
1. **SMC**: enumerate once with `#KEY` plus command 8 (3626 keys on the measured machine), keep keys starting with `T` or `f`/`s` of type `flt ` (and `sp78` on Intel) that are valid per 2.4 #4. Re-enumerate on wake and every 10 minutes. keyInfo is cached.
2. **IOHID**: `IOHIDEventSystemClientCreate`, matching `{PrimaryUsagePage:0xff00, PrimaryUsage:5}`; per service read the `Product` property and `IOHIDServiceClientCopyEvent(svc, 15 /*temperature*/, 0, 0)`, then `IOHIDEventGetFloatValue(ev, 15<<16 = 0xf0000)`. These are private symbols: they are resolved with `dlsym` from IOKit and declared in the C target; if any is missing, HID sensors silently disappear and the app keeps working with SMC only. Rules:
   - rename the six services called `gas gauge battery` to `gas gauge battery N`, ordered by LocationID so the names are stable;
   - drop `PMU tdev*` (about -9200, a "no data" sentinel) and `PMU tcal` (constant 51.82);
   - dedupe by (Product, LocationID) taking the maximum;
   - keep `PMU tdie1..14` (real die temperatures: 40 C idle, 51-62 C loaded, measured), `NAND CH0 temp` and `gas gauge battery N`; skip `als-temp`.
   FanPilot exposes the `PMU tdie*` sensors as the "SoC Die" area; they are also part of the failsafe hot set.
3. IOReport, IOAccelerator and SMART are not used.

### 3.2 Sensor catalog for Mac17,6/7/8/9 (M5 Pro / Max)
Of the 38 SMC keys in this table, 37 exist on the measured `Mac17,8` (`Tg50` is absent). The table is code, in `CatalogData.swift`.

| area | label | keys |
|---|---|---|
| CPU | Super Core 1-6 | Tp04, Tp0G, Tp0R, Tp0a, Tp0j, Tp0u |
| CPU | Performance Core 1-12 | Tm04, Tm0G, Tm0R, Tm0a, Tm0j, Tm0u, Tm1Q, Tm1c, Tm1o, Tm21, Tm2D, Tm2P |
| GPU | GPU Region 1-4 (+5,6 if present and valid) | Tg08, Tg12, Tg29, Tg3B (+Tg43, Tg50) |
| Battery | Battery, Battery Management Unit, Battery Proximity, Battery Gas Gauge | TB0T, TB1T, TB2T; HID `gas gauge battery 0` |
| Logic Board | Airflow Left, Airflow Right, Airflow Top | TaLP, TaRF, TaTP |
| Storage | SSD, SSD (NAND I/O) | TH0a; HID `NAND CH0 temp` |
| Power | Charger Proximity, Power Supply Proximity | TCHP, TPSP |
| Thunderbolt | Left / Right Thunderbolt Ports Proximity | TaLT, TaRT |
| Palm Rest | Trackpad, Trackpad Actuator | Ts0P, Ts1P |
| Wireless | Wireless Proximity | TW0P |
| SoC Die | PMU tdie 1-14 (HID) | deduped |
| Other | every other valid T/f key | TCMb, TVD0 (hottest under load, 69 C), TPD*, TRD*, TUD*, Tg*, Ta*, ... |

Idle values (measured): cores about 41-43 C, +14..+21 C under load; battery about 32.7; SSD about 37; airflow and palm rest about 30-32. The table accounts for about 36 SMC sensors plus 2 HID sensors.

### 3.3 Classification for models without an exact table
Order: (1) an exact model table in code (`SensorCatalog.swift` / `CatalogData.swift`, seeded with `Mac17,6-9` above; more models are added as data); (2) heuristics by key prefix and CPU topology from `sysctl hw.perflevel{0,1}.name/physicalcpu` ("Super"/"Performance" means `Tp` + `Tm` are cores; "Performance"/"Efficiency" means `Tp`/`Te`/`ft??`/`sd??` per generation): `Tp*`, `Te*`, `ft[EP]*`, `sd*`, `Tm*` (only if the perflevel names are Super/Performance) -> CPU; `Tg*`, `ftG*` -> GPU; `TB*T` -> Battery; `Ta*` -> Airflow; `TH*`, `TN*` -> Storage; `TC*`, `TP*` -> Power; `Ts*P` -> Palm; `TW*` -> Wireless; `TV*`, `TR*`, `TU*`, `TD*`, `TPD*` -> SoC/Other; (3) everything else "Other". The area is never inferred from the prefix alone across generations (`Tm` flips from Memory on M1/M2 to CPU on M5). The heuristics are bounded by the topology: a numbered core family never has more rows than the matching `hw.perflevel` has cores (the surplus keys go to "Other"; the M5 Pro exposes 23 `Tp`, 40 `Tm` and 111 `sd` keys for 18 cores), GPU and memory families are capped at 16 rows, and `TS0P` / `TS1P` stay in "Other" (a different sensor from `Ts0P` / `Ts1P`).

### 3.4 Aggregates
Computer Average (mean of valid curated sensors), Highest (max of valid curated sensors), Average CPU (mean of the CPU area), Highest CPU (max of the CPU area). Values stay floating point. "Valid" includes the HID "SoC Die" sensors, so Highest can be a die sensor; the curated list excludes "Other". If the CPU area is empty, the CPU aggregates fall back to SoC Die and then to Highest.

The failsafe hot set covers CPU, GPU, SoC Die and the SoC-related "Other" rails (`TVD*`, `TCMb`, `TPD*`, ...), and excludes battery, airflow, palm rest, wireless and storage. The helper reads it with two independent classifiers and takes the hottest value either one sees: the catalog-based CPU, GPU and SoC Die areas, and an explicit scan of the key prefixes `Tp, Te, Tm, Tg, TC, TVD, TPD, TRD, TUD` and the capital-G GPU variant used on Intel (minus the charger and power-supply keys `TCHP` and `TPSP`) plus the HID die sensors, sampled evenly over large families (at most 12 keys per prefix). A classification mistake in either one cannot hide a hot sensor, and the failsafe is blind only if both are. Readings at or above 125 C count (they are exactly what the failsafe must not ignore); sentinels (zero, 4.0, -9200) and values of 400 C and more are discarded as garbage. Limit-like constants in the "Other" group (`TVMX`, `TVms` and `ftRf` all read exactly 61.0 on the M5 Pro) are deliberately not part of the catalog-based hot set.

### 3.5 Cadence
`updateIntervalSecs` default 2, minimum 1, on a background queue; the UI is updated on main. Measured cost on the M5 Pro: an SMC read is about 0.17 ms, the "Other" group about 60 ms and an HID pass about 80 ms. This led to a `PollingPolicy` instead of one SMC pass and one HID pass per tick: the curated SMC sensors and the fans are read every tick; the HID pass every 4 s; the "Other" group every 10 s, except the 12 hottest failsafe-relevant "Other" sensors, which are read every tick. Sensors the user depends on (menu bar slots, pins, Boost rules, the curve source) are exempt: `SensorEngine.setPriorityIDs` makes them, and an HID pass for HID-backed ones, run every tick whatever their group. The helper's failsafe has its own 1 s hot-set reads and is not affected. Sensors are paused for 5 s after wake. The session maximum is tracked per sensor. There is no temporal smoothing for display; Curve mode has its own EMA.

---------------------------------------------------------------------------
## 4. Architecture

### 4.1 Processes
```
FanPilot.app (user, menu-bar, SwiftUI)  --- Unix socket NDJSON --->  fanpilotd (root LaunchDaemon)  ---> AppleSMC
fanpilotctl (CLI, user or root)         --- same socket --------->        |
                                                                           +-- reads temps itself for the failsafe
```
Ad-hoc signing constraint (no Developer ID): SMJobBless and SMAppService daemons are not viable, so the daemon is installed by `scripts/install_helper.sh` run with sudo. An XPC Mach service declared in the LaunchDaemon plist also works with ad-hoc signing and could pin the peer with `xpc_connection_set_peer_code_signing_requirement("cdhash H\"...\"")`, but it is harder to test from a shell. A Unix domain socket was chosen (testable with `nc -U`); the transport sits behind a protocol so XPC can be added.

### 4.2 Install layout (root-owned, not user-writable; the install script verifies parent directories and refuses otherwise)
- `/Library/PrivilegedHelperTools/com.fanpilot.helper` (root:wheel 0755), ad-hoc signed.
- `/Library/LaunchDaemons/com.fanpilot.helper.plist` (root:wheel 0644): `Label`, `ProgramArguments`, `RunAtLoad true`, `KeepAlive true`, `ProcessType Background`, `StandardErrorPath /var/log/fanpilot.log`, `ExitTimeOut 10`.
- `/Library/Application Support/FanPilot/helper.json` (root:wheel 0644): `{"allowedUIDs":[501],"authMode":"uid"|"pinned","pinnedCdhashes":[...],"failsafeTempC":95,"leaseMaxSeconds":30,"socketPath":"/var/run/fanpilot.sock"}`. Edited only via the install script or sudo. A damaged file fails closed (nobody but root may connect).
- Install: `launchctl bootstrap system <plist>`; uninstall: `launchctl bootout`, the helper restores auto on SIGTERM, then the files are removed.
- Socket `/var/run/fanpilot.sock` is created by the helper with mode 0666 (peers are checked, see 4.3); the parent directory is root-owned.

### 4.3 Peer authorization
FanPilot is ad-hoc signed, so there is no team ID to check. On `accept`: `getsockopt(LOCAL_PEERCRED)` gives the uid, which must be root or in `allowedUIDs`; `LOCAL_PEERPID` plus `proc_pidpath` give the process for the log. `authMode`:
- `uid` (default): uid check only. Weak against same-user malware; the blast radius is bounded by clamping, leases and the failsafe.
- `pinned`: additionally `LOCAL_PEERTOKEN` -> `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` -> `SecCodeCopySigningInformation`; the cdhash must be in `pinnedCdhashes` (the install script computes the cdhashes of the installed app and CLI; reinstall after each rebuild because an ad-hoc cdhash changes). Checked once per connection.

A connection must send `hello` within 2 s or it is closed. At most 4 concurrent connections. Maximum line length 64 KiB. All numbers are validated (finite, in range).

### 4.4 Wire protocol (NDJSON, one JSON object per line; every request gets exactly one reply)
Request: `{"id":N,"op":"...",...}`; reply: `{"id":N,"ok":true,...}` or `{"id":N,"ok":false,"err":"code","msg":"..."}`. Replies also echo `op`, and decoders ignore unknown keys.

| op | params | effect / reply |
|---|---|---|
| `hello` | `proto:1, client` | `helper version, fans:[{index,name,minRPM,maxRPM,backend,modeKey,hasFtst}], failsafeTempC, leaseMaxS, monitorOnly:bool` |
| `status` | - | `fans:[{index,actualRPM,targetRPM,mode(0/1),minRPM,maxRPM,owned,leaseRemainS}], failsafe:{active,reason,tempC}, lastError, dict` |
| `set` | `fan:i, rpm:Double, ttl:Double<=leaseMaxS` | takeover/set_target; replies `{applied:rpm, clamped:bool}`; renews the lease; marks this connection as owner of fan i. A repeat with an unchanged target renews the lease and writes nothing (2.7) |
| `setAll` | `rpms:[Double?]` | batch of `set`, null = untouched |
| `auto` | `fan:i or "all"` | release |
| `heartbeat` | `ttl` | renews all leases of this connection; replies `{owned:[fans]}` so the client notices lost ownership (sleep, failsafe, os_override) |
| `bye` | - | release this connection's fans, close |

Error codes: `bad_request, unauthorized, no_such_fan, monitor_only, mode_rejected, target_rejected, failsafe_active, io_error`. While the failsafe is active `set` is rejected with `failsafe_active` (the reply includes the forced RPM).

### 4.5 Helper safety rules (all required)
1. **Clamp** every target to the live `[F{i}Mn, F{i}Mx]`. Client-supplied limits are ignored. Non-finite or negative values give `bad_request`.
2. **Lease**: each owned fan has an expiry of now + ttl (ttl default 15 s, capped by `leaseMaxSeconds`). No renewal means release (watchdog). The app sends a heartbeat every 5 s, and `set` renews too.
3. **Disconnect**: socket EOF or error releases all fans owned by that connection.
4. **Signals**: SIGTERM, SIGINT, SIGHUP and SIGQUIT are handled via `DispatchSource.makeSignalSource`: release all, then `exit(0)`. SIGKILL or a crash is covered by `KeepAlive` restart, and **startup always runs release for every fan** (fail to auto).
5. **Sleep**: `IORegisterForSystemPower`; on `kIOMessageSystemWillSleep` release all fans, clear leases, then `IOAllowPowerChange`. After wake the helper does not re-take; the client sees `owned` missing in the next heartbeat reply and re-sends after its 5 s post-wake pause. Fan discovery is re-run on `HasPoweredOn`.
6. **Failsafe thermal override**: the helper reads the hot-set temperatures itself every 1 s while any fan is owned (and every 5 s while clients are connected, only to be ready). If `max(hotset) >= failsafeTempC` (default 95 C, configured range 85-100; the value can never be raised above 100 by a client or a damaged config) on **2 consecutive samples**, it takes over all fans at `Mx`, ignores client targets (`failsafe_active`) until `max < failsafeTempC - 7` for 10 s, then restores each client's target or releases fans only the failsafe held. Details of the confirmation: samples less than 0.5 s apart count as one observation (several reads inside one request usually return the same SMC value); a cooler or missing sample, or a pause of more than 11 s, restarts the count; while one hot sample is pending the helper samples every 1 s even if no fan is held, so a real overheat is confirmed about 1 s after it is first seen; a single-sample spike (for example the one-off 99.5 C `TCMb` reading measured on the M5 Pro while the CPU cores sat near 54 C) is ignored. If no valid hot-set temperature is readable for 10 s while fans are owned, the helper releases to auto (blind operation is unsafe) and refuses new control until a temperature is readable again.
7. **Verification and anti-fight**: 2.9. Every write is read back; unchanged targets are not rewritten (2.7).
8. **Idle**: with no connections and no owned fans the helper runs no timers (event-driven).
9. **Logging**: `os_log` subsystem `com.fanpilot.helper` plus stderr to `/var/log/fanpilot.log` (root:admin 0640). Every takeover and release is logged with its reason. The log can never take the daemon down or fill the disk: writes use `fputs` (a `FileHandle.write` on a full disk or closed stderr raises an uncatchable exception), control characters in peer-supplied text are escaped, per-connection lines are rate limited (one per second per uid), and the daemon starts the file over past 8 MiB (newsyslog would leave launchd's open descriptor pointing at the rotated file).
10. **Startup order**: bind the socket (a second instance fails here, before touching any fan) -> install signal handlers -> discover fans and release every fan that is not in auto, independent of what discovery thinks is controllable (writing mode 0 is always safe) -> only then enumerate sensors and accept clients.
11. **Connections**: a connection that sends nothing for 60 s after `hello` is closed; root gets two extra slots beyond the cap of 4 so `sudo fanpilotctl auto all` always gets through (and falls back to a direct SMC release if the helper does not answer).
12. **Failsafe fallback**: if a fan cannot be driven to maximum while the failsafe is active (target write refused, limits unreadable), it is handed back to the OS (mode 0) and the client's claim dropped; takeover is retried every tick.
13. **Wake**: stale manual modes are released at once; fan re-discovery runs 5 s later and never replaces a controllable fan by an unusable one (retried up to three times).

### 4.6 App-side lifecycle rules
- Launch: start in Auto. The saved mode is offered via "Resume last mode" and applied automatically only if `resumeOnLaunch` is on, because silently re-applying a manual fan speed at launch could surprise the user.
- Quit (`applicationShouldTerminate`): send `auto all` and wait up to 2 s for the reply (a fire-and-forget message could be lost at exit); the helper also restores on disconnect.
- Sleep (`NSWorkspace.willSleepNotification`): remember the policy, send `auto all`, stop timers (preference `turnOffFanControlForSleep`, default true). Wake: pause sensor checks, run a 5.0 s one-shot, then re-run sensor discovery, reconnect if needed and re-apply the policy.
- Helper unreachable: show the banner "Helper not running: monitor only" and offer "Install helper" (the app runs `osascript ... with administrator privileges` on the bundled install script, only after the user confirms); reconnect with backoff 1, 2, 4, 8, 30 s.
- Power-source change: re-evaluate the rule set for the new source; active fan state is not cleared, so ramps continue from the current speed instead of restarting.

---------------------------------------------------------------------------
## 5. Control policy (in the app; the helper only enforces safety)

### 5.1 Model
```
enum FanMode { auto, manual, max, boost, curve }
struct FanPolicy { mode; manualRPM: Int; manualPercent: Double; manualUnit: rpm|percent }
struct Policy { perFan: [FanPolicy]; linkFans: Bool = true; boost; curve }
```
The UI offers a global segmented control that sets all fans, plus an "unlink" disclosure for per-fan modes. Mapping to the wire: auto -> `auto`; manual, max, boost and curve -> `set` with a computed RPM, sent whenever it changes by at least 1 RPM and at least every 5 s (heartbeat).

### 5.2 RPM math
- `rpm = Int(round(min + p*(max - min)))` with p in [0,1]; percent 0 means `Mn` (manual mode never stops a fan; only Auto can); Max means `Mx`.
- `validatedRPM = clamp(rpm, Mn, Mx)` (client and helper both clamp).
- Link: when `linkFans` is on and one slider moves, the other fans follow by normalized position: `other = min_j + (rpm - min_i)/(max_i - min_i) * (max_j - min_j)`. Not applied in boost or curve modes.
- The slider is linear in RPM over `[Mn, Mx]` per fan, with no snapping; percent labels are presentation. Slider changes are debounced to one `set` per 100 ms.
- Warning and critical markers on the RPM gauge: 0.75 * `Mx` and 0.9 * `Mx`.

### 5.3 Auto Boost (rule engine)
Rule: `{id, enabled, sensor, limitC, percent(0-100), fans(all or one index), powerSource(battery|adapter)}`. Sensor selector: `highest` (all valid), `avgCPU`, `highestCPU`, or a named sensor key. Rules are stored per power source; Macs without a battery use the adapter set.

Per tick (rules are evaluated at each sensor tick, 2 s by default; the ramp resolves at 1 s):
1. For each enabled rule of the current power source: it triggers iff `temp > limit` (strict, floating point). Hysteresis: once active, a rule stays active while `temp > limit - hysteresisC` (default 3 C) and for at least `minHoldS` (default 15 s) from activation. A rule bound to one sensor releases after that sensor has been silent for 10 s while other sensors still report.
2. Per fan: the winner is the active rule with the highest percent; ties keep array order. "Auto Max" variant (`usePercent=false`): any firing rule means 100 %.
3. Goal RPM = `Mn + pct*(Mx-Mn)`. With no winner the goal is `Mn`, and once the ramp has reached `Mn` and 10 s have elapsed with no rule active, the fan is released to `auto`.
4. **Ramp limiter**: on a new goal compute `steps = round(T)` with `T_up = 6 s` and `T_down = 20 s` (configurable), 1 s per step. Each second `cur += (goal - cur)/stepsLeft`; on the last step `cur = goal` exactly and the final value is always written, so a ramp can neither overshoot nor stop short. If the goal changes mid-ramp, the ramp restarts from `cur`. Falling is never bypassed.
5. A newly boosted fan is sent as `set`; the helper performs the unlock, mode and target sequence (2.7). Emergency: if the hot set is at or above `failsafe - 5`, ramp-ups are bypassed and the goal is applied immediately.

Default rules (tuned for the measured behavior that 70 C under load still gives 0 RPM, 2.4 #7): on `highestCPU`, all fans, both power sources: 35 % at 58 C, 65 % at 70 C, 100 % at 82 C. The thresholds are starting points to be tuned on hardware (risk R6).

### 5.4 Curve mode
Points `[(tempC, percent)]` sorted by temperature, linear interpolation, flat outside the first and last point; the source selector is the same as for rules. The input temperature is an EMA (alpha 0.3 per sensor tick). The output percent rises immediately but falls only when the temperature is more than `fallHysteresisC` (3 C) below the lowest temperature at which the curve reaches the current level; it then goes through the same ramp limiter and release rules as 5.3. Default points: 45 C 0 %, 58 C 35 %, 70 C 65 %, 82 C 100 %.

### 5.5 Reassertion on the client
The helper owns the reassertion loop (2.9). The client only compares `status.owned` and `targetRPM` with its intent on each heartbeat and re-sends if they differ.

---------------------------------------------------------------------------
## 6. App features
Menu bar
- Label: configurable, two temperature slots (default: Highest and Average CPU) and a fan slot (Average RPM, a single fan, or none); `%.0f` plus unit, "N/A" when invalid; Celsius or Fahrenheit (C*1.8+32).
- Colors: warning at 90 C, critical at 100 C by default; an optional notification when exceeded.

Menu content
- Header: summary temperatures; helper status chip (Connected / Monitor only / Failsafe active / Not installed).
- Mode segmented control: Auto | Manual | Max | Boost | Curve.
- Per-fan row: name ("Left Side" / "Right Side" on two-fan MacBook Pro models such as `Mac17,8`, otherwise "Fan N"), actual RPM gauge with warning and critical markers, slider over `[Mn, Mx]` with RPM/% toggle (visible in Manual), link toggle.
- Buttons: Sensors window, Settings, Install/Reinstall helper, Quit.

Sensors window
- Table grouped by area (3.2), with columns name, key, source (SMC/HID), current, session max and a pin-to-menu-bar toggle; search, a "Show all (including Other)" toggle, copy as CSV. N/A rows are greyed.

Settings
- Update interval (1-60 s, default 2), temperature unit, menu-bar items, launch at login (`SMAppService.mainApp.register()`, which may need user approval; with ad-hoc signing it may fail, UNKNOWN), sleep behavior, resume on launch, boost rules editor (per power source), curve editor, ramp times, hysteresis, failsafe temperature display (read-only; edit in `helper.json`), helper install/uninstall, CSV logging, alerts, optional global shortcuts.

Persistence
- App: `UserDefaults` key `fanpilot.settings.v1`, one Codable JSON blob with a schema version; rules and curve live inside it. A corrupt blob yields defaults and never crashes; each field falls back individually.
- Helper: `helper.json` only (4.2).

---------------------------------------------------------------------------
## 7. Swift Package layout

Platform `.macOS(.v14)`, swift-tools-version 5.10, Swift language mode 5. Executable products: `FanPilotApp`, `fanpilotd`, `fanpilotctl`. Library products: `FanPilotKit`, `FanPilotSensors`, `FanPilotControl`, `FanPilotHelperCore`; C target `CSMC`. No resource bundle (the sensor catalog is Swift code), so `swift build` binaries run standalone.

```
FanPilot/
  Package.swift
  Sources/
    CSMC/                         C target (layout guarantees)
      include/smc.h               SMCKeyData_t (80 B, static asserts on the offsets 28/32/36/40/42/44/48),
                                  smc_open/close/call (read-only and write entry points), IOHID private
                                  prototypes (resolved via dlsym)
      smc.c
    FanPilotKit/                  shared contracts, no UI
      FourCC.swift  SMCTypes.swift  SMCCodec.swift      4CC, key info / value / errors, flt, ui8, fpe2, sp78, BE ints
      IOKitSMC.swift  InMemorySMC.swift                  real connection (read-only by default) and test double
      HIDThermal.swift                                   private IOHID temperature access
      SensorModels.swift  FanModels.swift                Sensor, Area, Source; FanInfo, Backend
      ControlModels.swift  AppSettings.swift             policy, rules, curve, app settings (tolerant Codable)
      HelperConfig.swift  Constants.swift                helper.json model; paths, limits, protocol version
      Wire.swift  LineSocket.swift                       request/reply types and error codes (4.4); NDJSON framing
      StandardError.swift  TolerantDecoding.swift
    FanPilotSensors/              sensor stack (unprivileged, read-only)
      SMCSensorReader.swift  HIDSensorReader.swift       enumerate T/f keys, validity rules (2.4, 2.5); HID cleanup (3.1)
      SensorCatalog.swift  CatalogData.swift             per-model tables (3.2)
      SensorClassifier.swift  SensorPlanner.swift        heuristics (3.3); which sensors exist on this machine
      SensorEngine.swift  SensorMonitor.swift            reads and PollingPolicy; timer, wake pause (3.5)
      FanReader.swift  HardwareInfo.swift                fan discovery (read-only) and names; sysctl topology
      Aggregates.swift  SensorSnapshot.swift  Diagnostics.swift  BatteryInfo.swift
    FanPilotControl/              pure control logic, no I/O, injected clock
      RPMMath.swift  ManualPolicyEditing.swift           percent <-> RPM, clamp, link (5.2)
      BoostEngine.swift  CurveEngine.swift  RampLimiter.swift  DemandFollower.swift   (5.3, 5.4)
      FanController.swift  FanCommand.swift  TemperatureInputs.swift
    FanPilotHelperCore/           root daemon logic, testable without root
      FanDiscovery.swift          2.6 backend selection
      FanWriter.swift             takeover / release / reassert (2.7-2.9); the only code that writes fan keys
      Failsafe.swift  HotSet.swift  SensorsHotSet.swift  4.5 #6 state machine; hot-set readers
      HelperEngine.swift          requests, ownership, leases, 1 Hz tick (4.4, 4.5)
      HelperServer.swift  PeerAuth.swift  PowerEvents.swift  HelperRuntime.swift  HelperLog.swift
      DaemonClient.swift  CLISupport.swift  HardwareSelfTest.swift    CLI helpers; Phase 0 (2.10)
    fanpilotd/main.swift          hands the command line to HelperRuntime
    fanpilotctl/                  CLI (8.2): CLI.swift, ReadCommands, DaemonCommands, HardwareCommands, main
    FanPilotApp/                  SwiftUI menu-bar app
      FanPilotApp.swift  WindowCoordinator.swift  StatusItem.swift  MenuContentView.swift  MainWindowView.swift
      AppModel.swift (+Control, +Sensors, +Lifecycle)    sensors, fans, policy, timers, sleep/wake
      HelperClient.swift  HelperInstaller.swift          socket client with reconnect/backoff/heartbeat; osascript install
      PowerMonitor.swift  LoginItem.swift  HotKeyManager.swift  Notifier.swift  CSVLogger.swift
      FanControlViews.swift  SensorTableView.swift  RulesEditorView.swift  CurveEditorView.swift
      SettingsView.swift  SettingsFanHelperPanes.swift  Theme.swift  Formatting.swift  AppExtras.swift  Credits.swift
  Tests/
    FanPilotKitTests/             codec, FourCC, struct layout, wire, line socket, models, SMC client
    FanPilotSensorsTests/         catalog, planner, readers, engine, diagnostics
    FanPilotControlTests/         RPM math, boost (strict <, hysteresis, tie-break), curve, ramp (exact goal, no overshoot), controller
    FanPilotHelperCoreTests/      FanWriter against InMemorySMC (order, retries, size-guard refusal, release order), failsafe, engine, server, self-test
  scripts/
    build_app.sh                  swift build -c release; assemble build/FanPilot.app (LSUIElement=1, LSMinimumSystemVersion 14.0);
                                  copy fanpilotd + fanpilotctl into Contents/Resources/helper/; codesign --force --sign - (inner first, then bundle)
    install_helper.sh             sudo; copies the helper, writes the plist and helper.json (allowedUIDs from $SUDO_UID, cdhashes if pinned), bootstraps; verifies ownership and modes
    uninstall_helper.sh           bootout, restore auto, remove files
    make_dmg.sh                   disk image packaging
    com.fanpilot.helper.plist.template
    Info.plist
  docs/
    SPEC.md                       this document
    PHASE0.md                     hardware self-test procedure
```

---------------------------------------------------------------------------
## 8. Build, test, CLI

### 8.1 Build
`swift build -c release`, then `scripts/build_app.sh` produces `FanPilot.app`; `sudo scripts/install_helper.sh` installs the helper. Every Mach-O is signed ad hoc with `codesign -s -` (arm64 requires a signature; the linker adds an ad-hoc one, which is replaced after copying). Locally built, non-quarantined bundles pass Gatekeeper. No entitlements are required: IOKit user-client access to AppleSMC and HID works unsandboxed.

### 8.2 CLI `fanpilotctl`
`list` (fans and limits, unprivileged), `sensors [--all] [--json]` (unprivileged), `watch` (1 Hz table), `status` (daemon), `set <fan|all> <rpm|NN%> [--hold SECONDS]` (holds the connection and heartbeats, then returns to auto), `max [--hold]`, `auto [fan|all]`, `selftest` (2.10), `daemon-ping`, `smc-read KEY` (debug, unprivileged), `smc-write KEY HEX` (root only, refuses non-`F*` keys, for Phase 0 only). Exit codes are non-zero on any rejected or failed step (1 failed, 2 usage, 3 helper not reachable, 4 needs root).

### 8.3 Test plan
Unit tests (above) run without hardware against `InMemorySMC` with an injected clock. Hardware tests, all described in `docs/PHASE0.md`: the Phase 0 self-test; `kill -9` of the helper while it owns a fan (expect a `KeepAlive` restart and `md == 0`); `kill -9` of the client (expect release on disconnect, or by lease expiry within 15 s); a sleep/wake cycle with control on; unplugging and replugging power with Boost rules; a sustained all-core load for 60 s with Boost and a check that the hysteresis prevents flapping; and a failsafe test with the foreground switch `fanpilotd --failsafe-test <C>`, which lowers the trigger below the normal 85 C floor so the failsafe can be provoked on real hardware without heating the machine. On the measured `Mac17,8`, manual mode, Max and the failsafe test (both fans driven to maximum) have been run.

---------------------------------------------------------------------------
## 9. Open risks and unknowns
- R1 (critical, resolved on one machine): whether the firmware honors `F0md=1` plus `F0Tg` writes without `Ftst`, and whether `thermalmonitord` reverts them. Verified on a `Mac17,8` running macOS 27 (2.10). Other models and OS builds must be checked with the self-test; the fallback is monitor-only mode.
- R2 UNKNOWN: whether `F<n>Tg` is reset by firmware after `md=0`, and what `F0St=3`, mode values other than 0/1, and `DICT` mean on M5.
- R3: sleep/wake and crash behavior of the firmware when the writer vanishes (does the SMC auto-revert?). Mitigated by helper release on every path, but a SIGKILL of the helper plus a stuck `md=1` is only recovered by the `KeepAlive` restart (startup release-all).
- R4: same-uid malware can drive the daemon in `uid` mode; bounded by clamping, leases and the failsafe; `pinned` mode needs a reinstall per rebuild.
- R5: the IOHID private APIs and private-symbol resolution could change; the SMC-only fallback must keep the app working.
- R6: default rule thresholds are guesses from one load test; tune on hardware.
- R7: login-item registration with ad-hoc signing is unverified.
- R8: Intel/T2 Backend B is untested (no hardware); `FS! ` and `fpe2` behavior follows public descriptions only.
- R9: the meaning of mode values beyond 0/1 and of `F<n>St`; whether `Tg43`/`Tg50` exist depends on the GPU core count (FanPilot includes them if they read valid).
- R10: more than 10 fans are unsupported (single-digit key); the cost of enumerating all 3626 SMC keys has not been timed on-device beyond sensor start-up.
