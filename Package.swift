// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexUsageCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "CodexUsageCore", targets: ["CodexUsageCore"])], targets: [.target(name: "CodexUsageCore", path: "Shared", exclude: ["UsageViews.swift"]), .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"], path: "Tests")])
