import Foundation
import ArgumentParser

/// Reads command input from a file path, or from stdin when the path is `-`.
///
/// Shared by every file-taking command (import-scene, update-scene, assign-rooms)
/// so they all support the same `-` stdin convention. stdin matters beyond
/// convenience: the Mac App Store build of the CLI is sandboxed, so it can only
/// read files from its own container or the app group container — piping JSON
/// via stdin is the escape hatch that works from any directory.
func readCommandInputData(_ path: String) throws -> Data {
    if path == "-" {
        // If stdin is an interactive terminal (nothing piped in), readDataToEndOfFile()
        // would block silently until EOF. Tell the user what's happening instead of
        // appearing to hang.
        if isatty(STDIN_FILENO) == 1 {
            FileHandle.standardError.write(Data("Reading JSON from stdin — press Ctrl-D when done, or Ctrl-C to abort.\n".utf8))
        }
        return FileHandle.standardInput.readDataToEndOfFile()
    }
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw ValidationError(
            "Cannot read '\(path)': \(error.localizedDescription)\n"
                + "Tip: pass '-' to read JSON from stdin (works from any directory), e.g.\n"
                + "  echo '{...}' | homeclaw-cli <command> -\n"
                + "Note: the sandboxed (App Store) CLI can only read files under\n"
                + "  ~/Library/Containers/com.shahine.homeclaw.cli/Data/ or\n"
                + "  ~/Library/Group Containers/group.com.shahine.homeclaw/"
        )
    }
}

/// Pretty-prints a value as JSON to stdout.
func printJSON(_ value: Any?) {
    guard let value else {
        print("null")
        return
    }

    // If it's already JSON-serializable
    if JSONSerialization.isValidJSONObject(value) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            print(string)
            return
        }
    }

    // Fallback
    print("\(value)")
}
