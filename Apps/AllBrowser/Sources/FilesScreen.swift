import SwiftUI
import DesignSystem
import FilesKit
import MediaKit
import StorageKit
import UniformTypeIdentifiers

struct FilesScreen: View {
    @EnvironmentObject private var files: FilesService
    @EnvironmentObject private var playback: PlaybackController
    @State private var showImporter = false
    @State private var renameTarget: LocalFileItem?
    @State private var renameText = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var errorMessage: String?

    private var isAtRoot: Bool {
        files.currentDirectory.standardizedFileURL.path == AppPaths.importedFiles.standardizedFileURL.path
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List {
                    if !isAtRoot {
                        Button {
                            files.goUp()
                        } label: {
                            Label("上级目录", systemImage: "chevron.left")
                        }
                    }
                    ForEach(files.items) { item in
                        fileRow(item)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("文件")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(ByteFormat.string(from: files.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        do { try files.importFile(from: url) }
                        catch { errorMessage = error.localizedDescription }
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("创建") {
                    try? files.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("保存") {
                    if let target = renameTarget {
                        try? files.rename(item: target, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
            .alert("错误", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { files.refresh() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                filterChip(nil, title: "全部")
                ForEach(LocalFileItem.FileCategory.allCases.filter { $0 != .other }, id: \.self) { category in
                    filterChip(category, title: category.title)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(ABColor.surfaceElevated)
    }

    private func filterChip(_ category: LocalFileItem.FileCategory?, title: String) -> some View {
        let selected = files.filter == category
        return Button {
            files.filter = category
            files.refresh()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? ABColor.accent : ABColor.surface)
                .foregroundStyle(selected ? ABColor.background : ABColor.textPrimary)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func fileRow(_ item: LocalFileItem) -> some View {
        Button {
            if item.isDirectory {
                files.openDirectory(item.url)
            } else if item.category == .audio || item.category == .video {
                playback.play(
                    .init(title: item.name, artist: "本地文件", sourceURL: item.url)
                )
            }
        } label: {
            HStack {
                Image(systemName: icon(for: item))
                    .foregroundStyle(ABColor.accent)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(item.name).foregroundStyle(ABColor.textPrimary)
                    if !item.isDirectory {
                        Text(ByteFormat.string(from: item.fileSize))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .contextMenu {
            Button("重命名") {
                renameTarget = item
                renameText = item.name
            }
            Button("删除", role: .destructive) {
                try? files.delete(item: item)
            }
            ShareLink(item: item.url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func icon(for item: LocalFileItem) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.category {
        case .audio: return "music.note"
        case .video: return "film"
        case .image: return "photo"
        case .document: return "doc"
        case .other: return "doc"
        }
    }
}
