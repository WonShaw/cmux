import Testing
@testable import CmuxFoundation

@Suite("comux git environment")
struct GitOfflineEnvironmentTests {
    @Test("repository-executable configuration is forced off and injected config is dropped")
    func forcedConfiguration() {
        let environment = GitOfflineEnvironment.applying(to: [
            "PATH": "/usr/bin",
            "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='evil'",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.fsmonitor",
            "GIT_CONFIG_VALUE_0": "evil",
        ])
        #expect(environment["GIT_CONFIG_PARAMETERS"] == nil)
        let count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        var config: [String: String] = [:]
        for index in 0..<count {
            config[environment["GIT_CONFIG_KEY_\(index)"] ?? ""] = environment["GIT_CONFIG_VALUE_\(index)"]
        }
        #expect(config["core.fsmonitor"] == "false")
        #expect(config["core.hooksPath"] == "/dev/null")
        #expect(config["safe.bareRepository"] == "explicit")
        #expect(config["safe.directory"] == "")
    }

    @Test("only filter drivers from the repository's own config are disabled")
    func filterNeutralizing() {
        let arguments = GitOfflineEnvironment.filterNeutralizingArguments(
            fromScopedNames: "local\tfilter.evil.clean\nglobal\tfilter.lfs.clean\n"
        )
        #expect(arguments == [
            "-c", "filter.evil.clean=", "-c", "filter.evil.smudge=",
            "-c", "filter.evil.process=", "-c", "filter.evil.required=false",
        ])
    }
}
