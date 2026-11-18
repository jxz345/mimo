import SwiftUI

typealias MimoMenuPresentation = MimoStatusPresentation

struct MimoMenuBarLabel: View {
    let presentation: MimoMenuPresentation

    var body: some View {
        HStack(spacing: 3) {
            switch presentation.kind {
            case .direct:
                if let country = presentation.country { Text(country).lineLimit(1) }
                else { Image(systemName: "arrow.up.right") }
            case .directWarning: Image(systemName: "exclamationmark.triangle")
            case .checking: Image(systemName: "clock")
            case .unavailable: Image(systemName: "info.circle")
            case .blocked:
                Image(systemName: ExitIPIndicatorSymbol.outsideAllowlist)
                if let country = presentation.country { Text(country).lineLimit(1) }
            case .verified, .tailnetWarning:
                if let country = presentation.country { Text(country).lineLimit(1) }
                else { Image(systemName: "checkmark.shield") }
                if presentation.kind == .tailnetWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                if presentation.countryChanged {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                }
            }
        }.accessibilityLabel(presentation.accessibilityText)
    }
}
