import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraScreen: View {
    @Bindable var store: CameraStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showGallery = false
    @State private var photoMonitorReady = false
    #if DEBUG
    @State private var galleryCheckStarted = false
    #endif
    @State private var showFn = false
    @State private var showSettings = false
    @State private var importLUT = false
    @State private var dragStartExposure: Float?
    @State private var reticle: CGPoint?
    @State private var reticleID = UUID()
    @State private var reticleToken = 0
    @State private var touching = false
    @State private var touchStart: CGPoint?
    @State private var reticleFromTouch = false

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()

            VStack(spacing: 6) {
                chipRow

                viewfinder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                controlsStack
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 0)

            toastView
        }
        .disabled(store.motionExposureActive)
        .animation(.snappy(duration: 0.28), value: store.chipPanel)
        .onChange(of: store.countdown) { _, _ in
            Haptics.tick()
        }
        .animation(.snappy(duration: 0.28), value: store.showManual)
        .animation(.snappy(duration: 0.2), value: store.toast)
        .onAppear {
            if !store.isShowcase {
                store.activate()
                store.resumeForegroundWork()
                Task { await store.importLockedCaptures() }
            }
        }
        .modifier(CaptureButtonModifier(store: store))
        .onChange(of: scenePhase) { _, phase in
            guard !store.isShowcase else { return }
            if phase != .active {
                store.savePreserved()
            }

            if phase == .active {
                if store.cameraActivated, !store.reviewingCaptures {
                    store.resumeForegroundWork()
                    store.engine.start()
                    store.refreshRecordingCodecs()
                }
            } else if phase == .background {
                store.suspendBackgroundWork()
                if !store.isRecording { store.engine.stop() }
            }
        }
        .onChange(of: store.selectedLensID) { _, _ in
            if store.viewfinderPull && (store.focusStart != nil || store.focusEnd != nil) {
                store.cancelFocusPull(); store.focusStart = nil; store.focusEnd = nil
                store.focusAPoint = nil; store.focusBPoint = nil; store.focusMarkTarget = 0
                store.showToast("Lens changed. Tap to set A and B again.")
            }
        }
        .onChange(of: store.requestGallery) { _, requested in if requested { openGallery(); store.requestGallery = false } }
        .sheet(isPresented: $showGallery, onDismiss: {
            store.reviewingCaptures = false
            store.engine.setGalleryVisible(false)
            // onDismiss belongs to the sheet itself, not a page inside its
            // NavigationStack. Always restore the desired camera state.
            if !store.isShowcase, scenePhase == .active {
                store.resumeForegroundWork()
                store.engine.start()
            }
        }) {
            GallerySheet(store: store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(store: store)
        }
        .sheet(isPresented: $showFn) {
            FnSheet(store: store, onImport: {
                importLUT = true
            })
        }
        .sheet(isPresented: $store.showShootingTools) { ShootingToolsSheet(store: store) }
        .fileImporter(
            isPresented: $importLUT,
            allowedContentTypes: [.data, .item]
        ) { result in
            if case .success(let url) = result {
                store.importLUT(from: url)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: store.shutterTick)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #if DEBUG
        .task { await verifyGalleryTransitions() }
        #endif
    }

    #if DEBUG
    private func verifyGalleryTransitions() async {
        guard ProcessInfo.processInfo.arguments.contains("--verify-gallery"), !galleryCheckStarted else { return }
        galleryCheckStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        store.selectMode(.photo); store.look = FilmLook.lineup[1]; store.dualShot = true
        try? await Task.sleep(for: .seconds(2))
        let mounts = GalleryVerification.previewMounts
        let heartbeat = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                GalleryVerification.longestMainGap = max(GalleryVerification.longestMainGap, now - last)
                last = now
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        defer { heartbeat.cancel() }
        var passed = true
        for iteration in 0..<12 {
            if iteration == 6 { store.selectMode(.video); try? await Task.sleep(for: .seconds(1)) }
            GalleryVerification.requestedAt = ProcessInfo.processInfo.systemUptime
            openGallery()
            try? await Task.sleep(for: .milliseconds(iteration % 2 == 0 ? 180 : 1200))
            let paused = await !store.engine.galleryResumeProbe().0
            showGallery = false
            try? await Task.sleep(for: .milliseconds(1100))
            let probe = await store.engine.galleryResumeProbe()
            let okay = paused && probe.0 && probe.1 < 0.7 && !store.reviewingCaptures && GalleryVerification.previewMounts == mounts
            passed = passed && okay
            NSLog("GALLERY_TRANSITION_VERIFY iteration=%ld %@ mode=%@ paused=%d running=%d frameAgeMs=%.0f mounts=%ld", iteration, okay ? "PASS" : "FAIL", store.mode.rawValue, paused ? 1 : 0, probe.0 ? 1 : 0, probe.1 * 1000, GalleryVerification.previewMounts)
        }
        NSLog("GALLERY_TRANSITION_VERIFY %@ items=%ld presentations=%ld maxPresentMs=%.0f maxMainGapMs=%.0f", passed && GalleryVerification.longestMainGap < 0.25 ? "PASS" : "FAIL", store.captures.count, GalleryVerification.presentations, GalleryVerification.longestPresentation * 1000, GalleryVerification.longestMainGap * 1000)
        await GalleryVerification.verifyDeletion()
    }
    #endif

    private func openGallery() {
        guard !showGallery, !store.isRecording, !store.motionExposureActive else { return }
        store.reviewingCaptures = true
        store.engine.setGalleryVisible(true)
        if !store.isShowcase {
            store.pauseCameraSensors()
            store.engine.stop()
        }
        showGallery = true
    }

    private var controlsStack: some View {
        VStack(spacing: 6) {
            if let panel = store.chipPanel {
                ChipEditor(panel: panel, store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ShutterDock(
                store: store,
                onGallery: { openGallery() },
                onSettings: { showSettings = true },
                onFn: { showFn = true }
            )
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            VStack {
                Spacer()

                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glass(Capsule())
                    .padding(.bottom, 140)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                Group {
                    if let scene = store.showcaseScene {
                        Image(uiImage: store.showcaseImage ?? UIImage(named: scene) ?? UIImage())
                            .resizable().scaledToFill()
                    } else if store.caps.hasCamera {
                        CameraPreview(engine: store.engine, enabled: !(store.mode == .video && store.dualShot && store.monitorShown))
                    } else {
                        DemoHarborScene()
                            .modifier(DemoStyle(style: store.styleParams))
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height
                )
                .opacity(store.mode == .video && store.monitorShown && !store.isShowcase ? 0 : 1)

                if store.caps.hasCamera, !store.isShowcase, store.mode != .video || store.monitorShown {
                    LUTMonitorView(layer: store.engine.monitorLayer, gravity: store.mode == .video && (store.dualShot || store.framingOptions.anamorphic != .off) ? .resizeAspect : .resizeAspectFill)
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height
                        )
                        .opacity(store.monitorShown && (store.mode == .video || photoMonitorReady) ? 1 : 0)
                        .onAppear { photoMonitorReady = store.engine.monitorLayer.isReadyForDisplay }
                        .onReceive(NotificationCenter.default.publisher(
                            for: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                            object: store.engine.monitorLayer
                        ).receive(on: RunLoop.main)) { _ in
                            photoMonitorReady = store.engine.monitorLayer.isReadyForDisplay
                        }
                        .allowsHitTesting(false)
                }

                if let image = store.aidsImage,
                   store.cleanFeed == false,
                   store.showZebra || store.showPeaking || store.showFalseColor {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: store.mode == .video && (store.dualShot || store.framingOptions.anamorphic != .off) ? .fit : .fill)
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height
                        )
                        .clipped()
                        .allowsHitTesting(false)
                }

                if store.showsFrameMask, store.cleanFeed == false,
                   !(store.mode == .video && (store.dualShot || store.aspect == .reel)) {
                    FrameOverlay(
                        scale: store.frameScale,
                        aspect: store.aspect,
                        label: store.mode == .rangefinder
                            ? store.focal.spaced
                            : store.aspect.title,
                        contentRatio: store.mode == .video ? nil : 3.0 / 4.0
                    )
                }

                if store.mode == .video, store.dualShot, store.cleanFeed == false {
                    DualShotFrameOverlay(isLandscape: store.isLandscape)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Dual Shot framing: landscape 16 by 9 and vertical reel 9 by 16")
                }

                if store.mode == .video, (store.dualShot || store.aspect == .reel), !store.cleanFeed {
                    ReelAssistOverlay(safeZones: store.framingOptions.safeZones, style: store.framingOptions.safeZoneStyle,
                                      subject: store.dualShot && store.subjectTracking ? store.trackedSubjectRect : nil, lost: store.dualShot && store.trackingLost,
                                      ordinaryReel: !store.dualShot, landscape: store.isLandscape, captureAngle: store.captureAngle)
                }

                if store.grid {
                    GridOverlay()
                }

                if store.showLevel {
                    LevelOverlay(
                        flat: store.levelFlat,
                        showsRoll: store.levelVisible,
                        angle: store.levelAngle,
                        pitch: store.levelPitch,
                        bubbleX: store.levelBubbleX,
                        bubbleY: store.levelBubbleY
                    )
                }

                if store.mode == .video, store.cleanFeed == false {
                    VStack {
                        Spacer()

                        HStack {
                            Spacer()

                            AudioMeter(level: store.audioLevel)
                                .overlay(alignment: .top) {
                                    if store.audioClipping {
                                        Text("CLIP").font(.system(size: 8, weight: .heavy)).foregroundStyle(.red).offset(y: -14)
                                    }
                                }
                                .padding(.trailing, 12)
                                .padding(.bottom, 12 + bottomReserve)
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Touch layer. It sits under every button, pill and panel, so
                // only a touch on bare viewfinder focuses, locks or changes
                // exposure. Controls never trigger the focus square.
                Color.clear
                .contentShape(Rectangle())
                .gesture(exposureDrag(size: geo.size))
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        // A tap anywhere moves the square and focuses there.
                        reticle = value.location
                        reticleID = UUID()
                        reticleFromTouch = false

                        if store.viewfinderPull { store.selectFocusMark(at: value.location, in: geo.size) }
                        else { store.focus(at: value.location, in: geo.size) }
                        hideReticleLater()
                    }
                )
                .simultaneousGesture(
                    // The yellow square appears the moment a finger touches down.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if touching == false {
                                touching = true
                                touchStart = value.startLocation
                                reticleToken += 1

                                // A square already on screen stays where it is.
                                // It only moves for a tap or a hold, so sliding
                                // to change exposure never refocuses.
                                if reticle == nil {
                                    reticle = value.startLocation
                                    reticleID = UUID()
                                    reticleFromTouch = true
                                } else {
                                    reticleFromTouch = false
                                }
                            }
                        }
                        .onEnded { _ in
                            touching = false
                            hideReticleLater()
                        }
                )
                .simultaneousGesture(
                    // Holding still locks exposure and focus under the square,
                    // while the finger is still down.
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            guard !store.viewfinderPull, let point = touchStart else { return }

                            // The square jumps to where the finger is holding.
                            if let current = reticle,
                               hypot(current.x - point.x, current.y - point.y) > 20 {
                                reticleID = UUID()
                            }

                            reticle = point
                            reticleFromTouch = false

                            Haptics.detent()
                            store.lockExposureFocus(at: point, in: geo.size)
                            reticleToken += 1
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        Haptics.tick()
                        store.cleanFeed.toggle()
                    }
                )

                if store.viewfinderPull, !store.cleanFeed {
                    ForEach(0..<2) { index in
                        if let mark = index == 0 ? store.focusAPoint : store.focusBPoint {
                            Text(index == 0 ? "A" : "B").font(.system(size: 13, weight: .bold))
                                .frame(width: 32, height: 32).foregroundStyle(.black)
                                .background(Theme.gold, in: Circle()).overlay(Circle().stroke(.white.opacity(0.8)))
                                .position(x: mark.x * geo.size.width, y: mark.y * geo.size.height)
                                .allowsHitTesting(false)
                        }
                    }
                }

                if store.mode == .video, store.dualShot, store.cleanFeed == false {
                    DualShotLiveWindow(store: store)
                }

                // Crops, zoom ruler and tools sit on the viewfinder, on no
                // background, so the picture runs all the way down.
                VStack(spacing: 6) {
                    Spacer()

                    if store.mode == .rangefinder, store.showFocalChips {
                        FocalChips(store: store)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if store.cleanFeed == false {
                        HStack(spacing: 8) {
                            Spacer()

                            HStack(spacing: 8) {
                                if store.viewfinderPull {
                                    ViewfinderFocusBar(store: store)
                                } else {
                                    ForEach(0..<3) { index in
                                        switch store.viewfinderShortcuts[index] {
                                        case .timelapse: timelapsePill
                                        case .magnify: magPill
                                        case .timer: countdownPill
                                        default: CustomShortcutButton(store: store, shortcut: store.viewfinderShortcuts[index])
                                        }
                                    }
                                }
                            }

                            Spacer()
                        }
                        .overlay(alignment: .trailing) {
                            if abVisible && !store.viewfinderPull { abPill }
                        }
                        .transition(.opacity)

                        ZoomBar(store: store)
                    }

                    if store.showsPhotoToolbar {
                        ToolBar(store: store)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .animation(.snappy(duration: 0.25), value: store.showFocalChips)

                if store.cleanFeed == false, store.isRecording == false {
                    VStack {
                        Spacer()

                        HStack {
                            Spacer()

                            if store.mode != .video {
                                Button {
                                    Haptics.tick()
                                    store.cycleBracket()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plusminus")
                                            .font(.system(size: 11, weight: .bold))

                                        Text(store.bracketStops == 0 ? "OFF" : "\(store.bracketStops) EV")
                                            .font(.system(size: 10, weight: .heavy))
                                    }
                                    .foregroundStyle(store.bracketStops == 0 ? Color.white.opacity(0.85) : Color.black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .glass(Capsule(), tint: store.bracketStops == 0 ? nil : Theme.gold)
                                }
                                .buttonStyle(UprightStyle())
                                .padding(.trailing, 6)
                                .padding(.bottom, bottomReserve - (store.showManual ? 10 : -12))
                            }


                        }
                    }
                }

                if store.motionExposureActive {
                    Label("Hold steady", systemImage: "timer")
                        .font(.headline).padding(12)
                        .background(.black.opacity(0.72), in: Capsule())
                        .allowsHitTesting(false)
                }
                if let remaining = store.countdown {
                    Text("\(remaining)")
                        .font(.system(size: 110, weight: .thin))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .contentTransition(.numericText())
                        .allowsHitTesting(false)
                }

                VStack {
                    if store.cleanFeed == false {
                        AidsBar(store: store) { clipTimecode }
                    }

                    // Under the aids bar: hold A/B for the original picture, and
                    // the AE/AF lock indicator.
                    if store.cleanFeed == false, store.aeafLocked {
                        HStack(spacing: 8) {
                            if store.aeafLocked {
                                Button {
                                    Haptics.tick()
                                    store.releaseLock()
                                } label: {
                                    Text("AE/AF LOCK")
                                        .font(.system(size: 10, weight: .heavy))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .glass(Capsule(), tint: Theme.gold)
                                }
                                .buttonStyle(UprightStyle())
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }

                    if store.showLUTPanel, store.cleanFeed == false {
                        HStack {
                            LUTPanel(store: store)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }

                    Spacer()

                    if store.cleanFeed == false,
                       (store.showHistogram && store.histogramData.isEmpty == false)
                        || (store.showWaveform && store.waveformImage != nil) {
                        HStack(alignment: .bottom, spacing: 8) {
                            if store.showHistogram, store.histogramData.isEmpty == false {
                                HistogramView(bins: store.histogramData, channels: store.histogramChannels)
                                    .frame(width: 112, height: 44)
                            }

                            if store.showWaveform, let wave = store.waveformImage {
                                WaveformView(image: wave)
                                    .frame(width: 150, height: 76)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                    }

                    if store.timelapseRunning {
                        Text("TIMELAPSE  \(store.timelapseCount)  ·  \(store.timelapseInterval)S")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.9), in: Capsule())
                            .padding(.bottom, 8)
                    }


                }
                .padding(.bottom, bottomReserve)

                if store.showMagnify, store.cleanFeed == false, store.caps.hasCamera {
                    MagnifyLoupe(
                        engine: store.engine,
                        point: reticle ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                        size: geo.size
                    )
                    .position(x: geo.size.width - 12 - 50, y: 70 + 50)
                    .transition(.opacity)
                }

                if store.showManual, store.cleanFeed == false {
                    ControlsOverlay(store: store, available: geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }

                if store.cleanFeed {
                    VStack {
                        HStack {
                            Spacer()

                            Button {
                                Haptics.tick()
                                store.cleanFeed = false
                            } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 30, height: 30)
                                    .glass(Circle())
                            }
                            .buttonStyle(UprightStyle())
                        }
                        .padding(10)

                        Spacer()
                    }
                }

                if let kind = store.typing, store.cleanFeed == false {
                    TypeInCard(store: store, kind: kind)
                }

                if let point = reticle, store.cleanFeed == false {
                    FocusReticle(
                        point: point,
                        size: geo.size,
                        locked: store.aeafLocked,
                        exposure: store.exposure
                    )
                    .id(reticleID)
                    .transition(.opacity)
                }

                if store.didResolveCamera && store.caps.hasCamera == false {
                    VStack {
                        Spacer()

                        Text(previewNote)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                .black.opacity(0.55),
                                in: Capsule()
                            )
                            .padding(.bottom, 14)
                    }
                }
            }
            .onAppear {
                store.viewRatio = Double(geo.size.width / max(geo.size.height, 1))
            }
            .onChange(of: geo.size) { _, size in
                store.viewRatio = Double(size.width / max(size.height, 1))
            }
        }
        .onChange(of: store.aeafLocked) { _, locked in
            if locked == false {
                hideReticleLater()
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder private var clipTimecode: some View {
        if store.mode == .video {
            if store.isRecording, let start = store.recordingStarted {
                TimelineView(.periodic(from: .now, by: 1.0 / Double(max(1, store.angleFrameRate)))) { context in
                    timecodePill(total: store.timecodeBase + context.date.timeIntervalSince(start), live: true)
                }
            } else {
                timecodePill(total: store.timecodeBase, live: false)
            }
        }
    }

    private var timelapsePill: some View {
        timerSettingPill(symbol: "clock.arrow.circlepath", value: store.timelapseInterval, cycle: store.cycleTimelapse, clear: store.clearTimelapse)
    }

    private var countdownPill: some View {
        timerSettingPill(symbol: "timer", value: store.timerSeconds, cycle: store.cycleTimer, clear: store.clearTimer)
    }

    private func timerSettingPill(symbol: String, value: Int, cycle: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(value == 0 ? "OFF" : "\(value)S").font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(value == 0 ? Color.white.opacity(0.85) : Color.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(Capsule(), tint: value == 0 ? nil : Theme.gold)
        .contentShape(Capsule())
        .onTapGesture { Haptics.tick(); cycle() }
        .onLongPressGesture(minimumDuration: 0.5) { Haptics.detent(); clear() }
        .disabled(store.isRecording)
    }

    private var previewNote: String {
        #if targetEnvironment(simulator)
        "Preview scene. Looks, LUTs, and frame lines still shoot."
        #else
        "Camera access is off. Open Settings to shoot for real."
        #endif
    }

    // Room kept clear at the bottom of the viewfinder for the zoom ruler and
    // the tool row.
    private var bottomReserve: CGFloat {
        (store.showsPhotoToolbar ? 136 : 90) + (store.mode == .rangefinder && store.showFocalChips ? 40 : 0)
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            Chip(
                title: store.mode != .video && store.naturalPhoto ? "NATURAL RAW" : store.mode != .video && store.livePhoto ? "LIVE PHOTO" : store.mode != .video && store.depthPortrait ? "DEPTH" : store.rawEnabled
                    ? "RAW + \(store.format.rawValue)"
                    : store.format.rawValue,
                systemImage: nil,
                showsDot: true,
                active: store.chipPanel == .format
            ) {
                toggle(.format)
            }

            Chip(
                title: exposureText,
                systemImage: "sun.max.fill",
                showsDot: false,
                active: store.chipPanel == .exposure
            ) {
                toggle(.exposure)
            }

            Chip(
                title: store.saveTarget.rawValue,
                systemImage: "square.on.square",
                showsDot: false,
                active: store.chipPanel == .save
            ) {
                toggle(.save)
            }

            Spacer(minLength: 4)

            StatusPill(store: store)
        }
    }

    // Switches the focus loupe on or off.
    private var magPill: some View {
        Button {
            Haptics.tick()

            withAnimation(.snappy(duration: 0.2)) {
                store.showMagnify.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))

                Text("MAG")
                    .font(.system(size: 10, weight: .heavy))
            }
            .foregroundStyle(store.showMagnify ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glass(Capsule(), tint: store.showMagnify ? Theme.gold : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel("Focus magnifier")
    }

    private var abVisible: Bool {
        store.styleActive || store.monitorLUT || store.comparing
    }

    // Hold to see the original picture without the look.
    private var abPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .bold))

            Text("A/B")
                .font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(store.comparing ? Color.black : Color.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glass(Capsule(), tint: store.comparing ? Theme.gold : nil)
        .contentShape(Capsule())
        .onTapGesture {
            Haptics.tick()
            store.comparing.toggle()
        }
        .accessibilityLabel("Compare original and graded preview")
        .accessibilityValue(store.comparing ? "Original" : "Graded")
    }

    private var exposureText: String {
        String(format: "%+.1f EV", store.exposure)
    }

    private func exposureDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                if dragStartExposure == nil {
                    dragStartExposure = store.exposure
                }

                guard !store.viewfinderPull else { return }
                let next = (dragStartExposure ?? store.exposure)
                    - Float(value.translation.height) / 90

                reticleToken += 1

                // A first touch that turns into a drag, with no square yet,
                // focuses where it started so the square is truthful.
                if reticleFromTouch, let start = touchStart {
                    reticleFromTouch = false
                    store.focus(at: start, in: size)
                }

                store.setExposure(next)
            }
            .onEnded { _ in
                dragStartExposure = nil
                hideReticleLater()
            }
    }

    // The square and its slider fade out a moment after the last touch,
    // unless exposure and focus are locked.
    private func hideReticleLater() {
        reticleToken += 1
        let token = reticleToken

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))

            guard token == reticleToken,
                  touching == false,
                  store.aeafLocked == false else {
                return
            }

            withAnimation(.easeOut(duration: 0.3)) {
                reticle = nil
            }
        }
    }

    private func toggle(_ panel: ChipPanel) {
        store.chipPanel = store.chipPanel == panel ? nil : panel
    }

    // Clip number and timecode (hours, minutes, seconds, frames). The
    // timecode carries on from clip to clip. Hold it to reset.
    private func timecodePill(total: Double, live: Bool) -> some View {
        Text(timecodeText(total: total))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                live ? Color.red.opacity(0.9) : Color.black.opacity(0.55),
                in: Capsule()
            )
            .onLongPressGesture(minimumDuration: 0.8) {
                Haptics.detent()
                store.resetTimecode()
            }
    }

    private func timecodeText(total: Double) -> String {
        let whole = max(0, total)
        let seconds = Int(whole)
        let fps = max(1, store.angleFrameRate)
        let frames = min(fps - 1, Int((whole - Double(seconds)) * Double(fps)))

        return String(
            format: "CLIP %02d  %02d:%02d:%02d:%02d",
            max(store.clipNumber, 1),
            seconds / 3600,
            (seconds / 60) % 60,
            seconds % 60,
            frames
        )
    }
}

