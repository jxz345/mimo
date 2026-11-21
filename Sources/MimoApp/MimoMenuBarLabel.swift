import SwiftUI

typealias MimoMenuPresentation = MimoStatusPresentation

struct MimoMenuBarLabel: View {
    let presentation: MimoMenuPresentation

    var body: some View {
        HStack(spacing: 3) {
            if presentation.isDirect {
                countryLabel
                directArrow
                if presentation.kind == .checking { Image(systemName: "clock").foregroundStyle(Color.orange) }
                if presentation.kind == .directWarning || presentation.kind == .tailnetWarning { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange) }
            } else {
                switch presentation.kind {
                case .direct: directArrow
                case .directWarning: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
                case .checking:
                    if presentation.trafficIsBlocked { MenuBarCountryLabel.allowlistStop }
                    Image(systemName: "clock").foregroundStyle(Color.orange)
                case .unavailable: Image(systemName: "info.circle").foregroundStyle(.secondary)
                case .blocked:
                    MenuBarCountryLabel.allowlistStop
                    countryLabel
                case .verified, .tailnetWarning:
                    countryLabel
                    Image(systemName: "checkmark.shield").foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
                    if presentation.kind == .tailnetWarning {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    }
                    if presentation.countryChanged {
                        Image(systemName: "circle.fill").font(.system(size: 6))
                    }
                }
            }
        }.accessibilityLabel(presentation.accessibilityText)
    }

    @ViewBuilder
    private var countryLabel: some View {
        if let country = presentation.country { Text(country).lineLimit(1) }
        else {
            Image(systemName: "globe").foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
        }
    }

    private var directArrow: some View {
        Image(systemName: "arrow.up.right").foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
    }
}
