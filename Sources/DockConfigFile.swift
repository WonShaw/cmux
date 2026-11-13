import Foundation

struct DockConfigFile: Codable, Sendable {
    let controls: [DockControlDefinition]

    init(controls: [DockControlDefinition]) {
        self.controls = controls
    }

    private enum CodingKeys: String, CodingKey {
        case controls
    }

    /// One `controls` entry. Legacy `"type": "browser"` controls decode to
    /// `nil` so they are skipped while every other control still loads (and
    /// still reports its own validation errors).
    private struct ControlEntry: Decodable {
        private enum TypeKey: String, CodingKey {
            case type
        }

        let definition: DockControlDefinition?

        init(from decoder: Decoder) throws {
            let rawType = (try? decoder.container(keyedBy: TypeKey.self))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .type) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if rawType == "browser" {
                definition = nil
            } else {
                definition = try DockControlDefinition(from: decoder)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controls = try container.decode([ControlEntry].self, forKey: .controls)
            .compactMap(\.definition)
    }
}
