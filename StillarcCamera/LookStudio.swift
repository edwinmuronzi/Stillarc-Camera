import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Preview rendering

// Draws a sample picture through a look, the same way photos and video are
// graded, so the preview shows what you will get.
nonisolated enum LookPreview {
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    static func render(_ base: CGImage, params: StyleParams) -> UIImage? {
        let input = CIImage(cgImage: base, options: [.colorSpace: NSNull()])
        let output = StyleGrade.apply(params, to: input)

        guard let cg = context.createCGImage(
            output,
            from: input.extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else {
            return nil
        }

        return UIImage(cgImage: cg)
    }

    // The sample: your last photo, or the built-in harbour scene.
    @MainActor
    static func sample(from store: CameraStore, longSide: CGFloat) -> CGImage? {
        var picture: UIImage?

        if let chosen = SampleLibrary.shared.selectedImage() {
            // A real photo you picked for the previews.
            picture = chosen
        } else if let last = store.captures.first(where: { $0.simulated == false })?.fullImage {
            picture = last
        } else {
            let renderer = ImageRenderer(
                content: DemoHarborScene().frame(width: 825, height: 1100)
            )
            renderer.scale = 1
            picture = renderer.uiImage
        }

        guard let picture else { return nil }

        let ratio = min(1, longSide / max(picture.size.width, picture.size.height))
        let size = CGSize(
            width: max(1, (picture.size.width * ratio).rounded()),
            height: max(1, (picture.size.height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in picture.draw(in: CGRect(origin: .zero, size: size)) }
            .cgImage
    }
}

// MARK: - Sample photos

// Real pictures for the previews, from your own photos. Add a few, like a
// portrait, a landscape and a night scene, and the looks show on them.
@Observable
final class SampleLibrary {
    static let shared = SampleLibrary()

    struct Item: Identifiable, Equatable {
        let id: String
        let url: URL
    }

    var items: [Item] = []

    // nil means automatic: your last photo, or the built-in harbour scene.
    var selectedID: String?

    private let folder: URL

    private init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        folder = documents.appendingPathComponent("LookSamples", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        reload()

        if let saved = UserDefaults.standard.string(forKey: "frameline.sample.selected"),
           items.contains(where: { $0.id == saved }) {
            selectedID = saved
        }
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []

        items = urls
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Item(id: $0.lastPathComponent, url: $0) }
    }

    // Keeps a copy at a sensible size, so previews stay quick.
    func add(_ data: Data) {
        guard let picture = UIImage(data: data) else { return }

        let longSide: CGFloat = 1600
        let ratio = min(1, longSide / max(picture.size.width, picture.size.height))

        let size = CGSize(
            width: max(1, (picture.size.width * ratio).rounded()),
            height: max(1, (picture.size.height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        let jpeg = UIGraphicsImageRenderer(size: size, format: format)
            .jpegData(withCompressionQuality: 0.9) { _ in
                picture.draw(in: CGRect(origin: .zero, size: size))
            }

        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).jpg"

        do {
            try jpeg.write(to: folder.appendingPathComponent(name))
        } catch {
            return
        }

        reload()
        select(name)
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))

        reload()

        if selectedID == id {
            select(nil)
        }
    }

    func select(_ id: String?) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "frameline.sample.selected")
    }

    func selectedImage() -> UIImage? {
        guard let id = selectedID,
              let item = items.first(where: { $0.id == id }) else {
            return nil
        }

        return UIImage(contentsOfFile: item.url.path)
    }
}

// A row to pick which picture the previews use, and to add your own.
struct SampleStrip: View {
    @State private var library = SampleLibrary.shared
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(selected: library.selectedID == nil) {
                    library.select(nil)
                } label: {
                    Text("AUTO")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(library.selectedID == nil ? Color.black : Color.white)
                        .frame(width: 44, height: 36)
                }

