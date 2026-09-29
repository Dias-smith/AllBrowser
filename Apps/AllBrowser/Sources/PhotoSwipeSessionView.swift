import SwiftUI
import Photos
import DesignSystem
import PhotosKit

struct PhotoSwipeSessionView: View {
    @EnvironmentObject private var photos: PhotosService
    @EnvironmentObject private var organize: PhotoOrganizeSession
    @Environment(\.dismiss) private var dismiss

    @State private var dragOffset: CGSize = .zero
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var showPhotoInfo = false
    @State private var cardFrame: CGRect = .zero
    @State private var albumFrames: [String: CGRect] = [:]

    // Fly animation — Photo A flies on a top layer; Photo B stays as the stable base
    // so settle does not remount the thumbnail (avoids end-of-flight flash).
    @State private var flyingItem: PhotoAssetItem?
    @State private var underlayItem: PhotoAssetItem?
    @State private var flyingAlbumID: String?
    @State private var flyingAsset: PHAsset?
    @State private var flyScale: CGFloat = 1
    @State private var flyOffset: CGSize = .zero
    @State private var flyOpacity: Double = 1
    @State private var albumCoverOpacity: Double = 0

    @GestureState private var isDragging = false

    private let swipeThreshold: CGFloat = 120
    private let flyTravelDuration: TimeInterval = 1.0
    private let flyCrossfadeDuration: TimeInterval = 0.5
    private let cardCorner: CGFloat = 28

    private var isFlying: Bool { flyingItem != nil }

    private var nextItem: PhotoAssetItem? {
        let nextIndex = organize.index + 1
        guard organize.queue.indices.contains(nextIndex) else { return nil }
        return organize.queue[nextIndex]
    }

    /// Stable resting photo under the flying card. Locked during flight so advance
    /// cannot swap in Photo C underneath, and B keeps the same view identity on settle.
    private var baseItem: PhotoAssetItem? {
        if let underlayItem { return underlayItem }
        return organize.current
    }

    private var progressCurrent: Int {
        guard !organize.queue.isEmpty else { return 0 }
        return min(organize.index + 1, organize.queue.count)
    }

