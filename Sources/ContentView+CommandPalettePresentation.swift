// Command execution policy shared by palette selection and focus restoration.
extension ContentView {
    static func commandPaletteShouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             "palette.layout.saveCurrent":
            return true
        default:
            return false
        }
    }
}
