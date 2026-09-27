import ArgumentParser
import Foundation

/// Home app accessory groups ("Group with Other Accessories"), which HomeKit
/// stores as service groups: one tile in the Home app, one target for Siri.
struct Groups: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List and manage Home app accessory groups",
        discussion: """
            A member is an accessory name or UUID, or a service UUID (the per-service
            `id` in `get --json`) to add one gang of a multi-gang accessory. Members
            must be the same kind (lights with lights), as in the Home app, unless
            --allow-mixed is passed. A switch displayed as a light counts as a light.
            """,
        subcommands: [
            GroupsList.self,
            GroupsCreate.self,
            GroupsAdd.self,
            GroupsRemove.self,
            GroupsRename.self,
            GroupsDelete.self,
        ],
        defaultSubcommand: GroupsList.self
    )
}

/// Options every group mutation shares.
struct GroupMutationOptions: ParsableArguments {
    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    /// Validates `values`, adds home and dry-run to `args`, sends `command`, and
    /// prints the result (JSON, or `summary` of the response data).
    func send(
        _ command: String,
        args: [String: Any],
        validating values: [(String, String)],
        summary: ([String: Any]) -> String
    ) throws {
        for (value, label) in values {
            if let err = validateInput(value, label: label) { throw ValidationError(err) }
        }
        var args = args
        args["dry_run"] = dryRun
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: command, args: args)
        guard response.success else {
            throw CommandFailure(response.error ?? "Unknown error")
        }
        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }
        let data = response.data?.value as? [String: Any] ?? [:]
        print((data["dry_run"] as? Bool == true ? "DRY RUN — " : "") + summary(data))
    }
}

/// "Name (Room)" lines for the member dictionaries a group response carries.
func formatGroupMembers(_ members: Any?) -> String {
    let members = members as? [[String: Any]] ?? []
    guard !members.isEmpty else { return "  (none)" }
    return members.map { member in
        let accessory = member["accessory"] as? String ?? "?"
        let name = member["name"] as? String ?? "?"
        let label = name == accessory ? name : "\(accessory) / \(name)"
        let room = (member["room"] as? String).map { " (\($0))" } ?? ""
        let kind = (member["kind"] as? String).map { " [\($0)]" } ?? ""
        return "  - \(label)\(room)\(kind)"
    }.joined(separator: "\n")
}

// MARK: - List

struct GroupsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List accessory groups and their members"
    )

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = [:]
        if let home { args["home_id"] = home }
        let response = try SocketClient.sendAny(command: "list_groups", args: args)
        guard response.success else {
            throw CommandFailure(response.error ?? "Unknown error")
        }
        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }
        let data = response.data?.value as? [String: Any] ?? [:]
        let groups = data["groups"] as? [[String: Any]] ?? []
        if groups.isEmpty { print("No groups.") }
        for group in groups {
            print("\(group["name"] as? String ?? "?")  \(group["id"] as? String ?? "")")
            print(formatGroupMembers(group["services"]))
        }
        if let hidden = data["hidden_groups"] as? Int, hidden > 0 {
            print("(\(hidden) more group(s) include accessories hidden by the device filter)")
        }
    }
}

// MARK: - Create

struct GroupsCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a group from accessories or services"
    )

    @Argument(help: "Name for the new group")
    var name: String

    @Argument(help: "Members: accessory names/UUIDs or service UUIDs")
    var members: [String]

    @Flag(name: .long, help: "Allow members of different kinds (the Home app only groups one kind)")
    var allowMixed = false

    @OptionGroup var options: GroupMutationOptions

    func validate() throws {
        if members.isEmpty { throw ValidationError("Pass at least one member.") }
    }

    func run() throws {
        try options.send(
            "create_group",
            args: ["name": name, "members": members, "allow_mixed": allowMixed],
            validating: [(name, "name")] + members.map { ($0, "member") }
        ) { data in
            "Created group '\(data["name"] as? String ?? name)':\n" + formatGroupMembers(data["services"])
        }
    }
}

// MARK: - Add / Remove

struct GroupsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add accessories or services to a group"
    )

    @Argument(help: "Group name or UUID")
    var group: String

    @Argument(help: "Members: accessory names/UUIDs or service UUIDs")
    var members: [String]

    @Flag(name: .long, help: "Allow members of different kinds (the Home app only groups one kind)")
    var allowMixed = false

    @OptionGroup var options: GroupMutationOptions

    func validate() throws {
        if members.isEmpty { throw ValidationError("Pass at least one member.") }
    }

    func run() throws {
        try options.send(
            "add_to_group",
            args: ["group": group, "members": members, "allow_mixed": allowMixed],
            validating: [(group, "group")] + members.map { ($0, "member") }
        ) { data in
            var out = "Added to '\(data["group"] as? String ?? group)':\n" + formatGroupMembers(data["added"])
            if let already = data["already_members"] as? [[String: Any]], !already.isEmpty {
                out += "\nAlready members (skipped):\n" + formatGroupMembers(already)
            }
            return out
        }
    }
}

struct GroupsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove accessories or services from a group"
    )

    @Argument(help: "Group name or UUID")
    var group: String

    @Argument(help: "Members: accessory names/UUIDs or service UUIDs")
    var members: [String]

    @OptionGroup var options: GroupMutationOptions

    func validate() throws {
        if members.isEmpty { throw ValidationError("Pass at least one member.") }
    }

    func run() throws {
        try options.send(
            "remove_from_group",
            args: ["group": group, "members": members],
            validating: [(group, "group")] + members.map { ($0, "member") }
        ) { data in
            var out = "Removed from '\(data["group"] as? String ?? group)':\n" + formatGroupMembers(data["removed"])
            if let notMembers = data["not_members"] as? [[String: Any]], !notMembers.isEmpty {
                out += "\nNot in the group (skipped):\n" + formatGroupMembers(notMembers)
            }
            return out
        }
    }
}

// MARK: - Rename / Delete

struct GroupsRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a group"
    )

    @Argument(help: "Group name or UUID")
    var group: String

    @Argument(help: "New name for the group")
    var newName: String

    @OptionGroup var options: GroupMutationOptions

    func run() throws {
        try options.send(
            "rename_group",
            args: ["group": group, "new_name": newName],
            validating: [(group, "group"), (newName, "new name")]
        ) { data in
            "Renamed group '\(data["old_name"] as? String ?? group)' → '\(data["new_name"] as? String ?? newName)'"
        }
    }
}

struct GroupsDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a group (its accessories are untouched)"
    )

    @Argument(help: "Group name or UUID")
    var group: String

    @OptionGroup var options: GroupMutationOptions

    func run() throws {
        try options.send(
            "delete_group",
            args: ["group": group],
            validating: [(group, "group")]
        ) { data in
            "Deleted group '\(data["name"] as? String ?? group)' (members untouched)"
        }
    }
}
