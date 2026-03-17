import ArgumentParser
import Foundation

struct HomeKitCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "homeclaw-cli",
        abstract: "Control HomeKit accessories via HomeClaw",
        subcommands: [
            List.self,
            Get.self,
            Set.self,
            Scenes.self,
            GetScene.self,
            Trigger.self,
            DeleteScene.self,
            ImportScene.self,
            AssignRooms.self,
            Search.self,
            Status.self,
            Config.self,
            DeviceMapCmd.self,
            Events.self,
            Triggers.self,
            WebhookLog.self,
        ],
        defaultSubcommand: Status.self
    )
}
