import Foundation

struct RemoteMacRuntimeInfo: Codable, Equatable, Sendable {
    let codeAnywhereVersion: String
    let codexVersion: String
    let operatingSystem: String
    let architecture: String
    let appServerPort: Int?
    let taskServicePort: Int?
}
