// swift-tools-version: 5.9
import PackageDescription

// Test the actual agent protocol without UIKit, Keychain, or the embedded Python runtime.
let package = Package(
    name: "PyPhoneAgentProtocol",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PyPhoneAgentProtocol", path: "sources/AgentProtocol"),
        .testTarget(name: "AgentProtocolTests", dependencies: ["PyPhoneAgentProtocol"],
                    path: "tests/AgentProtocol")
    ]
)
