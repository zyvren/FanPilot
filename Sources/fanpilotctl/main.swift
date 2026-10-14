import Foundation

// fanpilotctl: command line companion of the FanPilot helper (docs/SPEC.md 8.2). The logic lives in
// the other files of this target and in FanPilotHelperCore, where the unit tests can reach it.
exit(CLI.run(CommandLine.arguments))
