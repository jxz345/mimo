import AppIntents

enum MimoDestination: String, AppEnum {
    case dashboard

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mimo screen")
    static let caseDisplayRepresentations: [MimoDestination: DisplayRepresentation] = [
        .dashboard: DisplayRepresentation(title: "Dashboard")
    ]
}

/// Add this file to both the app target and the widget-extension target.
/// `OpenIntent` brings the app to the foreground when the Control Center button is used.
struct OpenMimoDashboardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Mimo"

    @Parameter(title: "Destination", default: .dashboard)
    var target: MimoDestination

    /// App Intents needs a parameterless initializer to deserialize the intent.
    init() {}

    /// The explicit wrapped-value initializer prevents Swift from selecting the
    /// property-wrapper (`IntentParameter`) initializer at a ControlWidget call site.
    init(target: MimoDestination) {
        self.target = target
    }
}
