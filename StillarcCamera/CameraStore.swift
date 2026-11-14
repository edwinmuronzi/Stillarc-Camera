import AVFoundation
import CoreMotion
import Observation
import Photos
import SwiftUI
import UIKit

@Observable
final class CameraStore {
    let engine = CaptureEngine()
    var isShowcase = false
    var showcaseScene: String?
    var showcaseImage: UIImage?
    var showWelcome = false
    var requestGallery = false
    var reviewingCaptures = false { didSet { if !reviewingCaptures { cleanupExpiredCaptures(); drainCaptureCleanup() } } }
    var deletingGallery = false
    #if DEBUG
    var rejectGalleryDeletionForVerification = false
    #endif
    var viewfinderShortcuts: [ViewfinderShortcut] = {
        let saved = UserDefaults.standard.stringArray(forKey: "frameline.shortcuts.v1")?.compactMap(ViewfinderShortcut.init(rawValue:))
        return saved?.count == 3 ? saved! : [.timelapse, .magnify, .timer]
    }() { didSet { if !isShowcase { UserDefaults.standard.set(viewfinderShortcuts.map(\.rawValue), forKey: "frameline.shortcuts.v1") } } }
    private(set) var photoToolbar = PhotoToolbarControl.load() {
        didSet { if !isShowcase { UserDefaults.standard.set(photoToolbar.map(\.rawValue), forKey: "frameline.photoToolbar.v1") } }
    }
    var showsPhotoToolbar: Bool {
        mode == .video || isRecording || photoToolbar.contains { $0 != .hidden }
    }

    func setPhotoToolbarControl(_ control: PhotoToolbarControl, at index: Int) {
        guard photoToolbar.indices.contains(index), photoToolbar[index] != control else { return }
        var updated = photoToolbar
        if control != .hidden, let previous = updated.firstIndex(of: control) {
            updated[previous] = updated[index]
        }
        updated[index] = control
        photoToolbar = updated
    }

    func restorePhotoToolbar() {
        photoToolbar = PhotoToolbarControl.defaults
    }

    @ObservationIgnored var lockedImportObserver: Task<Void, Never>?
    var importingLockedCaptures = false
    var libraryReady = false
    var libraryDirty = false

    @ObservationIgnored private var finalizationActivity: CaptureSaveActivity?
    @ObservationIgnored private var preserveTask: Task<Void, Never>?
    var isFrontCamera = false
    var showShootingTools = false
    var framingOptions = FramingOptions.load() {
        didSet {
            framingOptions.save()
            if framingOptions.anamorphic != .off && mode == .video { aspect = .sensor }
            configureAdvancedFraming()
        }
    }
    var subjectTracking = false { didSet { configureAdvancedFraming() } }
    var trackedSubjectRect: CGRect?
    var trackingLost = false
    var selectedPresetID: UUID?
    var shootingPresets = ShootingPreset.load() {
        didSet {
            if !isShowcase { ShootingPreset.save(shootingPresets) }
            if let selectedPresetID, !shootingPresets.contains(where: { $0.id == selectedPresetID }) { self.selectedPresetID = nil }
        }
    }
    var focusPullLensEnabled = false {
        didSet {
            guard focusPullLensEnabled != oldValue else { return }
            cancelFocusPull()
            focusAuto = true
            codecTask?.cancel()
            lastCodecKey = nil
            engine.setFocusPullMode(focusPullLensEnabled)
            refreshRecordingCodecs()
        }
    }
    var viewfinderPull = false
    var focusAPoint: CGPoint?
    var focusBPoint: CGPoint?
    var focusMarkTarget = 0
    var focusMarkBusy = false
    @ObservationIgnored var focusMarkTask: Task<Void, Never>?
    var focusStart: Float?
    var focusEnd: Float?
    var focusPullDuration = 2.0
    var focusPullRunning = false
    var focusPullProgress = 0.0
    @ObservationIgnored private var focusPullTask: Task<Void, Never>?
    @ObservationIgnored private var focusPullID = UUID()
    var microphoneOptions: [MicrophoneOption] = []
    var selectedMicrophone: String? { didSet { if selectedMicrophone != oldValue { updateAudioTools() } } }
    var headphoneMonitoring = false { didSet { if headphoneMonitoring != oldValue { updateAudioTools() } } }
    var headphonesConnected = false
    var audioClipping = false
    var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @ObservationIgnored private var applyingShootingPreset = false
    @ObservationIgnored private var audioToolsTask: Task<Void, Never>?

    var mode: CaptureMode = .rangefinder {
        didSet {
            if oldValue != mode {
                viewfinderPull = false; focusMarkTask?.cancel(); focusMarkBusy = false; cancelFocusPull()
                if mode == .video, livePhoto || depthPortrait { livePhoto = false; depthPortrait = false; engine.configurePhotoCompanions(live: false, depth: false) }
                updateStyle()
                updateMonitor()
                configureAdvancedFraming()
            }
        }
    }
    var focal = FocalLength.all[0]
    var format: PhotoFormat = .heif
    var saveTarget: SaveTarget = .both
    var aspect: FrameAspect = .sensor
    var exposure: Float = -0.7
    var naturalPhoto = false
    var livePhoto = false
    var depthPortrait = false
    var captureHDRHighlights = UserDefaults.standard.bool(forKey: "frameline.captureHDRHighlights") {
        didSet { if !isShowcase { UserDefaults.standard.set(captureHDRHighlights, forKey: "frameline.captureHDRHighlights") } }
    }
    var motionExposure: MotionExposure = .off
    var motionExposureSeconds = 2
    var motionExposureActive = false
    var rawEnabled = false
    var flash: FlashChoice = .off {
        didSet {
            if mode == .video { engine.setTorch(enabled: flash == .on) }
        }
    }
    var manual = false
    var iso: Float = 100
    var shutter: Double = 1.0 / 120
    var whiteBalance: Float = 5600
    var lockWhiteBalance = false
    var lensPosition: Float = 0.6

    var logProfile: LogProfile = .off {
        didSet {
            if oldValue != logProfile {
                updatePreviewLog()
                updateStyle()
                updateMonitor()
                refreshRecordingCodecs()
            }
        }
    }

    // Both outputs use the current camera format; toggling Dual Shot must
    // not stop the preview to rediscover identical codecs.
    var dualShot = false {
        didSet {
            engine.setDualPreview(dualShot && mode == .video)
            updatePreviewLog()
            refreshRecordingCodecs()
            configureAdvancedFraming()
        }
    }

    var availableCodecs: [RecordingCodec] = []
    var selectedCodec: RecordingCodec? { didSet { if selectedCodec != oldValue { updatePreviewLog() } } }

    // Resolution, frame rate and bitrate for video recording.
    var recSettings = RecordingSettings.load() {
        didSet {
            recSettings.save()

            updatePreviewLog()

            if oldValue.frameRate != recSettings.frameRate {
                applyShutterAngle(enableManual: false)
            }

            if oldValue.resolution != recSettings.resolution
                || oldValue.frameRate != recSettings.frameRate {
                refreshRecordingCodecs()
            }
        }
    }

    var videoOptions = RecordingOptions()

    // Back lenses (0.5x, 1x, 4x ...). Empty on the front camera.
    var lenses: [LensOption] = []
    var selectedLensID: String?
    @ObservationIgnored private var pendingLensRefresh: String?
    @ObservationIgnored private var pendingLaunchPreset: ShootingPreset?

    var lensZoom: Double {
        lenses.first { $0.uniqueID == selectedLensID }?.zoom ?? 1
    }

    // Exposure aids.
    var showHistogram = UserDefaults.standard.bool(forKey: "frameline.aid.hist") {
        didSet { aidsChanged() }
    }

    var showWaveform = UserDefaults.standard.bool(forKey: "frameline.aid.wave") {
        didSet { aidsChanged() }
    }

    var showZebra = UserDefaults.standard.bool(forKey: "frameline.aid.zebra") {
        didSet { aidsChanged() }
    }

    var peakColor = PeakColor.load() {
        didSet {
            UserDefaults.standard.set(peakColor.rawValue, forKey: "frameline.peak.color")
            sendPeaking()
        }
    }