                ForEach(library.items) { item in
                    chip(selected: library.selectedID == item.id) {
                        library.select(item.id)
                    } label: {
                        SampleThumb(url: item.url)
                            .frame(width: 44, height: 36)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            library.remove(item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: 6,
                    matching: .images
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .frame(width: 44, height: 36)
                        .background(
                            Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 40)
        .onChange(of: picked) { _, items in
            guard items.isEmpty == false else { return }

            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        library.add(data)
                    }
                }

                picked = []
            }
        }
    }

    private func chip<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            label()
                .background(selected ? Theme.gold : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Theme.gold : Color.white.opacity(0.12), lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
    }
}

struct SampleThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .clipped()
        .task {
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let full = UIImage(contentsOfFile: url.path) else { return nil }

                let size = CGSize(width: 120, height: 96)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1

                return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    let ratio = max(size.width / full.size.width, size.height / full.size.height)
                    let drawn = CGSize(width: full.size.width * ratio, height: full.size.height * ratio)

                    full.draw(in: CGRect(
                        x: (size.width - drawn.width) / 2,
                        y: (size.height - drawn.height) / 2,
                        width: drawn.width,
                        height: drawn.height
                    ))
                }
            }.value
        }
    }
}

// MARK: - Preview card

// The sample picture with the current look. It changes as the dials move.
struct LookPreviewCard: View {
    @Bindable var store: CameraStore

    @State private var base: CGImage?
    @State private var image: UIImage?
    @State private var task: Task<Void, Never>?
    @State private var zoomed = false
    @State private var library = SampleLibrary.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(zoomed ? 2.6 : 1)
                } else {
                    Rectangle().fill(Color.white.opacity(0.06))
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(zoomed ? "Double-tap to zoom out" : "Double-tap to zoom in")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.25)) {
                    zoomed.toggle()
                }
            }
        }
        .task {
            base = LookPreview.sample(from: store, longSide: 1300)
            schedule(immediately: true)
        }
        .onChange(of: store.styleParams) { _, _ in
            schedule(immediately: false)
        }
        .onChange(of: library.selectedID) { _, _ in
            base = LookPreview.sample(from: store, longSide: 1300)
            schedule(immediately: true)
        }
        .onChange(of: library.items) { _, _ in
            base = LookPreview.sample(from: store, longSide: 1300)
            schedule(immediately: true)
        }
    }

    private func schedule(immediately: Bool) {
        guard let base else { return }

        let params = store.styleParams

        task?.cancel()

        task = Task {
            if immediately == false {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard Task.isCancelled == false else { return }

            let rendered = await Task.detached(priority: .userInitiated) {
                LookPreview.render(base, params: params)
            }.value

            guard Task.isCancelled == false else { return }

            image = rendered
        }
    }
}

// MARK: - Look studio

// A full-screen place to try looks: the picture, the presets, and two dials,
// Quality for the grain and Tone from punchy to faded.
struct LookStudio: View {
    @Bindable var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @State private var thumbs: [String: UIImage] = [:]
    @State private var showManager = false
    @State private var sharedColour:URL?
    @State private var colourSharing=false
    @State private var colourShareError:String?
    @State private var thumbTask: Task<Void, Never>?
    @State private var library = SampleLibrary.shared

    private func clearSharedColour() {
        if let url=sharedColour {Task.detached(priority:.utility){try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}}
        sharedColour=nil
    }
    private var qualityBinding: Binding<Int> {
        Binding(
            get: { store.currentDials.quality },
            set: { store.setQuality($0) }
        )
    }