// MARK: - Native camera preview

// The inset shares camera frames and the monitor's already-rendered grade.
private struct DualShotLiveWindow: View {
    @Bindable var store: CameraStore
    @State private var width: CGFloat = 180
    @State private var origin = CGPoint(x: 16, y: 76)
    @GestureState private var drag: CGSize = .zero
    @GestureState private var resize: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let maximum = max(120, min(geo.size.width - 24, geo.size.height * 0.65 * 16 / 9))
            let w = min(maximum, max(120, width + resize))
            let h = w * 9 / 16
            let x = min(max(12, origin.x + drag.width), max(12, geo.size.width - w - 12))
            let y = min(max(12, origin.y + drag.height), max(12, geo.size.height - h - 12))

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let scene = store.showcaseScene {
                        Image(uiImage: store.showcaseImage ?? UIImage(named: scene) ?? UIImage()).resizable().scaledToFill()
                            .frame(width: w, height: h)
                    } else if store.caps.hasCamera {
                        LUTMonitorView(layer: store.engine.landscapeMonitorLayer)
                            .frame(width: w, height: h)
                    } else {
                        DemoHarborScene()
                            .modifier(DemoStyle(style: store.styleParams))
                            .frame(width: w, height: w * 16 / 9)
                    }
                }
                .frame(width: w, height: h)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text("LANDSCAPE 16:9")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("dualShotViewfinder")).updating($drag) { value, state, _ in
                    state = value.translation
                }.onEnded { value in
                    origin = CGPoint(
                        x: min(max(12, origin.x + value.translation.width), max(12, geo.size.width - w - 12)),
                        y: min(max(12, origin.y + value.translation.height), max(12, geo.size.height - h - 12))
                    )
                })

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.65), in: UnevenRoundedRectangle(topLeadingRadius: 10))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("dualShotViewfinder")).updating($resize) { value, state, _ in
                        state = value.translation.width
                    }.onEnded { value in
                        let next = min(maximum, max(120, width + value.translation.width))
                        width = next
                        origin.x = min(max(12, origin.x), max(12, geo.size.width - next - 12))
                        origin.y = min(max(12, origin.y), max(12, geo.size.height - next * 9 / 16 - 12))
                    })
                    .accessibilityLabel("Resize landscape preview")
                    .accessibilityAdjustableAction { direction in
                        width = min(maximum, max(120, width + (direction == .increment ? 24 : -24)))
                    }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.gold, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .position(x: x + w / 2, y: y + h / 2)
            .transaction { $0.animation = nil }
        }
        .coordinateSpace(name: "dualShotViewfinder")
    }
}

