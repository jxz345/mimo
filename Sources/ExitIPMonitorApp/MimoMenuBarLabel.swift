import SwiftUI

typealias MimoMenuPresentation = MimoStatusPresentation

struct MimoMenuBarLabel: View {
    let presentation: MimoMenuPresentation

    var body: some View {
        HStack(spacing: 3) {
            switch presentation.kind {
            case .direct: Image(systemName: "arrow.up.right")
            case .checking: Image(systemName: "clock")
            case .unavailable: Image(systemName: "info.circle")
            case .blocked:
                Image(systemName: ExitIPIndicatorSymbol.outsideAllowlist).foregroundStyle(.red)
                if let country = presentation.country { Text(country).lineLimit(1) }
            case .verified, .tailnetWarning:
                if let country = presentation.country { Text(country).lineLimit(1) }
                else { Image(systemName: "checkmark.shield") }
                if presentation.kind == .tailnetWarning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if presentation.countryChanged {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.yellow)
                }
            }
        }.accessibilityLabel(presentation.accessibilityText)
    }
}
