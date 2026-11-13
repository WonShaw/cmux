import Foundation

enum CmuxNavigationURLParseError: Error, Equatable {
    case unsupportedURLShape
    case invalidIdentifier(String)
}

struct CmuxNavigationURLRequest: Equatable {
    enum Target: Equatable {
        case workspace(UUID)
        case pane(workspaceId: UUID, paneId: UUID)
        case surface(workspaceId: UUID, surfaceId: UUID)
    }

    static var activeSupportedSchemes: Set<String> {
        [CmuxAppURLScheme.current.lowercased()]
    }

    let originalURL: URL
    let target: Target
    let stableFallbackWorkspaceId: UUID?
    let stableFallbackSurfaceId: UUID?

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxNavigationURLRequest?, CmuxNavigationURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedURLShape)
        }

        let route = routeComponents(from: components)
        guard route.first?.lowercased() == "workspace" else {
            return .success(nil)
        }

        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedFragment == nil else {
            return .failure(.unsupportedURLShape)
        }

        guard route.count == 2 || route.count == 4 else {
            return .failure(.unsupportedURLShape)
        }
        guard let workspaceId = UUID(uuidString: route[1]) else {
            return .failure(.invalidIdentifier("workspace"))
        }
        if route.count == 2 {
            let fallback: (workspaceId: UUID?, surfaceId: UUID?)?
            switch parseStableFallback(from: components, allowedNames: ["stable_workspace_id"]) {
            case .success(let parsedFallback):
                fallback = parsedFallback
            case .failure(let error):
                return .failure(error)
            }
            return .success(CmuxNavigationURLRequest(
                originalURL: url,
                target: .workspace(workspaceId),
                stableFallbackWorkspaceId: fallback?.workspaceId,
                stableFallbackSurfaceId: fallback?.surfaceId
            ))
        }

        let childKind = route[2].lowercased()
        guard let childId = UUID(uuidString: route[3]) else {
            switch childKind {
            case "pane":
                return .failure(.invalidIdentifier("pane"))
            case "surface", "panel":
                return .failure(.invalidIdentifier("surface"))
            default:
                return .failure(.unsupportedURLShape)
            }
        }

        switch childKind {
        case "pane":
            if components.percentEncodedQuery != nil {
                return .failure(.unsupportedURLShape)
            }
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .pane(workspaceId: workspaceId, paneId: childId),
                    stableFallbackWorkspaceId: nil,
                    stableFallbackSurfaceId: nil
                )
            )
        case "surface", "panel":
            let fallback: (workspaceId: UUID?, surfaceId: UUID?)?
            switch parseStableFallback(
                from: components,
                allowedNames: ["stable_workspace_id", "stable_surface_id"]
            ) {
            case .success(let parsedFallback):
                fallback = parsedFallback
            case .failure(let error):
                return .failure(error)
            }
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .surface(workspaceId: workspaceId, surfaceId: childId),
                    stableFallbackWorkspaceId: fallback?.workspaceId,
                    stableFallbackSurfaceId: fallback?.surfaceId
                )
            )
        default:
            return .failure(.unsupportedURLShape)
        }
    }

    static func workspaceLink(workspaceId: UUID, scheme: String = CmuxAppURLScheme.current) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)"
    }

    static func paneLink(
        workspaceId: UUID,
        paneId: UUID,
        scheme: String = CmuxAppURLScheme.current
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"
    }

    static func surfaceLink(
        workspaceId: UUID,
        surfaceId: UUID,
        stableWorkspaceId: UUID? = nil,
        stableSurfaceId: UUID? = nil,
        scheme: String = CmuxAppURLScheme.current
    ) -> String {
        var link = "\(scheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"
        var queryItems: [String] = []
        if let stableWorkspaceId {
            queryItems.append("stable_workspace_id=\(stableWorkspaceId.uuidString)")
        }
        if let stableSurfaceId {
            queryItems.append("stable_surface_id=\(stableSurfaceId.uuidString)")
        }
        if !queryItems.isEmpty {
            link += "?\(queryItems.joined(separator: "&"))"
        }
        return link
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func routeComponents(from components: URLComponents) -> [String] {
        var route: [String] = []
        if let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            route.append(host)
        }
        route += components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return route
    }

    private static func parseStableFallback(
        from components: URLComponents,
        allowedNames: Set<String>
    ) -> Result<(workspaceId: UUID?, surfaceId: UUID?)?, CmuxNavigationURLParseError> {
        guard components.percentEncodedQuery != nil else { return .success(nil) }
        guard let items = components.queryItems, !items.isEmpty else {
            return .failure(.unsupportedURLShape)
        }

        var stableWorkspaceId: UUID?
        var stableSurfaceId: UUID?
        var seenNames: Set<String> = []
        for item in items {
            guard allowedNames.contains(item.name),
                  seenNames.insert(item.name).inserted,
                  let value = item.value,
                  !value.isEmpty else {
                return .failure(.unsupportedURLShape)
            }

            guard let id = UUID(uuidString: value) else {
                switch item.name {
                case "stable_workspace_id":
                    return .failure(.invalidIdentifier("stable_workspace"))
                case "stable_surface_id":
                    return .failure(.invalidIdentifier("stable_surface"))
                default:
                    return .failure(.unsupportedURLShape)
                }
            }

            switch item.name {
            case "stable_workspace_id":
                stableWorkspaceId = id
            case "stable_surface_id":
                stableSurfaceId = id
            default:
                return .failure(.unsupportedURLShape)
            }
        }

        return .success((
            workspaceId: stableWorkspaceId,
            surfaceId: stableSurfaceId
        ))
    }
}