// Uses the existing live feed, including its look, without another capture
// connection or per-frame image work. Match VerticalMovie's centred crops.
private struct DualShotFrameOverlay: View {
    let isLandscape: Bool

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, geo.size.height * 9 / 16)
            let height = width * 16 / 9
            Rectangle()
                .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    Text("REEL 9:16")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 24, height: 76)
                        .padding(.leading, 3)
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let engine: CaptureEngine
    var enabled = true

    final class Coordinator {
        let engine: CaptureEngine
        var enabled: Bool
        init(engine: CaptureEngine, enabled: Bool) {
            self.engine = engine
            self.enabled = enabled
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, enabled: enabled) }

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        #if DEBUG
        GalleryVerification.previewMounts += 1
        #endif
        view.previewLayer.videoGravity = .resizeAspectFill
        engine.attachNativePreview(view.previewLayer, enabled: enabled)
        return view
    }

    func updateUIView(_ view: PreviewSurface, context: Context) {
        guard context.coordinator.enabled != enabled else { return }
        context.coordinator.enabled = enabled
        engine.attachNativePreview(view.previewLayer, enabled: enabled)
    }

    static func dismantleUIView(_ view: PreviewSurface, coordinator: Coordinator) {
        coordinator.engine.detachNativePreview(view.previewLayer)
    }
}

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Frame overlay

struct FrameOverlay: View {
    var scale: CGFloat
    var aspect: FrameAspect
    var label: String

    // Shape of the photo frame the preview shows, or nil to work in the
    // viewfinder's own shape (video).
    var contentRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let viewRatio = geo.size.width / max(geo.size.height, 1)
            let ratio = contentRatio ?? viewRatio

            let normalized = FrameMath.normalizedRect(
                focalScale: scale,
                aspect: aspect,
                sourceRatio: ratio
            )

