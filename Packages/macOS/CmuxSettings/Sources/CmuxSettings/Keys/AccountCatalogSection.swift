import Foundation

/// Settings under the dotted-id prefix `account.*`.
public struct AccountCatalogSection: SettingCatalogSection {
    public let welcomeShown = DefaultsKey<Bool>(
        id: "account.welcomeShown",
        defaultValue: false,
        userDefaultsKey: "cmuxWelcomeShown"
    )

    public init() {}
}