    // 0 marks only the sharpest edges, 1 marks almost everything.
    var peakSensitivity: Float = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "frameline.peak.sens") == nil
            ? 0.6
            : defaults.float(forKey: "frameline.peak.sens")
    }() {
        didSet {
            UserDefaults.standard.set(peakSensitivity, forKey: "frameline.peak.sens")
            sendPeaking()
        }
    }

    var showPeaking = UserDefaults.standard.bool(forKey: "frameline.aid.peak") {
        didSet { aidsChanged() }
    }

    var showFalseColor = UserDefaults.standard.bool(forKey: "frameline.aid.false") {
        didSet { aidsChanged() }
    }

    var histogramData: [Float] = []
    var histogramChannels: [[Float]] = []
    var waveformImage: CGImage?

    // Long-press lock, a view with no overlays, and saved looks.
    var aeafLocked = false
    var cleanFeed = false

    var savedLooks: [SavedLook] = SavedLook.load() {
        didSet { SavedLook.save(savedLooks) }
    }

    // Built once per device, not on every redraw.
    @ObservationIgnored private var specCache: [ControlKind: RulerSpec] = [:]
    @ObservationIgnored private var specKey = ""

    // Camera controls: ISO, shutter, WB, focus and EV, each manual or auto.
    var activeControl: ControlKind?

    // Orientation: 90 is portrait, 0 and 180 are the two landscapes.
    var captureAngle: Double = 90
    private var deviceAngle: Double = 90
    private var watchingOrientation = false
    @ObservationIgnored private var orientationObserver: NSObjectProtocol?
    private let motion = CMMotionManager()

    var isLandscape: Bool {
        captureAngle == 0 || captureAngle == 180
    }

    var typing: ControlKind?
    var showLUTPanel = false

    var isoAuto = true
    var shutterAuto = true
    var focusAuto = true

    var liveISO: Float = 100
    var liveShutter: Double = 1.0 / 60
    var liveKelvin: Float = 5600
    var liveFocus: Float = 0.5
    var aidsImage: CGImage?

    // Shutter angle lock: shutter follows frame rate.
    static let shutterAngles: [Double] = [45, 90, 144, 172.8, 180, 270, 360]

    var shutterAngleLock = false {
        didSet {
            if oldValue != shutterAngleLock {
                applyShutterAngle(enableManual: true)
            }
        }
    }

    var shutterAngle: Double = 180 {
        didSet {
            if oldValue != shutterAngle {
                applyShutterAngle(enableManual: false)
            }
        }
    }

    var effectiveRecordingSettings: RecordingSettings {
        var settings = recSettings
        if dualShot, mode == .video { settings.frameRate = min(settings.frameRate ?? 30, 30) }
        return settings
    }

    var angleFrameRate: Int { effectiveRecordingSettings.frameRate ?? 30 }

    var shutterAngleText: String {
        shutterAngle == shutterAngle.rounded()
            ? "\(Int(shutterAngle))°"
            : String(format: "%.1f°", shutterAngle)
    }

    var grid = false {
        didSet { if !restoringSession { savePreserved() } }
    }

    // Level line, from the accelerometer.
    // Zoomed loupe for checking focus, shown while a look is not hiding it.
    var showMagnify = UserDefaults.standard.bool(forKey: "frameline.magnify") {
        didSet { UserDefaults.standard.set(showMagnify, forKey: "frameline.magnify") }
    }

    var showLevel = UserDefaults.standard.bool(forKey: "frameline.level") {
        didSet { UserDefaults.standard.set(showLevel, forKey: "frameline.level") }
    }

    var levelAngle: Double = 0
    @ObservationIgnored private var levelSmoothed: Double = 0
    @ObservationIgnored private var smoothX = 0.0
    @ObservationIgnored private var smoothY = -1.0
    @ObservationIgnored private var smoothZ = 0.0
    var levelVisible = false

    // Second axis: forward and back tilt, and a bubble for a flat phone.
    var levelPitch: Double = 0
    var levelFlat = false
    var levelBubbleX: Double = 0
    var levelBubbleY: Double = 0

    // Settings that carry over between launches when this is on. The
    // focal length always starts at 24 mm otherwise.
    var preserveSettings = (UserDefaults.standard.object(forKey: "frameline.preserve") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(preserveSettings, forKey: "frameline.preserve") }
    }

    // Zoom is a power of two above the 24 mm view: 0 is 24 mm, 3 is 8x.
    static let maxZoomLog = 3.0
    var zoomLog: Double = 0
    var showFocalChips = false
    var zoomTargetLog: Double?
    var zoomReturnLog: Double?
    @ObservationIgnored private var zoomTask: Task<Void, Never>?

    // Shape of the viewfinder, so the video crop matches what is on screen.
    var viewRatio: Double = 3.0 / 4.0

    // Seconds for a full automatic zoom from one end to the other.
    var zoomSeconds: Double = (UserDefaults.standard.object(forKey: "frameline.zoomSeconds") as? Double) ?? 4 {
        didSet { UserDefaults.standard.set(zoomSeconds, forKey: "frameline.zoomSeconds") }
    }

    var stabilization: StabilizationChoice = StabilizationChoice(
        rawValue: UserDefaults.standard.string(forKey: "frameline.stab") ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(stabilization.rawValue, forKey: "frameline.stab")
            engine.setStabilization(stabilization.mode)
        }
    }

    var lockWBOnRecord = UserDefaults.standard.bool(forKey: "frameline.lockWBRecord") {
        didSet { UserDefaults.standard.set(lockWBOnRecord, forKey: "frameline.lockWBRecord") }
    }

    @ObservationIgnored private var wbLockedByRecording = false

    // Controls held at their current value, like the padlocks on a cinema
    // camera. A locked control ignores the ruler and every AUTO.
    var lockedControls: Set<ControlKind> = []

    // Seconds between frames for timelapse stills. 0 is off.
    var timelapseInterval: Int = UserDefaults.standard.integer(forKey: "frameline.timelapse") {
        didSet { UserDefaults.standard.set(timelapseInterval, forKey: "frameline.timelapse") }
    }

    var timelapseRunning = false
    @ObservationIgnored private var videoTimelapseActive = false
    var timelapseCount = 0
    @ObservationIgnored private var timelapseTask: Task<Void, Never>?

    // Microphone meter and input choice.
    var audioLevel: Float = 0
    var micInputs: [MicInput] = []
    var selectedMicUID = ""
    var micGain: Float = 0.5
    var micGainAvailable = false
    private var cameraControls: CameraControlBridge?
    var saveToPhotos = UserDefaults.standard.object(forKey:"stillarc.saveToPhotos") as? Bool ?? true {
        didSet {
            if !saveToPhotos && !saveInApp { saveInApp = true }
            if writesStoragePreferences { UserDefaults.standard.set(saveToPhotos,forKey:"stillarc.saveToPhotos") }
        }
    }
    var saveInApp = UserDefaults.standard.object(forKey:"stillarc.saveInApp") as? Bool ?? true {
        didSet {
            if !saveInApp && !saveToPhotos { saveToPhotos = true }
            if writesStoragePreferences { UserDefaults.standard.set(saveInApp,forKey:"stillarc.saveInApp") }
        }
    }
    var autoDeleteAfter = CaptureRetention(rawValue:UserDefaults.standard.integer(forKey:"stillarc.autoDeleteAfter")) ?? .never {
        didSet { if writesStoragePreferences { UserDefaults.standard.set(autoDeleteAfter.rawValue,forKey:"stillarc.autoDeleteAfter"); cleanupExpiredCaptures() } }
    }
    var protectedCaptureIDs = Set<UUID>()
    var automaticRemovalIDs = Set<UUID>()
    var look: FilmLook = .standard {
        didSet { updateStyle() }
    }

    // The current style as plain numbers, for the monitor and saved photos.
    var styleParams: StyleParams {
        // Looked up by id, so a preset you are editing shows its newest values.
        let resolved = allLooks.first { $0.id == look.id } ?? look

        var params = StyleParams(look: resolved, options: lookOptions, dials: currentDials)
        if mode != .video {
            params.refinedPhotoTexture = true
            if lookOptions.glowOn && resolved.id == "night35" {
                params.glow = 0
                params.halation = 0.38
            }
        }
        return params
    }

    // The presets, then the ones you made.
    var lookLibrary = LookLibraryPreferences.load() { didSet { if !isShowcase { lookLibrary.save(); CustomLookRegistry.shared.update(customLooks + lookLibrary.deletedLooks) } } }
    var libraryUndo: [LookLibrarySnapshot] = {
        UserDefaults.standard.data(forKey: "frameline.lookLibrary.undo").flatMap { try? JSONDecoder().decode([LookLibrarySnapshot].self, from: $0) } ?? []
    }()
    var allLooks: [FilmLook] {
        let catalog = (FilmLook.lineup + customLooks.map { FilmLook.custom($0) }).filter { $0.id == "standard" || !lookLibrary.hidden.contains($0.id) }
        return catalog.enumerated().sorted {
            let a = lookLibrary.order.firstIndex(of: $0.element.id) ?? (lookLibrary.order.count + $0.offset)
            let b = lookLibrary.order.firstIndex(of: $1.element.id) ?? (lookLibrary.order.count + $1.offset)
            return a < b
        }.map(\.element)
    }

    var customLooks: [CustomLook] = CustomLook.loadAll() {
        didSet {
            if !isShowcase { CustomLook.saveAll(customLooks); CustomLookRegistry.shared.update(customLooks + lookLibrary.deletedLooks) }
            updateStyle()
        }
    }

    // Quality and Tone are kept for each look.
    var lookDials: [String: LookDials] = LookDials.loadAll() {
        didSet {
            if !isShowcase { LookDials.saveAll(lookDials) }
            updateStyle()
        }
    }

    var currentDials: LookDials {
        lookDials[look.id] ?? LookRecipe.defaultDials(for: look.id)
    }

    func setQuality(_ index: Int) {
        var dials = currentDials
        dials.quality = min(max(index, 0), LookDials.grainAmounts.count - 1)
        lookDials[look.id] = dials
    }

    func setTone(_ index: Int) {
        var dials = currentDials
        dials.tone = min(max(index, 0), Tones.all.count - 1)
        lookDials[look.id] = dials
    }

    // Starts a preset from an existing look, from scratch, or at random.
    func addCustomLook(basedOn base: FilmLook?) -> UUID {
        let name = "Preset \(customLooks.count + 1)"

        let custom = base.map { CustomLook.copy(of: $0, named: name) }
            ?? CustomLook(name: name)

        customLooks.append(custom)

        return custom.id
    }

    func addRandomCustomLook() -> UUID {
        let custom = CustomLook.random(named: "Preset \(customLooks.count + 1)")

        customLooks.append(custom)

        return custom.id
    }

    func deleteCustomLooks(at offsets: IndexSet) {
        let removed = offsets.map { customLooks[$0].lookID }

        customLooks.remove(atOffsets: offsets)

        for id in removed {
            lookDials[id] = nil

            if look.id == id {
                look = .standard
            }
        }
    }

    // Uses one of your presets, with the dials it was made with.
    func useCustomLook(_ id: UUID) {
        guard let custom = customLooks.first(where: { $0.id == id }) else { return }

        if lookDials[custom.lookID] == nil {
            lookDials[custom.lookID] = LookDials(quality: custom.quality, tone: custom.tone)
        }

        look = FilmLook.custom(custom)
    }

    // Which parts of the look are on, and how strong it is.
    var lookOptions = LookOptions.load() {
        didSet {
            if !isShowcase { LookOptions.save(lookOptions) }
            updateStyle()
        }
    }

    var styleActive: Bool {
        styleParams.isIdentity == false
    }

    // The viewfinder draws the monitor layer for a LUT or a style.
    var monitorShown: Bool {
        (mode == .video && (dualShot || framingOptions.anamorphic != .off)) || ((monitorLUT || styleActive) && monitorAllowed)
    }

    // Holding the A/B pill shows the original picture, so the preview is
    // switched off for as long as it is held.
    var comparing = false {
        didSet {
            guard oldValue != comparing else { return }
            engine.setComparison(comparing)
            updateStyle()
            updateMonitor()
        }
    }

    var monitorAllowed: Bool {
        comparing == false
    }

    // Graded copies of saved photos, by capture id.
    var graded: [AnyHashable: GradedStills] = [:]
    var luts: [CubeLUT] = CubeLUT.builtIns
    var selectedLUT: CubeLUT? {
        didSet { updateMonitor() }
    }
    var bakeLUT = true
    @ObservationIgnored private var recordingLUTBaked = false
    @ObservationIgnored private var recordingAllowsOpticalSwitch = false

    var isLUTBaking: Bool {
        isRecording ? recordingLUTBaked : (bakeLUT && selectedLUT != nil)
    }

    func canSelectLens(_ lens: LensOption) -> Bool {
        guard isRecording else { return true }
        if recordingAllowsOpticalSwitch || caps.usesVirtualCamera { return true }
        return lens.deviceID == lenses.first(where: { $0.uniqueID == selectedLensID })?.deviceID
    }
    var lutIntensity: Float = 1.0 {
        didSet { updateMonitor() }
    }

    // Live LUT preview, also while recording Log.
    var monitorLUT = false {
        didSet { updateMonitor() }
    }

    var caps = DeviceCaps()
    var captures: [CaptureItem] = []
    var photoEdits: [UUID: PhotoEdit] = [:]
    var editingPhotos: Set<UUID> = []
    @ObservationIgnored var librarySaveTask: Task<Bool, Never>?
    var isRecording = false
    var isBusy = false
    private struct StillContext {
        let date = Date()
        let request: StillComposer.Request
        let detail: String
        let saves: Bool
        let mode: CaptureMode
        var natural = false
        var live = false
        var portrait = false
        var expectsRaw = false
        var keepInApp = true
    }
    @ObservationIgnored private var stillContexts: [UUID: StillContext] = [:]
    @ObservationIgnored private var compositionTail: Task<Void, Never>?
    @ObservationIgnored private var compositionTailID: UUID?
    @ObservationIgnored private var verifiedDepthIDs: Set<UUID> = []
    var pendingPhotoCount = 0

    private var photoCapacity: Int { rawEnabled || naturalPhoto || livePhoto || depthPortrait || format == .heifMax ? 2 : 5 }
    var recordingStarted: Date?

    // Timecode runs on from clip to clip. It restarts only when reset.
    var clipNumber = 0

    // Storage figures, read off the main thread so a busy disk can never
    // stall the screen.
    var storageTotalBytes: Double = 0
    var storageFreeBytes: Double = 0
    @ObservationIgnored private var storageTask: Task<Void, Never>?

    var clipInfo: [AnyHashable: ClipInfo] = [:]
    private var clipStartBase: Double = 0

    // Exposure bracketing: 0 is off, otherwise three photos at -n, 0 and +n.
    var bracketStops = UserDefaults.standard.integer(forKey: "frameline.bracket") {
        didSet { UserDefaults.standard.set(bracketStops, forKey: "frameline.bracket") }
    }

    private var bracketTask: Task<Void, Never>?
    var timecodeBase: Double = 0
    var chipPanel: ChipPanel?
    var toast: String?
    var showManual = false
    var focusPoint: CGPoint?
    var shutterTick = 0

    // Self-timer for photos: off, 3 or 10 seconds.
    var timerSeconds = UserDefaults.standard.integer(forKey: "frameline.timer") {
        didSet { UserDefaults.standard.set(timerSeconds, forKey: "frameline.timer") }
    }

    var countdown: Int?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    var didResolveCamera = false

    private var bound = false
    private var toastTask: Task<Void, Never>?
    private var photosSaveTask: Task<Bool, Never>?

    // One line that names everything that is switched on.
    var caption: String {
        if mode == .photo, motionExposure != .off {
            return "\(motionExposure.title) · \(motionExposureSeconds)s"
        }
        var parts: [String] = []

        switch mode {
        case .rangefinder:
            parts.append("Rangefinder \(focal.compact) frame lines")
        case .photo:
            parts.append("Photo \(focal.compact)")
        case .video:
            parts.append("Video \(focal.compact)")

            if logProfile != .off {
                parts.append(logProfile.title)
            }

            if dualShot {
                parts.append("Dual shot")
            }

            if let selectedCodec {
                parts.append(selectedCodec.title)
            }

            if let resolution = recSettings.resolution {
                parts.append(resolution.shortTitle)
            }

            if let fps = effectiveRecordingSettings.frameRate {
                parts.append("\(fps) fps")
            }
        }

        if mode != .video, rawEnabled, !depthPortrait, !livePhoto {
            parts.append("RAW")
        }

        if aspect != .sensor {
            parts.append("Crop \(aspect.title)")
        }

        if lensZoom != 1 {
            parts.append(lensZoom == lensZoom.rounded()
                ? "\(Int(lensZoom))x lens"
                : String(format: "%.1fx lens", lensZoom))
        }

        if styleActive {
            parts.append("Style \(look.name)")
        }

        if monitorLUT, let lut = selectedLUT {
            parts.append("LUT \(lutName(lut))")
        }

        if shutterAngleLock {
            parts.append("\(shutterAngleText) shutter")
        } else if shutterAuto == false {
            parts.append("Shutter \(rulerSpec(for: .shutter).format(shutter))")
        }

        if isoAuto == false {
            parts.append("ISO \(Int(iso))")
        }

        if lockWhiteBalance {
            parts.append("WB \(Int(whiteBalance))K")
        }

        if focusAuto == false {
            parts.append("Manual focus")
        }

        var aids: [String] = []
        if showHistogram { aids.append("histogram") }
        if showZebra { aids.append("zebras") }
        if showPeaking { aids.append("peaking") }
        if showFalseColor { aids.append("false colour") }

        if aids.isEmpty == false {
            parts.append(aids.joined(separator: ", "))
        }

        return parts.joined(separator: " · ")
    }

    var frameScale: CGFloat {
        mode == .rangefinder ? CGFloat(min(1, 24 * lensZoom / Double(focal.value))) : 1
    }

    var showsFrameMask: Bool {
        mode == .rangefinder || aspect != .sensor
    }

    func activate() {
        guard bound == false else { return }
        bound = true
        observeLockedImports()
        restoreLibrary()

        CustomLookRegistry.shared.update(customLooks + lookLibrary.deletedLooks)
        if !UserDefaults.standard.bool(forKey: "frameline.preserveSessionV2") {
            preserveSettings = true
            UserDefaults.standard.set(true, forKey: "frameline.preserveSessionV2")
        }
        startStorageUpdates()

        loadImportedLUTs()
        restorePreserved()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-single-recording") {
            mode = .video; dualShot = false; logProfile = .off
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-live-zoom") || ProcessInfo.processInfo.arguments.contains("--verify-advanced-preview") {
            mode = .video
            dualShot = true
            logProfile = .off
            subjectTracking = ProcessInfo.processInfo.arguments.contains("--verify-advanced-preview")
        }
        if (ProcessInfo.processInfo.arguments.contains("--verify-styled-recording") || ProcessInfo.processInfo.arguments.contains("--verify-efficiency") || ProcessInfo.processInfo.arguments.contains("--verify-interruption")) {
            mode = .video; dualShot = true; logProfile = .off
            look = FilmLook.lineup.first(where: { $0.id != "standard" }) ?? .standard
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-focus-pull") || ProcessInfo.processInfo.arguments.contains("--verify-viewfinder") {
            mode = .video; dualShot = true; logProfile = .off; focusPullLensEnabled = true
        }
        #endif
        engine.setStabilization(stabilization.mode)

        engine.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        engine.onCodecs = { [weak self] codecs in
            Task { @MainActor [weak self] in
                guard let self else { return }

                availableCodecs = codecs

                if let selectedCodec,
                   codecs.contains(selectedCodec) {
                    return
                }

                selectedCodec = codecs.first
            }
        }

        engine.onVideoOptions = { [weak self] options in
            Task { @MainActor [weak self] in
                self?.receive(videoOptions: options)
            }
        }

        engine.onTrackingUpdate = { [weak self] rect, lost, point in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackedSubjectRect = rect
                self.trackingLost = lost
                if self.subjectTracking, self.focusAuto, !self.aeafLocked, let point { self.engine.focusTrackedSubject(point) }
            }
        }
        engine.onAudioClip = { [weak self] clipping in
            Task { @MainActor [weak self] in if self?.audioClipping != clipping { self?.audioClipping = clipping } }
        }
        engine.onAudioState = { [weak self] options, selected, headphones, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneOptions = options
                if self.selectedMicrophone != selected { self.selectedMicrophone = selected }
                self.headphonesConnected = headphones
            }
        }
        configureAdvancedFraming()

        engine.onLenses = { [weak self] options, current, controlsNeedReapply in
            Task { @MainActor [weak self] in
                guard let self else { return }

                lenses = options
                selectedLensID = current

                installCameraControls()
                applyPendingLaunchPreset()

                // A zoom-only lens change preserves the camera's controls.
                if controlsNeedReapply { reapplyControls() }
                if let pending = pendingLensRefresh, pending == current {
                    pendingLensRefresh = nil
                    if !isRecording {
                        if logProfile != .off { refreshRecordingCodecs() }
                        else { engine.refreshVideoOptions(log: .off) }
                    }
                }
            }
        }

        engine.onAnalysis = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if showHistogram {
                    histogramData = frame.histogram
                    histogramChannels = frame.channels
                }

                waveformImage = showWaveform ? frame.waveform : nil

                aidsImage = (showZebra || showPeaking || showFalseColor) ? frame.overlay : nil
            }
        }

        engine.setAids(
            histogram: showHistogram,
            zebra: showZebra,
            peaking: showPeaking,
            falseColor: showFalseColor,
            waveform: showWaveform
        )

        sendPeaking()

        engine.onAudioLevel = { [weak self] decibels in
            Task { @MainActor [weak self] in
                // -60 dB and below is silence; 0 dB is full scale.
                self?.audioLevel = max(0, min(1, (decibels + 60) / 60))
            }
        }

        engine.onTimelapseCount = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.timelapseCount = count
            }
        }

        engine.onLive = { [weak self] live in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Only publish real changes so the screen is not redrawn
                // for tiny meter jitter.
                if abs(liveISO - live.iso) > 0.5 { liveISO = live.iso }

                if abs(liveShutter - live.shutter) > liveShutter * 0.01 {
                    liveShutter = live.shutter
                }

                if abs(liveKelvin - live.kelvin) > 20 { liveKelvin = live.kelvin }

                if abs(liveFocus - live.lensPosition) > 0.005 {
                    liveFocus = live.lensPosition
                }
            }
        }

        watchOrientation()
        observePreservedSettings()

        updatePreviewLog()

        engine.start()
        framingChanged()
        engine.setExposureBias(exposure)

        refreshRecordingCodecs()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-style-sliders") {
            verifyStyleSliders()
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-photo-combinations") {
            selectMode(.photo)
            UIApplication.shared.isIdleTimerDisabled = true
            focusPullLensEnabled = false
            if isFrontCamera { flip() }
            engine.verifyPhotoCombinations()
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-motion-exposure") {
            selectMode(.photo)
            engine.verifyMotionExposure()
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-raw-preview") { verifyRawPreview() }
        if ProcessInfo.processInfo.arguments.contains("--verify-log-photo-preset") { verifyLogPhotoPreset() }
        if ProcessInfo.processInfo.arguments.contains("--verify-preset-capture") { verifyPresetCapture() }
        if ProcessInfo.processInfo.arguments.contains("--verify-photo-pipeline") { verifyPhotoPipeline() }
        if ProcessInfo.processInfo.arguments.contains("--verify-single-recording") { verifySingleRecording() }
        if ProcessInfo.processInfo.arguments.contains("--verify-camera-reliability") { verifyCameraReliability() }
        if ProcessInfo.processInfo.arguments.contains("--verify-photo-burst") { verifyPhotoBurst() }
        if ProcessInfo.processInfo.arguments.contains("--verify-upgrade") { verifyUpgrade() }
        if ProcessInfo.processInfo.arguments.contains("--verify-library") { verifyLibraryAndEdits() }
        if ProcessInfo.processInfo.arguments.contains("--verify-nv12") { verifyNV12Output() }
        if ProcessInfo.processInfo.arguments.contains("--verify-manager") { verifyStyleManagement() }
        if ProcessInfo.processInfo.arguments.contains("--verify-depth") { verifyDepthResume() }
        if ProcessInfo.processInfo.arguments.contains("--verify-direct-grade") { verifyDirectGrade() }
        if ProcessInfo.processInfo.arguments.contains("--verify-viewfinder") { verifyViewfinderFocus() }
        if (ProcessInfo.processInfo.arguments.contains("--verify-styled-recording") || ProcessInfo.processInfo.arguments.contains("--verify-efficiency") || ProcessInfo.processInfo.arguments.contains("--verify-interruption")) {
            engine.verifyStyledRecording(style: styleParams)
            if ProcessInfo.processInfo.arguments.contains("--verify-efficiency") {
                UIApplication.shared.isIdleTimerDisabled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("--long-soak") ? 190 : 70))
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-focus-pull") {
            Task { @MainActor [weak self] in
                NSLog("FOCUS_VERIFY starting")
                UIApplication.shared.isIdleTimerDisabled = true
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                NSLog("FOCUS_VERIFY supported=%d", self.caps.supportsManualFocus ? 1 : 0)
                self.focusStart = 0.2; self.focusEnd = 0.8; self.focusPullDuration = 2
                self.runFocusPull()
                try? await Task.sleep(for: .seconds(2.5))
                NSLog("FOCUS_VERIFY result=%@ actual=%.3f", self.caps.supportsManualFocus && abs(self.liveFocus - 0.8) < 0.06 ? "PASS" : "FAIL", Double(self.liveFocus))
                self.focusPullLensEnabled = false
                self.setAuto(.focus)
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-lut-panel") { showLUTPanel = true }
        if ProcessInfo.processInfo.arguments.contains("--show-selected-preset") {
            saveShootingPreset(named: "Everyday")
            showLUTPanel = true
        }
        if ProcessInfo.processInfo.arguments.contains("--show-shooting-tools") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.showShootingTools = true
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--verify-live-zoom") || ProcessInfo.processInfo.arguments.contains("--verify-advanced-preview") {
            engine.verifyUnifiedPreviewZoom()
        }
        #endif
    }

    // Codec discovery stops and rebuilds the camera session, so it must not
    // run more often than needed. Repeat requests for the same setup are
    // skipped, and a burst of requests becomes one.
    private var codecTask: Task<Void, Never>?
    private var lastCodecKey: String?

    func refreshRecordingCodecs(force: Bool = false) {
        guard bound, mode == .video, !reviewingCaptures, !applyingShootingPreset, isRecording == false else { return }

        let key = [
            logProfile.rawValue,
            recSettings.resolution?.title ?? "auto",
            "\(effectiveRecordingSettings.frameRate ?? 0)",
            "\(selectedLensID ?? "")"
        ].joined(separator: "|")

        if force == false,
           key == lastCodecKey,
           availableCodecs.isEmpty == false {
            return
        }

        codecTask?.cancel()

        codecTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))

            guard Task.isCancelled == false,
                  let self,
                  bound, mode == .video, !reviewingCaptures,
                  isRecording == false else {
                return
            }

            lastCodecKey = key

            engine.discoverRecordingCodecs(
                log: logProfile,
                dual: dualShot,
                settings: effectiveRecordingSettings,
                preferredCodec: force ? nil : selectedCodec
            )
        }
    }

    private func receive(videoOptions options: RecordingOptions) {
        videoOptions = options

        guard options.locked == false,
              options.resolutions.isEmpty == false else {
            return
        }

        // Drop saved choices this camera or colour profile cannot do.
        var next = recSettings

        if let resolution = next.resolution,
           options.resolutions.contains(resolution) == false {
            next.resolution = nil
        }

        if let fps = next.frameRate,
           options.frameRates(for: next.resolution).contains(fps) == false {
            next.frameRate = nil
        }

        if next != recSettings {
            recSettings = next
        }
    }

    func selectResolution(_ resolution: RecResolution?) {
        guard isRecording == false else { return }

        var next = recSettings
        next.resolution = resolution

        if let fps = next.frameRate,
           videoOptions.frameRates(for: resolution).contains(fps) == false {
            next.frameRate = nil
        }

        recSettings = next
    }

    func selectFrameRate(_ fps: Int?) {
        guard isRecording == false else { return }

        var next = recSettings
        next.frameRate = fps

        if let fps,
           let resolution = next.resolution,
           videoOptions.frameRates(for: resolution).contains(fps) == false {
            next.resolution = nil
        }

        recSettings = next
    }

    func selectBitrate(_ bitrate: RecBitrate) {
        guard isRecording == false else { return }
        recSettings.bitrate = bitrate
    }

    // Used only to label the bitrate choices with an approximate Mbps figure.
    private var estimatedSize: (width: Int, height: Int) {
        if let resolution = recSettings.resolution {
            return (resolution.width, resolution.height)
        }

        let auto = videoOptions.resolutions.first {
            $0.isSixteenByNine && $0.width <= 3840
        } ?? videoOptions.resolutions.first

        if let auto {
            return (auto.width, auto.height)
        }

        return (3840, 2160)
    }

    // Bytes one second of video takes with the current codec, resolution,
    // frame rate and bitrate, for the recording time left on the phone.
    var estimatedRecordingBytesPerSecond: Double {
        let size = estimatedSize
        let fps = Double(recSettings.frameRate ?? 30)
        let pixelRate = Double(size.width * size.height) * fps
        let reference = 3840.0 * 2160.0 * 30.0
        let codec = selectedCodec?.rawValue ?? "hvc1"

        var bits: Double

        if codec.hasPrefix("ap") {
            // ProRes 422 rates at 4K 30 fps, scaled to the picture size.
            let base: Double

            switch codec {
            case "apch": base = 707
            case "apcn": base = 471
            case "apcs": base = 328
            default: base = 145
            }

            bits = base * 1_000_000 * pixelRate / reference
        } else if let chosen = recSettings.bitrate.bitsPerSecond(
            width: size.width,
            height: size.height,
            fps: fps,
            codec: codec
        ) {
            bits = Double(chosen)
        } else {
            // Automatic: about 50 Mbps for HEVC at 4K 30 fps.
            bits = max(8_000_000, 50_000_000 * pixelRate / reference)

            if codec == "avc1" { bits *= 1.6 }
        }

        // Sound, and the extra vertical file in dual shot.
        bits += 256_000

        if dualShot { bits *= 1.25 }

        return bits / 8
    }

    func bitrateTitle(_ bitrate: RecBitrate) -> String {
        let size = estimatedSize

        guard let bps = bitrate.bitsPerSecond(
            width: size.width,
            height: size.height,
            fps: Double(recSettings.frameRate ?? 30),
            codec: selectedCodec?.rawValue ?? "hvc1"
        ) else {
            return bitrate.title
        }

        return "\(bitrate.title) · about \(bps / 1_000_000) Mbps"
    }

    func selectCodec(_ codec: RecordingCodec) {
        guard availableCodecs.contains(codec) else { return }
        selectedCodec = codec
    }

    func framingChanged() {
        engine.updateFraming(
            focal: focal.value,
            rangefinder: mode == .rangefinder
        )
    }

    func selectMode(_ next: CaptureMode) {
        guard !motionExposureActive else { return }
        cancelFocusPull()
        mode = next
        if next != .video { logProfile = .off }
        if next == .video, flash == .auto { flash = .off }
        engine.setTorch(enabled: next == .video && flash == .on)
        engine.setDualPreview(dualShot && next == .video)
        showFocalChips = next == .rangefinder

        if next != .rangefinder {
            chipPanel = nil
        }

        framingChanged()

        cancelCountdown()

        // Log previews flat in video mode only.
        updatePreviewLog()

        if next == .video {
            refreshRecordingCodecs()
        }
    }

    func selectFocal(_ next: FocalLength) {
        focal = next
        showFocalChips = false
        framingChanged()
    }

    // Smooth focal length from the ruler, in whole millimetres.
    func setFocalValue(_ value: Double) {
        let clamped = min(max(value.rounded(), 24), 90)

        guard clamped != focal.value else { return }

        focal = FocalLength(value: clamped)
        framingChanged()
    }

    func setZoom(log value: Double) {
        zoomTask?.cancel()

        let clamped = min(max(value, 0), Self.maxZoomLog)

        zoomLog = clamped
        engine.setZoom(multiplier: pow(2, clamped))
    }

    // Where the automatic zoom is heading, picked on the ruler, and where
    // it started, so it can go back.
    func setZoomTarget(_ value: Double) {
        let clamped = min(max(value, 0), Self.maxZoomLog)

        zoomTargetLog = clamped
        showToast(String(format: "Zoom point %.1fx.", pow(2, clamped)))
    }

    func runZoomToTarget() {
        guard let target = zoomTargetLog else {
            showToast("Tap a point on the ruler to choose where to zoom.")
            return
        }

        zoomReturnLog = zoomLog
        autoZoom(toLog: target)
    }

    func runZoomBack() {
        let back = zoomReturnLog ?? 0

        zoomReturnLog = zoomLog
        autoZoom(toLog: back)
    }

    // The move takes the chosen number of seconds, at a steady speed. It
    // works while recording; a drag on the ruler takes over at once.
    private func autoZoom(toLog target: Double) {
        let start = zoomLog

        guard abs(target - start) > 0.01 else { return }

        let seconds = max(0.3, zoomSeconds)
        let begin = Date()

        zoomTask?.cancel()
        engine.rampZoom(to: pow(2, target), seconds: seconds)

        // The camera ramps by itself. This only moves the ruler to match.
        zoomTask = Task { @MainActor [weak self] in
            while let self, Task.isCancelled == false {
                let progress = min(1, Date().timeIntervalSince(begin) / seconds)

                zoomLog = start + (target - start) * progress

                if progress >= 1 { break }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func cycleZoomSeconds() {
        let options: [Double] = [2, 4, 8, 12]
        let index = options.firstIndex(of: zoomSeconds) ?? 1

        zoomSeconds = options[(index + 1) % options.count]
        showToast("Auto zoom takes \(Int(zoomSeconds)) seconds.")
    }

    // Locks a control at its current value, or releases it.
    func toggleLock(_ kind: ControlKind) {
        if lockedControls.contains(kind) {
            lockedControls.remove(kind)
            return
        }

        switch kind {
        case .ev:
            break

        case .iso:
            iso = liveISO
            isoAuto = false
            applyExposureControl()

        case .shutter:
            shutter = liveShutter
            shutterAuto = false
            applyExposureControl()

        case .wb:
            whiteBalance = liveKelvin
            lockWhiteBalance = true
            updateWhiteBalance()

        case .focus:
            lensPosition = liveFocus
            focusAuto = false
            engine.setLensPosition(lensPosition)
        }

        lockedControls.insert(kind)
    }

    // MARK: - Timelapse

    // In video mode a timelapse is recorded as one video: a frame every
    // interval, played back at 30 frames a second.
    private func startVideoTimelapse() {
        guard caps.hasCamera else {
            showToast("Video needs a camera. This simulator can shoot preview stills.")
            return
        }

        videoTimelapseActive = true
        timelapseRunning = true
        timelapseCount = 0

        engine.startTimelapse(interval: Double(max(1, timelapseInterval)))
    }

    // Cycles the seconds between timelapse frames. 0 is off.
    func cycleTimelapse() {
        guard timelapseRunning == false else { return }

        let options = [0, 1, 2, 5, 10, 30, 60]
        let index = options.firstIndex(of: timelapseInterval) ?? 0

        timelapseInterval = options[(index + 1) % options.count]

        showToast(
            timelapseInterval == 0
                ? "Timelapse off."
                : "Timelapse: a frame every \(timelapseInterval) seconds."
        )
    }

    // Holding the timelapse pill switches the timelapse off.
    func clearTimelapse() {
        guard timelapseRunning == false, timelapseInterval != 0 else { return }

        timelapseInterval = 0
        showToast("Timelapse off.")
    }

    // Holding the timer pill switches the countdown off.
    func clearTimer() {
        guard timerSeconds != 0 else { return }

        timerSeconds = 0
        showToast("Timer off.")
    }

    private func toggleTimelapse() {
        if timelapseRunning {
            timelapseTask?.cancel()
            timelapseTask = nil
            timelapseRunning = false
            showToast("Timelapse stopped. \(timelapseCount) frames.")
            return
        }

        timelapseRunning = true
        timelapseCount = 0

        let seconds = max(1, timelapseInterval)

        timelapseTask = Task { @MainActor [weak self] in
            while let self, Task.isCancelled == false {
                // Wait for the last photo to finish before the next one.
                var waited = 0

                while isBusy, waited < 40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }

                guard Task.isCancelled == false else { break }

                takePhoto()
                timelapseCount += 1

                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    // MARK: - Preserved settings

    private func observePreservedSettings() {
        withObservationTracking {
            _ = currentShootingPreset(named: "Last session")
            _ = selectedPresetID; _ = cleanFeed; _ = showManual; _ = showLUTPanel; _ = chipPanel; _ = isFrontCamera; _ = preserveSettings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.preserveTask?.cancel()
                self.preserveTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    self?.savePreserved()
                }
                self.reconcileSelectedPreset()
                self.observePreservedSettings()
            }
        }
    }

    private func reconcileSelectedPreset() {
        guard let id = selectedPresetID,
              let preset = shootingPresets.first(where: { $0.id == id }) else { return }
        if !currentShootingPreset(named: "").matchesSettings(of: preset) { selectedPresetID = nil }
    }

    func savePreserved() {
        guard bound, !isShowcase, preserveSettings, !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--verify-") }) else { return }

        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(currentShootingPreset(named: "Last session")) {
            defaults.set(data, forKey: "frameline.lastSession")
        }
        defaults.set(selectedPresetID?.uuidString, forKey: "frameline.p.selectedPreset")
        defaults.set(isFrontCamera, forKey: "frameline.p.front")
        defaults.set(grid, forKey: "frameline.p.grid")
        defaults.set(cleanFeed, forKey: "frameline.p.cleanFeed")
        defaults.set(showManual, forKey: "frameline.p.showManual")
        defaults.set(showLUTPanel, forKey: "frameline.p.lutPanel")
        defaults.set(chipPanel?.rawValue, forKey: "frameline.p.panel")

        defaults.set(focal.value, forKey: "frameline.p.focal")
        defaults.set(mode.rawValue, forKey: "frameline.p.mode")
        defaults.set(aspect.rawValue, forKey: "frameline.p.aspect")
        defaults.set(flash.rawValue, forKey: "frameline.p.flash")
        defaults.set(saveTarget.rawValue, forKey: "frameline.p.save")
        defaults.set(format.rawValue, forKey: "frameline.p.format")
        defaults.set(rawEnabled, forKey: "frameline.p.raw")
        defaults.set(naturalPhoto, forKey: "frameline.p.natural")
        defaults.set(livePhoto, forKey: "frameline.p.live")
        defaults.set(depthPortrait, forKey: "frameline.p.depth")
    }

    private var restoringSession = false
    private func restorePreserved() {
        guard preserveSettings else { return }
        restoringSession = true
        defer { restoringSession = false }

        let defaults = UserDefaults.standard
        grid = defaults.bool(forKey: "frameline.p.grid")

        if let data = defaults.data(forKey: "frameline.lastSession"),
           let preset = try? JSONDecoder().decode(ShootingPreset.self, from: data) {
            isFrontCamera = defaults.bool(forKey: "frameline.p.front")
            engine.restoreCamera(zoom: preset.lens, front: isFrontCamera)
            applyShootingPreset(preset)
            selectedPresetID = defaults.string(forKey: "frameline.p.selectedPreset").flatMap(UUID.init(uuidString:))
            cleanFeed = defaults.bool(forKey: "frameline.p.cleanFeed")
            showManual = defaults.bool(forKey: "frameline.p.showManual")
            showLUTPanel = defaults.bool(forKey: "frameline.p.lutPanel")
            chipPanel = defaults.string(forKey: "frameline.p.panel").flatMap(ChipPanel.init(rawValue:))
            toast = nil
            return
        }

        let value = defaults.double(forKey: "frameline.p.focal")

        if value >= 24, value <= 90 {
            focal = FocalLength(value: value)
        }

        if let raw = defaults.string(forKey: "frameline.p.mode"),
           let saved = CaptureMode(rawValue: raw) {
            mode = saved
        }

        if let raw = defaults.string(forKey: "frameline.p.aspect"),
           let saved = FrameAspect(rawValue: raw) {
            aspect = saved
        }

        if let raw = defaults.string(forKey: "frameline.p.flash"),
           let saved = FlashChoice(rawValue: raw) {
            flash = saved
        }

        if let raw = defaults.string(forKey: "frameline.p.save"),
           let saved = SaveTarget(rawValue: raw) {
            saveTarget = saved
        }

        if let raw = defaults.string(forKey: "frameline.p.format"),
           let saved = PhotoFormat(rawValue: raw) {
            format = saved
        }

        rawEnabled = defaults.bool(forKey: "frameline.p.raw")
        if mode != .video {
            naturalPhoto = defaults.bool(forKey: "frameline.p.natural")
            livePhoto = defaults.bool(forKey: "frameline.p.live")
            depthPortrait = defaults.bool(forKey: "frameline.p.depth")
            engine.configurePhotoCompanions(live: livePhoto, depth: depthPortrait, natural: naturalPhoto)
        }
    }

    func setExposure(_ value: Float) {
        aeafLocked = false
        let clamped = min(max(value, -3), 3)
        exposure = clamped
        cameraControls?.sync(exposure: clamped)

        if isoAuto && shutterAuto {
            engine.setExposureBias(clamped)
        } else {
            applyExposureControl()
        }
    }

    // Both ISO and shutter manual, or both automatic.
    func setManual(_ enabled: Bool) {
        if enabled {
            iso = liveISO
            shutter = liveShutter
            isoAuto = false
            shutterAuto = false
        } else {
            shutterAngleLock = false
            isoAuto = true
            shutterAuto = true
        }

        applyExposureControl()
    }

    func updateManual() {
        guard manual else { return }

        applyExposureControl()
    }

    // One tap on a lighting preset sets and locks that colour temperature.
    func setWhiteBalancePreset(_ kelvin: Double) {
        whiteBalance = Float(kelvin)
        lockWhiteBalance = true
        updateWhiteBalance()
    }

    func updateWhiteBalance() {
        // An explicit user adjustment replaces an automatic recording hold.
        wbLockedByRecording = false
        engine.setWhiteBalance(
            locked: lockWhiteBalance,
            temperature: whiteBalance
        )
    }

    func updateFocus() {
        engine.setLensPosition(lensPosition)
    }

    func focus(at viewPoint: CGPoint, in size: CGSize) {
        cancelFocusPull()
        focusAuto = true
        aeafLocked = false
        guard size.width > 0,
              size.height > 0,
              caps.hasCamera else { return }

        focusPoint = viewPoint
        if subjectTracking, mode == .video, dualShot {
            let width = min(size.width, size.height * 9 / 16)
            let height = width * 16 / 9
            let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            if rect.contains(viewPoint) {
                engine.selectTrackedSubject(CGPoint(x: (viewPoint.x - rect.minX) / rect.width, y: (viewPoint.y - rect.minY) / rect.height))
            }
        }

        // The viewfinder is always portrait, whatever the capture angle.
        let devicePoint = CGPoint(
            x: viewPoint.y / size.height,
            y: 1 - (viewPoint.x / size.width)
        )

        engine.focus(at: devicePoint)
    }

    func fireShutter() {
        if mode == .photo, motionExposure != .off {
            guard !motionExposureActive, pendingPhotoCount == 0, !timelapseRunning, bracketTask == nil else { return }
            if countdown != nil { cancelCountdown(); return }
            shutterTick += 1
            if timerSeconds > 0 { startCountdown() } else { takeMotionExposure() }
            return
        }
        if mode != .video, livePhoto, (styleParams.isIdentity == false || bakeLUT || saveTarget != .full || aspect != .sensor) {
            showToast("Live Photo keeps the original full frame. Turn off looks and LUT baking, and choose Full / Sensor."); return
        }
        if mode != .video, naturalPhoto, !caps.supportsNativeRaw {
            showToast("Natural RAW needs a supported rear lens. Turn it off or choose a compatible lens."); return
        }
        guard mode == .video || !isBusy else { return }
        shutterTick += 1

        // A running photo timelapse stops on the next press. A video
        // timelapse stops like any recording, further down.
        if timelapseRunning, videoTimelapseActive == false {
            toggleTimelapse()
            return
        }

        // Stopping a recording is never delayed.
        if mode == .video, isRecording {
            toggleRecording()
            return
        }

        // A second press during the countdown cancels it.
        if countdown != nil {
            cancelCountdown()
            return
        }

        if timerSeconds > 0 {
            startCountdown()
            return
        }

        if mode == .video {
            if timelapseInterval > 0 {
                startVideoTimelapse()
            } else {
                toggleRecording()
            }
        } else if timelapseInterval > 0 {
            toggleTimelapse()
        } else {
            takePhoto()
        }
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
    }

    private func startCountdown() {
        guard isBusy == false else { return }

        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var remaining = timerSeconds

            while remaining > 0 {
                countdown = remaining

                try? await Task.sleep(for: .seconds(1))

                if Task.isCancelled {
                    countdown = nil
                    return
                }

                remaining -= 1
            }

            countdown = nil
            timerTask = nil

            if mode == .video {
                toggleRecording()
            } else if mode == .photo, motionExposure != .off {
                takeMotionExposure()
            } else {
                takePhoto()
            }
        }
    }

    func cancelCountdown() {
        timerTask?.cancel()
        timerTask = nil
        countdown = nil
    }

    func cycleBracket() {
        bracketStops = bracketStops == 0 ? 1 : (bracketStops == 1 ? 2 : 0)
    }

    // Three photos in one press: darker, normal, brighter. The camera is
    // moved by exposure compensation, so it needs auto ISO and shutter.
    private func bracketPhotos() {
        let stops = Float(bracketStops)
        let original = exposure

        bracketTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for offset in [-stops, 0, stops] {
                engine.setExposureBias(min(max(original + offset, -3), 3))

                // Let the metering settle on the new exposure.
                try? await Task.sleep(for: .milliseconds(550))

                guard Task.isCancelled == false else { break }

                isBusy = true

                engine.capturePhoto(
                    raw: rawEnabled,
                    flash: .off,
                    format: format
                )

                var waited = 0

                while isBusy, waited < 80 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
            }

            engine.setExposureBias(original)
            isBusy = false
            bracketTask = nil
            showToast("Bracket saved.")
        }
    }

    private func takePhoto() {
        guard isBusy == false, bracketTask == nil else { return }

        if bracketStops > 0, caps.hasCamera {
            if isoAuto && shutterAuto {
                bracketPhotos()
                return
            }

            showToast("Bracketing needs auto ISO and shutter. Taking one photo.")
        }

        if caps.hasCamera {
            _ = submitPhoto()
        } else {
            #if targetEnvironment(simulator)
            captureSimulated()
            #else
            showToast("Allow Camera access in Settings to take a photo.")
            #endif
        }
    }

    private func takeMotionExposure() {
        guard caps.hasCamera, !motionExposureActive, pendingPhotoCount == 0 else { return }
        let id = UUID()
        stillContexts[id] = makeStillContext(motionDetail: "\(motionExposure.title) · \(motionExposureSeconds)s")
        pendingPhotoCount = stillContexts.count
        motionExposureActive = true
        showToast("Hold steady for \(motionExposureSeconds)s.")
        engine.captureMotionExposure(id: id, mode: motionExposure, seconds: motionExposureSeconds)
    }

    @discardableResult private func submitPhoto() -> UUID {
        let id = UUID()
        stillContexts[id] = makeStillContext()
        pendingPhotoCount = stillContexts.count
        isBusy = pendingPhotoCount >= photoCapacity
        engine.capturePhoto(raw: rawEnabled || naturalPhoto, flash: flash, format: format, id: id, nativeRaw: naturalPhoto)
        return id
    }

    func toggleRecording() {
        if isRecording {
            engine.stopRecording()
            return
        }

        guard caps.hasCamera else {
            showToast(
                "Video needs a camera. This simulator can shoot preview stills."
            )
            return
        }

        guard let selectedCodec else {
            showToast("No compatible recording codec is available.")
            refreshRecordingCodecs()
            return
        }

        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                await AVCaptureDevice.requestAccess(for: .audio)
            }

            guard !Task.isCancelled, !reviewingCaptures, !isRecording, mode == .video else { return }

            // Aspect crop: the same region the frame lines show on the
            // portrait viewfinder. For landscape video the region is turned
            // onto the landscape frame.
            var videoCrop: CGRect?
            let shownRatio = max(0.3, min(viewRatio, 2))
            var cropViewRatio = shownRatio

            if aspect != .sensor {
                let crop = VideoFrameGeometry.captureCrop(aspect:aspect,viewRatio:CGFloat(shownRatio),landscape:isLandscape)
                videoCrop = crop.rect
                cropViewRatio = crop.ratio
            }

            engine.setVideoCrop(videoCrop, viewRatio: cropViewRatio)

            let recordingID = UUID()
            if logProfile != .off, !currentVideoGrade.isActive, framingOptions.saveDesqueezed, framingOptions.anamorphic != .off {
                framingOptions.saveDesqueezed = false
                showToast("Raw Log uses preview-only anamorphic correction.")
            }
            let grade = currentVideoGrade
            recordingGrades[recordingID] = grade
            recordingDestinations[recordingID] = (saveInApp,saveToPhotos)
            let cube = grade.lut.flatMap { LUTMonitor.cubeData(from: $0.data, size: Int($0.size)) }
            recordingLUTBaked = cube != nil
            recordingAllowsOpticalSwitch = dualShot || grade.isActive || logProfile == .off
            engine.setTorch(enabled: flash == .on)
            engine.setRecordingGrade(cube: cube, size: grade.lut.map { Int($0.size) } ?? 0, intensity: grade.intensity, style: grade.style)
            engine.startRecording(
                log: logProfile,
                dual: dualShot,
                codec: selectedCodec,
                settings: effectiveRecordingSettings,
                recordingID: recordingID
            )
        }
    }

    func flip() {
        guard !isRecording, !motionExposureActive else { return }
        isFrontCamera.toggle()
        engine.flip()
    }

    // MARK: - Camera controls (ISO, shutter, WB, focus, EV)

    // The layout and the captures follow how the phone is held. The
    // accelerometer is used because it works whatever the interface or
    // rotation lock is set to.
    private func watchOrientation() {
        guard watchingOrientation == false else { return }
        watchingOrientation = true

        // Device motion blends the gyroscope with gravity, which is much
        // steadier than the raw accelerometer.
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0

            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let gravity = data?.gravity else { return }

                Task { @MainActor [weak self] in
                    self?.motionChanged(x: gravity.x, y: gravity.y)
                    self?.levelChanged(x: gravity.x, y: gravity.y, z: gravity.z)
                }
            }

            return
        }

        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.06

            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let acceleration = data?.acceleration else { return }

                Task { @MainActor [weak self] in
                    self?.motionChanged(x: acceleration.x, y: acceleration.y)
                    self?.levelChanged(
                        x: acceleration.x,
                        y: acceleration.y,
                        z: acceleration.z
                    )
                }
            }

            return
        }

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.deviceOrientationChanged()
            }
        }

        deviceOrientationChanged()
    }

    func suspendBackgroundWork() {
        savePreserved()
        engine.setAppForeground(false)
        if isRecording || pendingPhotoCount > 0 {
            let activity = CaptureSaveActivity()
            activity.begin()
            finalizationActivity = activity
        }
        pauseCameraSensors()
    }

    func pauseCameraSensors() {
        storageTask?.cancel(); storageTask = nil
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        watchingOrientation = false
    }

    func resumeForegroundWork() {
        guard bound else { return }
        finalizationActivity?.end(); finalizationActivity = nil
        startStorageUpdates()
        cleanupExpiredCaptures()
        watchOrientation()
    }

    // How far the phone is from level, to the nearest quarter turn.
    private func levelChanged(x: Double, y: Double, z: Double) {
        // Smooth the sensor first, so hand shake doesn't move the line.
        let weight = 0.12

        smoothX += (x - smoothX) * weight
        smoothY += (y - smoothY) * weight
        smoothZ += (z - smoothZ) * weight

        guard showLevel else {
            if levelVisible { levelVisible = false }
            return
        }

        // Flat on a table, or shooting straight down: a bubble level.
        let flat = abs(smoothZ) >= 0.85

        if flat != levelFlat { levelFlat = flat }

        if flat {
            if levelVisible == false { levelVisible = true }

            if abs(smoothX - levelBubbleX) > 0.004 { levelBubbleX = smoothX }
            if abs(smoothY - levelBubbleY) > 0.004 { levelBubbleY = smoothY }

            return
        }

        // Held up: a horizon line for roll, and a marker for tilt.
        let theta = atan2(smoothX, -smoothY) * 180 / .pi
        let nearest = (theta / 90).rounded() * 90
        let delta = theta - nearest

        let visible = abs(delta) < 20

        if visible != levelVisible { levelVisible = visible }

        // Only move when the change is real, and in half-degree steps.
        if abs(delta - levelAngle) > 0.5 {
            levelAngle = (delta * 2).rounded() / 2
        }

        let pitch = asin(min(max(smoothZ, -1), 1)) * 180 / .pi

        if abs(pitch - levelPitch) > 0.5 {
            levelPitch = (pitch * 2).rounded() / 2
        }
    }

    func refreshMics() {
        micInputs = (AVAudioSession.sharedInstance().availableInputs ?? []).map {
            MicInput(uid: $0.uid, name: $0.portName)
        }

        refreshMicGain()
    }

    // Not every microphone has a gain control, so the slider only shows
    // for the ones that do.
    private func refreshMicGain() {
        let audio = AVAudioSession.sharedInstance()

        micGainAvailable = audio.isInputGainSettable

        guard micGainAvailable else { return }

        let defaults = UserDefaults.standard

        if defaults.object(forKey: "frameline.micGain") != nil {
            let saved = defaults.float(forKey: "frameline.micGain")
            try? audio.setInputGain(min(max(saved, 0), 1))
        }

        micGain = audio.inputGain
    }

    func setMicGain(_ value: Float) {
        let audio = AVAudioSession.sharedInstance()
        let clamped = min(max(value, 0), 1)

        try? audio.setInputGain(clamped)
        micGain = clamped

        UserDefaults.standard.set(clamped, forKey: "frameline.micGain")
    }

    // The Camera Control button on iPhone 16 and later.
    private func installCameraControls() {
        if cameraControls == nil {
            let bridge = engine.makeCameraControlBridge()

            bridge.onExposure = { [weak self] value in
                self?.setExposure((value * 10).rounded() / 10)
            }

            bridge.onLens = { [weak self] index in
                guard let self, lenses.indices.contains(index) else { return }
                selectLens(lenses[index])
            }

            cameraControls = bridge
        }

        cameraControls?.install(
            lensTitles: lenses.map(\.title),
            selectedLens: lenses.firstIndex { $0.uniqueID == selectedLensID } ?? 0,
            exposure: exposure
        )

        // The saved microphone gain is applied once the session is ready.
        refreshMicGain()
    }

    func selectMic(_ uid: String) {
        selectedMicUID = uid

        let session = AVAudioSession.sharedInstance()
        let port = session.availableInputs?.first { $0.uid == uid }

        try? session.setPreferredInput(port)
        refreshMicGain()
    }

    // Gravity along the screen's x axis means landscape.
    private func motionChanged(x: Double, y: Double) {
        let angle: Double

        if abs(x) > 0.7, abs(x) > abs(y) + 0.2 {
            // Gravity toward the left edge is the phone turned anticlockwise.
            angle = x < 0 ? 0 : 180
        } else if y < -0.7, abs(y) > abs(x) + 0.2 {
            angle = 90
        } else {
            return
        }

        setDeviceAngle(angle)
    }

    private func deviceOrientationChanged() {
        switch UIDevice.current.orientation {
        case .portrait: setDeviceAngle(90)
        case .landscapeLeft: setDeviceAngle(0)
        case .landscapeRight: setDeviceAngle(180)
        default: return
        }
    }

    private func setDeviceAngle(_ angle: Double) {
        guard angle != deviceAngle else { return }

        deviceAngle = angle

        // Fixed while recording, like the native camera.
        if isRecording == false {
            applyOrientation(angle)
        }
    }

    private func applyOrientation(_ angle: Double) {
        captureAngle = angle
        engine.setOrientation(angle)
    }

    private func updatePreviewLog() {
        engine.setPreview(
            video: mode == .video,
            log: mode == .video ? logProfile : .off,
            settings: effectiveRecordingSettings, codec: selectedCodec
        )
    }

    func applyExposureControl() {
        aeafLocked = false
        manual = !(isoAuto && shutterAuto)

        engine.setExposureControl(
            isoAuto: isoAuto,
            shutterAuto: shutterAuto,
            iso: isoAuto ? liveISO : iso,
            shutter: shutterAuto ? liveShutter : shutter,
            bias: exposure
        )
    }

    // A rebuilt session resets exposure, white balance and focus.
    func reapplyControls() {
        if isoAuto && shutterAuto {
            engine.setExposureBias(exposure)
        } else {
            applyExposureControl()
        }

        if lockWhiteBalance {
            if wbLockedByRecording {
                engine.setWhiteBalance(locked: true, temperature: whiteBalance, holdCurrent: true)
            } else { updateWhiteBalance() }
        }

        if focusAuto == false {
            engine.setLensPosition(lensPosition)
        }
    }

    func isAuto(_ kind: ControlKind) -> Bool {
        switch kind {
        case .ev: return exposure == 0
        case .iso: return isoAuto
        case .shutter: return shutterAuto
        case .wb: return lockWhiteBalance == false
        case .focus: return focusAuto
        }
    }

    func value(for kind: ControlKind) -> Double {
        switch kind {
        case .ev: return Double(exposure)
        case .iso: return Double(isoAuto ? liveISO : iso)
        case .shutter: return shutterAuto ? liveShutter : shutter
        case .wb: return Double(lockWhiteBalance ? whiteBalance : liveKelvin)
        case .focus: return Double(focusAuto ? liveFocus : lensPosition)
        }
    }

    func displayText(for kind: ControlKind) -> String {
        switch kind {
        case .ev:
            return String(format: "%+.1f", exposure)
        case .iso:
            return "\(Int(value(for: .iso).rounded()))"
        case .shutter:
            return shutterAngleLock
                ? shutterAngleText
                : rulerSpec(for: .shutter).format(value(for: .shutter))
        case .wb:
            return "\(Int(value(for: .wb).rounded()))K"
        case .focus:
            return focusAuto ? "AF" : String(format: "%.2f", lensPosition)
        }
    }

    func setValue(_ kind: ControlKind, _ value: Double) {
        guard lockedControls.contains(kind) == false else { return }

        switch kind {
        case .ev:
            setExposure(Float(value))

        case .iso:
            iso = Float(value)
            isoAuto = false
            applyExposureControl()

        case .shutter:
            guard shutterAngleLock == false else { return }

            shutter = value
            shutterAuto = false
            applyExposureControl()

        case .wb:
            whiteBalance = Float(value)
            lockWhiteBalance = true
            updateWhiteBalance()

        case .focus:
            cancelFocusPull()
            lensPosition = Float(min(max(value, 0), 1))
            focusAuto = false
            engine.setLensPosition(lensPosition)
        }
    }

    func setAuto(_ kind: ControlKind) {
        guard lockedControls.contains(kind) == false else { return }

        switch kind {
        case .ev:
            setExposure(0)

        case .iso:
            isoAuto = true
            applyExposureControl()

        case .shutter:
            shutterAngleLock = false
            shutterAuto = true
            applyExposureControl()

        case .wb:
            lockWhiteBalance = false
            updateWhiteBalance()

        case .focus:
            cancelFocusPull()
            focusAuto = true
            engine.setFocusAuto()
        }
    }

    // MARK: - Exposure and focus lock, clean feed, saved looks

    // Long press on the viewfinder: meter and focus on that spot, then hold.
    // Adds the length of the clip that just ended to the running timecode.
    private func closeClip() {
        if let start = recordingStarted {
            timecodeBase += Date().timeIntervalSince(start)
        }

        recordingStarted = nil
    }

    private func startStorageUpdates() {
        guard storageTask == nil else { return }

        storageTask = Task { [weak self] in
            while Task.isCancelled == false {
                let figures = await Task.detached(priority: .utility) {
                    CameraStore.readStorage()
                }.value

                guard !Task.isCancelled, let self else { return }

                if storageTotalBytes != figures.total { storageTotalBytes = figures.total }
                if storageFreeBytes != figures.free { storageFreeBytes = figures.free }

                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    nonisolated private static func readStorage() -> (total: Double, free: Double) {
        let url = URL(fileURLWithPath: NSHomeDirectory())

        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])

        return (
            Double(values?.volumeTotalCapacity ?? 0),
            Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }

    // Hours, minutes, seconds and frames.
    func timecodeString(_ total: Double) -> String {
        let whole = max(0, total)
        let seconds = Int(whole)
        let fps = max(1, angleFrameRate)
        let frames = min(fps - 1, Int((whole - Double(seconds)) * Double(fps)))

        return String(
            format: "%02d:%02d:%02d:%02d",
            seconds / 3600,
            (seconds / 60) % 60,
            seconds % 60,
            frames
        )
    }

    func resetTimecode() {
        guard isRecording == false else { return }

        clipNumber = 0
        timecodeBase = 0
        showToast("Timecode reset.")
    }

    func lockExposureFocus(at viewPoint: CGPoint, in size: CGSize) {
        guard size.width > 0,
              size.height > 0,
              caps.hasCamera else { return }

        focusPoint = viewPoint
        focusAuto = true
        aeafLocked = true

        let devicePoint = CGPoint(
            x: viewPoint.y / size.height,
            y: 1 - (viewPoint.x / size.width)
        )

        engine.lockExposureFocus(at: devicePoint)
        showToast("Exposure and focus locked.")
    }

    func releaseLock() {
        guard aeafLocked else { return }

        aeafLocked = false

        engine.setFocusAuto()
        applyExposureControl()
        showToast("Exposure and focus unlocked.")
    }

    func saveCurrentLook() {
        let name = "Look \(savedLooks.count + 1)"

        savedLooks.append(
            SavedLook(
                name: name,
                lutName: (monitorLUT && selectedLUT != nil)
                    ? selectedLUT.map { lutName($0) }
                    : nil,
                styleID: look.id,
                intensity: lutIntensity,
                options: lookOptions,
                dials: currentDials
            )
        )

        showToast("\(name) saved.")
    }

    func applyLook(_ saved: SavedLook) {
        if let name = saved.lutName,
           let lut = luts.first(where: { lutName($0) == name }) {
            selectedLUT = lut
            lutIntensity = saved.intensity
            monitorLUT = true
        } else {
            monitorLUT = false
        }

        look = allLooks.first { $0.id == saved.styleID } ?? .standard

        if let dials = saved.dials {
            lookDials[look.id] = dials
        }

        // Strength, grain and the other details come back with the look.
        if let options = saved.options {
            lookOptions = options
        }

        showToast("\(saved.name) applied.")
    }

    // Takes the LUT, the style and the look details off the picture.
    func clearLook() {
        selectedLUT = nil
        monitorLUT = false
        showLUTPanel = false
        look = .standard

        showToast("Look off.")
    }

    // True when the picture is already showing this saved look.
    func isApplied(_ saved: SavedLook) -> Bool {
        let lutMatches: Bool

        if let name = saved.lutName {
            lutMatches = monitorLUT
                && selectedLUT.map { lutName($0) } == name
                && abs(saved.intensity - lutIntensity) < 0.01
        } else {
            lutMatches = monitorLUT == false
        }

        let optionsMatch = saved.options.map { $0 == lookOptions } ?? true

        return lutMatches && look.id == saved.styleID && optionsMatch
    }

    func renameLook(_ saved: SavedLook, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false,
              let index = savedLooks.firstIndex(where: { $0.id == saved.id }) else {
            return
        }

        savedLooks[index].name = String(trimmed.prefix(18))
    }

    func deleteLook(_ saved: SavedLook) {
        savedLooks.removeAll { $0.id == saved.id }
    }

    func autoAll() {
        for kind in ControlKind.allCases where lockedControls.contains(kind) == false {
            setAuto(kind)
        }

        showToast(
            lockedControls.isEmpty
                ? "Everything is automatic."
                : "Unlocked controls are automatic."
        )
    }

    // Typed values: ISO 400, shutter 1/125 or 125, WB 5600, focus 0 to 1
    // (or 0 to 100), EV +0.7.
    func commitTyped(_ kind: ControlKind, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: "s", with: "")

        var number: Double?

        if clean.contains("/") {
            let parts = clean.split(separator: "/")

            if parts.count == 2,
               let top = Double(parts[0]),
               let bottom = Double(parts[1]),
               bottom != 0 {
                number = top / bottom
            }
        } else {
            number = Double(clean)
        }

        guard var value = number else {
            showToast("That isn't a number.")
            return false
        }

        let spec = rulerSpec(for: kind)
        let low = spec.stops.first ?? value
        let high = spec.stops.last ?? value

        switch kind {
        case .shutter:
            // A plain 125 means 1/125.
            if clean.contains("/") == false, value >= 2 {
                value = 1 / value
            }

        case .focus:
            if value > 1 { value /= 100 }

        default:
            break
        }

        setValue(kind, min(max(value, low), high))
        return true
    }

    func rulerSpec(for kind: ControlKind) -> RulerSpec {
        let key = "\(caps.minISO)|\(caps.maxISO)|\(caps.minShutter)|\(caps.maxShutter)"

        if key != specKey {
            specKey = key
            specCache.removeAll()
        }

        if let cached = specCache[kind] {
            return cached
        }

        let built = buildRulerSpec(for: kind)
        specCache[kind] = built

        return built
    }

    private func buildRulerSpec(for kind: ControlKind) -> RulerSpec {
        switch kind {
        case .ev:
            return RulerSpec(
                stops: (-30...30).map { Double($0) / 10 },
                presets: [-2, -1, 0, 1, 2],
                logScale: false,
                labelEvery: 5,
                format: { String(format: "%+.1f", $0) }
            )

        case .iso:
            var low = Double(caps.minISO)
            var high = Double(caps.maxISO)

            if high <= low {
                low = 50
                high = 3200
            }

            let common: [Double] = [
                50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000,
                10000, 12800
            ]

            var stops = Set(common.filter { $0 >= low && $0 <= high })
            stops.insert(low.rounded())
            stops.insert(high.rounded())

            return RulerSpec(
                stops: stops.sorted(),
                presets: [100, 200, 400, 800, 1600, 3200],
                logScale: true,
                format: { "\(Int($0.rounded()))" }
            )

        case .shutter:
            var low = caps.minShutter
            var high = caps.maxShutter

            if high <= low {
                low = 1.0 / 8000
                high = 1.0 / 2
            }

            let denominators: [Double] = [
                8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000,
                800, 640, 500, 400, 320, 250, 240, 200, 160, 125, 120, 100,
                80, 60, 50, 48, 40, 30, 25, 24, 20, 15, 12, 10, 8, 6, 5, 4,
                3, 2, 1
            ]

            let stops = denominators
                .map { 1 / $0 }
                .filter { $0 >= low * 0.999 && $0 <= high * 1.001 }
                .sorted()

            let presets: [Double] = [24, 25, 30, 48, 50, 60, 100, 120, 250, 500, 1000]
                .map { 1 / $0 }

            return RulerSpec(
                stops: stops.isEmpty ? [1.0 / 60] : stops,
                presets: presets,
                logScale: true,
                format: { value in
                    value >= 0.999
                        ? "1s"
                        : "1/\(Int((1 / value).rounded()))"
                }
            )

        case .wb:
            return RulerSpec(
                stops: stride(from: 2500.0, through: 10000.0, by: 100.0).map { $0 },
                presets: [3200, 4000, 5000, 5600, 6500, 7500],
                logScale: false,
                labelEvery: 5,
                format: { "\(Int($0))K" }
            )

        case .focus:
            return RulerSpec(
                stops: (0...100).map { Double($0) / 100 },
                presets: [0, 0.25, 0.5, 0.75, 1],
                logScale: false,
                labelEvery: 10,
                format: { String(format: "%.2f", $0) }
            )
        }
    }

    func lutName(_ lut: CubeLUT) -> String {
        Mirror(reflecting: lut).children
            .first { $0.label == "name" }?.value as? String ?? "LUT"
    }

    func toggleMonitor() {
        guard selectedLUT != nil else {
            showToast("Pick a LUT first, then turn on the LUT preview.")
            return
        }

        monitorLUT.toggle()
    }

    private func sendPeaking() {
        let rgb = peakColor.premultiplied
        let threshold = Int((80 - peakSensitivity * 60).rounded())

        engine.setPeaking(red: rgb.0, green: rgb.1, blue: rgb.2, threshold: threshold)
    }

    private func updateStyle() {
        let params = styleParams
        let on = params.isIdentity == false && monitorAllowed
        engine.setStyle(on ? params : nil, keepPhotoPreviewWarm: mode != .video)
    }

    private func updateMonitor() {
        if monitorAllowed == false {
            engine.setMonitor(cube: nil, size: 0, intensity: 1)
            return
        }

        guard monitorLUT, let lut = selectedLUT else {
            if monitorLUT, selectedLUT == nil {
                monitorLUT = false
                return
            }

            engine.setMonitor(cube: nil, size: 0, intensity: 1)
            return
        }

        let size = Int(lut.size)

        guard let cube = LUTMonitor.cubeData(from: lut.data, size: size) else {
            monitorLUT = false
            showToast("This LUT can't be previewed live.")
            return
        }

        engine.setMonitor(cube: cube, size: size, intensity: lutIntensity)
    }

    private func aidsChanged() {
        guard !isShowcase else { return }
        #if DEBUG
        let persist = !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--verify-") })
        #else
        let persist = true
        #endif
        if persist {
            let defaults = UserDefaults.standard
            defaults.set(showHistogram, forKey: "frameline.aid.hist")
            defaults.set(showWaveform, forKey: "frameline.aid.wave")
            defaults.set(showZebra, forKey: "frameline.aid.zebra")
            defaults.set(showPeaking, forKey: "frameline.aid.peak")
            defaults.set(showFalseColor, forKey: "frameline.aid.false")
        }

        engine.setAids(
            histogram: showHistogram,
            zebra: showZebra,
            peaking: showPeaking,
            falseColor: showFalseColor,
            waveform: showWaveform
        )

        if showHistogram == false {
            histogramData = []
        }

        if showWaveform == false {
            waveformImage = nil
        }

        if showZebra == false, showPeaking == false, showFalseColor == false {
            aidsImage = nil
        }
    }

    // Shutter = angle / (360 x frame rate), for example 1/48 s at 180° and 24 fps.
    // Shutter = angle / (360 x frame rate), for example 1/48 s at 180° and 24 fps.
    // ISO keeps following the scene unless it was set by hand.
    private func applyShutterAngle(enableManual: Bool) {
        guard shutterAngleLock else { return }

        let target = shutterAngle / (360 * Double(angleFrameRate))

        shutter = min(
            max(target, caps.minShutter),
            max(caps.maxShutter, caps.minShutter)
        )

        shutterAuto = false
        applyExposureControl()
    }

    func selectLens(_ lens: LensOption) {
        guard canSelectLens(lens) else { return }

        guard lens.uniqueID != selectedLensID else { return }

        if !isRecording, focusPullLensEnabled,
           lens.deviceID != lenses.first(where: { $0.zoom == 1 })?.deviceID {
            // A selected optical camera takes priority over the dedicated
            // wide-camera focus-pull mode. Do not leave the lens menu disabled.
            focusPullLensEnabled = false
        }
        cancelFocusPull()
        // A queued codec probe must not rebuild the camera during the ramp.
        codecTask?.cancel()
        pendingLensRefresh = lens.uniqueID
        selectedLensID = lens.uniqueID
        engine.selectLens(lens.uniqueID)

        cameraControls?.sync(
            lensIndex: lenses.firstIndex { $0.uniqueID == lens.uniqueID }
        )

        // Refresh format choices only after the camera finishes its handoff.
    }

    private func configureAdvancedFraming() {
        var options = framingOptions
        if mode != .video { options.anamorphic = .off }
        engine.configureFraming(options, tracking: subjectTracking && dualShot && mode == .video)
        if !subjectTracking || mode != .video || !dualShot { trackedSubjectRect = nil; trackingLost = false }
    }

    func refreshAudioTools() { updateAudioTools(requestPermission: false) }

    private func updateAudioTools(requestPermission: Bool = true) {
        audioToolsTask?.cancel()
        audioToolsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if !allowed, requestPermission, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard !Task.isCancelled else { return }
            microphonePermission = allowed
            guard allowed else {
                if headphoneMonitoring { headphoneMonitoring = false }
                if requestPermission { showToast("Allow microphone access in Settings to use audio controls.") }
                return
            }
            engine.configureAudio(input: selectedMicrophone, monitoring: headphoneMonitoring)
        }
    }

    func requestAudioAccess() { updateAudioTools() }

    func markFocusStart() { focusStart = focusAuto ? liveFocus : lensPosition }
    func markFocusEnd() { focusEnd = focusAuto ? liveFocus : lensPosition }

    func cancelFocusPull() {
        focusPullID = UUID()
        focusPullTask?.cancel()
        focusPullTask = nil
        focusPullRunning = false
    }

    func runFocusPull(reverse: Bool = false) {
        guard caps.supportsManualFocus, let first = focusStart, let second = focusEnd else { return }
        guard !lockedControls.contains(.focus) else { showToast("Unlock Focus in M before running a pull."); return }
        cancelFocusPull()
        let id = UUID(); focusPullID = id
        let start = focusAuto ? liveFocus : lensPosition
        focusAuto = false
        let end = reverse ? first : second
        let duration = max(0.5, min(20, focusPullDuration))
        focusPullRunning = true; focusPullProgress = 0
        focusPullTask = Task { @MainActor [weak self] in
            let begin = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, self.focusPullID == id else { return }
                let p = min(1, (ProcessInfo.processInfo.systemUptime - begin) / duration)
                let eased = p * p * (3 - 2 * p)
                lensPosition = start + (end - start) * Float(eased)
                engine.setLensPosition(lensPosition)
                focusPullProgress = p
                if p >= 1 { focusPullRunning = false; return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func saveShootingPreset(named requested: String) {
        guard !isRecording else { return }
        let trimmed = String(requested.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        let name = trimmed.isEmpty ? "Setup \(shootingPresets.count + 1)" : trimmed
        let preset = currentShootingPreset(named: name)
        shootingPresets.append(preset)
        selectedPresetID = preset.id
        showToast("Saved \(name).")
    }

    func currentShootingPreset(named name: String) -> ShootingPreset {
        ShootingPreset(name: name, mode: mode.rawValue, format: format.rawValue, saveTarget: saveTarget.rawValue, aspect: aspect.rawValue,
            focal: focal.value, exposure: exposure, raw: rawEnabled, flash: flash.rawValue,
            log: logProfile.rawValue, dual: dualShot, width: recSettings.resolution?.width, height: recSettings.resolution?.height,
            fps: recSettings.frameRate, bitrate: recSettings.bitrate.rawValue, codec: selectedCodec?.rawValue,
            iso: iso, shutter: shutter, isoAuto: isoAuto, shutterAuto: shutterAuto, angleLocked: shutterAngleLock, shutterAngle: shutterAngle,
            whiteBalance: whiteBalance, whiteBalanceLocked: lockWhiteBalance && !wbLockedByRecording, focus: lensPosition, focusAuto: focusAuto,
            lens: lensZoom, zoom: zoomLog, stabilization: stabilization.rawValue,
            lookID: look.id, quality: currentDials.quality, tone: currentDials.tone, lookOptions: lookOptions,
            lutName: selectedLUT?.name, lutPreview: monitorLUT, lutBake: bakeLUT, lutIntensity: lutIntensity,
            framing: framingOptions, tracking: subjectTracking, focusStart: focusStart, focusEnd: focusEnd, focusDuration: focusPullDuration,
            audioInput: selectedMicrophone, audioMonitoring: headphoneMonitoring, focusLens: focusPullLensEnabled, naturalPhoto: naturalPhoto, livePhoto: livePhoto, depthPortrait: depthPortrait)
    }

    func openShootingPreset(_ preset: ShootingPreset) {
        guard !isRecording else {
            showToast("Stop recording before opening a preset.")
            return
        }
        activate()
        pendingLaunchPreset = preset
        if didResolveCamera { applyPendingLaunchPreset() }
    }

    private func applyPendingLaunchPreset() {
        guard let preset = pendingLaunchPreset else { return }
        pendingLaunchPreset = nil
        applyShootingPreset(preset)
    }

    func applyShootingPreset(_ preset: ShootingPreset) {
        guard !isRecording else { return }
        cancelFocusPull()
        var missing: [String] = []
        applyingShootingPreset = true
        selectMode(CaptureMode(rawValue:preset.mode) ?? .video)
        focusPullLensEnabled = (preset.depthPortrait ?? false) ? false : (preset.focusLens ?? false)
        naturalPhoto = mode != .video && (preset.naturalPhoto ?? false)
        livePhoto = mode != .video && (preset.livePhoto ?? false)
        depthPortrait = mode != .video && (preset.depthPortrait ?? false)
        engine.configurePhotoCompanions(live: livePhoto, depth: depthPortrait, natural: naturalPhoto)
        format = PhotoFormat(rawValue: preset.format) ?? .heif
        saveTarget = SaveTarget(rawValue: preset.saveTarget) ?? .both
        aspect = FrameAspect(rawValue: preset.aspect) ?? .sensor
        focal = FocalLength(value: preset.focal)
        rawEnabled = preset.raw; flash = FlashChoice(rawValue: preset.flash) ?? .off
        exposure = preset.exposure
        shutterAngleLock = false
        shutterAngle = preset.shutterAngle
        iso = preset.iso; shutter = preset.shutter; isoAuto = preset.isoAuto; shutterAuto = preset.shutterAuto
        shutterAngleLock = preset.angleLocked
        whiteBalance = preset.whiteBalance; lockWhiteBalance = preset.whiteBalanceLocked
        lensPosition = preset.focus; focusAuto = preset.focusAuto
        logProfile = mode == .video ? (LogProfile(rawValue:preset.log) ?? .off) : .off
        dualShot = preset.dual
        var settings = RecordingSettings()
        if let width = preset.width, let height = preset.height { settings.resolution = RecResolution(width: width, height: height) }
        settings.frameRate = preset.fps; settings.bitrate = RecBitrate(rawValue: preset.bitrate) ?? .auto
        recSettings = settings
        selectedCodec = preset.codec.map { RecordingCodec(rawValue: $0) }
        stabilization = StabilizationChoice(rawValue: preset.stabilization) ?? .auto
        if let chosen = allLooks.first(where: { $0.id == preset.lookID }) { look = chosen }
        else { look = .standard; missing.append("look unavailable") }
        setQuality(preset.quality); setTone(preset.tone); lookOptions = preset.lookOptions
        selectedLUT = preset.lutName.flatMap { name in luts.first(where: { $0.name == name }) }
        if preset.lutName != nil, selectedLUT == nil { missing.append("LUT unavailable") }
        monitorLUT = preset.lutPreview && selectedLUT != nil; bakeLUT = preset.lutBake; lutIntensity = preset.lutIntensity
        framingOptions = preset.framing; subjectTracking = preset.tracking
        focusStart = preset.focusStart; focusEnd = preset.focusEnd; focusPullDuration = preset.focusDuration
        selectedMicrophone = preset.audioInput; headphoneMonitoring = preset.audioMonitoring
        if let lens = lenses.min(by: { abs($0.zoom - preset.lens) < abs($1.zoom - preset.lens) }) { selectLens(lens) }
        setZoom(log: preset.zoom)
        framingChanged(); reapplyControls(); configureAdvancedFraming()
        if focusAuto { engine.setFocusAuto() } else { updateFocus() }
        applyingShootingPreset = false
        selectedPresetID = shootingPresets.contains(where: { $0.id == preset.id }) ? preset.id : nil
        refreshRecordingCodecs()
        if !restoringSession { showToast("Loaded \(preset.name)." + (missing.isEmpty ? "" : " " + missing.joined(separator: "; ") + ".")) }
    }

    func importLUT(from url: URL) {
        if url.pathExtension.lowercased()=="stillarclook" {
            guard !isRecording else {showToast("Stop recording before importing a shared look.");return}
            let directory=lutDirectory()
            Task {do {
                let lut=try await Task.detached(priority:.utility) {() throws ->CubeLUT in
                    let package=try StillarcLookPackage.read(url),lut=CubeLUT(id:UUID(),name:package.name,size:package.dimension,data:package.cube,isBuiltIn:false)
                    let text=try CameraColorShare.cubeText(package),saved=ImportedLUT(id:lut.id,name:lut.name,text:text)
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    try JSONEncoder().encode(saved).write(to:directory.appendingPathComponent(lut.id.uuidString),options:.atomic)
                    return lut
                }.value
                guard !isRecording else {showToast("The look was imported. Select it after recording.");luts.append(lut);return}
                luts.append(lut);look = .standard;selectedLUT=lut;lutIntensity=1;monitorLUT=true
                showToast("Imported shared colour. Use Standard gamma; texture and camera controls stay separate.")
            } catch {showToast(error.localizedDescription)}}
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let text = try? String(
            contentsOf: url,
            encoding: .utf8
        ) else {
            showToast("That file could not be read.")
            return
        }

        let name = url.deletingPathExtension().lastPathComponent

        guard let lut = CubeLUT.parse(
            text: text,
            name: name
        ) else {
            showToast("Use a valid 3D .cube LUT.")
            return
        }

        luts.append(lut)
        selectedLUT = lut

        saveImportedLUT(
            text: text,
            name: name,
            id: lut.id
        )

        showToast(
            "Imported \(name). Preview is on, and bake is \(bakeLUT ? "on" : "off")."
        )
    }

    func removeLUT(_ lut: CubeLUT) {
        guard lut.isBuiltIn == false else { return }

        luts.removeAll { $0.id == lut.id }

        if selectedLUT == lut {
            selectedLUT = nil
        }

        let url = lutDirectory()
            .appendingPathComponent(lut.id.uuidString)

        try? FileManager.default.removeItem(at: url)
    }

    func delete(_ item: CaptureItem) { deleteCaptures([item.id]) }

    func deleteCaptures(_ ids: Set<UUID>) {
        guard !deletingGallery else { return }
        let ids = ids.subtracting(editingPhotos)
        let removed = captures.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        deletingGallery = true
        let keys = Set(ids.map(AnyHashable.init))
        let grades = graded.filter { keys.contains($0.key) }
        let clips = clipInfo.filter { keys.contains($0.key) }
        let edits = photoEdits.filter { ids.contains($0.key) }
        let files = Set(removed.flatMap { item -> [URL] in
            let grade = graded[AnyHashable(item.id)]
            return [item.fullPhotoURL, item.cropPhotoURL, item.rawURL, item.movieURL, item.storiesURL, item.livePhotoMovieURL, item.depthMaskURL,
                    grade?.fullURL, grade?.cropURL, grade?.movie, grade?.storiesMovie].compactMap { $0 }.filter { $0.path != "/dev/null" }
        })
        captures.removeAll { ids.contains($0.id) }
        for id in ids { graded[AnyHashable(id)] = nil; clipInfo[AnyHashable(id)] = nil; photoEdits[id] = nil }
        persistLibrary()
        let barrier = librarySaveTask
        let photosBarrier = photosSaveTask
        var ephemeral = isShowcase
        #if DEBUG
        ephemeral = ephemeral || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--verify-") })
        if rejectGalleryDeletionForVerification { ephemeral = false }
        #endif
        Task {
            let saved = ephemeral ? true : await barrier?.value == true
            if saved {
                // Photos may still be reading a just-captured file. Let its
                // already-enqueued import finish before removing our copy.
                await photosBarrier?.value
                await GalleryThumbnails.shared.discard(files)
                await Task.detached(priority: .utility) { for file in files { try? FileManager.default.removeItem(at: file) } }.value
            } else {
                captures.append(contentsOf: removed.filter { item in !captures.contains(where: { $0.id == item.id }) })
                captures.sort { $0.date > $1.date }
                graded.merge(grades) { current, _ in current }; clipInfo.merge(clips) { current, _ in current }; photoEdits.merge(edits) { current, _ in current }
                showToast("Deletion couldn’t be saved. Your gallery items were kept.")
            }
            deletingGallery = false
            if saved { protectedCaptureIDs.subtract(ids) }
            drainCaptureCleanup()
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()

        toastTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: 2_000_000_000
            )

            if !Task.isCancelled {
                self?.toast = nil
            }
        }
    }

    private func handle(event: EngineEvent) {
        switch event {

        case .caps(let next):
            caps = next
            didResolveCamera = true
            if !next.hasCamera { applyPendingLaunchPreset() }

            iso = min(max(iso, next.minISO), next.maxISO)
            shutter = min(max(shutter, next.minShutter), next.maxShutter)

        case .recording(let active):
            isRecording = active
            if !active, reviewingCaptures { engine.stop() }

            if active {
                clipNumber += 1
                clipStartBase = timecodeBase
                recordingStarted = Date()

                // Hold white balance so it can't drift during the take.
                if lockWBOnRecord || ProcessInfo.processInfo.arguments.contains("--verify-wb-hold"), lockWhiteBalance == false {
                    whiteBalance = liveKelvin
                    lockWhiteBalance = true
                    wbLockedByRecording = true
                    engine.setWhiteBalance(locked: true, temperature: whiteBalance, holdCurrent: true)
                }
            } else {
                closeClip()

                if videoTimelapseActive {
                    videoTimelapseActive = false
                    timelapseRunning = false
                }

                if wbLockedByRecording {
                    wbLockedByRecording = false
                    lockWhiteBalance = false
                    updateWhiteBalance()
                }
            }

            if active == false {
                if !headphoneMonitoring { audioLevel = 0; audioClipping = false }
                applyOrientation(deviceAngle)
            }

            if active {
                showToast(
                    dualShot ? "Dual shot is rolling." : "Recording."
                )
            }

        case .photo(let id, let processed, let raw, let companion):
            if motionExposureActive { motionExposureActive = false }
            guard let processed else {
                stillContexts[id] = nil
                pendingPhotoCount = stillContexts.count
                isBusy = pendingPhotoCount >= photoCapacity
                if pendingPhotoCount == 0 { finalizationActivity?.end(); finalizationActivity = nil }
                showToast("The photo did not come through. Try again.")
                return
            }
            if stillContexts[id] == nil { stillContexts[id] = makeStillContext() }
            if bracketTask != nil { isBusy = false }
            storeStill(fullData: processed, raw: raw, simulated: false, id: id, companion: companion)

        case .movie(let primary, let secondary, let kind, let recordingID, let baked):
            defer { finalizationActivity?.end(); finalizationActivity = nil }
            let destination = recordingID.flatMap { recordingDestinations.removeValue(forKey:$0) } ?? (app:saveInApp,photos:saveToPhotos)
            let detail = movieDetail(kind: kind)
            let masterURL = persist(url: primary, ext: "mov")

            let storiesURL: URL? = secondary.map {
                persist(url: $0, ext: "mov")
            }

            let item = CaptureItem(
                fullImage: nil,
                cropImage: nil,
                movieURL: masterURL,
                storiesURL: storiesURL,
                rawURL: nil,
                detail: detail,
                simulated: false,
                mode: .video
            )

            clipInfo[AnyHashable(item.id)] = ClipInfo(
                number: max(clipNumber, 1),
                start: timecodeString(clipStartBase),
                end: timecodeString(timecodeBase),
                codec: selectedCodec?.title ?? "Video",
                gamma: logProfile.title,
                resolution: recSettings.resolution?.shortTitle,
                frameRate: max(1, angleFrameRate)
            )

            prepareCaptureStorage(id:item.id,keepInApp:destination.app)
            captures.insert(item, at: 0)
            persistLibrary()

            // Dual shot gives two files, horizontal and vertical. With a look
            // or LUT on, only the graded pair goes to Photos, so there are
            // never extra copies.
            let dual = storiesURL != nil
            let grade = recordingID.flatMap { recordingGrades.removeValue(forKey: $0) } ?? currentVideoGrade
            let grading = grade.isActive && !baked
            let keepsOriginals = dual == false || grading == false

            let originalSave = destination.photos && keepsOriginals ? saveVideosToLibrary([masterURL] + [storiesURL].compactMap { $0 }) : nil
            if !baked && grading {
                bakeVideo(item:item,sources:[masterURL] + [storiesURL].compactMap { $0 },grade:grade,savesOriginals:keepsOriginals,keepInApp:destination.app,savesToPhotos:destination.photos,precedingSave:originalSave)
            } else {
                completeCaptureStorage(id:item.id,keepInApp:destination.app,saves:[originalSave].compactMap { $0 })
            }

            if grading == false {
                showToast(dual ? "Saving Dual Shot…" : "Saving video…")
            }

        case .message(let text):
            if !isRecording { finalizationActivity?.end(); finalizationActivity = nil }
            showToast(text)

        case .exposureSample(let iso, let incomingShutter):
            if manual == false {
                self.iso = iso
                self.shutter = incomingShutter
            }
        }
    }

    // The untouched clip is saved first. When a LUT (with bake on) or a
    // style is active, a graded copy is made after recording stops, so
    // nothing extra runs while the camera is rolling.
    // True when a LUT or a style would change the video.
    private struct VideoGrade {
        let lut: CubeLUT?
        let intensity: Float
        let style: StyleParams
        var isActive: Bool { lut != nil || !style.isIdentity }
    }

    @ObservationIgnored private var recordingGrades: [UUID: VideoGrade] = [:]
    @ObservationIgnored private var recordingDestinations: [UUID:(app:Bool,photos:Bool)] = [:]

    private var currentVideoGrade: VideoGrade {
        VideoGrade(lut: bakeLUT ? selectedLUT : nil, intensity: lutIntensity, style: styleParams)
    }

    // Grades each file in turn. With savesOriginals false, only the graded
    // files are saved, and an original is saved only if its grade fails.
    private func bakeVideo(item: CaptureItem, sources: [URL], grade: VideoGrade, savesOriginals: Bool, keepInApp: Bool, savesToPhotos: Bool, precedingSave: Task<Bool,Never>?) {
        var cube: Data?
        var cubeSize = 0

        if let lut = grade.lut {
            cubeSize = Int(lut.size)
            cube = LUTMonitor.cubeData(from: lut.data, size: cubeSize)

            if cube == nil {
                cubeSize = 0
            }
        }

        let style = grade.style

        guard cube != nil || style.isIdentity == false else {
            let save = !savesOriginals && savesToPhotos ? saveVideosToLibrary(sources) : nil
            completeCaptureStorage(id:item.id,keepInApp:keepInApp,saves:[precedingSave,save].compactMap { $0 })
            return
        }

        let intensity = grade.intensity
        let saves = savesToPhotos
        let id = AnyHashable(item.id)

        showToast("Grading video…")

        Task { [weak self] in
            var made: [URL?] = []

            for source in sources {
                let url = await VideoBaker.bake(
                    source: source,
                    cube: cube,
                    cubeSize: cubeSize,
                    intensity: intensity,
                    style: style
                )

                made.append(url.map { self?.persist(url: $0, ext: "mov") ?? $0 })


            }

            guard let self else { return }

            var finalSave: Task<Bool,Never>?
            if saves {
                let outputs = sources.enumerated().compactMap { index, source -> URL? in
                    made[index] ?? (savesOriginals ? nil : source)
                }
                finalSave = saveVideosToLibrary(outputs)
            }

            var result = GradedStills()
            result.movie = made.first ?? nil
            result.storiesMovie = made.count > 1 ? made[1] : nil
            graded[id] = result
            persistLibrary()
            completeCaptureStorage(id:item.id,keepInApp:keepInApp,saves:[precedingSave,finalSave].compactMap { $0 },valid:made.allSatisfy { $0 != nil })

            if made.contains(where: { $0 == nil }) {
                showToast("A graded video could not be made.")
            } else {
                showToast(sources.count > 1 ? "Saving graded Dual Shot…" : "Saving graded video…")
            }
        }
    }

    private func captureSimulated() {
        let renderer = ImageRenderer(
            content: DemoHarborScene()
                .frame(width: 900, height: 1200)
        )

        renderer.scale = 2

        guard let image = renderer.uiImage,
              let data = image.jpegData(compressionQuality: 0.95)
        else {
            return
        }

        storeStill(
            fullData: data,
            raw: nil,
            simulated: true
        )
    }

    private func makeStillContext(motionDetail: String? = nil) -> StillContext {
        let scale: CGFloat = mode == .rangefinder ? CGFloat(min(1, 24 * lensZoom / Double(focal.value))) : 1
        let lut = bakeLUT ? selectedLUT : nil
        let cube = lut.flatMap { LUTMonitor.cubeData(from: $0.data, size: Int($0.size)) }
        return StillContext(request: StillComposer.Request(focalScale: scale, aspectRatio: aspect.ratio,
            saveTarget: saveTarget.rawValue, style: styleParams, cube: cube, cubeSize: cube == nil ? 0 : (lut?.size ?? 0),
            lutIntensity: lutIntensity, preserveHDR: motionDetail == nil && captureHDRHighlights), detail: motionDetail ?? caption, saves: saveToPhotos, mode: mode, natural: motionDetail == nil && naturalPhoto, live: motionDetail == nil && livePhoto, portrait: motionDetail == nil && depthPortrait, expectsRaw: motionDetail == nil && rawEnabled && !livePhoto && !depthPortrait, keepInApp:saveInApp)
    }

    private func storeStill(fullData: Data, raw: Data?, simulated: Bool, id: UUID = UUID(), companion: PhotoCompanion = PhotoCompanion()) {
        let context = stillContexts[id] ?? makeStillContext()
        stillContexts[id] = context
        pendingPhotoCount = stillContexts.count
        let previous = compositionTail
        compositionTailID = id
        compositionTail = Task { @MainActor [weak self] in
            await previous?.value
            let prepared = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    let developed = context.natural ? raw.flatMap { PhotoDeveloper.natural($0) } : nil
                    let depthMask = context.portrait ? companion.depth.flatMap(PortraitRenderer.mask) : nil
                    let portrait = depthMask.flatMap { PortraitRenderer.render(fullData, mask: $0, preserveHDR: context.request.preserveHDR) }
                    var result = StillComposer.compose(imageData: developed ?? fullData, request: context.request)
                    if let portrait {
                        let bokeh = StillComposer.compose(imageData: portrait, request: context.request)
                        result.gradedFull = bokeh.gradedFull ?? bokeh.fullJPEG
                        result.gradedCrop = bokeh.gradedCrop ?? bokeh.cropJPEG
                    }
                    var prepared = PreparedStill.make(result: result, raw: raw, id: id)
                    prepared.naturalDeveloped = developed != nil; prepared.portraitRendered = portrait != nil
                    if depthMask != nil, prepared.fullURL == nil, let crop = prepared.cropURL {
                        // Keep the full source privately even when only the
                        // framed export was requested. Photos exports stay unchanged.
                        let ext = fullData.starts(with: [0xff, 0xd8]) ? "jpg" : "heic"
                        let url = crop.deletingLastPathComponent().appendingPathComponent("depth-original").appendingPathExtension(ext)
                        if (try? fullData.write(to: url, options: .atomic)) != nil {
                            prepared.fullURL = url; prepared.full = PreparedStill.thumbnail(fullData)
                        }
                    }
                    if let depthMask, let file = prepared.fullURL {
                        let url = file.deletingLastPathComponent().appendingPathComponent("depth-mask.json")
                        if depthMask.save(url) { prepared.depthMaskURL = url }
                    }
                    return prepared
                }
            }.value
            guard let self else { return }
            if context.expectsRaw, !context.natural, prepared.rawURL == nil {
                showToast("RAW wasn’t available for this capture. The processed photo was kept.")
            }
            if context.natural, !prepared.naturalDeveloped { showToast("Natural RAW development wasn’t available; the standard photo and any RAW were kept.") }
            #if DEBUG
            if prepared.portraitRendered { verifiedDepthIDs.insert(id) }
            if ProcessInfo.processInfo.arguments.contains("--verify-upgrade") { NSLog("UPGRADE_CAPTURE id=%@ natural=%d depth=%d live=%d", id.uuidString, prepared.naturalDeveloped ? 1 : 0, prepared.portraitRendered ? 1 : 0, companion.liveMovie == nil ? 0 : 1) }
            #endif
            var item = CaptureItem(fullImage: prepared.full, cropImage: prepared.crop, movieURL: nil,
                storiesURL: nil, rawURL: prepared.rawURL, detail: context.detail, simulated: simulated, mode: context.mode)
            item.id = id; item.date = context.date
            item.fullPhotoURL = prepared.fullURL; item.cropPhotoURL = prepared.cropURL; item.depthMaskURL = prepared.depthMaskURL
            if prepared.gradedFull != nil || prepared.gradedCrop != nil {
                var value = GradedStills(full: prepared.gradedFull, crop: prepared.gradedCrop)
                value.fullURL = prepared.gradedFullURL; value.cropURL = prepared.gradedCropURL
                graded[AnyHashable(item.id)] = value
            }
            prepareCaptureStorage(id:item.id,keepInApp:context.keepInApp)
            let position = captures.firstIndex(where: { $0.date < item.date }) ?? captures.endIndex
            captures.insert(item, at: position)
            trimGalleryPreviews()
            persistLibrary()
            if prepared.photosURLs.isEmpty { showToast("Could not store the full-resolution photo. Check free space.") }
            stillContexts[id] = nil
            pendingPhotoCount = stillContexts.count
            isBusy = pendingPhotoCount >= photoCapacity
            if compositionTailID == id { compositionTail = nil; compositionTailID = nil }
            var photoSave: Task<Bool,Never>?
            if context.live, let movie = companion.liveMovie, let original = prepared.fullURL {
                let destination = original.deletingLastPathComponent().appendingPathComponent("live.mov")
                do {
                    try FileManager.default.moveItem(at: movie, to: destination)
                    if let index = captures.firstIndex(where: { $0.id == id }) { captures[index].livePhotoMovieURL = destination }
                    persistLibrary()
                    if context.saves { photoSave = saveLivePhoto(still: original, movie: destination) }
                } catch { showToast("The Live Photo movie couldn’t be kept. Your still is safe."); if context.saves { photoSave = saveStillFiles(prepared.photosURLs, raw: nil) } }
            } else if context.saves { photoSave = saveStillFiles(prepared.photosURLs, raw: prepared.rawURL) }
            completeCaptureStorage(id:id,keepInApp:context.keepInApp,saves:[photoSave].compactMap { $0 })
            if context.live && companion.liveMovie == nil { showToast("Live motion wasn’t delivered. The still photo was kept.") }
            if context.portrait && !prepared.portraitRendered { showToast(companion.depth == nil ? "Depth wasn’t delivered. The original photo was kept." : "This scene had too little usable depth. The original photo was kept.") }
            else if context.portrait && prepared.depthMaskURL == nil { showToast("The portrait was kept, but its depth edits couldn’t be stored. Check available space.") }
            if pendingPhotoCount == 0 { finalizationActivity?.end(); finalizationActivity = nil }
        }
    }

    #if DEBUG
    private func verifyStyleSliders() {
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            selectMode(.photo)
            look = .standard
            try? await Task.sleep(for: .seconds(3))
            guard caps.hasCamera, let night = FilmLook.lineup.first(where: { $0.id == "night35" }) else {
                NSLog("STYLE_SLIDERS_VERIFY FAIL camera unavailable")
                return
            }
            let initialExposure = exposure
            var ready = 0
            for _ in 0..<5 {
                look = night
                for _ in 0..<60 where !engine.monitorLayer.isReadyForDisplay {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                if engine.monitorLayer.isReadyForDisplay { ready += 1 }
                for step in 0..<20 {
                    setValue(.ev, -Double(step) / 10)
                    setValue(.focus, Double(step) / 20)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                look = .standard
                try? await Task.sleep(for: .milliseconds(160))
            }
            setAuto(.focus)
            setExposure(initialExposure)
            NSLog("STYLE_SLIDERS_VERIFY %@ ready=%ld/5 exposureAndFocusUpdates=200", ready == 5 ? "PASS" : "FAIL", ready)
        }
    }

    func verifyDepthResume() {
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            saveToPhotos = false; selectMode(.photo); format = .heif; look = .standard; saveTarget = .full; aspect = .sensor
            try? await Task.sleep(for: .seconds(2))
            setPhotoFeature(.portrait)
            try? await Task.sleep(for: .seconds(2))
            var delivered = 0
            for attempt in 0..<3 {
                refreshRecordingCodecs(force: true)
                if attempt > 0 {
                    engine.stop(releaseRenderCaches: false)
                    try? await Task.sleep(for: .milliseconds(200)); engine.start()
                    try? await Task.sleep(for: .milliseconds(650))
                }
                let id = submitPhoto(), start = ProcessInfo.processInfo.systemUptime
                while stillContexts[id] != nil, ProcessInfo.processInfo.systemUptime - start < 20 { try? await Task.sleep(for: .milliseconds(40)) }
                let passed = verifiedDepthIDs.remove(id) != nil && captures.first(where: { $0.id == id })?.depthMaskURL.flatMap(DepthMask.load)?.image != nil
                if passed { delivered += 1 }
                NSLog("DEPTH_RESUME_VERIFY attempt=%ld %@", attempt, passed ? "PASS" : "FAIL")
                if let item = captures.first(where: { $0.id == id }) { delete(item) }
            }
            setPhotoFeature(.standard)
            NSLog("DEPTH_RESUME_VERIFY %@ delivered=%ld/3", delivered == 3 ? "PASS" : "FAIL", delivered)
        }
    }

    func verifyUpgrade() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            saveToPhotos = false; selectMode(.photo); format = .heif; rawEnabled = false; flash = .off; saveTarget = .both; aspect = .sensor
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let initial = Set(captures.map(\.id))
            let tickStart = ProcessInfo.processInfo.systemUptime
            var ticks = 0
            let ticker = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(16)) } }
            defer { ticker.cancel() }
            for batch in 0..<4 {
                setPhotoFeature(.standard)
                look = batch.isMultiple(of: 2) ? .standard : FilmLook.lineup[1]
                var ids: [UUID] = []
                let begin = ProcessInfo.processInfo.systemUptime
                for _ in 0..<5 {
                    ids.append(submitPhoto()); try? await Task.sleep(for: .milliseconds(100))
                }
                while pendingPhotoCount > 0, ProcessInfo.processInfo.systemUptime - begin < 30 { try? await Task.sleep(for: .milliseconds(30)) }
                let count = captures.filter { ids.contains($0.id) }.count
                NSLog("UPGRADE_VERIFY burst=%ld %@ captured=%ld time=%.2f", batch, count == 5 && pendingPhotoCount == 0 ? "PASS" : "FAIL", count, ProcessInfo.processInfo.systemUptime - begin)
            }
            look = .standard
            for feature in [PhotoFeature.natural, .live, .portrait] {
                if feature == .portrait { focusPullLensEnabled = false }
                setPhotoFeature(feature)
                try? await Task.sleep(for: .seconds(2))
                let supported = feature == .natural ? caps.supportsNativeRaw : feature == .live ? caps.supportsLivePhoto : caps.supportsDepth
                if supported {
                    let id = submitPhoto(); let begin = ProcessInfo.processInfo.systemUptime
                    while stillContexts[id] != nil, ProcessInfo.processInfo.systemUptime - begin < 25 { try? await Task.sleep(for: .milliseconds(40)) }
                    NSLog("UPGRADE_VERIFY special=%@ %@", String(describing: feature), captures.contains(where: { $0.id == id }) ? "PASS delivered" : "FAIL")
                    if feature == .natural, let item = captures.first(where: { $0.id == id }), let rawURL = item.rawURL, let source = item.fullPhotoURL {
                        let result = await Task.detached(priority: .utility) {
                            guard let original = try? Data(contentsOf: rawURL), let data = try? Data(contentsOf: source),
                                  let preview = PhotoDeveloper.rawPreview(original), PreparedStill.thumbnail(preview) != nil,
                                  let developed = PhotoDeveloper.develop(data, edit: PhotoEdit(exposure: 0.5, useRAW: true), rawData: original), PreparedStill.thumbnail(developed) != nil else { return false }
                            return (try? Data(contentsOf: rawURL)) == original
                        }.value
                        NSLog("UPGRADE_VERIFY RAW editor %@", result ? "PASS" : "FAIL")
                    }
                } else { NSLog("UPGRADE_VERIFY special=%@ UNSUPPORTED current lens", String(describing: feature)) }
            }
            setPhotoFeature(.standard)
            if let sample = captures.first(where: { !initial.contains($0.id) }), let source = sample.fullPhotoURL {
                let result = await Task.detached(priority: .utility) {
                    guard let original = try? Data(contentsOf: source) else { return false }
                    let edit = PhotoEdit(styleID: FilmLook.lineup[1].id, exposure: 0.3, saturation: 0.8, warmth: 0.2)
                    guard let image = PhotoDeveloper.develop(original, edit: edit), PreparedStill.thumbnail(image) != nil else { return false }
                    return image != original && (try? Data(contentsOf: source)) == original
                }.value
                NSLog("UPGRADE_VERIFY nondestructive %@", result ? "PASS" : "FAIL")
            }
            let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
            let archive = CaptureLibrary(root: testRoot)
            let records = (0..<250).map { _ in LibraryRecord(id: UUID(), date: Date(), detail: "test", mode: "photo", edit: PhotoEdit()) }
            do {
                try await archive.save(records)
                let loaded = await archive.load()
                NSLog("UPGRADE_VERIFY archive %@ records=%ld", loaded.map(\.id) == records.map(\.id) ? "PASS" : "FAIL", loaded.count)
            } catch { NSLog("UPGRADE_VERIFY archive FAIL %@", error.localizedDescription) }
            try? FileManager.default.removeItem(at: testRoot)
            for item in captures.filter({ !initial.contains($0.id) }) { delete(item) }
            NSLog("UPGRADE_VERIFY COMPLETE mainActorTicks=%ld elapsed=%.2f thermal=%ld no Photos writes", ticks, ProcessInfo.processInfo.systemUptime - tickStart, ProcessInfo.processInfo.thermalState.rawValue)
        }
    }

    private func verifyCameraReliability() {
        Task { @MainActor in
            let priorIdle=UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled=true
            defer {UIApplication.shared.isIdleTimerDisabled=priorIdle}
            var results=[[String:Any]](),lensResults=[[String:Any]]()
            @MainActor func save(_ stage:String,_ passed:Bool?=nil,_ error:String?=nil) {
                var r:[String:Any]=["version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown","stage":stage,"takes":results,"lenses":lensResults,"thermal":ProcessInfo.processInfo.thermalState.rawValue]
                if let passed {r["passed"]=passed};if let error {r["error"]=error};CameraRecordingQA.write(r)
            }
            save("Waiting for camera")
            for _ in 0..<100 where !caps.hasCamera {try? await Task.sleep(for:.milliseconds(100))}
            guard caps.hasCamera else {save("failed",false,"No camera");return}
            dualShot=false;selectMode(.video);look = .standard;selectedLUT=nil;monitorLUT=false;flash = .off
            focusPullLensEnabled=true
            try? await Task.sleep(for:.seconds(2))
            for zoom in [0.5,4.0,8.0,1.0,8.0,0.5,1.0] {
                guard let lens=lenses.first(where:{abs($0.zoom-zoom)<0.15}) else {continue}
                let enabled=canSelectLens(lens);selectLens(lens)
                try? await Task.sleep(for:.milliseconds(1250))
                let snapshot=await engine.reliabilitySnapshot()
                let actual=snapshot["lens"] as? Double ?? -1
                let passed=enabled && abs(actual-lens.zoom)<0.15 && !focusPullLensEnabled
                lensResults.append(["zoom":lens.zoom,"enabled":enabled,"actual":actual,"focusLens":focusPullLensEnabled,"passed":passed])
                guard passed else {save("failed",false,"Lens selection failed");return}
            }
            try? await Task.sleep(for:.seconds(1));codecTask?.cancel()
            let codec=RecordingCodec(rawValue:AVVideoCodecType.hevc.rawValue)
            let phases:[(LogProfile,Int,Bool,Double)]=[(.log,30,false,8),(.log,60,false,8),(.log2,30,false,12),(.log2,60,false,8),(.log2,30,true,60)]
            for (profile,fps,monitor,seconds) in phases {
                if profile == .log && !caps.supportsLog || profile == .log2 && !caps.supportsLog2 {continue}
                guard ProcessInfo.processInfo.thermalState.rawValue<2 else {save("failed",false,"Phone needs cooling");return}
                focusPullLensEnabled = profile == .log2 && fps == 30 && !monitor
                try? await Task.sleep(for:.seconds(1))
                logProfile=profile;codecTask?.cancel();selectedCodec=codec;showHistogram=monitor
                if monitor,let lut=luts.first {selectedLUT=lut;monitorLUT=true} else {monitorLUT=false;selectedLUT=nil}
                let settings=RecordingSettings(resolution:RecResolution(width:3840,height:2160),frameRate:fps,bitrate:.high)
                engine.setPreview(video:true,log:profile,settings:settings,codec:codec)
                engine.discoverRecordingCodecs(log:profile,dual:false,settings:settings,preferredCodec:codec)
                try? await Task.sleep(for:.seconds(2));codecTask?.cancel()
                await engine.resetReliabilityMovie();engine.setVideoCrop(nil,viewRatio:9.0/16)
                engine.setRecordingGrade(cube:nil,size:0,intensity:1,style:.identity)
                let label="\(profile.rawValue) \(fps)fps monitor=\(monitor)"
                save("Starting "+label)
                engine.startRecording(log:profile,dual:false,codec:codec,settings:settings,recordingID:UUID())
                for _ in 0..<150 where !isRecording {try? await Task.sleep(for:.milliseconds(100))}
                guard isRecording else {save("failed",false,"Could not start "+label);return}
                engine.beginSingleCadenceProbe()
                let start=ProcessInfo.processInfo.systemUptime;var thermalPeak=ProcessInfo.processInfo.thermalState.rawValue
                var lensStep=0
                while ProcessInfo.processInfo.systemUptime-start<seconds {
                    if profile == .log && fps == 30 && !monitor, lensStep<3,
                       ProcessInfo.processInfo.systemUptime-start>=Double(lensStep+1)*2,
                       let lens=lenses.min(by:{abs($0.zoom-[8.0,0.5,1.0][lensStep])<abs($1.zoom-[8.0,0.5,1.0][lensStep])}) {
                        let enabled=canSelectLens(lens)
                        lensResults.append(["duringLogRecording":true,"zoom":lens.zoom,"enabled":enabled,"passed":enabled])
                        guard enabled else {engine.stopRecording();save("failed",false,"Virtual Log lens disabled");return}
                        selectLens(lens);lensStep+=1
                    }
                    guard UIApplication.shared.applicationState == .active else {engine.stopRecording();save("failed",false,"Camera left foreground");return}
                    thermalPeak=max(thermalPeak,ProcessInfo.processInfo.thermalState.rawValue)
                    save("Recording "+label)
                    try? await Task.sleep(for:.seconds(1))
                }
                var snapshot=await engine.reliabilitySnapshot();snapshot["thermalPeak"]=thermalPeak
                engine.endSingleCadenceProbe(label:label);engine.stopRecording()
                for _ in 0..<200 where isRecording {try? await Task.sleep(for:.milliseconds(100))}
                var file:[String:Any]?
                for _ in 0..<100 {file=await engine.reliabilityMovieResult();if file != nil {break};try? await Task.sleep(for:.milliseconds(100))}
                let measured=file?["measuredFPS"] as? Double ?? 0,gap=file?["maxGapAfter1sMs"] as? Double ?? 10000
                let previewCount=snapshot["monitorFrames"] as? Int ?? 0
                let previewGap=snapshot["monitorSteadyGapMs"] as? Double ?? 10000
                let previewPassed = !monitor || (previewCount>=Int(seconds*20) && previewGap<150)
                let expectedLog = profile == .log2 ? kCVImageBufferLogTransferFunction_AppleLog2 as String : kCVImageBufferLogTransferFunction_AppleLog as String
                let logPreserved = file?["logTransfer"] as? String == expectedLog && (file?["bits"] as? Int ?? 0)>=10
                let passed=file?["passed"] as? Bool == true && measured>=Double(fps)*0.95 && gap<=Double(2000)/Double(fps)+1 && previewPassed && logPreserved
                results.append(["label":label,"passed":passed,"snapshot":snapshot,"file":file ?? [:]])
                save("Finished "+label)
                if !passed {save("failed",false,"Recorded frame cadence failed "+label);return}
                try? await Task.sleep(for:.milliseconds(750))
            }
            save("complete",true)
        }
    }

    private func verifySingleRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            let originalHistogram = showHistogram
            defer { showHistogram = originalHistogram; UIApplication.shared.isIdleTimerDisabled = false }
            try? await Task.sleep(for: .seconds(2))
            let codec = RecordingCodec(rawValue: AVVideoCodecType.hevc.rawValue)
            let native = [("standard", 60), ("standard", 30)]
            let phases = ProcessInfo.processInfo.arguments.contains("--verify-native-only") ? native : [("vhs", 60), ("vhs", 30)] + native
            for (lookID, fps) in phases {
                let thermal = ProcessInfo.processInfo.thermalState
                guard thermal != .serious, thermal != .critical else {
                    NSLog("SINGLE_VERIFY stopped before %@ %ld fps: thermal=%ld", lookID, fps, thermal.rawValue)
                    return
                }
                look = FilmLook.lineup.first { $0.id == lookID } ?? .standard
                selectedLUT = nil
                if lookID == "standard" { showHistogram = false; histogramData = [] }
                let settings = RecordingSettings(resolution: RecResolution(width: 3840, height: 2160), frameRate: fps, bitrate: .high)
                engine.setPreview(video: true, log: .off, settings: settings, codec: codec)
                engine.discoverRecordingCodecs(log: .off, dual: false, settings: settings, preferredCodec: codec)
                engine.setVideoCrop(nil, viewRatio: 9.0 / 16)
                engine.setRecordingGrade(cube: nil, size: 0, intensity: 1, style: styleParams)
                engine.beginSingleCadenceProbe()
                NSLog("SINGLE_VERIFY start %@ %ld fps thermal=%ld", lookID, fps, thermal.rawValue)
                engine.startRecording(log: .off, dual: false, codec: codec, settings: settings, recordingID: UUID())
                for _ in 0..<120 where !isRecording { try? await Task.sleep(for: .milliseconds(100)) }
                guard isRecording else {
                    engine.stopRecording()
                    NSLog("SINGLE_VERIFY failed to start %@ %ld fps", lookID, fps)
                    return
                }
                if lookID == "standard" {
                    try? await Task.sleep(for: .seconds(1))
                    showHistogram = true
                    try? await Task.sleep(for: .seconds(1))
                    NSLog("NATIVE_HIST_VERIFY %@ fps=%ld bins=%ld", histogramData.isEmpty ? "FAIL" : "PASS", fps, histogramData.count)
                    showHistogram = false
                    try? await Task.sleep(for: .seconds(2))
                } else { try? await Task.sleep(for: .seconds(4)) }
                engine.endSingleCadenceProbe(label: "\(lookID) \(fps)fps")
                engine.stopRecording()
                for _ in 0..<45 where isRecording { try? await Task.sleep(for: .milliseconds(100)) }
                guard !isRecording else { NSLog("SINGLE_VERIFY failed to stop %@ %ld fps", lookID, fps); return }
                try? await Task.sleep(for: .milliseconds(650))
            }
            NSLog("SINGLE_VERIFY COMPLETE")
        }
    }

    func verifyPhotoBurst() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, caps.hasCamera else { NSLog("PHOTO_BURST_VERIFY FAIL no camera"); return }
            selectMode(.photo)
            setPhotoFeature(.standard)
            focusPullLensEnabled = false
            rawEnabled = false; format = .heif; flash = .off; saveToPhotos = false
            engine.setTorch(enabled: false)
            try? await Task.sleep(for: .seconds(1))
            for styled in [false, true] {
                look = styled ? (FilmLook.lineup.first(where: { $0.id == "night35" }) ?? .standard) : .standard
                try? await Task.sleep(for: .milliseconds(350))
                var ids: [UUID] = []
                let begin = ProcessInfo.processInfo.systemUptime
                for _ in 0..<5 {
                    ids.append(submitPhoto())
                    try? await Task.sleep(for: .milliseconds(140))
                }
                var ticks = 0
                while ids.contains(where: { stillContexts[$0] != nil }), ProcessInfo.processInfo.systemUptime - begin < 25 {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let completed = captures.filter { ids.contains($0.id) }
                let success = completed.count == 5 && !ids.contains(where: { stillContexts[$0] != nil })
                NSLog("PHOTO_BURST_VERIFY %@ styled=%d captured=%ld elapsed=%.2f mainActorTicks=%ld", success ? "PASS" : "FAIL", styled ? 1 : 0, completed.count, ProcessInfo.processInfo.systemUptime - begin, ticks)
                for item in completed { delete(item) }
            }
            NSLog("PHOTO_BURST_VERIFY COMPLETE no test shots saved to Photos")
        }
    }

    private func verifyRawPreview() {
        Task { @MainActor in
            let original = currentShootingPreset(named:"Restore"), dials = lookDials
            let destinations = (app:saveInApp,photos:saveToPhotos)
            let idle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { applyShootingPreset(original); lookDials = dials; saveInApp = true; saveToPhotos = destinations.photos; saveInApp = destinations.app; UIApplication.shared.isIdleTimerDisabled = idle }
            try? await Task.sleep(for:.seconds(2))
            selectMode(.photo); setPhotoFeature(.standard); focusPullLensEnabled = false; rawEnabled = true; format = .heif; flash = .off; saveToPhotos = false; look = .standard
            let id = submitPhoto()
            for _ in 0..<200 {
                if stillContexts[id] == nil { break }
                try? await Task.sleep(for:.milliseconds(100))
            }
            var report:[String:Any] = ["passed":false]
            if let item = captures.first(where:{ $0.id == id }) {
                if let url = item.rawURL {
                    report = await Task.detached(priority:.utility) {
                        guard let data = try? Data(contentsOf:url), let preview = PhotoDeveloper.rawPreviewImage(data) else { return ["passed":false,"error":"RAW preview decode"] as [String:Any] }
                        let size = preview.extent.size
                        return ["passed":max(size.width,size.height) <= 1601 && min(size.width,size.height) > 0,"width":size.width,"height":size.height,"headroom":preview.contentHeadroom] as [String:Any]
                    }.value
                }
                delete(item)
            }
            let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("raw-preview-verification.json")
            if let data = try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) { try? data.write(to:url,options:.atomic) }
            NSLog("RAW_PREVIEW_VERIFY %@",String(describing:report))
        }
    }

    private func verifyLogPhotoPreset() {
        Task { @MainActor in
            let original = currentShootingPreset(named:"Restore")
            let originalDials = lookDials, selected = selectedPresetID
            let idle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { applyShootingPreset(original); lookDials = originalDials; selectedPresetID = selected; UIApplication.shared.isIdleTimerDisabled = idle }
            try? await Task.sleep(for:.seconds(2))
            var preset = shootingPresets.first(where:{ $0.mode != CaptureMode.video.rawValue }) ?? original
            preset.mode = CaptureMode.photo.rawValue; preset.raw = false; preset.livePhoto = false; preset.depthPortrait = false; preset.naturalPhoto = false; preset.flash = FlashChoice.off.rawValue; preset.focusLens = true
            var results = [[String:Any]]()
            for profile in [LogProfile.log,.log2] {
                selectMode(.video); logProfile = profile
                let supported = await engine.verifyActivateLog(profile)
                // Unsupported Log 2 still exercises legacy preset/UI normalization;
                // no claim is made that this phone captured in that hardware profile.
                // Even a legacy photo preset carrying a video Log field must normalize to Standard.
                preset.log = profile.rawValue
                applyShootingPreset(preset)
                var legacy = currentShootingPreset(named:"Legacy comparison"); legacy.log = profile.rawValue
                let normalizedMatches = legacy.matchesSettings(of:currentShootingPreset(named:"Current"))
                let standard = logProfile == .off && mode == .photo && normalizedMatches
                let captured = await engine.verifyPresetPhoto(raw:rawEnabled || naturalPhoto,flash:flash,format:format,nativeRaw:naturalPhoto)
                results.append(["profile":profile.rawValue,"supported":supported,"standard":standard,"captured":captured])
                NSLog("LOG_PHOTO_PRESET_VERIFY %@ standard=%d captured=%d",profile.rawValue,standard ? 1 : 0,captured ? 1 : 0)
            }
            let passed = results.contains { $0["supported"] as? Bool == true } && results.allSatisfy { $0["standard"] as? Bool == true && $0["captured"] as? Bool == true }
            let report:[String:Any] = ["passed":passed,"results":results]
            let file = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("log-photo-preset-verification.json")
            if let data = try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) { try? data.write(to:file,options:.atomic) }
            NSLog("LOG_PHOTO_PRESET_VERIFY COMPLETE passed=%d",passed ? 1 : 0)
        }
    }

    private func verifyPresetCapture() {
        Task { @MainActor in
            let original = currentShootingPreset(named:"Restore")
            let originalDials = lookDials
            let selection = selectedPresetID
            let priorIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { applyShootingPreset(original); lookDials = originalDials; selectedPresetID = selection; UIApplication.shared.isIdleTimerDisabled = priorIdle }
            try? await Task.sleep(for:.seconds(2))
            var photo = original; photo.mode = CaptureMode.photo.rawValue; photo.raw = false; photo.livePhoto = false; photo.depthPortrait = false; photo.naturalPhoto = false; photo.flash = FlashChoice.off.rawValue; photo.focusLens = false; photo.isoAuto = true; photo.shutterAuto = true
            var raw = photo; raw.raw = true
            var depth = photo; depth.depthPortrait = true
            var live = photo; live.livePhoto = true
            var native = photo; native.naturalPhoto = true
            var checks = shootingPresets.filter { $0.mode != CaptureMode.video.rawValue }
            if ProcessInfo.processInfo.arguments.contains("--use-preset-fixtures") {
                let fixture = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("preset-regression-fixtures.json")
                if let data = try? Data(contentsOf:fixture), let presets = try? JSONDecoder().decode([ShootingPreset].self,from:data) { checks += presets }
                try? FileManager.default.removeItem(at:fixture)
            }
            checks += [photo,raw,depth,live,native]
            for lens in lenses {
                var lensPreset = photo; lensPreset.lens = lens.zoom; lensPreset.zoom = 0; lensPreset.format = PhotoFormat.heifMax.rawValue
                checks.append(lensPreset)
            }
            var passed = 0
            for (index,preset) in checks.enumerated() {
                applyShootingPreset(preset)
                try? await Task.sleep(for:.milliseconds(900))
                let ok = await engine.verifyPresetPhoto(raw:rawEnabled || naturalPhoto,flash:flash,format:format,nativeRaw:naturalPhoto)
                if ok { passed += 1 }
                NSLog("PRESET_CAPTURE_VERIFY index=%d passed=%d",index,ok ? 1 : 0)
            }
            selectedLUT = luts.first; monitorLUT = true; showLUTPanel = true
            clearLook()
            let off = selectedLUT == nil && !monitorLUT && !isLUTBaking && !showLUTPanel
            NSLog("PRESET_CAPTURE_VERIFY COMPLETE passed=%d total=%d lutOff=%d",passed,checks.count,off ? 1 : 0)
            let report: [String:Any] = ["passed":passed == checks.count && off,"captures":passed,"requested":checks.count,"lutOff":off]
            let file = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("preset-capture-verification.json")
            if let data = try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) { try? data.write(to:file,options:.atomic) }
        }
    }

    func verifyPhotoPipeline() {
        Task { @MainActor [weak self] in
            guard let self,
                  let first = UIImage(named: "Story02")?.jpegData(compressionQuality: 0.9),
                  let second = UIImage(named: "Story03")?.jpegData(compressionQuality: 0.9) else { return }
            var style = StyleParams.identity; style.saturation = 0; style.contrast = 1.15
            let firstID = UUID(), secondID = UUID(), thirdID = UUID()
            let plain = StillComposer.Request(focalScale: 1, aspectRatio: nil, saveTarget: "BOTH")
            let styled = StillComposer.Request(focalScale: 0.65, aspectRatio: 3.0 / 4, saveTarget: "BOTH", style: style)
            stillContexts[firstID] = StillContext(request: plain, detail: "QA original", saves: false, mode: .photo)
            stillContexts[secondID] = StillContext(request: styled, detail: "QA styled", saves: false, mode: .rangefinder)
            stillContexts[thirdID] = StillContext(request: plain, detail: "QA repeat", saves: false, mode: .photo)
            storeStill(fullData: second, raw: nil, simulated: true, id: secondID)
            storeStill(fullData: first, raw: nil, simulated: true, id: firstID)
            storeStill(fullData: first, raw: nil, simulated: true, id: thirdID)
            let begin = ProcessInfo.processInfo.systemUptime
            var ticks = 0
            while pendingPhotoCount > 0, ProcessInfo.processInfo.systemUptime - begin < 20 {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            let a = captures.first { $0.id == firstID }
            let b = captures.first { $0.id == secondID }
            let grade = graded[AnyHashable(secondID)]
            let correctA = a?.fullPhotoURL.flatMap { try? Data(contentsOf: $0) } == first
            let correctB = b?.fullPhotoURL.flatMap { try? Data(contentsOf: $0) } == second
            let files = [grade?.fullURL, grade?.cropURL].compactMap { $0 }
            let grades = files.count == 2 && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            let thumbnails = (a?.fullImage?.size.width ?? 10000) <= 640 && (b?.fullImage?.size.height ?? 10000) <= 640
            let order = captures.filter { [firstID, secondID, thirdID].contains($0.id) }.map(\.id) == [thirdID, secondID, firstID]
            NSLog("PHOTO_PIPELINE_VERIFY %@ isolated=%d gradedPair=%d thumbnailBudget=%d order=%d mainActorTicks=%ld pending=%ld", correctA && correctB && grades && thumbnails && order && pendingPhotoCount == 0 ? "PASS" : "FAIL", correctA && correctB ? 1 : 0, grades ? 1 : 0, thumbnails ? 1 : 0, order ? 1 : 0, ticks, pendingPhotoCount)
            for id in [firstID, secondID, thirdID] {
                if let item = captures.first(where: { $0.id == id }) { delete(item) }
            }
        }
    }
    #endif

    @discardableResult private func saveLivePhoto(still: URL, movie: URL) -> Task<Bool,Never> {
        enqueueSave {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: still, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: movie, options: nil)
                }
                return true
            } catch { return false }
        }
    }

    @discardableResult func saveStillFiles(_ urls: [URL], raw: URL?) -> Task<Bool,Never>? {
        guard !urls.isEmpty else { return nil }
        return enqueueSave {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for url in urls {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: url, options: nil)
                    }
                    if let raw {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: raw, options: nil)
                    }
                }
                return true
            } catch { return false }
        }
    }

    private struct ImportedLUT: Codable { var id: UUID; var name: String; var text: String }

    private func loadImportedLUTs() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: lutDirectory(), includingPropertiesForKeys: nil) else { return }
        for file in files where UUID(uuidString: file.lastPathComponent) != nil {
            guard let data = try? Data(contentsOf: file),
                  let saved = try? JSONDecoder().decode(ImportedLUT.self, from: data),
                  let parsed = CubeLUT.parse(text: saved.text, name: saved.name),
                  !luts.contains(where: { $0.id == saved.id }) else { continue }
            luts.append(CubeLUT(id: saved.id, name: saved.name, size: parsed.size, data: parsed.data, isBuiltIn: false))
        }
    }

    private func saveImportedLUT(
        text: String,
        name: String,
        id: UUID
    ) {
        guard let data = try? JSONEncoder().encode(ImportedLUT(id: id, name: name, text: text)) else { return }
        do {
            try FileManager.default.createDirectory(at: lutDirectory(), withIntermediateDirectories: true)
            try data.write(to: lutDirectory().appendingPathComponent(id.uuidString), options: .atomic)
        } catch { showToast("The LUT works now, but could not be stored for the next launch.") }
    }

    private func lutDirectory() -> URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
    }

    private func movieDetail(kind: DualKind) -> String {
        switch kind {
        case .none:
            return "Video File"
        case .secondCamera:
            return "Dual Camera Video"
        case .verticalCrop:
            return "Video with Vertical Stories Crop"
        }
    }

    private func persist(url: URL, ext: String) -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Movies", isDirectory: true)
        if url.path.hasPrefix(root.path + "/") { return url }
        let destination = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try FileManager.default.moveItem(at: url, to: destination); return destination }
        catch { showToast("The video is available now but couldn’t be moved to the permanent gallery. Export it before closing."); return url }
    }

    // MARK: - Photos library

    private func photosAccessGranted() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        if current == .authorized || current == .limited {
            return true
        }

        if current == .notDetermined {
            let next = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return next == .authorized || next == .limited
        }

        return false
    }

    // Saves run one after another so the permission prompt only appears once.
    @discardableResult private func enqueueSave(
        _ work: @escaping () async -> Bool
    ) -> Task<Bool,Never> {
        let previous = photosSaveTask
        let activity = CaptureSaveActivity()
        activity.begin()

        photosSaveTask = Task { [weak self] in
            defer { activity.end() }
            await previous?.value

            guard let self else { return false }

            guard await self.photosAccessGranted() else {
                self.showToast("Allow Photos access in Settings to save.")
                return false
            }
            let success = await work()
            if !success { self.showToast("Could not save to Photos.") }
            return success
        }
        return photosSaveTask!
    }

    @discardableResult private func saveVideosToLibrary(_ urls: [URL]) -> Task<Bool,Never>? {
        let urls = urls.filter { $0.path != "/dev/null" }
        guard urls.isEmpty == false else { return nil }

        // Commit both Dual Shot outputs together with one Photos transaction.
        return enqueueSave { [weak self] in
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for url in urls {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .video, fileURL: url, options: nil)
                    }
                }
                await MainActor.run {
                    self?.showToast(urls.count == 2 ? "Dual Shot saved." : "Video saved.")
                }
                return true
            } catch {
                return false
            }
        }
    }

    private func savePhotoToLibrary(_ data: Data) {
        enqueueSave {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }

                return true
            } catch {
                return false
            }
        }
    }
}

