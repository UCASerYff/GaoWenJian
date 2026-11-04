import Foundation
import AppKit

@main struct OrganizerHostIntegrationTests {
    @MainActor static func main() throws {
        guard NSApp == nil else { fatalError("Headless test cannot initialize NSApplication") }
        guard CommandLine.arguments.contains("--data-dir"),FileSafety.root.path.hasPrefix("/private/tmp/") else {fatalError("Only isolated synthetic data permitted")}
        let fm=FileManager.default
        let original=FileSafety.root.appendingPathComponent("公开原件.txt")
        try fm.createDirectory(at:FileSafety.root,withIntermediateDirectories:true)
        let bytes=Data("真实逻辑合成原文\n".utf8);try bytes.write(to:original)
        let store=WorkspaceStore()
        guard store.organizerHost.model == nil,!fm.fileExists(atPath:OrganizerHostController.directory.path) else {fatalError("Organizer must be lazy")}
        store.open(original)
        let draft=FileSession(text:"未保存公开稿",kind:.text,dirty:true);store.tabs.append(draft);store.select(draft)
        let ids=store.tabs.map(\.id)
        store.showOrganizer()
        guard store.showingOrganizer,store.tabs.map(\.id)==ids,draft.dirty,draft.text=="未保存公开稿",store.selection==draft.id else {fatalError("Navigating to organizer lost editor state")}
        store.showingNotes=true
        guard !store.showingOrganizer,store.showingNotes,store.tabs.map(\.id)==ids else {fatalError("Notes navigation inconsistent")}
        store.showOrganizer();store.select(draft)
        guard !store.showingOrganizer,!store.showingNotes,draft.dirty else {fatalError("Selecting draft must return to editor")}
        store.showOrganizer();store.showHome()
        guard !store.showingOrganizer,store.selection==nil,store.tabs.map(\.id)==ids else {fatalError("Home must preserve draft")}
        var protected=false
        do {try store.organizerHost.validateMoveSources?([original])} catch {protected=true}
        guard protected else {fatalError("Open source document was allowed to move")}
        protected=false
        do {try store.organizerHost.validateMoveSources?([FileSafety.root.appendingPathComponent("workspace.json")])} catch {protected=true}
        guard protected else {fatalError("Private workspace was allowed to move")}
        guard try Data(contentsOf:original)==bytes,NSApp==nil,!fm.fileExists(atPath:OrganizerHostController.directory.path) else {fatalError("Synthetic source modified or app initialized")}
        let interrupted=FileSafety.root.appendingPathComponent(".organizer-migration-SYNTHETIC.noindex",isDirectory:true)
        try fm.createDirectory(at:interrupted,withIntermediateDirectories:false)
        let resuming=OrganizerHostController();resuming.loadExisting()
        guard resuming.requiresMigrationResume,resuming.start()==nil,!fm.fileExists(atPath:OrganizerHostController.directory.path) else {fatalError("Interrupted migration must not create an empty library")}
        try fm.removeItem(at:interrupted)
        let providerAssertions=try OrganizerActionProviderTests.run(in:FileSafety.root.appendingPathComponent("ProviderFixtures"))
        print("PASS Organizer provider: \(providerAssertions) assertions using real transport/journals and injected presentation; NSApp=nil")
        print("START production organizer migration/activation fault tests")
        try OrganizerMigrationTests.run(in:FileSafety.root.appendingPathComponent("MigrationFixtures"))
        print("PASS Organizer host: lazy library, navigation/draft retention, open-document and private-data move guards; NSApp=nil")
    }
}
