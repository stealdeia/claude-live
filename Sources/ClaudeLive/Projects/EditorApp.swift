import Foundation

/// A VS Code-family editor we can inspect. Keeping this a list (rather than a
/// hardcoded bundle id) makes it cheap to add Insiders or a fork later.
struct EditorApp: Hashable {
    let bundleID: String
    let displayName: String
    /// Folder name under ~/Library/Application Support/ that holds workspaceStorage.
    let supportDirName: String
    /// Strings the editor may append to a window title, which are never project names.
    let titleNoise: [String]

    static let vsCode = EditorApp(
        bundleID: "com.microsoft.VSCode",
        displayName: "Visual Studio Code",
        supportDirName: "Code",
        titleNoise: ["Visual Studio Code", "Code"]
    )

    static let vsCodeInsiders = EditorApp(
        bundleID: "com.microsoft.VSCodeInsiders",
        displayName: "Visual Studio Code - Insiders",
        supportDirName: "Code - Insiders",
        titleNoise: ["Visual Studio Code - Insiders", "Code - Insiders"]
    )

    static let all: [EditorApp] = [.vsCode, .vsCodeInsiders]

    var workspaceStorageURL: URL {
        Paths.home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportDirName, isDirectory: true)
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }
}
