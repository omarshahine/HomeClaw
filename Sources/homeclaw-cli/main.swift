import Foundation

// Ignore SIGPIPE so piped commands (e.g. Node.js MCP server, `head`) don't
// kill the process when the reader closes early. Without this, large responses
// cause exit code 141 (128 + SIGPIPE).
signal(SIGPIPE, SIG_IGN)

HomeKitCLI.main()