// MARK: - Camera control types

enum ControlKind: String, CaseIterable, Identifiable {
    case ev
    case iso
    case shutter
    case wb
    case focus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ev: return "EV"
        case .iso: return "ISO"
        case .shutter: return "SHUTTER"
        case .wb: return "WB"
        case .focus: return "FOCUS"
        }
    }

    var hint: String {
        switch self {
        case .ev: return "+0.7"
        case .iso: return "400"
        case .shutter: return "1/125"
        case .wb: return "5600"
        case .focus: return "0 to 1"
        }
    }
}

struct RulerSpec {
    let stops: [Double]
    let presets: [Double]
    let logScale: Bool
    let labelEvery: Int
    let format: (Double) -> String
    let presetSet: Set<Int>

    init(
        stops: [Double],
        presets: [Double],
        logScale: Bool,
        labelEvery: Int = 1,
        format: @escaping (Double) -> String
    ) {
        self.stops = stops
        self.presets = presets
        self.logScale = logScale
        self.labelEvery = max(1, labelEvery)
        self.format = format

        let warp: (Double) -> Double = { logScale ? log(max($0, 0.000001)) : $0 }

        var found = Set<Int>()

        for preset in presets {
            var best = 0
            var bestDistance = Double.infinity

            for (position, stop) in stops.enumerated() {
                let distance = abs(warp(stop) - warp(preset))

                if distance < bestDistance {
                    bestDistance = distance
                    best = position
                }
            }

            found.insert(best)
        }

        presetSet = found
    }

