// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleNotesMCP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppleNotesMCP", targets: ["AppleNotesMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "SQLiteVecBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../Vendor/sqlite-vec"),
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_VEC_OMIT_FS")
            ]
        ),
        .target(
            name: "AppleNotesMCPLibrary",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "CSQLite",
                "SQLiteVecBridge"
            ],
            path: "Sources/AppleNotesMCP",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AppleNotesMCP",
            dependencies: [
                "AppleNotesMCPLibrary"
            ],
            path: "Sources/AppleNotesMCPExecutable"
        ),
        .executableTarget(
            name: "AppleNotesMCPTestHarness",
            dependencies: [
                "AppleNotesMCP",
                "AppleNotesMCPLibrary",
                "CSQLite"
            ],
            path: "Tests/AppleNotesMCPTestHarness"
        ),
        .testTarget(
            name: "AppleNotesMCPTests",
            dependencies: [
                "AppleNotesMCPTestHarness"
            ],
            path: "Tests/AppleNotesMCPTests"
        )
    ]
)