    private var progressTotal: Int { organize.queue.count }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: 0) {
                    sessionHeader

                    if organize.isFinished && !isFlying {
                        finishedState
                    } else if organize.current != nil || isFlying {
                        actionHintRow
                            .padding(.top, 10)
                            .padding(.bottom, 14)

                        cardArea
                            .padding(.horizontal, 20)

                        Spacer(minLength: 16)

                        folderBar
                            .padding(.bottom, 8)
                    } else {
                        finishedState
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: SessionCoordinateSpace.name)
            .onPreferenceChange(CardFrameKey.self) { value in
                if !isFlying, value != .zero {
                    cardFrame = value
                }
            }
            .onPreferenceChange(AlbumFrameKey.self) { value in
                albumFrames.merge(value, uniquingKeysWith: { $1 })
            }
        }
        .background(ABColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let toast = organize.toastMessage {
                Text(toast)
                    .font(ABFont.body(13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            organize.clearToast()
                        }
                    }
            }
        }
        .alert("New Album", isPresented: $showNewAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") {
                Task { await createAndAdd() }
            }
            Button("Cancel", role: .cancel) { newAlbumName = "" }
        }
        .alert("Error", isPresented: Binding(
            get: { organize.lastError != nil },
            set: { if !$0 { organize.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(organize.lastError ?? "")
        }
        .sheet(isPresented: $showPhotoInfo) {
            photoInfoSheet
        }
    }

    private var sessionHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ABColor.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ABColor.surface))
            }
            .accessibilityLabel("Back")

            Spacer()

            Text(organize.kind.title)
                .font(ABFont.title(17))
                .foregroundStyle(ABColor.textPrimary)

            Spacer()

            Button {
                organize.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ABColor.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ABColor.surface))
            }
            .disabled(isFlying)
            .opacity(isFlying ? 0.4 : 1)
            .accessibilityLabel("Undo")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var actionHintRow: some View {
        HStack {
            Text("← DELETE")
                .font(.caption.weight(.bold))
                .foregroundStyle(ABColor.danger)
                .tracking(0.6)

            Spacer()

            Text("\(progressCurrent) / \(progressTotal)")
                .font(ABFont.mono(14))
                .foregroundStyle(ABColor.textPrimary)

            Spacer()

            Text("KEEP →")
                .font(.caption.weight(.bold))
                .foregroundStyle(ABColor.accent)
                .tracking(0.6)
        }
        .padding(.horizontal, 28)
        .opacity(isFlying ? 0.35 : 1)
    }

    private var finishedState: some View {
        VStack(spacing: 16) {
            Spacer()
            EmptyStateView(
                title: "Queue complete",
                subtitle: "Review the delete basket anytime, or pick another category.",
                systemImage: "checkmark.circle"
            )
            Button("Done") { dismiss() }
                .buttonStyle(ABPrimaryButtonStyle())
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    /// Storyboard layers:
    /// - Back: Photo B locked as base (full size / opacity) for the whole flight
    /// - Front: Photo A scales + moves (opacity 1), then cross-fades at album
    private var cardArea: some View {
        ZStack {
            if let base = baseItem {
                photoCard(item: base, showsOverlays: !isFlying)
                    .offset(isFlying ? .zero : dragOffset)
                    .rotationEffect(isFlying ? .zero : .degrees(Double(dragOffset.width / 20)))
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CardFrameKey.self,
                                value: isFlying
                                    ? .zero
                                    : geo.frame(in: .named(SessionCoordinateSpace.name))
                            )
                        }
                    )
                    .gesture(isFlying ? nil : dragGesture)
                    .allowsHitTesting(!isFlying)
                    .id(base.id)
            } else if isFlying {
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(ABColor.surface)
            }

            if let flying = flyingItem {
                photoCard(item: flying, showsOverlays: false)
                    .scaleEffect(flyScale, anchor: .center)
                    .offset(flyOffset)
                    .opacity(flyOpacity)
                    .allowsHitTesting(false)
                    .id(flying.id)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(nil, value: isFlying)
    }

    private func photoCard(item: PhotoAssetItem, showsOverlays: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(ABColor.surface)

            PhotoThumbnailView(
                asset: item.asset,
                targetSize: CGSize(width: 900, height: 1200),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsOverlays {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showPhotoInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(10)
                                .background(Circle().fill(.black.opacity(0.28)))
                        }
                        .opacity(max(keepOpacity, deleteOpacity) > 0.15 ? 0.15 : 1)
                        .padding(14)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "sparkle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(12)
                    }
                    .padding(10)
                }

                // KEEP / DELETE: horizontally centered, same top height as before.
                ZStack(alignment: .top) {
                    swipeBadge(title: "DELETE", color: ABColor.danger, opacity: deleteOpacity)
                    swipeBadge(title: "KEEP", color: ABColor.accent, opacity: keepOpacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
    }

    private var photoInfoSheet: some View {
        NavigationStack {
            List {
                if let item = organize.current {
                    if let date = item.creationDate {
                        LabeledContent("Date") {
                            Text(date, style: .date)
                        }
                    }
                    LabeledContent("Type") {
                        Text(item.isVideo ? "Video" : (item.isScreenshot ? "Screenshot" : "Photo"))
                    }
                    LabeledContent("Progress") {
                        Text("\(progressCurrent) / \(progressTotal)")
                    }
                }
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPhotoInfo = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var folderBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Move to album")
                    .font(ABFont.body(14))
                    .foregroundStyle(ABColor.textSecondary)
                Spacer()
                Button {
                    showNewAlbum = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ABColor.background)
                        .frame(width: 30, height: 30)
                        .background(ABColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityLabel("New Album")
                .disabled(isFlying)
                .opacity(isFlying ? 0.4 : 1)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 12) {
                        ForEach(photos.albums) { album in
                            let focused = album.id == organize.focusedAlbumID
                            let receiving = flyingAlbumID == album.id
                            Button {
                                moveCurrent(to: album)
                            } label: {
                                folderChip(
                                    title: album.title,
                                    systemImage: "square.and.arrow.down",
                                    emphasized: focused,
                                    coverAsset: receiving ? flyingAsset : nil,
                                    coverOpacity: receiving ? albumCoverOpacity : 0
                                )
                            }
                            .id(album.id)
                            .disabled(isFlying)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: AlbumFrameKey.self,
                                        value: [album.id: geo.frame(in: .named(SessionCoordinateSpace.name))]
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .onAppear { scrollToFocusedAlbum(using: proxy) }
                    .onChange(of: organize.focusedAlbumID) { _, _ in
                        scrollToFocusedAlbum(using: proxy)
                    }
                }
            }
        }
    }

    private func folderChip(
        title: String,
        systemImage: String,
        emphasized: Bool = false,
        coverAsset: PHAsset? = nil,
        coverOpacity: Double = 0
    ) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(emphasized ? ABColor.background : ABColor.accent)
                    .opacity(1.0 - coverOpacity)

                if let coverAsset {
                    PhotoThumbnailView(asset: coverAsset, targetSize: CGSize(width: 72, height: 72))
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(coverOpacity)
                }
            }
            .frame(width: 28, height: 28)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasized ? ABColor.background : ABColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 88)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(emphasized ? ABColor.accent : ABColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func swipeBadge(title: String, color: Color, opacity: Double) -> some View {
        Text(title)
            .font(.title2.bold())
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color, lineWidth: 3)
            )
            .rotationEffect(.degrees(title == "KEEP" ? 12 : -12))
            .opacity(min(1, opacity * 1.35))
            .scaleEffect(opacity > 0 ? 1 : 0.85)
    }

    private var keepOpacity: Double {
        max(0, Double(dragOffset.width / swipeThreshold))
    }

    private var deleteOpacity: Double {
        max(0, Double(-dragOffset.width / swipeThreshold))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard !isFlying else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isFlying else { return }
                let width = value.translation.width
                if width > swipeThreshold {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = CGSize(width: 500, height: value.translation.height)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        organize.keep()
                        dragOffset = .zero
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } else if width < -swipeThreshold {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = CGSize(width: -500, height: value.translation.height)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        organize.markDeleteCandidate()
                        dragOffset = .zero
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func moveCurrent(to album: PhotoAlbumItem) {
        guard !isFlying, let item = organize.current else { return }

        let source = cardFrame == .zero ? fallbackCardFrame() : cardFrame
        let albumFrame = albumFrames[album.id] ?? fallbackAlbumFrame()
        // Aim at the album icon glyph near the top-center of the vertical chip.
        let target = CGRect(
            x: albumFrame.midX - 14,
            y: albumFrame.minY + 14,
            width: 28,
            height: 28
        )

        let dx = target.midX - source.midX
        let dy = target.midY - source.midY
        let targetScale = min(target.width / max(source.width, 1), target.height / max(source.height, 1))
        let startOffset = dragOffset

        flyingAlbumID = album.id
        flyingAsset = item.asset
        flyScale = 1
        flyOffset = startOffset
        flyOpacity = 1
        albumCoverOpacity = 0
        dragOffset = .zero
        underlayItem = nextItem
        flyingItem = item
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: self.flyTravelDuration)) {
                self.flyOffset = CGSize(width: dx, height: dy)
                self.flyScale = max(targetScale, 0.04)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + self.flyTravelDuration) {
                withAnimation(.easeInOut(duration: self.flyCrossfadeDuration)) {
                    self.flyOpacity = 0
                    self.albumCoverOpacity = 1
                }
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.flyTravelDuration + self.flyCrossfadeDuration + 0.05
            ) {
                Task { @MainActor in
                    await self.organize.addCurrentToAlbum(album)
                    self.settleFlyState()
                }
            }
        }
    }

    private func settleFlyState() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flyingItem = nil
            flyingAlbumID = nil
            flyingAsset = nil
            flyScale = 1
            flyOffset = .zero
            flyOpacity = 1
            albumCoverOpacity = 0
            underlayItem = nil
        }
    }

    private func createAndAdd() async {
        do {
            let album = try await photos.createAlbum(named: newAlbumName)
            newAlbumName = ""
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                moveCurrent(to: album)
            }
        } catch {
            organize.lastError = error.localizedDescription
        }
    }

    private func scrollToFocusedAlbum(using proxy: ScrollViewProxy) {
        guard let id = organize.focusedAlbumID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func fallbackCardFrame() -> CGRect {
        CGRect(x: 24, y: 120, width: UIScreen.main.bounds.width - 48, height: 480)
    }

    private func fallbackAlbumFrame() -> CGRect {
        CGRect(x: 20, y: UIScreen.main.bounds.height - 200, width: 100, height: 72)
    }
}

private enum SessionCoordinateSpace {
    static let name = "PhotoSwipeSessionSpace"
}

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct AlbumFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
