import Foundation
@testable import PermissionManager

/// In-memory provider: never touches a framework, never shows a sheet.
actor FakePermissionProvider: PermissionProviding {
    nonisolated let kind: PermissionKind
    private var current: PermissionStatus
    private let answerOnRequest: PermissionStatus
    private let delayNanos: UInt64
    private(set) var requestCount = 0
    private(set) var statusCount = 0

    init(_ kind: PermissionKind, status: PermissionStatus, answers: PermissionStatus = .granted, delayNanos: UInt64 = 0) {
        self.kind = kind
        self.current = status
        self.answerOnRequest = answers
        self.delayNanos = delayNanos
    }

    func status() async -> PermissionStatus {
        statusCount += 1
        return current
    }

    func request() async -> PermissionStatus {
        requestCount += 1
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if current == .notDetermined { current = answerOnRequest }
        return current
    }

    func setStatus(_ status: PermissionStatus) { current = status }
}
