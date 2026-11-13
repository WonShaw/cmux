import SwiftUI
import CmuxAppKitSupportUI

/// A Bonsplit terminal tab whose panel registry entry is stale must remain
/// explainable instead of falling through to an empty view.
struct TerminalPanelUnavailableView: View {
    let appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(
                magnified: "exclamationmark.triangle",
                pointSize: 28,
                tint: Color(nsColor: .secondaryLabelColor)
            )
            Text(String(localized: "terminalPanel.unavailable.title", defaultValue: "Terminal unavailable"))
                .cmuxFont(size: 14, weight: .semibold)
                .foregroundStyle(.primary)
            Text(String(localized: "terminalPanel.unavailable.detail", defaultValue: "Close this tab and open a new terminal."))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
