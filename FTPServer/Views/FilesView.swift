import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    static func contents(of directory: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return FileItem(
                url: url,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct FilesView: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        NavigationStack {
            FolderView(directory: controller.rootDirectory, title: "Files")
                .navigationDestination(for: FileItem.self) { item in
                    FolderView(directory: item.url, title: item.name)
                }
        }
    }
}

private struct FolderView: View {
    let directory: URL
    let title: String

    @Environment(ServerController.self) private var controller
    @State private var items: [FileItem] = []
    @State private var previewURL: URL?
    @State private var showImporter = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: FileItem?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(items) { item in
                row(for: item)
                    .swipeActions {
                        Button(role: .destructive) { delete(item) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            renameText = item.name
                            renaming = item
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        if !item.isDirectory {
                            ShareLink(item: item.url)
                        }
                        Button(role: .destructive) { delete(item) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 40)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import Files", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
        }
        .refreshable { reload() }
        .onAppear(perform: reload)
        .onChange(of: controller.fileSystemRevision) { reload() }
        .quickLookPreview($previewURL, in: items.filter { !$0.isDirectory }.map(\.url))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder(named: newFolderName) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let item = renaming { rename(item, to: renameText) }
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let label = HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.isDirectory ? item.modified.formatted(date: .numeric, time: .omitted) : item.size.formatted(.byteCount(style: .file)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
        if item.isDirectory {
            NavigationLink(value: item) { label }
        } else {
            Button { previewURL = item.url } label: { label }
                .foregroundStyle(.primary)
        }
    }

    private func reload() {
        items = FileItem.contents(of: directory)
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        controller.noteLocalFileChange()
        reload()
    }

    private func delete(_ item: FileItem) {
        perform { try FileManager.default.removeItem(at: item.url) }
    }

    private func createFolder(named name: String) {
        guard let name = validName(name) else { return }
        perform {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        }
    }

    private func rename(_ item: FileItem, to name: String) {
        guard let name = validName(name), name != item.name else { return }
        perform {
            try FileManager.default.moveItem(at: item.url, to: directory.appendingPathComponent(name))
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        perform {
            for source in try result.get() {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: availableURL(for: source.lastPathComponent))
            }
        }
    }

    private func availableURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(counter)"
            candidate = directory.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            errorMessage = "“\(name)” is not a valid name."
            return nil
        }
        return trimmed
    }
}