    private var toneBinding: Binding<Int> {
        Binding(
            get: { store.currentDials.tone },
            set: { store.setTone($0) }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    showManager = true
                } label: {
                    Label("Manage", systemImage: "square.stack.3d.up")
                        .font(.system(size: 16, weight: .semibold))
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 26, weight: .semibold))
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.gold)
            .padding(.top, 6)

            LookPreviewCard(store: store)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxHeight: .infinity)

            SampleStrip()

            strip
            HStack {
                if let sharedColour {ShareLink(item:sharedColour) {Label("Share colour look",systemImage:"square.and.arrow.up")}}
                else {Button(colourSharing ? "Preparing colour look…":"Share colour with Studio",systemImage:"square.and.arrow.up") {
                    guard !colourSharing else {return};colourSharing=true;colourShareError=nil
                    let style=store.styleParams,monitor=store.monitorLUT,lut=store.monitorLUT ? store.selectedLUT:nil,intensity=store.lutIntensity
                    Task {do {let url=try await Task.detached(priority:.utility){try CameraColorShare.exportNative(style:style,lut:lut,intensity:intensity)}.value;if store.styleParams==style && store.monitorLUT==monitor && store.lutIntensity==intensity && (!monitor || store.selectedLUT?.id==lut?.id) {sharedColour=url} else {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}} catch {colourShareError=error.localizedDescription};colourSharing=false}
                }.disabled(colourSharing)}
            }.font(.caption).foregroundStyle(Theme.gold)
            if let colourShareError {Text(colourShareError).font(.caption).foregroundStyle(.red)}
            Text("Native .stillarclook colour for Studio → Film → Import. Grain, halos, framing, HDR and camera settings stay here. Prepare a new file after changing the look.").font(.caption2).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    dial(
                        "Quality",
                        names: LookDials.qualityNames,
                        selection: qualityBinding
                    )

                    dial(
                        "Tone",
                        names: Tones.names,
                        selection: toneBinding
                    )
                }

                VStack(spacing: 2) {
                    Text(LookDials.note(forQuality: store.currentDials.quality))

                    Text(Tones.note(forTone: store.currentDials.tone))
                }
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black.ignoresSafeArea())
        .onChange(of:store.styleParams) {_,_ in clearSharedColour()}
        .onChange(of:store.selectedLUT?.id) {_,_ in clearSharedColour()}
        .onChange(of:store.lutIntensity) {_,_ in clearSharedColour()}
        .onChange(of:store.monitorLUT) {_,_ in clearSharedColour()}
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showManager) {
            LookManager(store: store)
        }
        .task {
            buildThumbs()
        }
        .onChange(of: store.customLooks) { _, _ in
            buildThumbs()
        }
        .onChange(of: library.selectedID) { _, _ in
            buildThumbs()
        }
        .onChange(of: library.items) { _, _ in
            buildThumbs()
        }
        .onChange(of: store.allLooks.map(\.id)) { _, _ in buildThumbs() }
    }

    // The presets, side by side. Tap one to use it.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.allLooks) { look in
                        tile(look)
                            .id(look.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(store.look.id, anchor: .center)
            }
            .onChange(of: store.look.id) { _, id in
                withAnimation(.snappy) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 112)
    }

    private func tile(_ look: FilmLook) -> some View {
        let selected = store.look.id == look.id
        let dials = store.lookDials[look.id] ?? LookRecipe.defaultDials(for: look.id)

        return Button {
            Haptics.tick()
            store.look = look
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let image = thumbs[look.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: selected ? 84 : 72, height: selected ? 84 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            selected ? Theme.gold : .white.opacity(0.12),
                            lineWidth: selected ? 2.5 : 1
                        )
                }

                Text(look.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(selected ? Theme.gold : .white)

                Text("\(LookDials.qualityNames[min(max(dials.quality, 0), 6)]) · \(Tones.names[min(max(dials.tone, 0), Tones.all.count - 1)])")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(width: 92)
        }
        .buttonStyle(.plain)
    }

    private func dial(_ title: String, names: [String], selection: Binding<Int>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))

            Spacer()

            Picker(title, selection: selection) {
                ForEach(names.indices, id: \.self) { index in
                    Text(names[index])
                        .font(.system(size: 17, weight: .semibold))
                        .tag(index)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 104, height: 92)
            .clipped()
        }
        .padding(.horizontal, 14)
        .background(
            Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    // Made off the main thread, so the studio stays smooth.
    private func buildThumbs() {
        guard let base = LookPreview.sample(from: store, longSide: 200) else { return }

        let list = store.allLooks.map {
            ($0.id, StyleParams(look: $0, options: LookOptions(), dials: nil))
        }

        thumbTask?.cancel()

        thumbTask = Task {
            let result = await Task.detached(priority: .utility) { () -> [String: UIImage] in
                var made: [String: UIImage] = [:]

                for (id, params) in list {
                    if Task.isCancelled { break }

                    if let image = LookPreview.render(base, params: params) {
                        made[id] = image
                    }
                }

                return made
            }.value

            guard Task.isCancelled == false else { return }

            thumbs = result
        }
    }
}