enum CmuxTextURLParseError: Error, Equatable {
    case missingText
    case textTooLong(maxLength: Int)
    case textContainsUnsafeCharacters
    case nameTooLong(maxLength: Int)
    case nameContainsUnsafeCharacters
    case titleTooLong(maxLength: Int)
    case titleContainsUnsafeCharacters
    case invalidBooleanParameter(String)
    case duplicateParameter(String)
    case unsupportedParameter(String)
    case multipleLinks
}

struct CmuxTextURLRequest: Equatable {
    enum Kind: String, Equatable {
        case prompt
        case rules
    }

    static let maxTextLength = 8_000
    static let maxNameLength = 120
    static let maxTitleLength = 160
    static let supportedSchemes: Set<String> = ["cmux", "cmux-nightly", "cmux-rc", "cmux-dev"]
    static var activeSupportedSchemes: Set<String> {
        [CmuxAppURLScheme.current.lowercased()]
    }

    let originalURL: URL
    let kind: Kind
    let text: String
    let name: String?
    let title: String?
    let noFocus: Bool

    var pasteText: String {
        text
    }

    private struct ParsedQueryItem {
        let name: String
        let value: String?
    }

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxTextURLRequest?, CmuxTextURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let kind = textTarget(from: url) else {
            return .success(nil)
        }
        guard !containsPathPayload(url) else {
            return .failure(.unsupportedParameter("path"))
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.missingText)
        }

        let queryItems = parsedQueryItems(from: components)
        let allowedQueryNames: Set<String> = ["text", "name", "title", "no-focus"]
        var seenQueryNames = Set<String>()
        for item in queryItems {
            let name = item.name.lowercased()
            guard allowedQueryNames.contains(name) else {
                return .failure(.unsupportedParameter(displayParameterName(item.name)))
            }
            guard seenQueryNames.insert(name).inserted else {
                return .failure(.duplicateParameter(displayParameterName(item.name)))
            }
        }

        guard let text = exactQueryValue(namedAnyOf: ["text"], in: queryItems) else {
            return .failure(.missingText)
        }
        guard text.count <= maxTextLength else {
            return .failure(.textTooLong(maxLength: maxTextLength))
        }
        guard !containsUnsafeTextCharacter(text) else {
            return .failure(.textContainsUnsafeCharacters)
        }

        let name = normalizedQueryValue(namedAnyOf: ["name"], in: queryItems)
        if let name {
            guard name.count <= maxNameLength else {
                return .failure(.nameTooLong(maxLength: maxNameLength))
            }
            guard !containsUnsafeHiddenCharacter(name) else {
                return .failure(.nameContainsUnsafeCharacters)
            }
        }

        let title = normalizedQueryValue(namedAnyOf: ["title"], in: queryItems)
        if let title {
            guard title.count <= maxTitleLength else {
                return .failure(.titleTooLong(maxLength: maxTitleLength))
            }
            guard !containsUnsafeHiddenCharacter(title) else {
                return .failure(.titleContainsUnsafeCharacters)
            }
        }

        let noFocus: Bool
        switch normalizedBooleanValue(named: "no-focus", in: queryItems) {
        case .success(let value):
            noFocus = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(CmuxTextURLRequest(
            originalURL: url,
            kind: kind,
            text: text,
            name: name,
            title: title,
            noFocus: noFocus
        ))
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func textTarget(from url: URL) -> Kind? {
        if let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
           !host.isEmpty {
            return kind(named: host)
        }

        let firstPathComponent = url.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
        guard let firstPathComponent else { return nil }
        return kind(named: firstPathComponent)
    }

    private static func kind(named value: String) -> Kind? {
        switch value {
        case "prompt":
            return .prompt
        case "rule", "rules":
            return .rules
        default:
            return nil
        }
    }

    private static func containsPathPayload(_ url: URL) -> Bool {
        if let host = url.host?.lowercased(),
           kind(named: host) != nil {
            return !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }
        let pathComponents = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return pathComponents.first.map { kind(named: $0.lowercased()) != nil } == true && pathComponents.count > 1
    }

    private static func parsedQueryItems(from components: URLComponents) -> [ParsedQueryItem] {
        guard let query = components.percentEncodedQuery,
              !query.isEmpty else {
            return []
        }
        return query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { rawPair in
                let parts = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = percentDecodedQueryComponent(String(parts[0])) ?? String(parts[0])
                let value = parts.count > 1
                    ? percentDecodedQueryComponent(String(parts[1])) ?? String(parts[1])
                    : nil
                return ParsedQueryItem(name: name, value: value)
            }
    }

    private static func percentDecodedQueryComponent(_ value: String) -> String? {
        value.removingPercentEncoding
    }

    private static func normalizedQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func exactQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value,
              !value.isEmpty else {
            return nil
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedBooleanValue(named name: String, in queryItems: [ParsedQueryItem]) -> Result<Bool, CmuxTextURLParseError> {
        guard let item = queryItems.first(where: { $0.name.lowercased() == name }) else {
            return .success(false)
        }
        guard let rawValue = item.value else {
            return .success(true)
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return .success(true)
        }
        switch normalized {
        case "1", "true", "yes", "on":
            return .success(true)
        case "0", "false", "no", "off":
            return .success(false)
        default:
            return .failure(.invalidBooleanParameter(displayParameterName(item.name)))
        }
    }

    private static func containsUnsafeTextCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func containsUnsafeHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func displayParameterName(_ name: String) -> String {
        if name.isEmpty || containsUnsafeHiddenCharacter(name) {
            return "?"
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "?"
        }
        let prefix = String(name.prefix(64))
        return prefix.count == name.count ? name : "\(prefix)..."
    }
}
