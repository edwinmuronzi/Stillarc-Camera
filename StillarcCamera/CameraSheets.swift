import AVKit
import SwiftUI
import UIKit

struct FnSheet: View {
    @Bindable var store: CameraStore
    var onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Starts short, so the viewfinder stays in view while styles are tried.
    @State private var detent: PresentationDetent = Self.compact
    @State private var thumbs: [String: UIImage] = [:]
    @State private var showStudio = false
    @State private var showShootingTools = false

    private static let compact = PresentationDetent.height(300)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Camera style") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(store.allLooks) { look in
                                    styleButton(look)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Text(detent == Self.compact
                            ? "Tap a style and watch the viewfinder. Pull up for look details, LUT and video options."
                            : "Styles show live in the viewfinder. With a style on, the graded photo saves to Photos; your original remains in the gallery.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Button {
                        showStudio = true
                    } label: {
                        Label("Open the look studio", systemImage: "slider.horizontal.below.rectangle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Theme.gold, in: Capsule())
                    }

                    Button {
                        showShootingTools = true
                    } label: {
                        Label("Shooting tools", systemImage: "camera.badge.ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                    }

                    section("Look details") {
                        lookDetails
                    }

                    section("LUT") {
                        ForEach(store.luts) { lut in
                            HStack {
                                Button {
                                    store.selectedLUT = store.selectedLUT == lut ? nil : lut
                                } label: {
                                    HStack {
                                        Image(systemName: store.selectedLUT == lut ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(Theme.gold)
                                        Text(lut.name)
                                            .foregroundStyle(.white)
                                        if lut.isBuiltIn {
                                            Text("Built in")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white.opacity(0.45))
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                if lut.isBuiltIn == false {
                                    Button(role: .destructive) {
                                        store.removeLUT(lut)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }
                        }
                        Toggle("Bake LUT into photos and video", isOn: $store.bakeLUT)
                            .tint(Theme.gold)
                        Button {
                            dismiss()
                            onImport()
                        } label: {
                            Label("Import .cube LUT", systemImage: "square.and.arrow.down")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("The viewfinder shows the full LUT when its preview is on. With bake on, the LUT is saved into photos and video. Dual Shot saves only two videos, with the look and baked LUT applied.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    section("Video") {
                        Picker("Gamma", selection: $store.logProfile) {
                            ForEach(LogProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(logNote)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                        Toggle("Dual shot", isOn: $store.dualShot)
                            .tint(Theme.gold)
                        Text("Capture a landscape video and a vertical reel at the same time. One recording saves as two videos: landscape 16:9 and vertical 9:16.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(20)
            }
            .background(Theme.ink)
            .navigationTitle("Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { buildThumbs() }
            .onChange(of: store.allLooks.map(\.id)) { _, _ in buildThumbs() }
            .fullScreenCover(isPresented: $showStudio) {
                LookStudio(store: store)
            }
        }
        .presentationDetents([Self.compact, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .sheet(isPresented: $showShootingTools) { ShootingToolsSheet(store: store) }
        .presentationBackground(Theme.ink.opacity(0.94))
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // Strength, and each detail of the chosen look, on or off.
    @ViewBuilder
    private var lookDetails: some View {
        let recipe = LookRecipe.recipe(for: store.look.id)
        let hasLook = store.look.id != "standard"

        VStack(alignment: .leading, spacing: 12) {
            if hasLook {
                HStack {
                    Text("Strength")

                    Spacer()

                    Text("\(Int((store.lookOptions.strength * 100).rounded()))%")
                        .foregroundStyle(.white.opacity(0.6))
                }

                Slider(
                    value: Binding(
                        get: { Double(store.lookOptions.strength) },
                        set: { store.lookOptions.strength = Float($0) }
                    ),
                    in: 0...1
                )
                .tint(Theme.gold)

                if recipe.vignette > 0 {
                    Toggle("Dark corners", isOn: $store.lookOptions.vignetteOn)
                        .tint(Theme.gold)
                }

                if recipe.glow > 0 {
                    Toggle("Glow", isOn: $store.lookOptions.glowOn)
                        .tint(Theme.gold)
                }

                if recipe.soften > 0 || recipe.sharpen > 0 {
                    Toggle(
                        recipe.sharpen > 0 ? "Sharpening" : "Softness",
                        isOn: $store.lookOptions.softnessOn
                    )
                    .tint(Theme.gold)
                }
            }

            Toggle("Date stamp", isOn: $store.lookOptions.dateStamp)
                .tint(Theme.gold)

            Text("The date stamp adds an orange date to the corner, like a compact film camera. It shows in the viewfinder, in saved photos and in graded video.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func styleButton(_ look: FilmLook) -> some View {
        let selected = store.look.id == look.id

        return Button {
            store.look = look
        } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = thumbs[look.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Theme.gold : .white.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                }

                Text(look.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 84)
                    .foregroundStyle(selected ? Theme.gold : .white)
            }
        }
        .buttonStyle(.plain)
    }

    // Each style applied to a small sample, so the strip shows what it does.
    private func buildThumbs() {
        guard let base = LookPreview.sample(from: store, longSide: 220) else { return }

        let list = store.allLooks.map {
            ($0.id, StyleParams(look: $0, options: LookOptions(), dials: nil))
        }

        Task {
            let result = await Task.detached(priority: .utility) { () -> [String: UIImage] in
                var made: [String: UIImage] = [:]

                for (id, params) in list {
                    if let image = LookPreview.render(base, params: params) {
                        made[id] = image
                    }
                }

                return made
            }.value

            thumbs = result
        }
    }

    private var logNote: String {
        switch store.logProfile {
        case .off:
            "Standard video gamma."
        case .log:
            store.caps.supportsLog ? "This iPhone can record Apple Log." : "Apple Log is not on this camera, so video stays in standard gamma."
        case .log2:
            store.caps.supportsLog2 ? "This iPhone can record Apple Log 2." : "Apple Log 2 is not on this camera, so video stays in standard gamma."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

struct SettingsSheet: View {
    @Bindable var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @State private var showStudio = false

    private var codecBinding: Binding<RecordingCodec?> {
        Binding(
            get: { store.selectedCodec },
            set: { next in
                if let next {
                    store.selectCodec(next)
                }
            }
        )
    }

    private var resolutionBinding: Binding<RecResolution?> {
        Binding(
            get: { store.recSettings.resolution },
            set: { store.selectResolution($0) }
        )
    }

    private var frameRateBinding: Binding<Int?> {
        Binding(
            get: { store.effectiveRecordingSettings.frameRate },
            set: { store.selectFrameRate($0) }
        )
    }

    private var bitrateBinding: Binding<RecBitrate> {
        Binding(
            get: { store.recSettings.bitrate },
            set: { store.selectBitrate($0) }
        )
    }

    private var recordingLocked: Bool {
        store.isRecording
    }

    private var isProRes: Bool {
        store.selectedCodec?.isProRes == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Looks") {
                    Button {
                        showStudio = true
                    } label: {
                        Label("Look studio and presets", systemImage: "slider.horizontal.below.rectangle")
                    }

                    Text("Try looks with the Quality and Tone dials, and make your own presets from an existing one, from scratch, or at random.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Viewfinder") {
                    Toggle("Thirds grid", isOn: $store.grid)
                    Toggle("Level line", isOn: $store.showLevel)

                    if store.showPeaking {
                        Picker("Peaking colour", selection: $store.peakColor) {
                            ForEach(PeakColor.allCases) { colour in
                                Text(colour.title).tag(colour)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Peaking sensitivity")

                                Spacer()

                                Text("\(Int((store.peakSensitivity * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(store.peakSensitivity) },
                                    set: { store.peakSensitivity = Float($0) }
                                ),
                                in: 0...1
                            )
                        }
                    }

                    Picker("Frame", selection: $store.aspect) {
                        ForEach(FrameAspect.allCases, id: \.self) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }

                    Picker("Save", selection: $store.saveTarget) {
                        ForEach(SaveTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                }

                Section("Discover StillarcCamera") {
                    Button("Replay the feature tour", systemImage: "sparkles.rectangle.stack") { store.showWelcome = true }
                }

                Section("Shooting") {
                    Toggle("Preserve settings", isOn: $store.preserveSettings)
                    Toggle("Lock white balance while recording", isOn: $store.lockWBOnRecord)
                    Toggle("Mirror front camera", isOn: $store.mirrorFrontCamera)
                        .disabled(store.isRecording || store.pendingPhotoCount > 0 || store.motionExposureActive)
                        .accessibilityIdentifier("mirrorFrontCamera")
                    Text("Mirror on shows and saves selfies like a mirror. Turn it off for a natural, unmirrored preview, photo and video. This choice is remembered when you reopen Stillarc.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Stabilization", selection: $store.stabilization) {
                        ForEach(StabilizationChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .disabled(store.isRecording)

                    Picker("Timelapse interval", selection: $store.timelapseInterval) {
                        Text("Off").tag(0)
                        Text("1 second").tag(1)
                        Text("2 seconds").tag(2)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }

                    Text("Photo modes take a photo every interval. Video mode records a timelapse video.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    Picker(
                        "Microphone",
                        selection: Binding(
                            get: { store.selectedMicUID },
                            set: { store.selectMic($0) }
                        )
                    ) {
                        Text("Automatic").tag("")

                        ForEach(store.micInputs) { input in
                            Text(input.name).tag(input.uid)
                        }
                    }

                    if store.micGainAvailable {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Input gain")

                                Spacer()

                                Text("\(Int((store.micGain * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(store.micGain) },
                                    set: { store.setMicGain(Float($0)) }
                                ),
                                in: 0...1
                            )
                        }
                    }
                }

                Section {
                    Picker("Codec", selection: codecBinding) {
                        if store.availableCodecs.isEmpty {
                            Text("Discovering…").tag(RecordingCodec?.none)
                        }

                        ForEach(store.availableCodecs) { codec in
                            Text(codec.title).tag(Optional(codec))
                        }
                    }
                    .disabled(recordingLocked)

                    Picker("Resolution", selection: resolutionBinding) {
                        Text("Auto").tag(RecResolution?.none)

                        ForEach(store.videoOptions.resolutions) { resolution in
                            Text(resolution.title).tag(Optional(resolution))
                        }
                    }
                    .disabled(recordingLocked || store.videoOptions.locked)

                    Picker("Frame rate", selection: frameRateBinding) {
                        if !store.dualShot { Text("Auto").tag(Int?.none) }

                        ForEach(
                            store.videoOptions.frameRates(for: store.recSettings.resolution).filter { !store.dualShot || $0 <= 30 },
                            id: \.self
                        ) { fps in
                            Text("\(fps) fps").tag(Optional(fps))
                        }
                    }
                    .disabled(recordingLocked || store.videoOptions.locked)

                    Picker("Bitrate", selection: bitrateBinding) {
                        ForEach(RecBitrate.allCases) { bitrate in
                            Text(store.bitrateTitle(bitrate)).tag(bitrate)
                        }
                    }
                    .disabled(
                        recordingLocked
                            || isProRes
                            || store.videoOptions.bitrateSupported == false
                    )
                } header: {
                    Text("Video recording")
                } footer: {
                    Text(recordingNote)
                }

                Section("Files") {
                    Toggle("Save captures in app",isOn:$store.saveInApp)
                    Toggle("Save to Photos", isOn: $store.saveToPhotos)
                    Picker("Automatically delete app copies",selection:$store.autoDeleteAfter) {
                        ForEach(CaptureRetention.allCases) { Text($0.title).tag($0) }
                    }
                    Text("At least one save destination stays on. Turning off in-app saving affects new captures; existing items stay until you delete them or automatic cleanup applies. Cleanup uses capture age, runs when you open or return to the app, and applies to existing and future app copies. Photos is never deleted. Failed Photos saves stay in the app as recovery copies.").font(.footnote).foregroundStyle(.secondary)
                    Text("Rangefinder keeps the wide frame and writes the frame-line crop beside it when BOTH is selected. With a style or baked LUT on, each is saved untouched and graded. RAW adds a DNG when the camera supports it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("This camera") {
                    LabeledContent("Capture", value: store.caps.hasCamera ? "Live" : "Preview scene")
                    LabeledContent("Apple Log", value: store.caps.supportsLog ? "Available" : "Unavailable")
                    LabeledContent("Apple Log 2", value: store.caps.supportsLog2 ? "Available" : "Unavailable")
                    LabeledContent("Dual camera", value: store.caps.supportsMultiCam ? "Available" : "Vertical crop fallback")
                    LabeledContent("RAW", value: store.caps.supportsRaw ? "Available" : "Unavailable")
                }
            }
            .fullScreenCover(isPresented: $showStudio) {
                LookStudio(store: store)
            }
            .navigationTitle("Settings")
            .onAppear { store.refreshMics() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var recordingNote: String {
        if store.videoOptions.locked {
            return "Dual shot picks the resolution and frame rate automatically."
        }

        if isProRes {
            return "ProRes records at a fixed bitrate. Choose HEVC or H.264 to set one."
        }

        if store.videoOptions.bitrateSupported == false {
            return "This format does not allow a custom bitrate. Resolution and frame rate options follow the current gamma (Standard, Log or Log 2)."
        }

        return "Only options this camera supports in the current gamma are listed. Changing resolution or frame rate refreshes the available codecs."
    }
}

struct GallerySheet: View {
    @Bindable var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var deletion: Set<UUID> = []
    @State private var confirmDeletion = false

    private var selectedFiles: [URL] {
        var seen: Set<URL> = []
        return store.captures.filter { selected.contains($0.id) }.flatMap { item -> [URL] in
            let grade = store.graded[AnyHashable(item.id)]
            let files: [URL?]
            if let movie = item.movieURL {
                files = [grade?.movie ?? movie, grade?.storiesMovie ?? item.storiesURL]
            } else {
                files = [grade?.cropURL ?? item.cropPhotoURL ?? grade?.fullURL ?? item.fullPhotoURL]
            }
            return files.compactMap { $0 }.filter { seen.insert($0).inserted }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.captures.isEmpty {
                    ContentUnavailableView("No frames yet", systemImage: "viewfinder", description: Text("Your photos and videos will appear here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(store.captures) { item in
                                Group {
                                    if selecting {
                                        Button {
                                            if !selected.insert(item.id).inserted { selected.remove(item.id) }
                                        } label: {
                                            thumbnail(item)
                                                .overlay(alignment: .topTrailing) {
                                                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                        .font(.title2).symbolRenderingMode(.palette)
                                                        .foregroundStyle(selected.contains(item.id) ? Theme.gold : .white, .black.opacity(0.65))
                                                        .padding(10)
                                                }
                                        }.buttonStyle(.plain)
                                        .accessibilityLabel("Select \(item.mode.title) from \(item.date.formatted())")
                                        .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
                                    } else {
                                        NavigationLink {
                                            CaptureDetail(store: store, item: item, graded: store.graded[AnyHashable(item.id)], info: store.clipInfo[AnyHashable(item.id)])
                                        } label: { thumbnail(item) }
                                        .contextMenu {
                                            Button("Delete", role: .destructive) { requestDelete([item.id]) }
                                        }
                                    }
                                }.disabled(store.deletingGallery || store.editingPhotos.contains(item.id))
                            }
                        }.padding(16)
                    }
                }
            }
            .background(Theme.ink)
            .navigationTitle(selecting ? "\(selected.count) selected" : "Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if selecting {
                        let files = selectedFiles
                        if !files.isEmpty {
                            ShareLink(items: files) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share selected captures")
                        }
                    }
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                        .disabled(store.captures.isEmpty || store.deletingGallery)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if store.deletingGallery { ProgressView("Deleting…") }
                    else if selecting {
                        Button(selected.count == store.captures.count ? "Deselect all" : "Select all") {
                            selected = selected.count == store.captures.count ? [] : Set(store.captures.filter { !store.editingPhotos.contains($0.id) }.map(\.id))
                        }
                        Spacer()
                        Button(role: .destructive) { requestDelete(selected) } label: {
                            HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete (\(selected.count))") }
                        }.tint(.red).disabled(selected.isEmpty)
                    } else {
                        Spacer()
                        Button(role: .destructive) { requestDelete(Set(store.captures.map(\.id))) } label: {
                            HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete all") }
                        }.tint(.red).disabled(store.captures.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete \(deletion.count) item\(deletion.count == 1 ? "" : "s") from the app gallery?", isPresented: $confirmDeletion, titleVisibility: .visible) {
                Button("Delete \(deletion.count) item\(deletion.count == 1 ? "" : "s")", role: .destructive) {
                    store.deleteCaptures(deletion)
                    selected.subtract(deletion); deletion = []
                    if store.captures.isEmpty { selecting = false }
                }
            } message: { Text("This removes the app’s originals and edits. Copies already saved to Photos are not deleted.") }
            .onChange(of: store.captures.map(\.id)) { _, ids in selected.formIntersection(ids) }
        }.tint(Theme.gold).preferredColorScheme(.dark)
        #if DEBUG
        .onAppear {
            GalleryVerification.didPresent()
            if ProcessInfo.processInfo.arguments.contains("--select-gallery") { selecting = true; selected = Set(store.captures.prefix(2).map(\.id)) }
        }
        #endif
    }
    private func requestDelete(_ ids: Set<UUID>) {
        deletion = ids.subtracting(store.editingPhotos)
        if !deletion.isEmpty { confirmDeletion = true }
    }
    private func thumbnail(_ item: CaptureItem) -> some View {
        CaptureThumb(item: item, graded: store.graded[AnyHashable(item.id)], info: store.clipInfo[AnyHashable(item.id)])
    }
}

struct CaptureThumb: View {
    let item: CaptureItem
    var graded: GradedStills?
    var info: ClipInfo?

    @State private var videoFrame: UIImage?
    @State private var diskPhoto: UIImage?

    private var still: UIImage? {
        diskPhoto ?? graded?.crop ?? graded?.full ?? item.cropImage ?? item.fullImage
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = still ?? videoFrame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }

            if item.movieURL != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 6) {
                Text(item.simulated ? "Preview" : item.mode.title)
                    .pill()

                if let info {
                    Text(String(format: "CLIP %02d", info.number))
                        .pill()
                }

                if graded != nil {
                    Text("Graded")
                        .pill()
                }
            }
            .padding(8)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: graded?.cropURL ?? graded?.fullURL ?? item.cropPhotoURL ?? item.fullPhotoURL) {
            guard let url = graded?.cropURL ?? graded?.fullURL ?? item.cropPhotoURL ?? item.fullPhotoURL else { return }
            let image = await GalleryThumbnails.shared.image(at: url)
            guard !Task.isCancelled else { return }; diskPhoto = image
        }
        .onDisappear { diskPhoto = nil; videoFrame = nil }
        .task(id: item.movieURL) {
            guard still == nil, let url = item.movieURL else { return }
            let image = await GalleryThumbnails.shared.image(at: url, video: true)
            guard !Task.isCancelled else { return }
            videoFrame = image
        }
    }
}

private extension Text {
    func pill() -> some View {
        font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.gold, in: Capsule())
    }
}

enum VideoFrame {
    static func load(from url: URL, maxSide: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)

        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }
}

enum StillVersion: String, CaseIterable, Identifiable {
    case graded = "Graded"
    case original = "Original"

    var id: String { rawValue }
}

struct CaptureDetail: View {
    let store: CameraStore
    let item: CaptureItem
    var initialGraded: GradedStills?
    var graded: GradedStills? { store.graded[AnyHashable(item.id)] ?? initialGraded }
    var info: ClipInfo?

    init(store: CameraStore, item: CaptureItem, graded: GradedStills?, info: ClipInfo?) {
        self.store = store; self.item = item; self.initialGraded = graded; self.info = info
    }

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showPhotoEditor = false

    @State private var version: StillVersion = .graded
    @State private var master: AVPlayer?
    @State private var stories: AVPlayer?
    @State private var gradedMaster: AVPlayer?

    private var showingGraded: Bool {
        (store.graded[AnyHashable(item.id)] ?? graded) != nil && version == .graded
    }

    @State private var fullResolutionPreview: UIImage?
    @State private var cropResolutionPreview: UIImage?
    private var fullPhotoURL: URL? { showingGraded ? (graded?.fullURL ?? item.fullPhotoURL) : item.fullPhotoURL }
    private var cropPhotoURL: URL? { showingGraded ? (graded?.cropURL ?? item.cropPhotoURL) : item.cropPhotoURL }
    private var sharePhotoURL: URL? { cropPhotoURL ?? fullPhotoURL }

    // The picture the share button sends: the version on screen.
    private var shareImage: UIImage? {
        if showingGraded {
            return graded?.crop ?? graded?.full ?? item.cropImage ?? item.fullImage
        }

        return item.cropImage ?? item.fullImage
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            Text(value)
                .foregroundStyle(.white)
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                if let info {
                    VStack(spacing: 8) {
                        infoRow("Clip", String(format: "CLIP %02d", info.number))
                        infoRow("Timecode", "\(info.start) – \(info.end)")
                        infoRow("Codec", info.codec)
                        infoRow("Gamma", info.gamma)

                        if let resolution = info.resolution {
                            infoRow("Resolution", resolution)
                        }

                        infoRow("Frame rate", "\(info.frameRate) fps")
                    }
                    .padding(14)
                    .background(
                        Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }

                if graded != nil, item.movieURL == nil {
                    Picker("Version", selection: $version) {
                        ForEach(StillVersion.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let full = fullResolutionPreview ?? (showingGraded ? (graded?.full ?? item.fullImage) : item.fullImage) {
                    labeled(showingGraded && store.photoEdits[item.id]?.hasCustomFraming == true ? "Edited photo" : "Full frame", image: full)
                }

                if cropPhotoURL != fullPhotoURL, let crop = cropResolutionPreview ?? (showingGraded ? (graded?.crop ?? item.cropImage) : item.cropImage) {
                    labeled("Frame lines", image: crop)
                }

                if item.fullPhotoURL != nil || item.cropPhotoURL != nil {
                    Button { showPhotoEditor = true } label: { Label("Develop photo", systemImage: "slider.horizontal.3") }
                        .tint(Theme.gold)
                    Text("Adjust the look, crop, horizon and saved size. New depth captures also let you change background blur. Your original stays safe.").font(.caption).foregroundStyle(.secondary)
                }

                if let live = item.livePhotoMovieURL {
                    ShareLink(item: live) { Label("Share Live Photo motion", systemImage: "livephoto") }
                    Text("The Live Photo plays in Photos when it was saved there. This shares its motion file separately.").font(.caption).foregroundStyle(.secondary)
                }
                if let raw = item.rawURL {
                    ShareLink(item: raw) { Label("Share RAW", systemImage: "square.and.arrow.up") }
                }

                if let movie = item.movieURL {
                    Text("Master")
                        .font(.headline)
                    if let master {
                        VideoPlayer(player: master)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    ShareLink(item: movie) { Label("Share master", systemImage: "square.and.arrow.up") }
                }

                if let gradedMovie = graded?.movie {
                    Text("Graded master")
                        .font(.headline)
                    if let gradedMaster {
                        VideoPlayer(player: gradedMaster)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    ShareLink(item: gradedMovie) { Label("Share graded master", systemImage: "square.and.arrow.up") }
                }

                if let storiesURL = item.storiesURL {
                    Text("Stories")
                        .font(.headline)
                    if let stories {
                        VideoPlayer(player: stories)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    ShareLink(item: storiesURL) { Label("Share Stories", systemImage: "square.and.arrow.up") }
                }
            }
            .padding(20)
        }
        .background(Theme.ink)
        .navigationTitle(item.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = sharePhotoURL {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                } else if let image = shareImage {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Photo", image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task(id: sharePhotoURL) {
            let full = fullPhotoURL; let crop = cropPhotoURL
            fullResolutionPreview = nil; cropResolutionPreview = nil
            let images = await Task.detached(priority: .userInitiated) {
                let first = full.flatMap { try? Data(contentsOf: $0) }.flatMap { PreparedStill.thumbnail($0, maxPixel: 2560, hdr: true) }
                let second = crop == full ? nil : crop.flatMap { try? Data(contentsOf: $0) }.flatMap { PreparedStill.thumbnail($0, maxPixel: 2560, hdr: true) }
                return (first, second)
            }.value
            guard !Task.isCancelled else { return }
            fullResolutionPreview = images.0; cropResolutionPreview = images.1
        }
        .sheet(isPresented: $showPhotoEditor) { PhotoEditor(store: store, item: item) }
        .confirmationDialog(
            "Delete this capture from the gallery?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(item)
                dismiss()
            }
        } message: {
            Text("Copies already saved to Photos are not removed.")
        }
        .onAppear {
            // Built once, so redraws never replace a playing video.
            if master == nil, let url = item.movieURL {
                master = AVPlayer(url: url)
            }

            if stories == nil, let url = item.storiesURL {
                stories = AVPlayer(url: url)
            }

            if gradedMaster == nil, let url = graded?.movie {
                gradedMaster = AVPlayer(url: url)
            }
        }
        .onChange(of: graded?.movie) { _, url in
            if gradedMaster == nil, let url {
                gradedMaster = AVPlayer(url: url)
            }
        }
        .onDisappear {
            master?.pause()
            stories?.pause()
            gradedMaster?.pause()
        }
    }

    private func labeled(_ title: String, image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .allowedDynamicRange(.high)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

extension StyleParams {
    init(look: FilmLook) {
        self.init(look: look, options: LookOptions())
    }
}