// MARK: - Manage your presets

struct LookManager: View {
    @Bindable var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: UUID?
    @State private var reset = false
    @State private var setupName = ""
    @State private var importingPresets = false
    @State private var exportingPresets = false
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        Menu("Copy an existing style") {
                            ForEach(FilmLook.lineup) { look in
                                Button(look.name) { store.rememberLibraryChange(); editing = store.addCustomLook(basedOn: look) }
                            }
                        }
                        Button("From scratch") { store.rememberLibraryChange(); editing = store.addCustomLook(basedOn: nil) }
                        Button("Random settings") { store.rememberLibraryChange(); editing = store.addRandomCustomLook() }
                    } label: { Label("Add style", systemImage: "plus.circle.fill") }
                }
                Section {
                    ForEach(store.allLooks) { look in
                        HStack {
                            Button {
                                if let custom = store.customLooks.first(where: { $0.lookID == look.id }) { editing = custom.id }
                                else { store.look = look }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(look.name).foregroundStyle(.primary)
                                    Text(look.id == "standard" ? "Always available" : (look.id.hasPrefix("custom") ? "Your style · tap to edit" : "Built-in style"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Spacer()
                            if store.look.id == look.id { Image(systemName: "checkmark").foregroundStyle(Theme.gold) }
                        }.deleteDisabled(look.id == "standard")
                    }
                    .onDelete { store.deleteStyles($0) }
                    .onMove { store.moveStyles(from: $0, to: $1) }
                } header: { Text("Styles") } footer: {
                    Text("Swipe to remove a style from your camera. Drag its handle in Edit to change the order. Standard stays available. Restore deleted brings removed styles back.")
                }
                Section("Shooting presets") {
                    Button("Import presets", systemImage: "square.and.arrow.down") { importingPresets = true }
                        .disabled(store.isRecording)
                    Button("Export presets", systemImage: "square.and.arrow.up") { exportingPresets = true }
                        .disabled(store.shootingPresets.isEmpty)
                    HStack {
                        TextField("Preset name", text: $setupName)
                        Button("Add") { store.rememberLibraryChange(); store.saveShootingPreset(named: setupName); setupName = "" }
                    }
                    ForEach(store.shootingPresets) { preset in
                        HStack {
                            TextField("Preset name", text: Binding(get: { store.shootingPresets.first(where: { $0.id == preset.id })?.name ?? preset.name }, set: { value in
                                if let index = store.shootingPresets.firstIndex(where: { $0.id == preset.id }) { store.shootingPresets[index].name = String(value.prefix(48)) }
                            }))
                            Button("Use") { store.applyShootingPreset(preset) }.buttonStyle(.borderless).tint(Theme.gold)
                        }
                        .contextMenu {
                            Button("Copy launch link", systemImage: "link") {
                                UIPasteboard.general.string = "stillarc://preset/\(preset.id.uuidString)"
                                notice = "Launch link copied. Paste it into an Open URLs action in Shortcuts."
                            }
                        }
                    }
                    .onDelete { store.deleteManagedPresets($0) }
                    .onMove { store.moveManagedPresets(from: $0, to: $1) }
                }
                Section("Restore") {
                    Button("Undo last library change", systemImage: "arrow.uturn.backward") { store.undoLibraryChange() }.disabled(store.libraryUndo.isEmpty)
                    Button("Restore deleted styles and presets", systemImage: "arrow.counterclockwise") { store.restoreDeletedLibraryItems() }
                        .disabled(store.lookLibrary.hidden.isEmpty && store.lookLibrary.deletedLooks.isEmpty && store.lookLibrary.deletedPresets.isEmpty)
                    Button("Reset styles and presets", role: .destructive) { reset = true }
                    Text("Reset restores built-in styles and removes custom styles and shooting presets. Photos and videos stay safe. Undo can restore the previous library.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Styles & presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: Binding(get: { editing.map(EditorID.init) }, set: { editing = $0?.id })) { selection in CustomLookEditor(store: store, id: selection.id) }
            .fileImporter(isPresented: $importingPresets, allowedContentTypes: [.json]) { result in
                Task {
                    do {
                        let url = try result.get()
                        let incoming = try await Task.detached(priority: .userInitiated) { try PresetFile.read(url) }.value
                        guard !store.isRecording else {
                            notice = "Stop recording before importing presets."
                            return
                        }
                        store.rememberLibraryChange()
                        store.shootingPresets += incoming.map { value in
                            var copy = value
                            copy.id = UUID()
                            let name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            copy.name = name.isEmpty ? "Imported preset" : String(name.prefix(48))
                            return copy
                        }
                        notice = "Imported \(incoming.count) presets. Install any referenced custom styles and LUTs separately."
                    } catch {
                        notice = "This file could not be imported as Stillarc Camera presets."
                    }
                }
            }
            .fileExporter(isPresented: $exportingPresets, document: PresetFile(presets: store.shootingPresets), contentType: .json, defaultFilename: "Stillarc Camera Presets") { result in
                if case .failure = result { notice = "The presets could not be exported." }
            }
            .alert("Shooting presets", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
            .confirmationDialog("Reset styles and presets? Photos and videos stay safe.", isPresented: $reset) {
                Button("Reset styles and presets", role: .destructive) { store.resetStyleLibrary() }
            }
        }.tint(Theme.gold).preferredColorScheme(.dark)
    }
    private struct EditorID: Identifiable { let id: UUID }
}

// MARK: - Make or change a preset

struct CustomLookEditor: View {
    @Bindable var store: CameraStore
    let id: UUID

    private var index: Int? {
        store.customLooks.firstIndex { $0.id == id }
    }

    var body: some View {
        if let index {
            Form {
                Section {
                    LookPreviewCard(store: store)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    SampleStrip()
                        .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Preset name", text: $store.customLooks[index].name)
                }

                Section("Colour") {
                    slider("Warmth", $store.customLooks[index].warmth, -1...1)
                    slider("Saturation", $store.customLooks[index].saturation, 0...2)
                    slider("Contrast", $store.customLooks[index].contrast, 0.6...1.6)
                    slider("Brightness", $store.customLooks[index].brightness, -0.2...0.2)
                    slider("Lifted blacks", $store.customLooks[index].shadowLift, 0...0.6)
                }

                Section("Shadow colour") {
                    slider("Hue", $store.customLooks[index].shadowHue, 0...1)
                    slider("Amount", $store.customLooks[index].shadowAmount, 0...0.5)
                }

                Section("Highlight colour") {
                    slider("Hue", $store.customLooks[index].highlightHue, 0...1)
                    slider("Amount", $store.customLooks[index].highlightAmount, 0...0.5)
                }

                Section("Character") {
                    slider("Dark corners", $store.customLooks[index].vignette, 0...0.6)
                    slider("Glow", $store.customLooks[index].glow, 0...0.6)
                    slider("Softness", $store.customLooks[index].soften, 0...0.8)
                    slider("Sharpening", $store.customLooks[index].sharpen, 0...2)
                }

                Section {
                    Text("Quality and Tone start where you set them in the Look studio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(store.customLooks[index].name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.useCustomLook(id)
            }
        } else {
            Text("This preset is gone.")
                .foregroundStyle(.secondary)
        }
    }

    private func slider(
        _ title: String,
        _ value: Binding<Float>,
        _ range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)

                Spacer()

                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13, design: .monospaced))
            }

            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(Theme.gold)
        }
    }
}
