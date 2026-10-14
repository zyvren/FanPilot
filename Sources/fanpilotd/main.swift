import FanPilotHelperCore
import Foundation

// fanpilotd: the FanPilot root helper. All logic lives in FanPilotHelperCore so it can be tested
// without root; this file only hands over the command line.
exit(HelperRuntime.main(arguments: Array(CommandLine.arguments.dropFirst())))
