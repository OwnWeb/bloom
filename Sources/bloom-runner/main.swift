import BloomRunner
import Foundation

// The server a Cloud workspace's machine runs. Everything it does is `BloomRunner`, which has
// tests; this file only hands over the arguments.

exit(await RunnerCommandLine.run(Array(CommandLine.arguments.dropFirst())))