            // Where the photo frame lands in the viewfinder, filling it.
            let area: CGRect = {
                guard let content = contentRatio else {
                    return CGRect(origin: .zero, size: geo.size)
                }

                if viewRatio < content {
                    let width = geo.size.height * content

                    return CGRect(
                        x: (geo.size.width - width) / 2,
                        y: 0,
                        width: width,
                        height: geo.size.height
                    )
                }

                let height = geo.size.width / content

                return CGRect(
                    x: 0,
                    y: (geo.size.height - height) / 2,
                    width: geo.size.width,
                    height: height
                )
            }()

            let fullRect = CGRect(
                x: area.minX + normalized.minX * area.width,
                y: area.minY + normalized.minY * area.height,
                width: normalized.width * area.width,
                height: normalized.height * area.height
            )

            // A crop wider than the visible picture stops at the edge.
            let rect = fullRect.intersection(
                CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4)
            )

            let nearlyFull = rect.width > geo.size.width - 12
                && rect.height > geo.size.height - 6

            let drawn = nearlyFull
                ? CGRect(
                    x: 10,
                    y: 10,
                    width: geo.size.width - 20,
                    height: geo.size.height - 20
                )
                : rect

            Canvas { context, size in
                var shade = Path()
                shade.addRect(CGRect(origin: .zero, size: size))
                shade.addRoundedRect(
                    in: drawn,
                    cornerSize: CGSize(width: 18, height: 18)
                )

                context.fill(
                    shade,
                    with: .color(.black.opacity(nearlyFull ? 0 : 0.42)),
                    style: FillStyle(eoFill: true)
                )

                context.stroke(
                    Path(roundedRect: drawn, cornerRadius: 18),
                    with: .color(.white),
                    lineWidth: 1.6
                )
            }

            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                .position(
                    x: drawn.minX + 42,
                    y: drawn.minY + 22
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Focus square and exposure slider

struct ReticleTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tick: CGFloat = 7

        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + tick))

        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - tick))

        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + tick, y: rect.midY))

        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - tick, y: rect.midY))

        return path
    }
}

// Yellow focus square where you touch, with a sun slider beside it that
// shows the exposure. Drag up or down anywhere to change it.
struct FocusReticle: View {
    let point: CGPoint
    let size: CGSize
    let locked: Bool
    let exposure: Float

    @State private var appeared = false
    @State private var pulse = false

    private let side: CGFloat = 76
    private let sliderHeight: CGFloat = 150

    var body: some View {
        let onRight = point.x < size.width - 64
        let sliderX = point.x + (onRight ? side / 2 + 24 : -(side / 2 + 24))

        let sliderY = min(
            max(point.y, sliderHeight / 2 + 8),
            max(size.height - sliderHeight / 2 - 8, sliderHeight / 2 + 8)
        )

        let clamped = min(max(exposure, -3), 3)
        let fraction = CGFloat(1 - (clamped + 3) / 6)

        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.gold, lineWidth: locked ? 2.4 : 1.5)

                ReticleTicks()
                    .stroke(Theme.gold, lineWidth: 1.5)
            }
            .frame(width: side, height: side)
            .scaleEffect(appeared ? (pulse ? 1.14 : 1) : 1.5)
            .opacity(appeared ? 1 : 0)
            .position(point)

            if locked {
                Text("AE/AF LOCK")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.gold)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .position(x: point.x, y: point.y - side / 2 - 14)
            }

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.gold.opacity(0.9))
                    .frame(width: 1.5, height: sliderHeight)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .offset(y: fraction * sliderHeight - 14)
            }
            .frame(width: 30, height: sliderHeight, alignment: .top)
            .position(x: sliderX, y: sliderY)
            .opacity(appeared ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) {
                appeared = true
            }
        }
        .onChange(of: locked) { _, isLocked in
            guard isLocked else { return }

            withAnimation(.easeOut(duration: 0.12)) {
                pulse = true
            }

            withAnimation(.easeIn(duration: 0.2).delay(0.12)) {
                pulse = false
            }
        }
    }
}

// MARK: - Level line and audio meter

struct LevelLine: View {
    var angle: Double

    var body: some View {
        let level = abs(angle) < 1

        ZStack {
            HStack {
                Rectangle().frame(width: 26, height: 1.5)

                Spacer()

                Rectangle().frame(width: 26, height: 1.5)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 28)

            Rectangle()
                .fill(level ? Theme.gold : Color.white.opacity(0.9))
                .frame(width: 150, height: level ? 2.5 : 1.5)
                .rotationEffect(.degrees(-angle))
        }
        .animation(.smooth(duration: 0.3), value: angle)
        .allowsHitTesting(false)
    }
}

struct AudioMeter: View {
    var level: Float

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.5))

                Capsule()
                    .fill(
                        level > 0.9 ? Color.red
                            : (level > 0.75 ? Theme.gold : Color.green)
                    )
                    .frame(height: 70 * CGFloat(min(max(level, 0.02), 1)))
            }
            .frame(width: 5, height: 70)
            .animation(.easeOut(duration: 0.1), value: level)
        }
    }
}

// MARK: - Zoom, crops, status and level

// Quick crops for rangefinder. They hide again once one is chosen.
struct FocalChips: View {
    @Bindable var store: CameraStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FocalLength.all) { focal in
                let selected = focal == store.focal

                Button {
                    Haptics.tick()

                    withAnimation(.snappy(duration: 0.25)) {
                        store.selectFocal(focal)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(focal.value))")
                            .font(.system(size: 15, weight: selected ? .bold : .semibold))
                            .lineLimit(1)
                            .fixedSize()

                        Text("mm")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.95))
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .background(Capsule().fill(selected ? Theme.gold : Color.black.opacity(0.35)))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(UprightStyle())
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

// Zoom ruler with automatic zoom in and out over a set time. In
// rangefinder it scrubs the focal length instead.
struct ZoomBar: View {
    @Bindable var store: CameraStore

    var body: some View {
        HStack(spacing: 8) {
            if store.mode != .rangefinder {
                actionButton(symbol: "arrow.uturn.backward", label: "Zoom back") {
                    store.runZoomBack()
                }
            }

            ZoomRuler(store: store)

            if store.mode != .rangefinder {
                actionButton(symbol: "scope", label: "Zoom to the chosen point") {
                    store.runZoomToTarget()
                }

                Button {
                    Haptics.tick()
                    store.cycleZoomSeconds()
                } label: {
                    Text("\(Int(store.zoomSeconds))S")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .frame(width: 34, height: 30)
                        .glass(Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(UprightStyle())
                .accessibilityLabel("Automatic zoom time")
            }
        }
        .padding(.horizontal, 4)
    }

    private func actionButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .glass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel(label)
    }
}

struct ZoomRuler: View {
    @Bindable var store: CameraStore
    @State private var dragStart: Double?
    @State private var lastStep = 0
    @State private var width: CGFloat = 220

    // Points per doubling of zoom.
    private let spacing: CGFloat = 120

    private var isFocal: Bool { store.mode == .rangefinder }

    private var span: Double {
        isFocal ? log2(90.0 / 24.0) : CameraStore.maxZoomLog
    }

    private var current: Double {
        isFocal ? log2(store.focal.value / 24) : store.zoomLog
    }

    private var labels: [(position: Double, text: String)] {
        if isFocal {
            return FocalLength.all.map {
                (position: log2($0.value / 24), text: "\(Int($0.value))")
            }
        }

        return [
            (position: 0, text: "1x"),
            (position: 1, text: "2x"),
            (position: 2, text: "4x"),
            (position: 3, text: "8x")
        ]
    }

    private var readout: String {
        isFocal
            ? "\(Int(store.focal.value)) mm"
            : String(format: "%.1fx", pow(2, store.zoomLog))
    }

    var body: some View {
        VStack(spacing: 1) {
            // Keep the readout in its own view so it animates smoothly.
            Text(readout)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.gold)
                .contentTransition(.numericText(value: current))
                .animation(.linear(duration: 0.1), value: current)

            // Store/gesture updates drive the ruler; a static ruler needs no
            // display-rate timer between interactions.
            Canvas { context, size in
                let middle = size.width / 2
                let baseline = size.height

                // Fine ticks, a sixth of a doubling apart.
                var position = 0.0

                while position <= span + 0.0001 {
                    let x = middle + CGFloat(position - current) * spacing

                    if x > -8, x < size.width + 8 {
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: baseline))
                        tick.addLine(to: CGPoint(x: x, y: baseline - 6))

                        context.stroke(tick, with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }

                    position += 1.0 / 6.0
                }

                // Marked values.
                for label in labels {
                    let x = middle + CGFloat(label.position - current) * spacing

                    guard x > -20, x < size.width + 20 else { continue }

                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: baseline))
                    tick.addLine(to: CGPoint(x: x, y: baseline - 13))

                    context.stroke(tick, with: .color(.white.opacity(0.95)), lineWidth: 1.5)

