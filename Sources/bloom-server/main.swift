import BloomServer
import Foundation

// The server a Cloud workspace's machine runs. Everything it does is `BloomServer`, which has
// tests; this file only hands over the arguments.

exit(await ServerCommandLine.run(Array(CommandLine.arguments.dropFirst())))
