import SwiftUI

typealias MimoMenuPresentation = MimoStatusPresentation

struct MimoMenuBarLabel: View {
    let presentation: MimoMenuPresentation

    var body: some View {
        HStack(spacing: 3) {
            if presentation.isDirect {
                if let country = presentation.country { Text(country).lineLimit(1) }
                directArrow
                if presentation.kind == .checking { Image(systemName: "clock").foregroundStyle(Color.orange) }
                if presentation.kind == .directWarning { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange) }
            } else {
                switch presentation.kind {
                case .direct: directArrow
                case .directWarning: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
                case .checking: Image(systemName: "clock").foregroundStyle(Color.orange)
                case .unavailable: Image(systemName: "info.circle").foregroundStyle(.secondary)
                case .blocked:
                    MenuBarCountryLabel.allowlistStop
                    if let country = presentation.country { Text(country).lineLimit(1) }
                case .verified, .tailnetWarning:
                    if let country = presentation.country { Text(country).lineLimit(1) }
                    else { Image(systemName: "checkmark.shield").foregroundStyle(Color.blue) }
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

    private var directArrow: some View {
        Image(systemName: "arrow.up.right").foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
    }
}