                    context.draw(
                        Text(label.text)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.85)),
                        at: CGPoint(x: x, y: baseline - 20),
                        anchor: .center
                    )
                }

                // The point the automatic zoom is heading for.
                if isFocal == false, let target = store.zoomTargetLog {
                    let x = middle + CGFloat(target - current) * spacing

                    if x > -10, x < size.width + 10 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 3.5, y: 0, width: 7, height: 7)),
                            with: .color(Theme.gold)
                        )
                    }
                }

                var marker = Path()
                marker.move(to: CGPoint(x: middle, y: 0))
                marker.addLine(to: CGPoint(x: middle, y: baseline))

                context.stroke(marker, with: .color(Theme.gold), lineWidth: 1.6)
            }
            .frame(height: 32)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = current
                    }

                    let next = (dragStart ?? current)
                        - Double(value.translation.width) / Double(spacing)

                    let clamped = min(max(next, 0), span)

                    if isFocal {
                        store.setFocalValue(24 * pow(2, clamped))
                    } else {
                        store.setZoom(log: clamped)
                    }

                    let step = Int((clamped * 6).rounded())

                    if step != lastStep {
                        lastStep = step
                        Haptics.tick()
                    }
                }
                .onEnded { value in
                    dragStart = nil

                    // A tap on a marked value picks it as the zoom point.
                    let moved = hypot(value.translation.width, value.translation.height)

                    if moved < 6, isFocal == false {
                        let middle = width / 2

                        let nearest = labels.min {
                            abs(middle + CGFloat($0.position - current) * spacing - value.startLocation.x)
                                < abs(middle + CGFloat($1.position - current) * spacing - value.startLocation.x)
                        }

                        if let nearest,
                           abs(middle + CGFloat(nearest.position - current) * spacing - value.startLocation.x) < 26 {
                            Haptics.tick()
                            store.setZoomTarget(nearest.position)
                        }
                    }
                }
        )
    }
}

// Battery and free space, like the status line on a cinema camera.
struct StatusPill: View {
    let store: CameraStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let device = UIDevice.current
            let level: Float = store.isShowcase ? 1 : device.batteryLevel
            let charging = !store.isShowcase && (device.batteryState == .charging || device.batteryState == .full)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: batterySymbol(level: level, charging: charging))

                    Text(level < 0 ? "--%" : "\(Int((level * 100).rounded()))%")
                }
                .foregroundStyle(level >= 0 && level < 0.2 && charging == false ? Color.red : Color.white.opacity(0.9))

                HStack(spacing: 3) {
                    Image(systemName: store.mode == .video ? "film" : "internaldrive")

                    // Video shows the recording time left for the codec and
                    // picture settings in use, and stills show free space.
                    Text(store.mode == .video ? timeLeft : freeSpace)
                }
                .foregroundStyle(Color.white.opacity(0.9))

                storageBar
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
    }

    // How full the phone is: a thin bar of used space, with the percentage.
    // It turns yellow when 15% is left and red at 5%.
    private var storageBar: some View {
        let total = totalBytes
        let free = freeBytes
        let used = total > 0 ? min(max(1 - free / total, 0), 1) : 0
        let freeShare = 1 - used

        let tint: Color = freeShare < 0.05
            ? .red
            : (freeShare < 0.15 ? Theme.gold : Color.white)

        return HStack(spacing: 5) {
            Text(total > 0 ? "\(Int((used * 100).rounded()))% USED" : "--% USED")
                .foregroundStyle(tint.opacity(0.9))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))

                GeometryReader { bar in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, bar.size.width * used))
                }
            }
            .frame(width: 54, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            total > 0
                ? "Storage \(Int((used * 100).rounded())) percent used"
                : "Storage unknown"
        )
    }

    private var totalBytes: Double {
        store.storageTotalBytes
    }

    private func batterySymbol(level: Float, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }

        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var freeBytes: Double {
        store.storageFreeBytes
    }

    // Hours and minutes of video that still fit.
    private var timeLeft: String {
        let rate = max(store.estimatedRecordingBytesPerSecond, 1)
        let seconds = Int(freeBytes / rate)

        if seconds >= 3600 {
            return String(format: "%dh%02dm", seconds / 3600, (seconds / 60) % 60)
        }

        if seconds >= 60 {
            return "\(seconds / 60)m"
        }

        return "<1m"
    }

    private var freeSpace: String {
        let gigabytes = freeBytes / 1_000_000_000

        return gigabytes >= 100
            ? "\(Int(gigabytes))GB"
            : String(format: "%.1fGB", gigabytes)
    }
}

// Level on two axes: a horizon line and a tilt marker when the phone is
// held up, and a rolling ball when it is flat.
struct LevelOverlay: View {
    var flat: Bool
    var showsRoll: Bool
    var angle: Double
    var pitch: Double
    var bubbleX: Double
    var bubbleY: Double

    var body: some View {
        ZStack {
            if flat {
                bubble
            } else {
                if showsRoll {
                    LevelLine(angle: angle)
                }

                tilt
            }
        }
        .allowsHitTesting(false)
    }

    private var bubble: some View {
        let level = abs(bubbleX) < 0.02 && abs(bubbleY) < 0.02

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                .frame(width: 110, height: 110)

            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1, height: 22)

            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 22, height: 1)

            Circle()
                .fill(level ? Theme.gold : Color.white.opacity(0.9))
                .frame(width: 18, height: 18)
                .offset(
                    x: CGFloat(max(-1, min(1, bubbleX))) * 46,
                    y: CGFloat(-max(-1, min(1, bubbleY))) * 46
                )
                .animation(.easeOut(duration: 0.1), value: bubbleX)
                .animation(.easeOut(duration: 0.1), value: bubbleY)
        }
    }

    // Forward and back tilt: a marker on a short scale at the left edge.
    private var tilt: some View {
        let level = abs(pitch) < 1
        let offset = CGFloat(max(-30, min(30, pitch))) * 2.4

        return HStack {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1.5, height: 140)

                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 14, height: 1.5)

                Rectangle()
                    .fill(level ? Theme.gold : Color.white.opacity(0.9))
                    .frame(width: level ? 26 : 18, height: level ? 3 : 2)
                    .offset(y: offset)
                    .animation(.easeOut(duration: 0.1), value: pitch)
            }
            .padding(.leading, 14)

            Spacer()
        }
    }
}

// MARK: - Focus loupe

// A zoomed window on the picture around the focus point, to judge focus. It
// follows the square you last tapped, or the middle of the picture.
struct MagnifyLoupe: View {
    let engine: CaptureEngine
    let point: CGPoint
    let size: CGSize

    private let window: CGFloat = 100

    var body: some View {
        LUTMonitorView(layer: engine.loupeLayer)
            .frame(width: window, height: window)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.gold, lineWidth: 1.5)
            }
            .overlay {
                ReticleTicks()
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    .padding(36)
            }
            .shadow(color: .black.opacity(0.5), radius: 4)
            .allowsHitTesting(false)
            .onAppear {
                engine.setLoupe(on: true, point: point, viewSize: size)
            }
            .onChange(of: point) { _, next in
                engine.setLoupe(on: true, point: next, viewSize: size)
            }
            .onChange(of: size) { _, next in
                engine.setLoupe(on: true, point: point, viewSize: next)
            }
            .onDisappear {
                engine.setLoupe(on: false, point: point, viewSize: size)
            }
    }
}

// MARK: - Grid overlay

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height

                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))

                path.move(to: CGPoint(x: w * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: w * 2 / 3, y: h))

                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))

                path.move(to: CGPoint(x: 0, y: h * 2 / 3))
                path.addLine(to: CGPoint(x: w, y: h * 2 / 3))
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Chips

struct Chip: View {
    var title: String
    var systemImage: String?
    var showsDot: Bool
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsDot {
                    Circle()
                        .fill(Theme.gold)
                        .frame(width: 8, height: 8)
                }

                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                }

                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .bar(Capsule())
        }
        .buttonStyle(UprightStyle())
    }
}

// MARK: - Exposure aids

struct AidsBar<Timecode: View>: View {
    @State private var showAids = false
    @Bindable var store: CameraStore
    @ViewBuilder var timecode: () -> Timecode

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                pill("HIST", isOn: $store.showHistogram)
                if store.mode == .video {
                    HStack(spacing: 6) {
                    aidsMenu
                    Button { store.toggleViewfinderPull() } label: {
                        Image(systemName: "camera.metering.center.weighted").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(store.viewfinderPull ? .black : .white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glass(Capsule(), tint: store.viewfinderPull ? Theme.gold : nil)
                    }.accessibilityLabel("Set focus pull in viewfinder")
                    }.fixedSize()
                }
            }
            .frame(width: 50, alignment: .leading)

            if store.mode == .video {
                timecode().frame(maxWidth: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button { store.showLUTPanel.toggle() } label: {
                    Text("LUT")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .glass(Capsule(), tint: store.isLUTBaking ? Theme.gold : .white)
                }
                .buttonStyle(UprightStyle())
                .accessibilityLabel(store.isLUTBaking ? "LUT baking on" : "LUT baking off")

                if store.mode != .video { aidsMenu }
            }
            .frame(width: store.mode == .video ? 50 : nil, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var aidsMenu: some View {
        Button {
            Haptics.tick()
            showAids.toggle()
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .glass(Capsule())
        }
        .buttonStyle(UprightStyle())
        .popover(isPresented: $showAids, arrowEdge: .top) {
            ExposureAidsPanel(store: store, dismiss: { showAids = false })
                .presentationCompactAdaptation(.popover)
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--show-aids-panel") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    showAids = true
                }
            }
        }
        #endif
        .accessibilityLabel("Exposure aids and hide controls")
    }

    private func pill(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(isOn.wrappedValue ? .black : .white.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .glass(Capsule(), tint: isOn.wrappedValue ? Theme.gold : nil)
        }
        .buttonStyle(UprightStyle())
    }
}

