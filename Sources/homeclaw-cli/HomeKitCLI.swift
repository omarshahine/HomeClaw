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
            Rename.self,
            CreateRoom.self,
            RenameRoom.self,
            RemoveRoom.self,
            RemoveAccessory.self,
            CreateZone.self,
            RemoveZone.self,
            AddRoomToZone.self,
            RemoveRoomFromZone.self,
            Search.self,
            Status.self,
            Config.self,
            DeviceMapCmd.self,
            Events.self,
            Automations.self,
            Triggers.self,
            WebhookLog.self,
        ],
        defaultSubcommand: Status.self
    )
}
