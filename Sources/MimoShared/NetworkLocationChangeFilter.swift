import Foundation

/// The Setup: root describes the selected network location, but configd also
/// republishes it when preferences are applied without changing that location.
/// Compare all fields except the apply timestamp; unknown changes stay relevant.
/// Callers serialize access and filter before requesting early traffic blocking.
public struct NetworkLocationChangeFilter {
    public struct Decision {
        public let shouldNotify: Bool
        public let changedFields: [String]
    }

    private var previous: [String: Any]?

    public init() {}

    public mutating func seed(_ value: [String: Any]?) {
        previous = value
    }

    public mutating func evaluate(_ value: [String: Any]?) -> Decision {
        let old = previous
        previous = value
        guard let old, let value,
              let oldSet = old["CurrentSet"] as? String, !oldSet.isEmpty,
              let newSet = value["CurrentSet"] as? String, !newSet.isEmpty else {
            return Decision(shouldNotify: true, changedFields: ["unavailable location"])
        }
        let before = old as NSDictionary, after = value as NSDictionary
        let fields = Set(old.keys).union(value.keys).filter {
            (before[$0] as? NSObject) != (after[$0] as? NSObject)
        }.sorted()
        return Decision(shouldNotify: fields.contains { $0 != "LastUpdated" }, changedFields: fields)
    }
}