struct LUTMonitorView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()

        layer.videoGravity = gravity
        view.host(layer)

        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        layer.videoGravity = gravity
        uiView.host(layer)
    }

    static func dismantleUIView(_ uiView: LayerHostView, coordinator: ()) {
        if let hosted = uiView.hosted, hosted.superlayer === uiView.layer {
            hosted.removeFromSuperlayer()
        }
    }
}

final class LayerHostView: UIView {
    var hosted: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
    }

    func host(_ layer: CALayer) {
        guard hosted !== layer else { return }

        layer.removeFromSuperlayer()
        self.layer.addSublayer(layer)

        hosted = layer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

struct WaveformView: View {
    let image: CGImage

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)

            // Graticule at 0, 25, 50, 75 and 100 percent.
            Canvas { context, size in
                for step in 0...4 {
                    let y = size.height * CGFloat(step) / 4

                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))

                    context.stroke(
                        line,
                        with: .color(.white.opacity(step == 0 || step == 4 ? 0.28 : 0.14)),
                        lineWidth: 0.5
                    )
                }
            }
        }
        .padding(4)
        .glass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct HistogramView: View {
    let bins: [Float]
    var channels: [[Float]] = []

    var body: some View {
        Canvas { context, size in
            // Red, green and blue overlaid. Where they stack they turn to
            // white, and a stray colour shows a colour cast.
            if channels.count == 3, channels[0].isEmpty == false {
                context.blendMode = .plusLighter

                let colors: [Color] = [.red, .green, .blue]

                for (index, channel) in channels.enumerated() {
                    var path = Path()
                    let step = size.width / CGFloat(max(channel.count - 1, 1))

                    path.move(to: CGPoint(x: 0, y: size.height))

                    for (position, value) in channel.enumerated() {
                        let height = max(1, CGFloat(value) * (size.height - 4))

                        path.addLine(
                            to: CGPoint(
                                x: CGFloat(position) * step,
                                y: size.height - height
                            )
                        )
                    }

                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()

                    context.fill(path, with: .color(colors[index].opacity(0.8)))
                }

                return
            }

            guard bins.isEmpty == false else { return }

            let barWidth = size.width / CGFloat(bins.count)

            for (index, value) in bins.enumerated() {
                let height = max(1, CGFloat(value) * (size.height - 4))

                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: size.height - height,
                    width: max(barWidth - 0.5, 0.5),
                    height: height
                )

                // The last bins are the clipped highlights.
                let color: Color = index >= bins.count - 2
                    ? .red.opacity(0.9)
                    : .white.opacity(0.85)

                context.fill(Path(rect), with: .color(color))
            }
        }
        .padding(4)
        .glass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Glass and orientation

extension View {
    // Flat dark panel for controls that sit on the viewfinder.
    func glass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        self.background {
            shape.fill(tint?.opacity(0.95) ?? Color.black.opacity(0.5))
        }
    }

    // Solid dark bar with a hairline edge, as in the app's bars and chips.
    func bar<S: Shape>(_ shape: S) -> some View {
        self
            .background { shape.fill(Color(white: 0.11)) }
            .overlay { shape.stroke(Color.white.opacity(0.10), lineWidth: 0.8) }
    }
}

// Button style that dims while pressed. The layout never rotates.
struct UprightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func prepare() {
        selection.prepare()
        soft.prepare()
        rigid.prepare()
    }

    static func tick() {
        selection.selectionChanged()
        selection.prepare()
    }

    static func tap() {
        soft.impactOccurred()
        soft.prepare()
    }

    static func detent() {
        rigid.impactOccurred(intensity: 0.9)
        rigid.prepare()
    }
}

// MARK: - Controls overlay

struct ControlsOverlay: View {
    @Bindable var store: CameraStore
    var available: CGFloat = 480

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if store.activeControl == .wb {
                WBPresetPanel(store: store)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let kind = store.activeControl {
                RulerPanel(store: store, kind: kind, available: available)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            VStack(spacing: 6) {
                ForEach(ControlKind.allCases) { kind in
                    ControlTile(store: store, kind: kind)
                }

                Button {
                    Haptics.tap()
                    store.autoAll()
                } label: {
                    Text("AUTO")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 28)
                        .glass(Capsule(), tint: Theme.gold)
                }
                .buttonStyle(UprightStyle())
            }
        }
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.22), value: store.activeControl)
    }
}

struct WBPreset: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let kelvin: Double

    static let all: [WBPreset] = [
        WBPreset(id: "tungsten", name: "TUNGSTEN", symbol: "lightbulb.fill", kelvin: 3200),
        WBPreset(id: "indoors", name: "INDOORS", symbol: "house.fill", kelvin: 4000),
        WBPreset(id: "flash", name: "FLASH", symbol: "bolt.fill", kelvin: 5500),
        WBPreset(id: "sun", name: "SUN", symbol: "sun.max.fill", kelvin: 5600),
        WBPreset(id: "cloudy", name: "CLOUDY", symbol: "cloud.fill", kelvin: 6500),
        WBPreset(id: "shade", name: "SHADE", symbol: "tree.fill", kelvin: 7500)
    ]
}

// Lighting presets, one tap each, shown beside the white balance ruler.
struct WBPresetPanel: View {
    @Bindable var store: CameraStore

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.fixed(52), spacing: 6),
                GridItem(.fixed(52), spacing: 6)
            ],
            spacing: 6
        ) {
            ForEach(WBPreset.all) { preset in
                let on = store.lockWhiteBalance
                    && abs(Double(store.whiteBalance) - preset.kelvin) < 50

                Button {
                    Haptics.tick()
                    store.setWhiteBalancePreset(preset.kelvin)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 16, weight: .semibold))

                        Text(preset.name)
                            .font(.system(size: 7, weight: .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text("\(Int(preset.kelvin))K")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 52, height: 58)
                    .glass(
                        RoundedRectangle(cornerRadius: 12, style: .continuous),
                        tint: on ? Theme.gold : nil
                    )
                }
                .buttonStyle(UprightStyle())
            }
        }
        .padding(6)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ControlTile: View {
    @Bindable var store: CameraStore
    let kind: ControlKind

    var body: some View {
        let active = store.activeControl == kind
        let auto = store.isAuto(kind)

        Button {
            Haptics.tick()
            store.activeControl = active ? nil : kind
        } label: {
            VStack(spacing: 1) {
                Text(kind.label)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))

                Text(store.displayText(for: kind))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(auto ? Color.white : Theme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 56, height: 38)
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Theme.gold : Color.clear, lineWidth: 1.4)
            }
            .overlay(alignment: .topTrailing) {
                if store.lockedControls.contains(kind) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 12, height: 12)
                        .background(Theme.gold, in: Circle())
                        .offset(x: 3, y: -3)
                } else if auto, kind != .ev {
                    Text("A")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 11, height: 11)
                        .background(Theme.gold, in: Circle())
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(UprightStyle())
        // Hold a control to lock it at its current value, hold again to free it.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                Haptics.detent()
                store.toggleLock(kind)
            }
        )
    }
}

// MARK: - Scrolling ruler

struct RulerPanel: View {
    @Bindable var store: CameraStore
    let kind: ControlKind
    var available: CGFloat = 480

    @State private var startPosition: Double?
    @State private var dragPosition: Double?

    private let spacing: CGFloat = 14

