import AppKit
import CmuxFoundation

struct AgentSessionWebTheme: Equatable {
    let isDark: Bool
    let pageBackground: String
    let surfaceBackground: String
    let surfaceElevatedBackground: String
    let inputBackground: String
    let border: String
    let borderStrong: String
    let text: String
    let mutedText: String
    let softText: String
    let accent: String
    let accentSoft: String
    let danger: String
    let shadow: String

    var dictionary: [String: Any] {
        [
            "isDark": isDark,
            "pageBackground": pageBackground,
            "surfaceBackground": surfaceBackground,
            "surfaceElevatedBackground": surfaceElevatedBackground,
            "inputBackground": inputBackground,
            "border": border,
            "borderStrong": borderStrong,
            "text": text,
            "mutedText": mutedText,
            "softText": softText,
            "accent": accent,
            "accentSoft": accentSoft,
            "danger": danger,
            "shadow": shadow
        ]
    }

    static func resolve(appearance: PanelAppearance) -> AgentSessionWebTheme {
        let base = appearance.backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let inverseOverlay: NSColor = isDark ? .black : .white
        let contentBackground = appearance.contentBackgroundColor
        let transparentContent = contentBackground.alphaComponent < 0.001
        let baseSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.72 : 0.34
        let elevatedSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.84 : 0.48
        let inputAlpha: CGFloat = appearance.drawsContentBackground ? 0.60 : 0.36
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.62 : 1.34,
            of: overlay
        )
        let borderStrong = base.markdownThemeOverlay(
            targetContrast: isDark ? 2.12 : 1.64,
            of: overlay
        )
        let surface = base
            .blended(withFraction: isDark ? 0.05 : 0.03, of: overlay)?
            .withAlphaComponent(baseSurfaceAlpha)
            ?? base.withAlphaComponent(baseSurfaceAlpha)
        let surfaceElevated = base
            .blended(withFraction: isDark ? 0.08 : 0.05, of: overlay)?
            .withAlphaComponent(elevatedSurfaceAlpha)
            ?? base.withAlphaComponent(elevatedSurfaceAlpha)
        let input = base
            .blended(withFraction: isDark ? 0.18 : 0.10, of: inverseOverlay)?
            .withAlphaComponent(inputAlpha)
            ?? base.withAlphaComponent(inputAlpha)
        let foreground = appearance.foregroundColor
        let accent = cmuxAccentNSColor()
        let danger = (NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed)
        return AgentSessionWebTheme(
            isDark: isDark,
            pageBackground: transparentContent ? "transparent" : contentBackground.markdownCSSColor,
            surfaceBackground: surface.markdownCSSColor,
            surfaceElevatedBackground: surfaceElevated.markdownCSSColor,
            inputBackground: input.markdownCSSColor,
            border: border.withAlphaComponent(border.alphaComponent * 0.72).markdownCSSColor,
            borderStrong: borderStrong.markdownCSSColor,
            text: foreground.markdownCSSColor,
            mutedText: foreground.withAlphaComponent(0.58).markdownCSSColor,
            softText: foreground.withAlphaComponent(0.78).markdownCSSColor,
            accent: accent.markdownCSSColor,
            accentSoft: accent.withAlphaComponent(isDark ? 0.20 : 0.16).markdownCSSColor,
            danger: danger.markdownCSSColor,
            shadow: isDark ? "rgba(0, 0, 0, 0.20)" : "rgba(0, 0, 0, 0.10)"
        )
    }
}

/// Whether `url` points at this machine. Agent Chat only talks to loopback.
func agentSessionIsLoopbackURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
