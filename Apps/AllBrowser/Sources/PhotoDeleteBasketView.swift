import SwiftUI
import DesignSystem
import PhotosKit

struct PhotoDeleteBasketView: View {
    @EnvironmentObject private var photos: PhotosService
    @Environment(\.dismiss) private var dismiss

    @State private var items: [PhotoAssetItem] = []
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private let spacing: CGFloat = 4
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                EmptyStateView(
                    title: "Basket empty",
                    subtitle: "Swipe left on photos to add them here before deleting.",
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(items) { item in
                            ZStack(alignment: .topTrailing) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        PhotoThumbnailView(
                                            asset: item.asset,
                                            targetSize: CGSize(width: 360, height: 360)
                                        )
                                    }
                                    .clipped()
                                    .contentShape(Rectangle())

                                Button {
                                    photos.reviewStore.removePendingDelete(item.id)
                                    refresh()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .padding(6)
                                }
                            }
                        }
                    }
                    .padding(spacing)
                }

                VStack(spacing: 10) {
                    Text("\(items.count) photos marked for deletion. They’ll move to Recently Deleted in Photos.")
                        .font(.caption)
                        .foregroundStyle(ABColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text(isDeleting ? "Deleting…" : "Delete \(items.count) Photos")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ABColor.danger)
                    .disabled(isDeleting)
                }
                .padding(16)
                .background(ABColor.surfaceElevated)
            }
        }
        .background(ABColor.background)
        .navigationTitle("Delete Basket")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .confirmationDialog(
            "Delete \(items.count) photos?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from your library. You can recover from Recently Deleted in the Photos app for a limited time.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() {
        items = photos.pendingDeleteItems()
    }

    private func deleteAll() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await photos.deleteAssets(items.map(\.asset))
            refresh()
            if items.isEmpty {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