    var body: some View {
        let spec = store.rulerSpec(for: kind)
        let locked = (kind == .shutter && store.shutterAngleLock)
            || store.lockedControls.contains(kind)
        let index = spec.index(of: store.value(for: kind))
        let position = dragPosition ?? Double(index)

        VStack(spacing: 6) {
            Button {
                store.typing = kind
            } label: {
                HStack(spacing: 3) {
                    Text(store.displayText(for: kind))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.gold)

                    Image(systemName: "keyboard")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(UprightStyle())

            ruler(spec: spec, position: position)
                .frame(
                    width: 84,
                    height: max(110, min(238, available - (kind == .shutter ? 200 : 140)))
                )
                .opacity(locked ? 0.3 : 1)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(spec: spec, locked: locked))

            Button {
                Haptics.tick()
                store.setAuto(kind)
            } label: {
                pill("AUTO", on: store.isAuto(kind))
            }
            .buttonStyle(UprightStyle())

            if kind == .shutter {
                Button {
                    Haptics.tick()
                    store.shutterAngleLock.toggle()
                } label: {
                    pill("ANGLE", on: store.shutterAngleLock)
                }
                .buttonStyle(UprightStyle())

                if store.shutterAngleLock {
                    Menu {
                        ForEach(CameraStore.shutterAngles, id: \.self) { angle in
                            Button(
                                angle == angle.rounded()
                                    ? "\(Int(angle))°"
                                    : String(format: "%.1f°", angle)
                            ) {
                                store.shutterAngle = angle
                            }
                        }
                    } label: {
                        Text(store.shutterAngleText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
        }
        .padding(8)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func pill(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.9))
            .frame(width: 60, height: 24)
            .glass(Capsule(), tint: on ? Theme.gold : nil)
    }

    // The ruler follows the finger like a window blind: pull down and the
    // scale moves down, bringing higher values up to the marker.
    private func drag(spec: RulerSpec, locked: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard locked == false else { return }

                let current = spec.index(of: store.value(for: kind))

                if startPosition == nil {
                    startPosition = Double(current)
                    Haptics.prepare()
                }

                let top = Double(max(spec.stops.count - 1, 0))

                let raw = min(
                    max(
                        (startPosition ?? 0)
                            + Double(value.translation.height) / Double(spacing),
                        0
                    ),
                    top
                )

                // Magnet: the scale resists near the common values.
                var shown = raw

                if let snap = spec.snapIndex(near: Int(raw.rounded()), within: 2) {
                    let preset = Double(snap)

                    if abs(raw - preset) < 1.6 {
                        shown = preset + (raw - preset) * 0.3
                    }
                }

                dragPosition = shown

                let target = Int(shown.rounded())

                guard target != current else { return }

                store.setValue(kind, spec.stops[target])

                if spec.presetSet.contains(target) {
                    Haptics.detent()
                } else {
                    Haptics.tick()
                }
            }
            .onEnded { _ in
                startPosition = nil

                withAnimation(.snappy(duration: 0.14)) {
                    dragPosition = nil
                }
            }
    }

    private func ruler(spec: RulerSpec, position: Double) -> some View {
        Canvas { context, size in
            let middle = size.height / 2
            let reach = Int(size.height / spacing / 2) + 2
            let base = Int(position.rounded())

            for offset in -reach...reach {
                let item = base + offset

                guard spec.stops.indices.contains(item) else { continue }

                let y = middle + CGFloat(position - Double(item)) * spacing

                let isPreset = spec.presetSet.contains(item)
                let labelled = isPreset || item % spec.labelEvery == 0

                let length: CGFloat = isPreset ? 22 : (labelled ? 14 : 8)
                let edge = size.width - 4

                var tick = Path()
                tick.move(to: CGPoint(x: edge - length, y: y))
                tick.addLine(to: CGPoint(x: edge, y: y))

                context.stroke(
                    tick,
                    with: .color(.white.opacity(isPreset ? 0.95 : 0.45)),
                    lineWidth: isPreset ? 1.6 : 1
                )

                if labelled {
                    context.draw(
                        Text(spec.format(spec.stops[item]))
                            .font(.system(size: isPreset ? 10 : 9, weight: isPreset ? .bold : .regular))
                            .foregroundColor(.white.opacity(isPreset ? 1 : 0.6)),
                        at: CGPoint(x: edge - length - 4, y: y),
                        anchor: .trailing
                    )
                }
            }

            var marker = Path()
            marker.move(to: CGPoint(x: 0, y: middle))
            marker.addLine(to: CGPoint(x: size.width, y: middle))

            context.stroke(marker, with: .color(Theme.gold), lineWidth: 1.4)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Type a value

struct TypeInCard: View {
    @Bindable var store: CameraStore
    let kind: ControlKind

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let spec = store.rulerSpec(for: kind)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.label)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Button {
                    store.typing = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(UprightStyle())
            }

            TextField(kind.hint, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .focused($focused)
                .submitLabel(.done)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.gold)
                .onSubmit { commit() }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(spec.presets, id: \.self) { preset in
                        Button {
                            Haptics.tap()
                            store.setValue(kind, preset)
                            store.typing = nil
                        } label: {
                            Text(spec.format(preset))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glass(Capsule())
                        }
                        .buttonStyle(UprightStyle())
                    }
                }
            }

            Button {
                commit()
            } label: {
                Text("SET")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .glass(Capsule(), tint: Theme.gold)
            }
            .buttonStyle(UprightStyle())
        }
        .padding(14)
        .frame(width: 260)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear {
            text = ""
            focused = true
        }
    }

    private func commit() {
        if store.commitTyped(kind, text: text) {
            store.typing = nil
        }
    }
}

// MARK: - LUT panel

struct LUTPanel: View {
    @Bindable var store: CameraStore
    @State private var renaming: UUID?
    @State private var savingPreset = false
    @State private var managingPresets = false
    @State private var newName = ""

    private let snaps: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(
                        "OFF",
                        selected: store.monitorLUT == false
                            && store.look.id == "standard"
                    ) {
                        store.clearLook()
                    }

                    // The camera style in use, tap to remove it.
                    if store.look.id != "standard" {
                        chip("✕ \(store.look.name)", selected: true) {
                            store.look = .standard
                        }
                    }

                    ForEach(store.luts) { lut in
                        chip(
                            store.lutName(lut),
                            selected: store.monitorLUT
                                && store.selectedLUT?.id == lut.id
                        ) {
                            store.selectedLUT = lut
                            store.monitorLUT = true
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("+ SAVE PRESET", selected: false) {
                        newName = ""
                        savingPreset = true
                    }
                    .disabled(store.isRecording)
                    chip("PRESETS", selected: false) { managingPresets = true }
                    ForEach(store.shootingPresets) { preset in
                        chip(preset.name, selected: store.selectedPresetID == preset.id) { store.applyShootingPreset(preset) }
                            .disabled(store.isRecording)
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { newName = preset.name; renaming = preset.id }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.shootingPresets.removeAll { $0.id == preset.id }
                                }
                            }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("MIX")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.65))

                Slider(
                    value: Binding(
                        get: { Double(store.lutIntensity) },
                        set: { newValue in
                            var next = newValue

                            if let near = snaps.first(where: { abs($0 - newValue) < 0.04 }) {
                                next = near

                                if Float(near) != store.lutIntensity {
                                    Haptics.detent()
                                }
                            }

                            store.lutIntensity = Float(next)
                        }
                    ),
                    in: 0...1
                )
                .tint(Theme.gold)

                Text("\(Int((store.lutIntensity * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.gold)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(8)
        .frame(maxWidth: 250)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .alert(
            "Rename preset",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if $0 == false { renaming = nil } }
            )
        ) {
            TextField("Name", text: $newName)

            Button("Save") {
                let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
                if let index = store.shootingPresets.firstIndex(where: { $0.id == renaming }), !trimmed.isEmpty {
                    store.shootingPresets[index].name = trimmed
                }

                renaming = nil
            }

            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        }
        .alert("Save shooting preset", isPresented: $savingPreset) {
            TextField("Preset name", text: $newName)
            Button("Save") { store.saveShootingPreset(named: newName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the current camera settings, style, LUT, framing and audio setup.")
        }
        .sheet(isPresented: $managingPresets) {
            ShootingPresetsSheet(store: store)
        }
    }

    private func chip(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glass(Capsule(), tint: selected ? Theme.gold : nil)
        }
        .buttonStyle(UprightStyle())
    }
}

// MARK: - Lens selector

struct LensButton: View {
    @Bindable var store: CameraStore
    @State private var open = false

    private var current: String {
        store.lenses.first { $0.uniqueID == store.selectedLensID }?.title
            ?? store.lenses.first?.title
            ?? "1x"
    }

    var body: some View {
        let single = store.lenses.count < 2

        Button {
            guard single == false else { return }

            Haptics.tick()

            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                open.toggle()
            }
        } label: {
            circle(current, selected: open)
        }
        .buttonStyle(UprightStyle())
        .opacity(single ? 0.4 : 1)
        .accessibilityLabel("Lens \(current)")
        .overlay(alignment: .bottom) {
            if open {
                // A thin vertical line of circles above the button, the same
                // material as the LUT picker.
                VStack(spacing: 6) {
                    ForEach(store.lenses.reversed()) { lens in
                        let selected = lens.uniqueID == store.selectedLensID

                        Button {
                            Haptics.tick()

                            store.selectLens(lens)

                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                open = false
                            }
                        } label: {
                            circle(lens.title, selected: selected)
                        }
                        .buttonStyle(UprightStyle())
                        .disabled(!store.canSelectLens(lens))
                        .opacity(store.canSelectLens(lens) ? 1 : 0.4)
                    }
                }
                .fixedSize()
                .offset(y: -40)
                .transition(
                    .scale(scale: 0.4, anchor: .bottom)
                        .combined(with: .opacity)
                )
            }
        }
    }

    // Same flat dark glass as the LUT picker chips, yellow when selected.
    private func circle(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 34, height: 34)
            .glass(Circle(), tint: selected ? Theme.gold : nil)
            .animation(.easeOut(duration: 0.2), value: selected)
    }
}

// Dock bar with a round bite out of the middle for the shutter.
struct DockBarShape: Shape {
    var gap: CGFloat

    func path(in rect: CGRect) -> Path {
        let bar = Path(roundedRect: rect, cornerRadius: rect.height / 2)

        let hole = Path(
            ellipseIn: CGRect(
                x: rect.midX - gap,
                y: rect.midY - gap,
                width: gap * 2,
                height: gap * 2
            )
        )

        return bar.subtracting(hole)
    }
}

// MARK: - Focal length selector

struct FocalBar: View {
    @Bindable var store: CameraStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FocalLength.all) { focal in
                let selected = focal == store.focal

                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        store.selectFocal(focal)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(focal.value))")
                            .font(.system(size: 15, weight: selected ? .bold : .semibold))
                            .lineLimit(1)
                            .fixedSize()

                        Text("mm")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(
                        Capsule().fill(selected ? Theme.gold : Color.clear)
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(UprightStyle())
            }
        }
    }
}

// MARK: - Tool bar

struct ToolBar: View {
    @Bindable var store: CameraStore