    private func warp(_ value: Double) -> Double {
        logScale ? log(max(value, 0.000001)) : value
    }

    func index(of value: Double) -> Int {
        guard stops.isEmpty == false else { return 0 }

        let target = warp(value)
        var best = 0
        var bestDistance = Double.infinity

        for (position, stop) in stops.enumerated() {
            let distance = abs(warp(stop) - target)

            if distance < bestDistance {
                bestDistance = distance
                best = position
            }
        }

        return best
    }

    // The nearest preset within a few ticks, so scrolling sticks to it.
    func snapIndex(near position: Int, within range: Int) -> Int? {
        presetSet
            .filter { abs($0 - position) <= range }
            .min { abs($0 - position) < abs($1 - position) }
    }
}

// Graded copies of a saved photo. The originals stay on the capture item.
struct GradedStills {
    var fullURL: URL? = nil
    var cropURL: URL? = nil
    var full: UIImage?
    var crop: UIImage?
    var movie: URL?
    var storiesMovie: URL?
}


// MARK: - Saved looks

struct SavedLook: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lutName: String?
    var styleID: String
    var intensity: Float
    var options: LookOptions?
    var dials: LookDials?

    private static let key = "frameline.savedLooks"

    static func load() -> [SavedLook] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let looks = try? JSONDecoder().decode([SavedLook].self, from: data) else {
            return []
        }

        return looks
    }

    static func save(_ looks: [SavedLook]) {
        if let data = try? JSONEncoder().encode(looks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct MicInput: Identifiable, Hashable {
    let uid: String
    let name: String

    var id: String { uid }
}

// What the gallery shows for a recorded clip.
nonisolated struct ClipInfo: Codable, Sendable {
    var number: Int
    var start: String
    var end: String
    var codec: String
    var gamma: String
    var resolution: String?
    var frameRate: Int
}

enum StabilizationChoice: String, CaseIterable, Identifiable {
    case auto
    case off
    case standard
    case cinematic
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        case .extreme: "Extreme"
        }
    }

    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .auto: .auto
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        case .extreme: .cinematicExtended
        }
    }
}

// The colour of the focus peaking marks.
enum PeakColor: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .white: "White"
        }
    }

    // Premultiplied against the mark's opacity.
    var premultiplied: (UInt8, UInt8, UInt8) {
        switch self {
        case .red: (235, 45, 45)
        case .yellow: (235, 200, 20)
        case .green: (30, 225, 60)
        case .blue: (50, 130, 245)
        case .white: (235, 235, 235)
        }
    }

    static func load() -> PeakColor {
        PeakColor(
            rawValue: UserDefaults.standard.string(forKey: "frameline.peak.color") ?? ""
        ) ?? .red
    }
}
