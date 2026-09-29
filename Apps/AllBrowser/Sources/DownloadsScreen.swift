import SwiftUI
import QuickLook
import DesignSystem
import DownloadsKit
import StorageKit

struct DownloadsScreen: View {
    @EnvironmentObject private var downloads: DownloadService
    @State private var previewURL: URL?
    @State private var filter: DownloadFilter = .all

    private enum DownloadFilter: String, CaseIterable, Identifiable {
        case all, completed, blocked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .completed: return "已完成"
            case .blocked: return "已拦截"
            }
        }
    }

    private var filteredItems: [DownloadItem] {
        switch filter {
        case .all: return downloads.items
        case .completed: return downloads.items.filter { $0.state == .completed }
        case .blocked: return downloads.items.filter { $0.state == .blocked || $0.state == .failed }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = downloads.lastBlockedMessage {
                    blockedBanner(message)
                }

                Picker("筛选", selection: $filter) {
                    ForEach(DownloadFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if filteredItems.isEmpty {
                    EmptyStateView(
                        title: "暂无下载",
                        subtitle: "浏览网页时的文件下载会显示在这里。\n不支持下载音视频内容（版权保护）。",
                        systemImage: "arrow.down.circle"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            downloadRow(item)
                                .contextMenu { itemMenu(item) }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                downloads.delete(filteredItems[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(ABColor.background)
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清除已完成与拦截记录", role: .destructive) {
                            downloads.clearCompleted()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("为遵守版权政策，本应用不会下载音视频文件。")
                    .font(.caption2)
                    .foregroundStyle(ABColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ABColor.surfaceElevated)
            }
            .sheet(item: Binding(
                get: { previewURL.map(IdentifiableURL.init) },
                set: { previewURL = $0?.url }
            )) { item in
                DownloadQuickLook(url: item.url)
            }
        }
    }

    private func blockedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(ABColor.accentSecondary)
            Text(message)
                .font(ABFont.body(13))
                .foregroundStyle(ABColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                downloads.clearBlockedBanner()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(ABColor.textSecondary)
            }
        }
        .padding(12)
        .background(ABColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        Button {
            if item.state == .completed, let url = item.fileURL {
                previewURL = url
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: item))
                    .font(.system(size: 22))
                    .foregroundStyle(iconColor(for: item))
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.filename)
                        .foregroundStyle(ABColor.textPrimary)
                        .lineLimit(2)
                    Text(subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if item.state == .downloading {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(item.state != .completed)
    }

    @ViewBuilder
    private func itemMenu(_ item: DownloadItem) -> some View {
        if item.state == .completed, let url = item.fileURL {
            Button("预览") { previewURL = url }
            ShareLink(item: url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        Button("删除", role: .destructive) {
            downloads.delete(item)
        }
    }

    private func iconName(for item: DownloadItem) -> String {
        switch item.state {
        case .downloading: return "arrow.down.circle"
        case .completed: return "doc.fill"
        case .failed: return "xmark.circle"
        case .blocked: return "hand.raised.fill"
        }
    }

    private func iconColor(for item: DownloadItem) -> Color {
        switch item.state {
        case .downloading: return ABColor.accent
        case .completed: return ABColor.accent
        case .failed, .blocked: return ABColor.danger
        }
    }

    private func subtitle(for item: DownloadItem) -> String {
        switch item.state {
        case .downloading:
            return "下载中…"
        case .completed:
            return ByteFormat.string(from: item.byteCount)
        case .failed, .blocked:
            return item.errorMessage ?? "不可下载"
        }
    }
}

private struct IdentifiableURL: Identifiable {
    var id: String { url.path }
    let url: URL
}

private struct DownloadQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