    var body: some View {
        Group {
            if store.isRecording {
                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    if store.mode != .video || store.caps.hasTorch {
                        flashButton.frame(width: 44)
                    }
                    manualButton.frame(width: 44)
                }
            } else if store.mode != .video {
                HStack(spacing: 0) {
                    ForEach(store.photoToolbar.indices, id: \.self) { index in
                        photoControl(store.photoToolbar[index])
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                // Five equal cells, with RAW always on the shutter's axis.
                // Each cell expands independently; conditional groups and
                // nested spacers must not take a share of the row's width.
                HStack(spacing: 0) {
                    cropButton
                    aspectButton
                    rawButton
                    if store.mode != .video || store.caps.hasTorch {
                        flashButton
                    } else {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 40)
                    }
                    manualButton
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.22), value: store.isRecording)
        .shadow(color: .black.opacity(0.55), radius: 3)
    }

    @ViewBuilder private func photoControl(_ control: PhotoToolbarControl) -> some View {
        switch control {
        case .rangefinder: cropButton
        case .aspect: aspectButton
        case .raw: rawButton
        case .flash: flashButton
        case .manual: manualButton
        case .histogram: CustomShortcutButton(store: store, shortcut: .histogram)
        case .looks: CustomShortcutButton(store: store, shortcut: .looks)
        case .gallery: CustomShortcutButton(store: store, shortcut: .gallery)
        case .hidden: Color.clear.accessibilityHidden(true)
        }
    }

    private var cropButton: some View {
        Button {
            if store.mode == .rangefinder {
                if store.showFocalChips { store.selectMode(.photo) }
                else { store.showFocalChips = true }
            } else {
                store.selectMode(.rangefinder)
            }
        } label: {
            Image(systemName: "crop")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(store.mode == .rangefinder ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Circle().fill(store.mode == .rangefinder ? Theme.gold : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel("Rangefinder")
    }

    private var aspectButton: some View {
        Button { cycleAspect() } label: {
            Group {
                if store.aspect == .sensor {
                    Image(systemName: "pip")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white)
                } else {
                    outlined(store.aspect.title, on: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(UprightStyle())
        .disabled(store.mode == .video && store.framingOptions.anamorphic != .off)
        .opacity(store.mode == .video && store.framingOptions.anamorphic != .off ? 0.4 : 1)
        .accessibilityLabel("Aspect \(store.aspect.title)")
    }

    private var rawButton: some View {
        Button { store.rawEnabled.toggle() } label: {
            outlined("RAW", on: store.rawEnabled)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel("RAW")
        .disabled(store.mode != .video && (store.livePhoto || store.depthPortrait))
    }

    private var flashButton: some View {
        Button { cycleFlash() } label: {
            Image(systemName: store.flash.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(store.flash == .off ? Color.white : Theme.gold)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel(store.mode == .video ? "Video flashlight" : "Photo flash")
    }

    private var manualButton: some View {
        Button {
            store.viewfinderPull = false; store.focusMarkTask?.cancel(); store.focusMarkBusy = false
            store.showManual.toggle()
            if !store.showManual {
                store.activeControl = nil
                store.typing = nil
            }
        } label: {
            outlined("M", on: store.showManual)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(UprightStyle())
        .accessibilityLabel("Manual controls")
    }

    // A small rounded outline, filled yellow when on.
    private func outlined(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.system(size: title.count > 2 ? 10 : 12, weight: .heavy))
            .foregroundStyle(on ? Color.black : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 5)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Theme.gold : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(on ? Theme.gold : Color.white, lineWidth: 1.6)
            }
    }

    private func cycleAspect() {
        let all = FrameAspect.allCases
        let index = all.firstIndex(of: store.aspect) ?? 0

        store.aspect = all[(index + 1) % all.count]
        store.showToast(store.aspect.title)
    }

    private func cycleFlash() {
        if store.mode == .video {
            store.flash = store.flash == .on ? .off : .on
            return
        }
        let all = FlashChoice.allCases
        let index = all.firstIndex(of: store.flash) ?? 0

        store.flash = all[(index + 1) % all.count]
    }
}

// MARK: - Shutter dock

struct ShutterDock: View {
    @Bindable var store: CameraStore
    var onGallery: () -> Void
    var onSettings: () -> Void
    var onFn: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // The bar stops short of the shutter and curves around it,
                // like brackets.
                DockBarShape(gap: 39)
                    .fill(Color.clear)
                    .frame(height: 42)
                    .bar(DockBarShape(gap: 39))

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    Button(action: onGallery) {
                        thumb
                    }
                    .buttonStyle(UprightStyle())

                    Spacer(minLength: 0)

                    Button(action: onSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(UprightStyle())

                    Spacer(minLength: 0)

                    Button(action: store.fireShutter) {
                        shutter
                    }
                    .buttonStyle(UprightStyle())
                    .disabled(store.isBusy && store.mode != .video)

                    Spacer(minLength: 0)

                    Button(action: onFn) {
                        Text("Fn")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .overlay {
                                Circle().stroke(Color.white, lineWidth: 1.6)
                            }
                    }
                    .buttonStyle(UprightStyle())

                    Spacer(minLength: 0)

                    Button(action: store.flip) {
                        Image(systemName: "camera.rotate")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(UprightStyle())

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            }

            ZStack {
                HStack(spacing: 26) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                store.selectMode(mode)
                            }
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(
                                    store.mode == mode
                                        ? Theme.gold
                                        : .white.opacity(0.62)
                                )
                        }
                        .buttonStyle(UprightStyle())
                    }
                }

                HStack {
                    Spacer()

                    LensButton(store: store)
                }
                .padding(.trailing, 4)
            }

            if store.mode == .video, store.isRecording == false {
                codecSelector
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Text(store.caption)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .animation(.snappy(duration: 0.22), value: store.mode)
        .animation(.snappy(duration: 0.22), value: store.selectedCodec)
        .animation(.snappy(duration: 0.3), value: store.isRecording)
    }

    private var codecSelector: some View {
        Menu {
            if store.availableCodecs.isEmpty {
                Button("No compatible codecs found") {}
                    .disabled(true)
            } else {
                ForEach(store.availableCodecs) { codec in
                    Button {
                        store.selectCodec(codec)
                    } label: {
                        if store.selectedCodec == codec {
                            Label(codec.title, systemImage: "checkmark")
                        } else {
                            Text(codec.title)
                        }
                    }
                }
            }

            Divider()

            Button {
                store.refreshRecordingCodecs()
            } label: {
                Label("Refresh codecs", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 12, weight: .bold))

                Text(store.selectedCodec?.title ?? "Discovering codecs…")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
            }
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Color.white.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Theme.gold.opacity(0.35), lineWidth: 1)
            }
        }
        .disabled(store.isRecording)
        .accessibilityLabel("Recording codec")
    }

    private var thumb: some View {
        ZStack {
            if let capture = store.captures.first,
               let image = store.graded[AnyHashable(capture.id)]?.crop ?? store.graded[AnyHashable(capture.id)]?.full ?? capture.cropImage ?? capture.fullImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let scene = store.showcaseScene {
                Image(scene).resizable().scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle").font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if store.pendingPhotoCount > 0 {
                Text("\(store.pendingPhotoCount)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black).padding(3).background(Theme.gold, in: Circle()).offset(x: 5, y: -5)
            }
        }
        .accessibilityLabel(store.pendingPhotoCount > 0 ? "Gallery, \(store.pendingPhotoCount) photos processing" : "Gallery")
    }

    @ViewBuilder
    private var shutter: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 66, height: 66)

            switch store.mode {
            case .rangefinder:
                Circle()
                    .fill(.white)
                    .frame(width: 52, height: 52)

                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.black)

            case .photo:
                Circle()
                    .fill(.white)
                    .frame(width: 52, height: 52)

            case .video:
                if store.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.red)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 50, height: 50)
                }
            }
        }
        .opacity(store.isBusy ? 0.45 : 1)
    }
}

// MARK: - Chip editor

struct ChipEditor: View {
    let panel: ChipPanel
    @Bindable var store: CameraStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch panel {
            case .format:
                ForEach(PhotoFormat.allCases) { format in
                    Button {
                        store.format = format
                        store.chipPanel = nil
                    } label: {
                        row(
                            format.rawValue,
                            selected: store.format == format
                        )
                    }
                    .buttonStyle(UprightStyle())
                }

            case .exposure:
                HStack {
                    Text("−3")

                    Slider(
                        value: Binding(
                            get: { Double(store.exposure) },
                            set: { store.setExposure(Float($0)) }
                        ),
                        in: -3...3
                    )
                    .tint(Theme.gold)

                    Text("+3")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            case .save:
                ForEach(SaveTarget.allCases) { target in
                    Button {
                        store.saveTarget = target
                        store.chipPanel = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            row(
                                target.rawValue,
                                selected: store.saveTarget == target
                            )

                            Text(target.detail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .buttonStyle(UprightStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func row(
        _ title: String,
        selected: Bool
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Theme.gold : .white)

            Spacer()

            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.gold)
            }
        }
    }
}

// Shows a camera style on the built-in demo scene, where there is no
// live camera to run through the monitor.
struct DemoStyle: ViewModifier {
    let style: StyleParams

    func body(content: Content) -> some View {
        content
            .saturation(Double(style.saturation))
            .contrast(Double(style.contrast))
            .brightness(Double(style.brightness))
            .overlay {
                Color(
                    red: Double(style.tintRed),
                    green: Double(style.tintGreen),
                    blue: Double(style.tintBlue)
                )
                .opacity(Double(style.tintOpacity))
                .allowsHitTesting(false)
            }
    }
}

// The Camera Control button and the volume buttons act as the shutter.
struct CaptureButtonModifier: ViewModifier {
    let store: CameraStore

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended, !store.isShowcase, !store.reviewingCaptures {
                    Task { @MainActor in
                        guard !store.isShowcase, !store.reviewingCaptures else { return }
                        store.fireShutter()
                    }
                }
            }
        } else {
            content
        }
    }
}
