import Foundation

public struct MimoManualRefresh: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case queued, checking, succeeded, deferred, failed }
    public var id = UUID()
    public var requestedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var phase: Phase = .queued
    public var message = "Refresh queued."
    public var pending: Bool { phase == .queued || phase == .checking }
    public init(at date: Date) { requestedAt = date }
}
