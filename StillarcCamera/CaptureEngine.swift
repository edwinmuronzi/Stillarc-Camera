import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO

// MARK: - Recording Codec

struct RecordingCodec: Identifiable, Hashable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    var isProRes: Bool { rawValue.hasPrefix("ap") }

    var title: String {
        switch rawValue {
        case "hvc1", "hev1":
            return "HEVC (H.265)"
        case "avc1":
            return "H.264"
        case "apch":
            return "Apple ProRes 422 HQ"
        case "apcn":
            return "Apple ProRes 422"
        case "apcs":
            return "Apple ProRes 422 LT"
        case "apco":
            return "Apple ProRes 422 Proxy"
        default:
            return "Other (\(rawValue))"
        }
    }

    var videoCodec: AVVideoCodecType {
        AVVideoCodecType(rawValue: rawValue)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ codec: AVVideoCodecType) {
        rawValue = codec.rawValue
    }
}

// MARK: - Lens

// One stop on the lens bar. Optical lenses use crop 1. Stops such as 2x
// and 8x are a 2x crop of the main and telephoto sensors.
nonisolated struct LensOption: Identifiable, Hashable, Sendable {
    let deviceID: String
    let crop: Double
    let zoom: Double

    var id: String { "\(deviceID)@\(crop)" }
    var uniqueID: String { id }

    var title: String {
        zoom == zoom.rounded()
            ? "\(Int(zoom))x"
            : String(format: "%.1fx", zoom)
    }
}

// MARK: - Exposure aids

struct AnalysisFrame: @unchecked Sendable {
    var histogram: [Float]
    var overlay: CGImage?
    var waveform: CGImage?
    var channels: [[Float]] = []
}

struct LiveValues: Sendable {
    var iso: Float
    var shutter: Double
    var kelvin: Float
    var lensPosition: Float
}

// MARK: - Recording Settings

nonisolated struct RecResolution: Identifiable, Hashable, Sendable {
    let width: Int
    let height: Int

    var id: String { "\(width)x\(height)" }

    var dimensions: String { "\(width)×\(height)" }

    var shortTitle: String {
        switch (width, height) {
        case (7680, 4320): return "8K"
        case (4096, 2160): return "4K DCI"
        case (3840, 2160): return "4K"
        case (2560, 1440): return "1440p"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return dimensions
        }
    }

    var title: String {
        shortTitle == dimensions
            ? dimensions
            : "\(shortTitle) · \(dimensions)"
    }

    var isSixteenByNine: Bool {
        guard height > 0 else { return false }
        return abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.02
    }
}

nonisolated enum RecBitrate: String, CaseIterable, Identifiable, Sendable {
    case auto
    case low
    case medium
    case high
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    // Bits per pixel per frame. Resolution and frame rate scale the result.
    private var factor: Double? {
        switch self {
        case .auto: return nil
        case .low: return 0.06
        case .medium: return 0.12
        case .high: return 0.20
        case .maximum: return 0.35
        }
    }

    func bitsPerSecond(
        width: Int,
        height: Int,
        fps: Double,
        codec: String
    ) -> Int? {
        guard let factor else { return nil }

        // H.264 needs roughly 1.6x the bitrate of HEVC for similar quality.
        let codecScale = codec == "avc1" ? 1.6 : 1.0

        let raw = Double(width) * Double(height) * fps * factor * codecScale
        let megabits = max((raw / 1_000_000).rounded(), 4)

        return Int(megabits) * 1_000_000
    }
}

nonisolated struct RecordingSettings: Equatable, Sendable {
    var resolution: RecResolution?
    var frameRate: Int?
    var bitrate: RecBitrate = .auto

    static func load() -> RecordingSettings {
        let defaults = UserDefaults.standard
        var settings = RecordingSettings()

        let width = defaults.integer(forKey: "frameline.rec.width")
        let height = defaults.integer(forKey: "frameline.rec.height")

        if width > 0, height > 0 {
            settings.resolution = RecResolution(width: width, height: height)
        }

        let fps = defaults.integer(forKey: "frameline.rec.fps")

        if fps > 0 {
            settings.frameRate = fps
        }

        if let raw = defaults.string(forKey: "frameline.rec.bitrate"),
           let bitrate = RecBitrate(rawValue: raw) {
            settings.bitrate = bitrate
        }

        return settings
    }

    func save() {
        let defaults = UserDefaults.standard

        defaults.set(resolution?.width ?? 0, forKey: "frameline.rec.width")
        defaults.set(resolution?.height ?? 0, forKey: "frameline.rec.height")
        defaults.set(frameRate ?? 0, forKey: "frameline.rec.fps")
        defaults.set(bitrate.rawValue, forKey: "frameline.rec.bitrate")
    }
}

nonisolated struct RecordingOptions: Equatable, Sendable {
    var resolutions: [RecResolution] = []
    var frameRatesByResolution: [String: [Int]] = [:]
    var allFrameRates: [Int] = []
    var bitrateSupported = false

    // True in dual-camera mode, where the format is chosen automatically.
    var locked = false

    func frameRates(for resolution: RecResolution?) -> [Int] {
        guard let resolution else { return allFrameRates }
        return frameRatesByResolution[resolution.id] ?? []
    }
}

// Pixel-format families that decide which codecs a format can record.
private nonisolated enum FormatGroup: Int, CaseIterable {
    case tenBit422
    case tenBit420
    case eightBit420

    var label: String {
        switch self {
        case .tenBit422: return "10-bit 4:2:2"
        case .tenBit420: return "10-bit 4:2:0"
        case .eightBit420: return "8-bit 4:2:0"
        }
    }
}

private nonisolated struct FormatProbe {
    let group: FormatGroup
    let format: AVCaptureDevice.Format
    let codecs: [RecordingCodec]
}

enum EngineEvent: Sendable {
    case caps(DeviceCaps)
    case recording(Bool)
    case photo(id: UUID, processed: Data?, raw: Data?, companion: PhotoCompanion = PhotoCompanion())
    case movie(primary: URL, secondary: URL?, kind: DualKind, recordingID: UUID? = nil, baked: Bool = false)
    case message(String)
    case exposureSample(iso: Float, shutter: Double)
}

nonisolated final class CaptureEngine: NSObject,
    AVCapturePhotoCaptureDelegate,
    AVCaptureFileOutputRecordingDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    let session: AVCaptureSession
    var onEvent: (@Sendable (EngineEvent) -> Void)?

    // Codec discovery is delivered separately so existing EngineEvent
    // handling remains compatible.
    var onCodecs: (@Sendable ([RecordingCodec]) -> Void)?

    // Resolutions, frame rates and bitrate support for the current camera.
    var onVideoOptions: (@Sendable (RecordingOptions) -> Void)?

    // Back lenses on this phone, plus the id of the one in use. Empty on
    // the front camera.
    var onTrackingUpdate: (@Sendable (CGRect?, Bool, CGPoint?) -> Void)?
    var onAudioState: (@Sendable ([MicrophoneOption], String?, Bool, Bool) -> Void)?
    var onAudioClip: (@Sendable (Bool) -> Void)?
    let reelTrackingState = ReelTrackingState()
    private lazy var subjectTracker: SubjectTracker = {
        let tracker = SubjectTracker(state: reelTrackingState)
        tracker.onUpdate = { [weak self] rect, lost, point in self?.onTrackingUpdate?(rect, lost, point) }
        return tracker
    }()
    private var frameOptions = FramingOptions()
    private var trackingEnabled = false
    private var anamorphicPreviewPool: CVPixelBufferPool?
    private var previewPoolSizes: [ObjectIdentifier: CGSize] = [:]
    private var previewFormats: [ObjectIdentifier: CMVideoFormatDescription] = [:]
    private let previewColorSpace = CGColorSpaceCreateDeviceRGB()
    private let cameraAudio = CameraAudioController()
    private let audioQueue = DispatchQueue(label: "stillarc.audio", qos: .userInteractive)
    private var headphonesMonitoring = false
    private var preferredMicrophone: String?
    private var routeObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var sessionWanted = false
    private var needsSessionRebuild = false
    var onLenses: (@Sendable ([LensOption], String?, Bool) -> Void)?

    private let queue = DispatchQueue(label: "stillarc.capture")

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let storiesOutput = AVCaptureMovieFileOutput()

    private var videoDevice: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back
    private var photoDelegates: [Int64: PhotoShotDelegate] = [:]
    private var stopAfterPhotos = false
    private var dualActive = false
    private var primaryURL: URL?
    private var secondaryURL: URL?
    private var finishedPrimary = false
    private var finishedSecondary = false
    private let multiCam: Bool
    private var exportStories = false
    private var framingFocal: Double = 35
    private var framingZoom: Double = 1
    private var videoStabilization: AVCaptureVideoStabilizationMode = .auto
    private var framingRangefinder = true
    private var lensChoice: LensOption?
    private var videoCrop: CGRect?
    private var lensZoom: Double = 1
    private var lensCrop: Double = 1

    // Exposure aids (histogram, zebras, focus peaking).
    var onAnalysis: (@Sendable (AnalysisFrame) -> Void)?
    private let analysisOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "stillarc.analysis", qos: .userInitiated)
    private let scopesQueue = DispatchQueue(label: "stillarc.scopes", qos: .utility)
    private let auxiliaryLock = NSLock()
    private var scopesBusy = false
    private var loupeBusy = false
    private var scopesRGBPool: CVPixelBufferPool?
    private var scopesRGBSize = CGSize.zero
    private let aidsLock = NSLock()
    private var aidHistogram = false
    private var aidWaveform = false
    private var aidZebra = false
    private var aidPeaking = false

    // Premultiplied colour of the peaking marks, and how sensitive they are.
    private var peakRed: UInt8 = 235
    private var peakGreen: UInt8 = 45
    private var peakBlue: UInt8 = 45
    private var peakThreshold = 44
    private var aidFalseColor = false
    private var lastAnalysis: CFAbsoluteTime = 0

    // Log HEVC recording through an asset writer.
    private let writerVideoOutput = AVCaptureVideoDataOutput()
    private let writerAudioOutput = AVCaptureAudioDataOutput()
    private let writerQueue = DispatchQueue(label: "stillarc.writer", qos: .userInitiated)
    private let writerLock = NSLock()
    private var activeWriter: LogWriter?

    // LUT monitor.
    let monitorLayer = AVSampleBufferDisplayLayer()
    let landscapeMonitorLayer = AVSampleBufferDisplayLayer()

    // Focus loupe: its own picture, drawn from the camera frames.
    let loupeLayer = AVSampleBufferDisplayLayer()
    private let loupeLock = NSLock()
    private var loupeOn = false
    private var loupeViewPoint = CGPoint.zero
    private var loupeViewSize = CGSize.zero
    private var loupePool: CVPixelBufferPool?
    private var lastLoupe: CFAbsoluteTime = 0
    private let monitorLock = NSLock()
    private var monitorRevision: UInt64 = 0
    private var previewMatchRevision: UInt64 = 0
    private var previewMatchWriter: UUID?
    private var previewMatchValue = false
    private let recordedPreviewRenderer = RecordedPreviewRenderer()
    private var monitorCube: Data?
    private var monitorCubeSize = 0
    private var monitorIntensity: Float = 1
    private var monitorStyle: StyleParams?
    private var lastMonitor: CFAbsoluteTime = 0
    private var monitorBusy = false
    private var monitorEnqueued = 0
    private var monitorNotReady = 0
    private var monitorStatsTime: CFAbsoluteTime = 0

    // Live camera values and automatic ISO / shutter metering.
    var onLive: (@Sendable (LiveValues) -> Void)?

    // Frames kept so far by a timelapse video.
    var onTimelapseCount: (@Sendable (Int) -> Void)?
    private var activeTimelapse: TimelapseWriter?
    private var timelapseStopping = false
    var onAudioLevel: (@Sendable (Float) -> Void)?
    private var lastAudioDb: Float = -160
    private var liveTimer: DispatchSourceTimer?
    private var tickCount = 0
    private var ctlISOAuto = true
    private var ctlShutterAuto = true
    private var ctlISO: Float = 100
    private var ctlShutter: Double = 1.0 / 60
    private var ctlBias: Float = 0
    private var exposureApplying = false
    private var exposurePending = false
    private var exposureApplyStart: TimeInterval = 0
    private var lastExposureApplied: TimeInterval = 0
    private var previewLog: LogProfile = .off
    private var requestedPhotoLive = false
    private var requestedPhotoDepth = false
    private var requestedNaturalRaw = false
    private var previewCodec: RecordingCodec?
    private var previewVideo = false
    private var previewSettings: RecordingSettings?
    private var cachedProbes: [FormatProbe] = []
    private var cachedProbeKey: String?
    private var deviceAngle: CGFloat = 90
    private var focusMeasurementID = UUID()
    private var focusLocked = false

    // Orientation: photos and video follow how the phone is held.
    var onOrientation: (@Sendable (Double) -> Void)?
    private var lastAngle: CGFloat = 90
    private var liveWriter: LiveMovieWriter?
    private var recordingCube: Data?
    private var recordingCubeSize = 0
    private var recordingIntensity: Float = 1
    private var recordingStyle: StyleParams = .identity
    private var torchRequested = false
    private var torchLevel: Float = 1
    private var dualPreview = false
    private var monitorComparing = false
    private var landscapePreviewPool: CVPixelBufferPool?
    private var reelPreviewPool: CVPixelBufferPool?
    private var skipRestore = false
    private var activeRecordingID: UUID?
    private var audioConfigured = false
    private var videoViewRatio = 3.0 / 4.0
    private var monitorPool: CVPixelBufferPool?
    private var monitorPoolSize: (width: Int, height: Int) = (0, 0)

    // Size of the stream the aids and the LUT preview read.
    private var analysisSwap = false
    private var analysisUnscaled = false
    private var analysisMismatch = 0
    private var analysisIgnoredLogged = false
    private var edgeHold = 0
    private var monitorHoldUntil: CFAbsoluteTime = 0
    private var monitorSourceFormat: OSType = 0
    private var monitorEdges: (l: Int, r: Int, t: Int, b: Int) = (0, 0, 0, 0)
    private var analysisToggles = 0
    private var analysisApplied: (w: Int, h: Int) = (0, 0)

    // Stale or half-settled preview frames are never shown.
    private var lastMonitorEnqueue: CFAbsoluteTime = 0
    private var monitorSourceSize: (w: Int, h: Int) = (0, 0)
    private var monitorSettle = 0
    private var galleryVisible = false
    private var lastLive: LiveValues?

    private let renderResources = MovieRenderResources()
    private var ciContext: CIContext { renderResources.context }
    private lazy var scopesContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .priorityRequestLow: true])

    override init() {
        multiCam = AVCaptureMultiCamSession.isMultiCamSupported
        // Dual Shot uses one source. A regular session supports the unified
        // rear camera and its continuous ISP-managed constituent handoffs.
        session = AVCaptureSession()

        super.init()
        cameraAudio.onMeter = { [weak self] db, clipping in
            self?.onAudioLevel?(db)
            self?.onAudioClip?(clipping)
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishAudioState() }
        }

        installSessionObservers()

        // A scaled analysis stream that crashed once is switched off.
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: "frameline.scaleTrial") {
            defaults.set(true, forKey: "frameline.scaleDisabled")
            defaults.set(false, forKey: "frameline.scaleTrial")
        }

        // The size request was reworked, so earlier give-ups are cleared once.
        if defaults.bool(forKey: "frameline.scaleResetV4") == false {
            defaults.set(false, forKey: "frameline.scaleDisabled")
            defaults.set(false, forKey: "frameline.scaleTrial")
            defaults.set(true, forKey: "frameline.scaleResetV4")
        }

        analysisUnscaled = defaults.bool(forKey: "frameline.scaleDisabled")
    }

    deinit {
        liveTimer?.cancel()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.liveTimer?.cancel(); self.liveTimer = nil
                self.audioQueue.async { [weak self] in self?.cameraAudio.stop() }
                if self.currentLiveWriter() != nil || self.currentWriter() != nil || self.movieOutput.isRecording {
                    self.emit(.message("Camera interrupted. Finishing the current recording."))
                    self.stopRecording()
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.sessionWanted else { return }
                self.startOnQueue()
            }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let reset = (notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset
            self?.queue.async { [weak self] in
                guard let self else { return }
                if reset {
                    self.needsSessionRebuild = true
                    if self.currentLiveWriter() != nil || self.currentWriter() != nil || self.movieOutput.isRecording {
                        self.emit(.message("Camera service restarted. Finishing the current recording."))
                        self.stopRecording()
                    } else if self.sessionWanted { self.startOnQueue() }
                } else {
                    self.emit(.message("The camera stopped unexpectedly. Return to the app to resume."))
                }
            }
        })
    }

    private weak var nativePreviewLayer: AVCaptureVideoPreviewLayer?
    private var nativePreviewEnabled = true

    private var frontRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let frontMirrorLock = NSLock()
    private var frontMirrorEnabled = true
    private var frontMirrored: Bool {
        frontMirrorLock.withLock { frontMirrorEnabled } && position == .front
    }
    func setFrontCameraMirroring(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording, !self.storiesOutput.isRecording,
                  self.currentLiveWriter() == nil, self.currentWriter() == nil, self.photoDelegates.isEmpty, self.motionExposureID == nil else { return }
            self.frontMirrorLock.withLock { self.frontMirrorEnabled = enabled }
            self.rotateConnections()
        }
    }
    // Raw 90-degree rotation is not portrait on every sensor (notably newer
    // front cameras). Ask AVFoundation for this camera's static orientation.
    private func orient(_ connection: AVCaptureConnection, uprightAngle: CGFloat) {
        let sourceDevice=connection.inputPorts.compactMap {($0.input as? AVCaptureDeviceInput)?.device}.first ?? videoDevice
        guard let device=sourceDevice,device.position == .front else {
            if connection.isVideoRotationAngleSupported(uprightAngle), connection.videoRotationAngle != uprightAngle {
                connection.videoRotationAngle = uprightAngle
            }
            return
        }
        let orientation: AVCaptureVideoOrientation
        switch uprightAngle {
        case 0: orientation = .landscapeRight
        case 180: orientation = .landscapeLeft
        case 270: orientation = .portraitUpsideDown
        default: orientation = .portrait
        }
        if #available(iOS 27.0, *) {
            if frontRotationCoordinator?.device !== device {
                frontRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
            let angle = frontRotationCoordinator!.videoRotationAngleRelative(toDeviceOrientation: orientation)
            if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            // Legacy semantic orientation also accounts for the sensor mounting.
            connection.videoOrientation = orientation
        }
    }

    func attachNativePreview(_ layer: AVCaptureVideoPreviewLayer, enabled: Bool) {
        queue.async { [weak self, weak layer] in
            guard let self, let layer else { return }
            if self.nativePreviewLayer !== layer {
                self.nativePreviewLayer?.session = nil
                self.nativePreviewLayer = layer
            }
            self.nativePreviewEnabled = enabled
            if layer.session !== self.session { layer.session = self.session }
            self.updateNativePreviewConnection()
        }
    }

    func detachNativePreview(_ layer: AVCaptureVideoPreviewLayer) {
        queue.async { [weak self, layer] in
            guard self?.nativePreviewLayer === layer else { return }
            layer.session = nil
            self?.nativePreviewLayer = nil
        }
    }

    private func updateNativePreviewConnection() {
        guard let connection = nativePreviewLayer?.connection else { return }
        if connection.isEnabled != nativePreviewEnabled { connection.isEnabled = nativePreviewEnabled }
        orient(connection, uprightAngle: 90)
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            let front = frontMirrored
            if connection.isVideoMirrored != front { connection.isVideoMirrored = front }
        }
    }

    func makeCameraControlBridge() -> CameraControlBridge {
        CameraControlBridge(session: session, configurationQueue: queue)
    }

    // MARK: - Session Controls

    func start() {
        queue.async { [weak self] in
            self?.sessionWanted = true
            self?.stopAfterPhotos = false
            if self?.session.isRunning == false { self?.startOnQueue() }
        }
    }

    func setGalleryVisible(_ visible: Bool) {
        monitorLock.lock(); galleryVisible = visible; monitorLock.unlock()
        if !visible {
            // A covered display layer can stop consuming samples without
            // entering .failed. Drop its stale queue before revealing it.
            analysisQueue.async { [weak self] in
                self?.monitorLayer.sampleBufferRenderer.flush()
                self?.landscapeMonitorLayer.sampleBufferRenderer.flush()
            }
        }
    }
    private var previewSuppressed: Bool {
        monitorLock.lock(); defer { monitorLock.unlock() }; return galleryVisible
    }

    func setAppForeground(_ foreground: Bool) {
        queue.async { [weak self] in self?.sessionWanted = foreground }
    }

    func stop(releaseRenderCaches: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.previewSuppressed, self.movieOutput.isRecording || self.storiesOutput.isRecording
                || self.currentLiveWriter() != nil || self.currentWriter() != nil || self.currentTimelapse() != nil { return }
            self.sessionWanted = false
            if let id = self.motionExposureID {
                self.analysisQueue.async { [weak self] in self?.finishMotionExposure(id: id, cancelled: true) }
            }
            if !self.photoDelegates.isEmpty { self.stopAfterPhotos = true; return }
            self.liveTimer?.cancel(); self.liveTimer = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.audioQueue.async { [weak self] in self?.cameraAudio.stop() }
            if releaseRenderCaches, self.currentLiveWriter() == nil, self.currentWriter() == nil {
                self.analysisQueue.async { [weak self] in self?.ciContext.clearCaches() }
            }
        }
    }

    func flip() {
        queue.async { [weak self] in
            guard let self else { return }

            self.position = self.position == .back ? .front : .back
            self.rebuildSingle()
        }
    }

    // MARK: - Video aspect crop

    // Normalized rectangle of the viewfinder to keep, or nil for full frame.
    func setVideoCrop(_ rect: CGRect?, viewRatio: Double) {
        queue.async { [weak self] in
            self?.videoCrop = rect
            self?.videoViewRatio = viewRatio
        }
    }

    // MARK: - Lens

    private var physicalFocusMode = false
    private var lensTransitionID = UUID()
    private var cachedLensOptions: [LensOption]?

    func setFocusPullMode(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.currentLiveWriter() == nil, self.currentWriter() == nil, !self.movieOutput.isRecording else { return }
            self.physicalFocusMode = enabled
            if enabled {
                self.position = .back
                if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                    let crop = self.lensChoice?.deviceID == wide.uniqueID ? (self.lensChoice?.crop ?? 1) : 1
                    self.lensChoice = LensOption(deviceID: wide.uniqueID, crop: crop, zoom: crop)
                }
            }
            guard self.videoDevice != nil else { return }
            self.lensTransitionID = UUID()
            self.rebuildSingle()
        }
    }

    func restoreCamera(zoom: Double, front: Bool) {
        queue.async { [weak self] in
            guard let self, self.videoDevice == nil,
                  let choice = self.lensOptions().min(by: { abs($0.zoom - zoom) < abs($1.zoom - zoom) }) else { return }
            self.position = front ? .front : .back
            self.lensChoice = choice
            self.lensZoom = choice.zoom
            self.lensCrop = choice.crop
        }
    }

    func selectLens(_ id: String) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  self.position == .back,
                  let choice = self.lensOptions().first(where: { $0.id == id }) else { return }

            if device.isVirtualDevice {
                let token = UUID()
                self.lensTransitionID = token
                self.lensChoice = choice
                self.lensZoom = choice.zoom
                self.lensCrop = choice.crop
                let multiplier = self.framingRangefinder ? 1 : self.framingZoom
                let target = self.zoomFactor(on: device, multiplier: multiplier)
                self.rampLens(device, to: Double(target), token: token) { [weak self] in
                    self?.publishLenses()
                }
                return
            }

            let rolling = self.movieOutput.isRecording || self.currentWriter() != nil || self.currentLiveWriter() != nil
            if rolling, device.uniqueID != choice.deviceID, self.currentLiveWriter() == nil {
                self.emit(.message("This raw recording supports zoom on the current lens."))
                return
            }
            let token = UUID()
            self.lensTransitionID = token
            self.lensChoice = choice
            let multiplier = self.framingRangefinder ? 1 : self.framingZoom

            if device.uniqueID == choice.deviceID {
                self.lensZoom = choice.zoom
                self.lensCrop = choice.crop
                let target = Double(device.minAvailableVideoZoomFactor) * multiplier * choice.crop
                self.rampLens(device, to: target, token: token) { [weak self] in self?.publishLenses() }
                return
            }

            guard let next = AVCaptureDevice(uniqueID: choice.deviceID),
                  let input = try? AVCaptureDeviceInput(device: next) else {
                self.emit(.message("That lens can't be used right now."))
                self.publishLenses()
                return
            }
            let sourceBase = self.lensZoom / max(self.lensCrop, 0.01)
            let plan = LensTransitionPlan(
                sourceBase: sourceBase, sourceFactor: Double(device.videoZoomFactor),
                sourceMinimum: Double(device.minAvailableVideoZoomFactor),
                sourceMaximum: Double(min(device.maxAvailableVideoZoomFactor, 16)),
                destinationBase: choice.zoom / choice.crop,
                destinationMinimum: Double(next.minAvailableVideoZoomFactor),
                destinationMaximum: Double(min(next.maxAvailableVideoZoomFactor, 16)),
                targetZoom: choice.zoom * multiplier
            )
            self.rampLens(device, to: plan.sourceFactor, token: token) { [weak self] in
                guard let self else { return }
                let actualZoom = sourceBase * Double(device.videoZoomFactor / device.minAvailableVideoZoomFactor)
                self.swapInput(to: choice, input: input, matchingZoom: actualZoom, token: token)
            }
        }
    }

    private func rampLens(_ device: AVCaptureDevice, to requested: Double, token: UUID, completion: @escaping @Sendable () -> Void) {
        guard lensTransitionID == token, videoDevice === device else { return }
        let target = min(Double(maximumZoom(on: device)), max(Double(device.minAvailableVideoZoomFactor), requested))
        let start = Double(device.videoZoomFactor)
        let duration = LensTransitionPlan.duration(from: start, to: target)
        guard duration > 0 else { completion(); return }
        lock(device) {
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            let rate = Float(abs(log2(target / max(start, 0.001))) / duration)
            device.ramp(toVideoZoomFactor: CGFloat(target), withRate: max(0.05, rate))
        }
        waitForLensRamp(device, target: target, deadline: ProcessInfo.processInfo.systemUptime + max(0.8, duration + 0.45), token: token, completion: completion)
    }

    private func waitForLensRamp(_ device: AVCaptureDevice, target: Double, deadline: Double, token: UUID, completion: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.lensTransitionID == token, self.videoDevice === device else { return }
            let current = Double(device.videoZoomFactor)
            if abs(log2(max(current, 0.001) / target)) < 0.015 || ProcessInfo.processInfo.systemUptime >= deadline {
                completion()
            } else {
                self.waitForLensRamp(device, target: target, deadline: deadline, token: token, completion: completion)
            }
        }
    }

    // Configure the new camera at a matching field of view before it sends
    // its first frame; only then ramp to the selected lens's final crop.
    private func swapInput(to choice: LensOption, input newInput: AVCaptureDeviceInput, matchingZoom: Double, token: UUID) {
        guard lensTransitionID == token else { return }
        let newDevice = newInput.device
        let oldInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        session.beginConfiguration()
        oldInputs.forEach { session.removeInput($0) }
        guard session.canAddInput(newInput) else {
            oldInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            emit(.message("That lens can't be used right now."))
            publishLenses()
            return
        }
        session.addInput(newInput)
        videoDevice = newDevice
        if previewVideo { applyPreviewFormat() }
        lensZoom = choice.zoom
        lensCrop = choice.crop
        let base = choice.zoom / choice.crop
        let minimum = newDevice.minAvailableVideoZoomFactor
        let maximum = min(newDevice.maxAvailableVideoZoomFactor, 16)
        let start = min(maximum, max(minimum, CGFloat(matchingZoom / base) * minimum))
        lock(newDevice) { newDevice.videoZoomFactor = start }
        rotateConnections()
        session.commitConfiguration()
        restoreFocus()
        applyTorch()
        retryRequestedTorch()
        publishCaps()
        let multiplier = framingRangefinder ? 1 : framingZoom
        let target = Double(minimum) * multiplier * choice.crop
        // Let the matched first frame reach the preview before continuing
        // the zoom. Starting the ramp during input negotiation skips it.
        queue.asyncAfter(deadline: .now() + 0.075) { [weak self] in
            self?.rampLens(newDevice, to: target, token: token) { [weak self] in self?.publishLenses(reapplyControls: true) }
        }
    }

    // Cheap refresh of the resolution and frame-rate choices.
    func refreshVideoOptions(log: LogProfile) {
        queue.async { [weak self] in
            self?.publishVideoOptions(log: log)
        }
    }

    // Field of view at a comparable 16:9 format, so lenses can be compared.
    private func comparableFOV(_ device: AVCaptureDevice) -> Double {
        let matching = device.formats.filter {
            let size = $0.formatDescription.dimensions
            return size.width == 1920 && size.height == 1080
        }

        let fov = matching.map { Double($0.videoFieldOfView) }.max()
            ?? Double(device.activeFormat.videoFieldOfView)

        return tan(fov * .pi / 360)
    }

    // Native lenses plus the 2x crops of the main and telephoto sensors:
    // 0.5x, 1x, 2x, 4x, 8x on iPhone 17 Pro.
    private func lensOptions() -> [LensOption] {
        if let cachedLensOptions { return cachedLensOptions }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .back
        ).devices

        guard let wide = devices.first(where: {
            $0.deviceType == .builtInWideAngleCamera
        }) else {
            return []
        }

        let wideTan = comparableFOV(wide)
        var options: [LensOption] = []

        for device in devices {
            let raw = wideTan / comparableFOV(device)
            let zoom: Double

            switch device.deviceType {
            case .builtInWideAngleCamera:
                zoom = 1
            case .builtInUltraWideCamera:
                zoom = 0.5
            default:
                // Telephoto: whole numbers (2x, 3x, 4x, 5x).
                zoom = max(2, (raw + 0.25).rounded(.down))
            }

            print("STILLARC LENS: \(device.localizedName) measured \(raw)x, labelled \(zoom)x")

            options.append(
                LensOption(deviceID: device.uniqueID, crop: 1, zoom: zoom)
            )

            if device.deviceType != .builtInUltraWideCamera,
               device.maxAvailableVideoZoomFactor >= 2 {
                let total = zoom * 2
                let exists = options.contains { abs($0.zoom - total) < 0.1 }

                if exists == false {
                    options.append(
                        LensOption(deviceID: device.uniqueID, crop: 2, zoom: total)
                    )
                }
            }
        }

        // Drop a crop stop when a real lens already sits at that zoom.
        var seen = Set<Double>()
        let unique = options
            .sorted { first, second in
                first.zoom == second.zoom
                    ? first.crop < second.crop
                    : first.zoom < second.zoom
            }
            .filter { seen.insert($0.zoom).inserted }

        cachedLensOptions = unique
        return unique
    }

    private func publishLenses(reapplyControls: Bool = false) {
        let handler = onLenses

        guard position == .back else {
            lensZoom = 1
            lensCrop = 1

            Task { @MainActor in handler?([], nil, reapplyControls) }
            return
        }

        let options = lensOptions()
        let deviceID = videoDevice?.uniqueID

        let current: LensOption?

        if let choice = lensChoice,
           (choice.deviceID == deviceID || videoDevice?.isVirtualDevice == true),
           options.contains(choice) {
            current = choice
        } else {
            current = options.first {
                videoDevice?.isVirtualDevice == true ? $0.zoom == 1 : ($0.deviceID == deviceID && $0.crop == 1)
            }
        }

        lensZoom = current?.zoom ?? 1
        lensCrop = current?.crop ?? 1

        let currentID = current?.id

        Task { @MainActor in
            handler?(options, currentID, reapplyControls)
        }
    }

    // MARK: - Framing

    func updateFraming(focal: Double, rangefinder: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            self.framingFocal = focal
            self.framingRangefinder = rangefinder
            self.applyFraming()
        }
    }

    // Zoom as a multiplier of the 24 mm view. Cancels any zoom ramp.
    func setZoom(multiplier: Double) {
        queue.async { [weak self] in
            guard let self else { return }

            self.framingZoom = multiplier

            self.applyFraming(animated: true)
        }
    }

    // A zoom that takes a set time, at a steady speed. Works while recording.
    func rampZoom(to multiplier: Double, seconds: Double) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.framingZoom = multiplier
            let target = self.zoomFactor(on: device, multiplier: multiplier)
            self.lock(device) {
                let current = max(device.videoZoomFactor, 0.01)
                let octaves = abs(log2(Double(target / current)))

                guard octaves > 0.001 else { return }

                let rate = Float(max(octaves / max(seconds, 0.2), 0.02))
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            }
        }
    }

    func setStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        queue.async { [weak self] in
            guard let self else { return }

            self.videoStabilization = mode

            for output in self.session.outputs {
                guard output is AVCaptureMovieFileOutput
                        || output === self.writerVideoOutput,
                      let connection = output.connection(with: .video),
                      connection.isVideoStabilizationSupported else {
                    continue
                }

                connection.preferredVideoStabilizationMode = self.supported(mode)
            }
        }
    }

    // Falls back to automatic when the current format cannot do the mode.
    private func supported(_ mode: AVCaptureVideoStabilizationMode) -> AVCaptureVideoStabilizationMode {
        guard let device = videoDevice,
              device.activeFormat.isVideoStabilizationModeSupported(mode) else {
            return .auto
        }

        return mode
    }

    // MARK: - Exposure

    func setExposureBias(_ bias: Float) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.lock(device) {
                let clamped = min(
                    max(bias, device.minExposureTargetBias),
                    device.maxExposureTargetBias
                )

                guard device.isExposureModeSupported(.continuousAutoExposure) else {
                    return
                }

                // Bias only works in an auto mode. A locked or custom
                // exposure left behind would ignore the slider.
                if device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }

                device.setExposureTargetBias(clamped)
            }
        }
    }

    func setManualExposure(
        enabled: Bool,
        iso: Float,
        shutter: Double,
        bias: Float
    ) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.lock(device) {
                if enabled {
                    guard device.isExposureModeSupported(.custom) else {
                        self.emit(.message("Manual exposure is not supported by this camera."))
                        return
                    }

                    let format = device.activeFormat

                    let minimumShutter = max(
                        format.minExposureDuration.seconds,
                        0.0001
                    )

                    let maximumShutter = max(
                        format.maxExposureDuration.seconds,
                        minimumShutter
                    )

                    let seconds = min(
                        max(shutter, minimumShutter),
                        maximumShutter
                    )

                    let clampedISO = min(
                        max(iso, format.minISO),
                        format.maxISO
                    )

                    let duration = CMTime(
                        seconds: seconds,
                        preferredTimescale: 1_000_000
                    )

                    device.setExposureModeCustom(
                        duration: duration,
                        iso: clampedISO
                    ) { [weak self, weak device] _ in
                        guard let self, let device else { return }

                        self.emit(
                            .exposureSample(
                                iso: device.iso,
                                shutter: device.exposureDuration.seconds
                            )
                        )
                    }

                } else {
                    guard device.isExposureModeSupported(.continuousAutoExposure) else {
                        return
                    }

                    device.exposureMode = .continuousAutoExposure

                    let clamped = min(
                        max(bias, device.minExposureTargetBias),
                        device.maxExposureTargetBias
                    )

                    device.setExposureTargetBias(clamped)
                }
            }
        }
    }

    // MARK: - White Balance

    func setWhiteBalance(locked: Bool, temperature: Float, holdCurrent: Bool = false) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.lock(device) {
                if locked, holdCurrent {
                    // Freezing AWB is supported independently of assigning
                    // custom Kelvin gains, notably on virtual multi-cameras.
                    guard device.isWhiteBalanceModeSupported(.locked) else { return }
                    device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains)
                    #if DEBUG
                    NSLog("WB_HOLD_VERIFY locked=%d customGains=%d", device.whiteBalanceMode == .locked ? 1 : 0, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported ? 1 : 0)
                    #endif
                    return
                }
                if locked {
                    guard device.isWhiteBalanceModeSupported(.locked),
                          device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                        self.emit(.message("Custom white balance is not supported by this camera."))
                        return
                    }

                    let safeTemperature = min(
                        max(temperature, 2500),
                        10000
                    )

                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: safeTemperature,
                        tint: 0
                    )

                    let convertedGains = device.deviceWhiteBalanceGains(for: values)
                    let maximumGain = device.maxWhiteBalanceGain

                    var gains = convertedGains

                    gains.redGain = min(max(gains.redGain, 1), maximumGain)
                    gains.greenGain = min(max(gains.greenGain, 1), maximumGain)
                    gains.blueGain = min(max(gains.blueGain, 1), maximumGain)

                    device.setWhiteBalanceModeLocked(with: gains)

                } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        }
    }

    // MARK: - Focus

    func setLensPosition(_ position: Float) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            guard device.isFocusModeSupported(.locked),
                  device.isLockingFocusWithCustomLensPositionSupported else {
                self.emit(.message("Manual focus is not supported by this camera."))
                return
            }

            self.focusMeasurementID = UUID()
            self.focusLocked = true

            self.lock(device) {
                let safePosition = min(max(position, 0), 1)
                device.setFocusModeLocked(lensPosition: safePosition)
            }
        }
    }

    // Measure one point without moving exposure. Stop autofocus after settling,
    // and return the actual hardware lens position rather than a guessed delay.
    func measureFocus(at point: CGPoint, viewSize: CGSize? = nil, reel: Bool = false) async -> Float? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let device = self.videoDevice,
                      device.isLockingFocusWithCustomLensPositionSupported,
                      device.isFocusPointOfInterestSupported,
                      device.isFocusModeSupported(.autoFocus) else { continuation.resume(returning: nil); return }
                var devicePoint = point
                if self.position == .front,let layer=self.nativePreviewLayer,layer.bounds.width>0,layer.bounds.height>0 {
                    devicePoint=layer.captureDevicePointConverted(fromLayerPoint:CGPoint(x:point.x*layer.bounds.width,y:point.y*layer.bounds.height))
                } else if let viewSize, viewSize.width > 0, viewSize.height > 0 {
                    let angle = self.captureAngle()
                    let dimensions = device.activeFormat.formatDescription.dimensions
                    let landscape = angle == 0 || angle == 180
                    let sourceRatio = landscape ? CGFloat(max(dimensions.width, dimensions.height)) / CGFloat(min(dimensions.width, dimensions.height)) : CGFloat(min(dimensions.width, dimensions.height)) / CGFloat(max(dimensions.width, dimensions.height))
                    let feedRatio: CGFloat = reel ? 9.0 / 16 : sourceRatio
                    let viewRatio = viewSize.width / viewSize.height
                    let visibleW = min(1, viewRatio / feedRatio), visibleH = min(1, feedRatio / viewRatio)
                    let feed = CGPoint(x: (1 - visibleW) / 2 + point.x * visibleW, y: (1 - visibleH) / 2 + point.y * visibleH)
                    let crop = ReelGeometry.crop(in: CGRect(x: 0, y: 0, width: sourceRatio, height: 1), ratio: feedRatio, center: reel ? self.reelTrackingState.current : CGPoint(x: 0.5, y: 0.5))
                    var x = (crop.minX + feed.x * crop.width) / sourceRatio
                    let y = crop.minY + feed.y * crop.height
                    if self.frontMirrored { x = 1 - x }
                    switch angle {
                    case 0: devicePoint = CGPoint(x: x, y: y)
                    case 180: devicePoint = CGPoint(x: 1 - x, y: 1 - y)
                    case 270: devicePoint = CGPoint(x: 1 - y, y: x)
                    default: devicePoint = CGPoint(x: y, y: 1 - x)
                    }
                }
                self.lock(device) { device.focusPointOfInterest = devicePoint; device.focusMode = .autoFocus }
                let measurement = UUID(); self.focusMeasurementID = measurement
                self.waitForFocus(device, token: measurement, attempts: 0, completion: { continuation.resume(returning: $0) })
            }
        }
    }
    private func waitForFocus(_ device: AVCaptureDevice, token: UUID, attempts: Int, completion: @escaping @Sendable (Float?) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.videoDevice === device, self.focusMeasurementID == token else { completion(nil); return }
            if attempts >= 20 { completion(nil); return }
            if attempts < 2 || device.isAdjustingFocus { self.waitForFocus(device, token: token, attempts: attempts + 1, completion: completion); return }
            let position = device.lensPosition
            self.focusLocked = true
            self.lock(device) { device.setFocusModeLocked(lensPosition: position, completionHandler: nil) }
            completion(position)
        }
    }

    func focusFrontPreview(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, self.position == .front, let layer=self.nativePreviewLayer,
                  layer.bounds.width>0,layer.bounds.height>0 else {return}
            let p=CGPoint(x:point.x*layer.bounds.width,y:point.y*layer.bounds.height)
            self.focus(at:layer.captureDevicePointConverted(fromLayerPoint:p))
        }
    }

    func focus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.focusMeasurementID = UUID()
            self.focusLocked = false

            self.lock(device) {
                let safePoint = CGPoint(
                    x: min(max(point.x, 0), 1),
                    y: min(max(point.y, 0), 1)
                )

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = safePoint

                    // Keeps refocusing at that point instead of locking.
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }

                // Leave exposure alone when ISO or shutter is set by hand.
                if self.ctlISOAuto, self.ctlShutterAuto,
                   device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = safePoint

                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
            }
        }
    }

    // Meters and focuses at a point, then holds both.
    func lockExposureFocus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.focusLocked = true

            let safePoint = CGPoint(
                x: min(max(point.x, 0), 1),
                y: min(max(point.y, 0), 1)
            )

            self.lock(device) {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = safePoint

                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = safePoint

                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
            }

            // Hold both once the camera has settled on the spot.
            self.queue.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.focusLocked,
                      let device = self.videoDevice else { return }

                self.lock(device) {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }

                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                }
            }
        }
    }

    // MARK: - Torch / Flashlight

    func setTorch(enabled: Bool, level: Float = 1) {
        queue.async { [weak self] in
            guard let self else { return }
            self.torchRequested = enabled
            self.torchLevel = min(max(level, 0.01), 1)
            self.applyTorch(reportFailure: enabled)
            self.retryRequestedTorch()
        }
    }

    private func retryRequestedTorch() {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.torchRequested, self.session.isRunning else { return }
            self.applyTorch()
        }
    }

    private func applyTorch(reportFailure: Bool = false) {
        guard let device = videoDevice, device.hasTorch else { return }
        if torchRequested && (!device.isTorchAvailable || !device.isTorchModeSupported(.on)) {
            if reportFailure { emit(.message("The flashlight is unavailable on this camera.")) }
            return
        }
        lock(device) {
            if torchRequested {
                do { try device.setTorchModeOn(level: torchLevel) }
                catch { if reportFailure { emit(.message("Could not turn on the flashlight.")) } }
            } else if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
        }
    }

    private func prepareDepthFormat() {
        guard let device = videoDevice else { return }
        if device.activeFormat.supportedDepthDataFormats.isEmpty,
           let format = device.formats.filter({ !$0.supportedDepthDataFormats.isEmpty && $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) }).max(by: {
               let a = $0.formatDescription.dimensions, b = $1.formatDescription.dimensions
               return a.width * a.height < b.width * b.height
           }) {
            lock(device) { device.activeFormat = format }
        }
        if let depth = device.activeFormat.supportedDepthDataFormats.max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }) {
            lock(device) { device.activeDepthDataFormat = depth }
        }
        photoOutput.isZeroShutterLagEnabled = false
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = false }
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) { photoOutput.maxPhotoDimensions = largest }
    }

    func configurePhotoCompanions(live: Bool, depth: Bool, natural: Bool = false) {
        queue.async { [weak self] in
            guard let self, self.photoDelegates.isEmpty, !self.movieOutput.isRecording, self.currentLiveWriter() == nil else { return }
            self.requestedPhotoLive = live; self.requestedPhotoDepth = depth; self.requestedNaturalRaw = natural
            if depth, self.position == .front, self.videoDevice?.deviceType != .builtInTrueDepthCamera {
                self.rebuildSingle(); return
            }
            self.session.beginConfiguration()
            if self.photoOutput.isAppleProRAWSupported { self.photoOutput.isAppleProRAWEnabled = !natural && !depth && !live }
            if depth, self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
            if depth { self.prepareDepthFormat() }
            else {
                if self.photoOutput.isZeroShutterLagSupported { self.photoOutput.isZeroShutterLagEnabled = true }
                if self.photoOutput.isFastCapturePrioritizationSupported { self.photoOutput.isFastCapturePrioritizationEnabled = true }
            }
            if live, self.session.outputs.contains(self.movieOutput) { self.session.removeOutput(self.movieOutput) }
            self.photoOutput.isLivePhotoCaptureEnabled = live && self.photoOutput.isLivePhotoCaptureSupported
            self.photoOutput.isDepthDataDeliveryEnabled = depth && self.photoOutput.isDepthDataDeliverySupported
            if !live, !self.session.outputs.contains(self.movieOutput), self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            self.session.commitConfiguration()
            self.publishCaps()
            if live && !self.photoOutput.isLivePhotoCaptureEnabled { self.emit(.message("Live Photos aren’t available on this camera configuration.")) }
            if depth && !self.photoOutput.isDepthDataDeliveryEnabled { self.emit(.message("Depth portraits aren’t available on this lens.")) }
        }
    }

    // MARK: - Photo Capture

    // The session queue owns the capture ID; the analysis queue owns the frames.
    private var motionExposureID: UUID?
    private var motionAccumulator: MotionExposureAccumulator?

    func captureMotionExposure(id: UUID, mode: MotionExposure, seconds: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, self.motionExposureID == nil, !self.movieOutput.isRecording,
                  self.currentLiveWriter() == nil else {
                self.emit(.photo(id: id, processed: nil, raw: nil))
                return
            }
            self.motionExposureID = id
            self.syncAnalysisOutput()
            guard self.session.outputs.contains(self.analysisOutput) else {
                self.motionExposureID = nil
                self.emit(.photo(id: id, processed: nil, raw: nil))
                return
            }
            let angle = self.captureAngle()
            let orientation: CGImagePropertyOrientation = angle == 0 ? .left : angle == 180 ? .right : angle == 270 ? .down : .up
            let mirrored = self.frontMirrored
            self.analysisQueue.async { [weak self] in
                guard let self else { return }
                self.motionAccumulator = MotionExposureAccumulator(id: id, mode: mode, orientation: orientation)
                self.analysisQueue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                    self?.finishMotionExposure(id: id, cancelled: false)
                }
                self.mirrorMotionExposure = mirrored
            }
        }
    }

    private var mirrorMotionExposure = false

    private func finishMotionExposure(id: UUID, cancelled: Bool) {
        guard let accumulator = motionAccumulator, accumulator.id == id else { return }
        motionAccumulator = nil
        let data = cancelled ? nil : accumulator.finish(context: PhotoDeveloper.context)
        queue.async { [weak self] in
            guard let self, self.motionExposureID == id else { return }
            self.motionExposureID = nil
            self.syncAnalysisOutput()
            #if DEBUG
            if self.motionVerificationIDs.remove(id) != nil {
                let size = data.flatMap { CIImage(data: $0)?.extent.size }
                NSLog("MOTION_EXPOSURE_VERIFY %@ size=%@", size == nil ? "FAIL" : "PASS", String(describing: size))
                return
            }
            #endif
            self.emit(.photo(id: id, processed: data, raw: nil))
        }
    }

    #if DEBUG
    private var motionVerificationIDs: Set<UUID> = []
    func verifyMotionExposure() {
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self, self.session.isRunning else {
                NSLog("MOTION_EXPOSURE_VERIFY FAIL camera unavailable")
                return
            }
            for (index, effect) in [MotionExposure.blur, .trails].enumerated() {
                self.queue.asyncAfter(deadline: .now() + .seconds(index * 3)) { [weak self] in
                    guard let self else { return }
                    let id = UUID()
                    self.motionVerificationIDs.insert(id)
                    self.captureMotionExposure(id: id, mode: effect, seconds: 1)
                }
            }
        }
    }
    #endif

    #if DEBUG
    func verifyActivateLog(_ profile: LogProfile) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let device = self.videoDevice,
                      device.formats.contains(where:{ $0.supportedColorSpaces.contains(self.colorSpace(for:profile)) }) else { continuation.resume(returning:false); return }
                continuation.resume(returning:self.applyLog(profile))
            }
        }
    }
    private var photoCombinationChecks: [UUID: String] = [:]
    private var presetPhotoChecks: [UUID: CheckedContinuation<Bool,Never>] = [:]
    private var frontPhotoGeometry=[[String:Int]]()
    func verifyPresetPhoto(raw: Bool, flash: FlashChoice, format: PhotoFormat, nativeRaw: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.session.isRunning else { continuation.resume(returning:false); return }
                let id = UUID(); self.presetPhotoChecks[id] = continuation
                self.capturePhoto(raw:raw,flash:flash,format:format,id:id,nativeRaw:nativeRaw)
                self.queue.asyncAfter(deadline:.now()+20) { [weak self] in self?.presetPhotoChecks.removeValue(forKey:id)?.resume(returning:false) }
            }
        }
    }

    func verifyFrontCamera() async {
        let original: (AVCaptureDevice.Position, CGFloat, Bool) = await withCheckedContinuation { c in
            queue.async { [self] in
                let saved=(position,deviceAngle,frontMirrorLock.withLock {frontMirrorEnabled})
                position = .front;rebuildSingle()
                session.beginConfiguration();addAnalysisOutput(force:true);rotateConnections();session.commitConfiguration()
                c.resume(returning:saved)
            }
        }
        var checks=[[String:Double]](),photos=[Bool]()
        for mirrored in [false,true] {
            for angle:CGFloat in [0,180,270,90] {
                let values:[String:Double] = await withCheckedContinuation { c in
                    queue.async { [self] in
                        frontMirrorLock.withLock {frontMirrorEnabled=mirrored};deviceAngle=angle;rotateConnections()
                        let analysis=analysisOutput.connection(with:.video),photo=photoOutput.connection(with:.video),movie=movieOutput.connection(with:.video),preview=nativePreviewLayer?.connection
                        var expected=angle,portrait:CGFloat=90
                        if #available(iOS 27.0,*),let coordinator=frontRotationCoordinator {
                            let orientation:AVCaptureVideoOrientation=angle==0 ? .landscapeRight:angle==180 ? .landscapeLeft:angle==270 ? .portraitUpsideDown:.portrait
                            expected=coordinator.videoRotationAngleRelative(toDeviceOrientation:orientation);portrait=coordinator.videoRotationAngleRelative(toDeviceOrientation:.portrait)
                        }
                        let pass=videoDevice?.position == .front && analysis != nil && photo != nil && preview != nil && abs((analysis?.videoRotationAngle ?? -999)-portrait)<0.01 && abs((photo?.videoRotationAngle ?? -999)-expected)<0.01 && abs((preview?.videoRotationAngle ?? -999)-portrait)<0.01 && analysis?.isVideoMirrored == false && photo?.isVideoMirrored == mirrored && preview?.isVideoMirrored == mirrored
                        c.resume(returning:["desiredAngle":Double(angle),"mirror":mirrored ? 1:0,"photoAngle":Double(photo?.videoRotationAngle ?? -1),"movieAngle":Double(movie?.videoRotationAngle ?? -1),"previewAngle":Double(preview?.videoRotationAngle ?? -1),"analysisAngle":Double(analysis?.videoRotationAngle ?? -1),"expectedCaptureAngle":Double(expected),"expectedPortraitAngle":Double(portrait),"passed":pass ? 1:0])
                    }
                }
                checks.append(values);try? await Task.sleep(for:.milliseconds(200))
            }
            photos.append(await verifyPresetPhoto(raw:false,flash:.off,format:.jpeg,nativeRaw:false))
        }
        await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in
            queue.async { [self] in frontMirrorLock.withLock {frontMirrorEnabled=original.2};deviceAngle=original.1;position=original.0;rebuildSingle();c.resume() }
        }
        let geometry:[[String:Int]] = await withCheckedContinuation {c in queue.async { [self] in c.resume(returning:frontPhotoGeometry)}}
        let result:[String:Any]=["photoGeometry":geometry,"passed":geometry.count==2 && geometry.allSatisfy {($0["height"] ?? 0)>=($0["width"] ?? 1)} && checks.count==8 && checks.allSatisfy {$0["passed"]==1} && photos.allSatisfy {$0},"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "unknown","checks":checks,"frontPhotosDelivered":photos,"thermal":ProcessInfo.processInfo.thermalState.rawValue,"scope":"Native front camera semantic rotation and mirror routing at four orientations; JPEG capture in both mirror states. Captures are discarded, not saved to Photos."]
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("front-camera-verification.json")
        try? JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:url,options:.atomic)
    }

    func verifyPhotoCombinations() {
        for (index, check) in ["Depth", "Live + Depth", "ProRAW + HEIF"].enumerated() {
            queue.asyncAfter(deadline: .now() + .seconds(4 + index * 9)) { [weak self] in
                guard let self else { return }
                let live = index == 1
                self.configurePhotoCompanions(live: live, depth: index != 2)
                self.queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                    guard let self, self.session.isRunning else {
                        NSLog("CAPTURE_COMBINATION_VERIFY %@ camera unavailable", check)
                        return
                    }
                    let id = UUID()
                    self.photoCombinationChecks[id] = check
                    self.capturePhoto(raw: index == 2, flash: .off, format: .heif, id: id)
                }
            }
        }
    }
    #endif

    func capturePhoto(raw: Bool, flash: FlashChoice, format: PhotoFormat, id: UUID = UUID(), nativeRaw: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }

            self.synchronizePhotoDimensions()
            let settings = self.makePhotoSettings(
                raw: raw,
                flash: flash,
                format: format, nativeRaw: nativeRaw
            )

            if self.photoOutput.isLivePhotoCaptureEnabled, !self.photoOutput.isLivePhotoCaptureSuspended {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Live-\(id.uuidString).mov")
            }
            if self.requestedPhotoDepth, self.photoOutput.isDepthDataDeliverySupported, !self.photoOutput.isDepthDataDeliveryEnabled { self.photoOutput.isDepthDataDeliveryEnabled = true }
            if self.photoOutput.isDepthDataDeliveryEnabled && self.requestedPhotoDepth {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = true
            }
            if settings.rawPhotoPixelFormatType == 0 {
                let desired: AVCapturePhotoOutput.QualityPrioritization = settings.isDepthDataDeliveryEnabled ? .quality : .balanced
                settings.photoQualityPrioritization = desired.rawValue <= self.photoOutput.maxPhotoQualityPrioritization.rawValue ? desired : self.photoOutput.maxPhotoQualityPrioritization
            }

            let angle = self.captureAngle()

            if let connection = self.photoOutput.connection(with: .video) {
                self.orient(connection, uprightAngle: angle)
            }

            #if DEBUG
            if self.requestedPhotoDepth { NSLog("DEPTH_REQUEST supported=%d enabled=%d requested=%d camera=%@", self.photoOutput.isDepthDataDeliverySupported ? 1 : 0, self.photoOutput.isDepthDataDeliveryEnabled ? 1 : 0, settings.isDepthDataDeliveryEnabled ? 1 : 0, self.videoDevice?.localizedName ?? "none") }
            #endif
            let uniqueID = settings.uniqueID
            let delegate = PhotoShotDelegate { [weak self] processed, raw, companion in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.photoDelegates[uniqueID] = nil
                    #if DEBUG
                    if let continuation = self.presetPhotoChecks.removeValue(forKey:id) {
                        if ProcessInfo.processInfo.arguments.contains("--verify-front-camera"),let data=processed,let source=CGImageSourceCreateWithData(data as CFData,nil),let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:256] as CFDictionary) {
                            self.frontPhotoGeometry.append(["width":thumbnail.width,"height":thumbnail.height,"mirrored":self.frontMirrored ? 1:0])
                        }
                        if let movie = companion.liveMovie { try? FileManager.default.removeItem(at:movie) }
                        NSLog("PRESET_CAPTURE_RESULT processed=%d raw=%d depth=%d",processed == nil ? 0 : 1,raw == nil ? 0 : 1,companion.depth == nil ? 0 : 1)
                        continuation.resume(returning:processed != nil)
                        return
                    }
                    if let check = self.photoCombinationChecks.removeValue(forKey: id) {
                        let hdr = processed.flatMap(HDRPhoto.expanded) != nil
                        NSLog("CAPTURE_COMBINATION_VERIFY %@ processed=%d raw=%d depth=%d live=%d hdr=%d",
                            check, processed == nil ? 0 : 1, raw == nil ? 0 : 1, companion.depth == nil ? 0 : 1,
                            companion.liveMovie == nil ? 0 : 1, hdr ? 1 : 0)
                        if check == "ProRAW + HEIF", hdr, let processed {
                            Task.detached(priority: .utility) {
                                let request = StillComposer.Request(focalScale: 0.8, aspectRatio: 1, saveTarget: "BOTH",
                                    style: StyleParams(saturation: 0.95), preserveHDR: true)
                                let result = StillComposer.compose(imageData: processed, request: request)
                                NSLog("HDR_CAPTURE_VERIFY crop=%d graded=%d gradedCrop=%d",
                                    result.cropJPEG.flatMap(HDRPhoto.expanded) == nil ? 0 : 1,
                                    result.gradedFull.flatMap(HDRPhoto.expanded) == nil ? 0 : 1,
                                    result.gradedCrop.flatMap(HDRPhoto.expanded) == nil ? 0 : 1)
                            }
                        }
                        if let movie = companion.liveMovie { try? FileManager.default.removeItem(at: movie) }
                        return
                    }
                    #endif
                    self.emit(.photo(id: id, processed: processed, raw: raw, companion: companion))
                    if self.photoDelegates.isEmpty, self.stopAfterPhotos, !self.sessionWanted {
                        self.stopAfterPhotos = false
                        self.stop()
                    }
                }
            }
            self.photoDelegates[uniqueID] = delegate
            if let reason = PhotoCaptureGuard.submit(output:self.photoOutput,settings:settings,delegate:delegate) {
                self.photoDelegates[uniqueID] = nil
                if let movie = settings.livePhotoMovieFileURL { try? FileManager.default.removeItem(at:movie) }
                NSLog("PHOTO_REQUEST_REJECTED %@ raw=%u dimensions=%dx%d maxQuality=%ld quality=%ld",reason,settings.rawPhotoPixelFormatType,settings.maxPhotoDimensions.width,settings.maxPhotoDimensions.height,self.photoOutput.maxPhotoQualityPrioritization.rawValue,settings.photoQualityPrioritization.rawValue)
                #if DEBUG
                if let continuation = self.presetPhotoChecks.removeValue(forKey:id) { continuation.resume(returning:false); return }
                #endif
                self.emit(.photo(id:id,processed:nil,raw:nil,companion:PhotoCompanion()))
            }
        }
    }

    // MARK: - Recording Codec Discovery

    func discoverRecordingCodecs(
        log: LogProfile,
        dual: Bool,
        settings: RecordingSettings = RecordingSettings(),
        preferredCodec: RecordingCodec? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.movieOutput.isRecording || self.currentLiveWriter() != nil {
                return
            }

            // A restored video setup already has its requested preview format.
            // Reuse its codecs instead of cycling pixel formats on screen.
            if let device = self.videoDevice, let preferredCodec,
               self.previewVideo, self.previewLog == log,
               self.previewSettings?.resolution == settings.resolution,
               self.previewSettings?.frameRate == settings.frameRate,
               self.matchesResolution(settings.resolution, format: device.activeFormat),
               (log == .off || device.activeColorSpace == self.colorSpace(for: log)),
               self.applyRequestedFrameRate(settings.frameRate ?? 30, to: device) {
                let subtype = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
                let group: FormatGroup = subtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? .tenBit422
                    : subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? .tenBit420 : .eightBit420
                let probe = FormatProbe(group: group, format: device.activeFormat, codecs: self.safeCodecs(from: self.movieOutput))
                let codecs = self.unionCodecs([probe], log: log)
                if codecs.contains(preferredCodec) {
                    self.cachedProbes = [probe]
                    self.cachedProbeKey = self.probeKey(log: log, settings: settings)
                    self.publishVideoOptions(log: log)
                    self.publishCodecs(codecs)
                    return
                }
            }

            if self.videoDevice != nil, log == .off, !self.usesCustomFormat(log: log, settings: settings) {
                self.publishVideoOptions(log: log)
                self.publishCodecs(self.safeCodecs(from: self.movieOutput))
                return
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            // Dual Shot exports two crops of a single camera recording.
            // Probe that same camera instead of switching to MultiCam.
            self.rebuildSingle(commitRestart: false)
            self.dualActive = false

            guard self.videoDevice != nil else {
                self.publishCodecs([])
                self.restorePhotoSession()
                return
            }

            // Custom path: Log, or an explicit resolution / frame rate.
            if self.dualActive == false,
               self.usesCustomFormat(log: log, settings: settings) {

                let probes = self.probeFormats(log: log, settings: settings)
                let union = self.unionCodecs(probes, log: log)

                self.cachedProbes = probes
                self.cachedProbeKey = self.probeKey(log: log, settings: settings)

                if union.isEmpty == false {
                    print("""
                    STILLARC DISCOVERED RECORDING CODECS (custom format):
                    \(union.map { "\($0.title) [\($0.rawValue)]" })
                    """)

                    self.publishVideoOptions(log: log)
                    self.publishCodecs(union)
                    self.restorePhotoSession()
                    return
                }

                print("STILLARC: no codec found for the requested format; using the default format.")

                self.rebuildSingle(commitRestart: false)
                self.dualActive = false
            }

            guard self.applyLog(log) else {
                self.publishVideoOptions(log: log)
                self.publishCodecs([])
                self.restorePhotoSession()
                return
            }

            if self.session.isRunning == false {
                self.session.startRunning()
            }

            let primary = self.safeCodecs(from: self.movieOutput)

            let available: [RecordingCodec]

            if self.dualActive {
                let secondary = self.safeCodecs(from: self.storiesOutput)
                let secondaryIDs = Set(secondary.map(\.rawValue))
                available = primary.filter {
                    secondaryIDs.contains($0.rawValue)
                }
            } else {
                available = primary
            }

            print("""
            STILLARC DISCOVERED RECORDING CODECS:
            \(available.map { "\($0.title) [\($0.rawValue)]" })
            """)

            self.publishVideoOptions(log: log)
            self.publishCodecs(available)
            self.restorePhotoSession()
        }
    }

    private func safeCodecs(
        from output: AVCaptureMovieFileOutput
    ) -> [RecordingCodec] {
        output.availableVideoCodecTypes
            .map(RecordingCodec.init)
            .filter { codec in
                let value = codec.rawValue.lowercased()

                // ProRes RAW is intentionally excluded.
                return !value.contains("raw")
                    && value != "braw"
                    && value != "brhq"
            }
            .sorted { first, second in
                self.codecPriority(first) < self.codecPriority(second)
            }
    }

    private func codecPriority(_ codec: RecordingCodec) -> Int {
        switch codec.rawValue {
        case "hvc1", "hev1": return 0
        case "avc1": return 1
        case "apch": return 2
        case "apcn": return 3
        case "apcs": return 4
        case "apco": return 5
        default: return 6
        }
    }

    private func publishCodecs(_ codecs: [RecordingCodec]) {
        let handler = onCodecs

        Task { @MainActor in
            handler?(codecs)
        }
    }

    // MARK: - Recording

    func startRecording(
        log: LogProfile,
        dual: Bool,
        codec: RecordingCodec? = nil,
        settings: RecordingSettings = RecordingSettings(),
        recordingID: UUID? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.movieOutput.isRecording
                || self.currentWriter() != nil
                || self.currentLiveWriter() != nil
                || self.currentTimelapse() != nil { return }

            self.activeRecordingID = recordingID

            // Standard video from the running preview starts at once, with
            // no session restart.
            let custom = self.usesCustomFormat(log: log, settings: settings)
            let key = self.probeKey(log: log, settings: settings)

            // The preview already runs in the recording format.
            let previewMatches = self.previewVideo
                && self.previewLog == log
                && self.previewSettings?.resolution == settings.resolution
                && self.previewSettings?.frameRate == settings.frameRate

            // Dual shot cuts a horizontal and a vertical file from this one
            // recording afterwards. It needs no second camera and no session
            // restart, so it starts in place like any other video.
            let wantsDual = dual && self.position == .back

            let inPlace = self.dualActive == false
                && self.session.isRunning
                && self.videoDevice != nil
                && self.movieOutput.connection(with: .video) != nil
                && (custom
                    ? (previewMatches
                        && self.cachedProbeKey == key
                        && self.cachedProbes.isEmpty == false)
                    : log == .off)

            self.skipRestore = inPlace

            if inPlace {
                self.exportStories = wantsDual
            } else {
                if self.session.isRunning {
                    self.session.stopRunning()
                }

                self.rebuildSingle(commitRestart: false)
                self.dualActive = false
                self.exportStories = wantsDual
            }

            guard self.videoDevice != nil else {
                self.emit(.message("No camera is available for recording."))
                self.emit(.recording(false))
                return
            }

            var availableForRecording: [RecordingCodec] = []
            var probes: [FormatProbe] = []
            var customApplied = false

            if self.dualActive == false,
               self.usesCustomFormat(log: log, settings: settings) {

                probes = inPlace
                    ? self.cachedProbes
                    : self.probeFormats(log: log, settings: settings)

                if inPlace == false {
                    self.cachedProbes = probes
                    self.cachedProbeKey = key
                }

                let union = self.unionCodecs(probes, log: log)

                if union.isEmpty {
                    self.emit(.message(
                        "Those video settings are not available together on this camera. Using the default format."
                    ))

                    // Start again from the proven default configuration.
                    self.rebuildSingle(commitRestart: false)
                    self.dualActive = false
                    probes = []
                } else {
                    customApplied = true
                    availableForRecording = union
                }
            }

            if customApplied == false {
                guard self.applyLog(log) else {
                    self.restorePhotoSession()
                    self.emit(.recording(false))
                    return
                }

                self.applyFraming()

                if self.session.isRunning == false {
                    self.session.startRunning()
                }

                let available = self.safeCodecs(from: self.movieOutput)

                if self.dualActive {
                    let secondary = self.safeCodecs(from: self.storiesOutput)
                    let secondaryIDs = Set(secondary.map(\.rawValue))

                    availableForRecording = available.filter {
                        secondaryIDs.contains($0.rawValue)
                    }
                } else {
                    availableForRecording = available
                }
            }

            self.publishCodecs(availableForRecording)

            let selectedCodec: RecordingCodec?

            if let codec {
                selectedCodec = availableForRecording.first {
                    $0.rawValue == codec.rawValue
                }

                guard selectedCodec != nil else {
                    self.emit(.message(
                        "\(codec.title) is not available with the current camera format."
                    ))
                    self.restorePhotoSession()
                    self.emit(.recording(false))
                    return
                }
            } else {
                selectedCodec = availableForRecording.first
            }

            guard let selectedCodec else {
                self.emit(.message(
                    "This camera format does not provide a supported video recording codec."
                ))
                self.restorePhotoSession()
                self.emit(.recording(false))
                return
            }

            // Make sure the camera is on a format that supports the chosen codec.
            if customApplied {
                let writerCodec = log != .off && selectedCodec.isProRes == false

                let matched = probes.first { candidate in
                    candidate.codecs.contains { $0.rawValue == selectedCodec.rawValue }
                } ?? (writerCodec ? probes.first : nil)

                guard let probe = matched else {
                    self.emit(.message(
                        "\(selectedCodec.title) is not available with the current camera format."
                    ))
                    self.restorePhotoSession()
                    self.emit(.recording(false))
                    return
                }

                if self.videoDevice?.activeFormat !== probe.format {
                    let ready = self.activate(
                        probe.format,
                        fps: settings.frameRate,
                        colorSpace: self.colorSpace(for: log),
                        log: log
                    )

                    guard ready else {
                        self.emit(.message("Could not switch the camera to that format."))
                        self.restorePhotoSession()
                        self.emit(.recording(false))
                        return
                    }

                    if self.session.isRunning == false {
                        self.session.startRunning()
                    }

                    Thread.sleep(forTimeInterval: 0.15)
                }

                self.applyFraming()
            }

            if let device = self.videoDevice {
                _ = self.applyRequestedFrameRate(settings.frameRate ?? 30, to: device)
            }

            let bitrate = self.targetBitrate(
                settings.bitrate,
                codec: selectedCodec
            )

            if dual || self.videoCrop != nil || self.recordingCube != nil || !self.recordingStyle.isIdentity || (self.framingSnapshot().saveDesqueezed && self.framingSnapshot().anamorphic != .off) {
                if self.startLiveRecording(dual: dual, recordingID: recordingID, codec: selectedCodec, bitrate: bitrate) {
                    self.emit(.recording(true))
                } else {
                    self.emit(.message("Could not prepare live recording. No videos were saved."))
                    self.syncAnalysisOutput()
                    self.emit(.recording(false))
                }
                return
            }

            // Log with HEVC goes through the asset writer.
            if customApplied, log != .off, selectedCodec.isProRes == false {
                if self.startWriterRecording(codec: selectedCodec, bitrate: bitrate) {
                    self.applyTorch()
                    self.retryRequestedTorch()
                    self.emit(.recording(true))
                } else {
                    self.emit(.message("Could not start Log HEVC recording."))
                    self.restorePhotoSession()
                    self.emit(.recording(false))
                }

                return
            }

            guard self.prepareCodec(
                self.movieOutput,
                selected: selectedCodec,
                bitrate: bitrate
            ) else {
                self.emit(.message(
                    "Could not configure \(selectedCodec.title) for recording."
                ))
                self.restorePhotoSession()
                self.emit(.recording(false))
                return
            }

            if self.dualActive {
                guard self.prepareCodec(
                    self.storiesOutput,
                    selected: selectedCodec,
                    bitrate: bitrate
                ) else {
                    self.emit(.message(
                        "The secondary camera cannot use \(selectedCodec.title)."
                    ))
                    self.restorePhotoSession()
                    self.emit(.recording(false))
                    return
                }
            }

            self.finishedPrimary = false
            self.finishedSecondary = !self.dualActive

            self.primaryURL = self.makeURL(
                prefix: log == .off ? "Stillarc" : "Log"
            )

            self.secondaryURL = self.dualActive
                ? self.makeURL(prefix: "Stories")
                : nil

            guard let primaryURL = self.primaryURL else {
                self.restorePhotoSession()
                self.emit(.message("Could not create a recording file."))
                self.emit(.recording(false))
                return
            }

            if let device = self.videoDevice {
                let size = device.activeFormat.formatDescription.dimensions
                let frame = device.activeVideoMinFrameDuration

                print("""
                STILLARC RECORDING
                Codec: \(selectedCodec.title)
                Resolution: \(size.width)x\(size.height)
                Frame duration: \(frame.isValid ? frame.seconds : 0)
                Bitrate: \(bitrate.map { "\($0 / 1_000_000) Mbps" } ?? "default")
                """)
            }

            // Keep a small native analysis stream ready so HIST/scopes can
            // be turned on during hardware recording without reconfiguring it.
            if !self.dualActive && !self.session.outputs.contains(self.analysisOutput) {
                self.session.beginConfiguration()
                self.addAnalysisOutput(force: true)
                self.session.commitConfiguration()
            }
            self.rotateConnections()

            self.movieOutput.startRecording(
                to: primaryURL,
                recordingDelegate: self
            )

            if self.dualActive, let secondaryURL = self.secondaryURL {
                self.storiesOutput.startRecording(
                    to: secondaryURL,
                    recordingDelegate: self
                )
            }

            self.applyTorch()
            self.retryRequestedTorch()
            self.emit(.recording(true))
        }
    }

    func stopRecording() {
        queue.async { [weak self] in
            guard let self else { return }

            if self.currentLiveWriter() != nil {
                self.finishLiveRecording()
                return
            }

            if self.currentTimelapse() != nil {
                self.finishTimelapse()
                return
            }

            if self.currentWriter() != nil {
                self.finishWriterRecording()
                return
            }

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }

            if self.storiesOutput.isRecording {
                self.storiesOutput.stopRecording()
            }
        }
    }

    // MARK: - Movie Delegate

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let finishedOK = (error as NSError?)?
            .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)

        queue.async { [weak self] in
            guard let self else { return }

            if output === self.movieOutput {
                self.finishedPrimary = true

                if finishedOK == false {
                    self.primaryURL = nil
                }
            } else {
                self.finishedSecondary = true

                if finishedOK == false {
                    self.secondaryURL = nil
                }
            }

            guard self.finishedPrimary, self.finishedSecondary else {
                return
            }

            self.emit(.recording(false))
            self.finishMovies()
            self.syncAnalysisOutput()
        }
    }

    // MARK: - Session Setup

    private func startOnQueue() {
        guard !session.isInterrupted else { return }
        if needsSessionRebuild {
            guard currentLiveWriter() == nil, currentWriter() == nil, !movieOutput.isRecording else { return }
            needsSessionRebuild = false
            rebuildSingle()
        }
        startLiveTimer()

        if session.isRunning { return }

        #if targetEnvironment(simulator)
        emit(.caps(DeviceCaps()))
        return
        #else

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if let device = videoDevice, session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }) {
                // Resuming keeps the selected input, format, zoom and controls.
                session.startRunning()
                applyTorch()
                retryRequestedTorch()
            } else {
                rebuildSingle()
            }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.queue.async {
                    if granted {
                        self?.rebuildSingle()
                    } else {
                        self?.emit(.caps(DeviceCaps()))
                    }
                }
            }

        default:
            emit(.caps(DeviceCaps()))
        }

        #endif
    }

    private func rebuildSingle(commitRestart: Bool = true) {
        if session.isRunning {
            session.stopRunning()
        }

        session.automaticallyConfiguresCaptureDeviceForWideColor = true

        session.beginConfiguration()

        session.inputs.forEach {
            session.removeInput($0)
        }

        session.outputs.forEach {
            session.removeOutput($0)
        }

        dualActive = false

        guard let device = bestDevice(position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            videoDevice = nil
            session.commitConfiguration()
            emit(.caps(DeviceCaps()))
            return
        }

        videoDevice = device

        session.addInput(input)

        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality

            // Allow the largest photo size this camera format offers.
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
            }) {
                photoOutput.maxPhotoDimensions = largest
            }

            if photoOutput.isAppleProRAWSupported {
                photoOutput.isAppleProRAWEnabled = !requestedNaturalRaw && !requestedPhotoDepth && !requestedPhotoLive
            }

            // Shorter wait between tapping and capturing.
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = true
            }

            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
        }

        if !requestedPhotoLive, session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        photoOutput.isLivePhotoCaptureEnabled = requestedPhotoLive && photoOutput.isLivePhotoCaptureSupported
        if requestedPhotoDepth { prepareDepthFormat() }
        photoOutput.isDepthDataDeliveryEnabled = requestedPhotoDepth && photoOutput.isDepthDataDeliverySupported

        addAnalysisOutput()
        addAudioIfAllowed()
        if session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }), session.canAddOutput(writerAudioOutput) {
            writerAudioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(writerAudioOutput)
        }
        rotateConnections()

        session.commitConfiguration()

        if commitRestart {
            // Video mode previews in the recording format (flat in Log).
            if previewVideo, position == .back, dualActive == false {
                applyPreviewFormat()
            }

            lensZoom = position == .back ? (lensChoice?.zoom ?? 1) : 1
            lensCrop = position == .back ? (lensChoice?.crop ?? 1) : 1
            applyFraming()
            session.startRunning()
            applyTorch()
            retryRequestedTorch()
            rotateConnections()
            restoreFocus()
            publishOrientation()
            publishCaps()
            publishLenses(reapplyControls: true)

            let iso = device.iso
            let shutter = device.exposureDuration.seconds

            emit(.exposureSample(iso: iso, shutter: shutter))
        }
    }

    private func configureDual() -> Bool {
        guard let multi = session as? AVCaptureMultiCamSession,
              let back = bestDevice(position: .back, useChosenLens: false),
              let front = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .front
              ),
              let backInput = try? AVCaptureDeviceInput(device: back),
              let frontInput = try? AVCaptureDeviceInput(device: front) else {
            return false
        }

        session.beginConfiguration()

        session.inputs.forEach {
            session.removeInput($0)
        }

        session.outputs.forEach {
            session.removeOutput($0)
        }

        guard session.canAddInput(backInput),
              session.canAddInput(frontInput) else {
            session.commitConfiguration()
            return false
        }

        session.addInput(backInput)
        session.addInput(frontInput)

        guard session.canAddOutput(movieOutput),
              session.canAddOutput(storiesOutput) else {
            session.commitConfiguration()
            return false
        }

        session.addOutput(movieOutput)
        session.addOutput(storiesOutput)

        guard connect(input: backInput, to: movieOutput),
              connect(input: frontInput, to: storiesOutput) else {
            session.commitConfiguration()
            return false
        }

        addAudioIfAllowed()
        rotateConnections()

        if multi.hardwareCost > 1 || multi.systemPressureCost > 1 {
            session.commitConfiguration()
            return false
        }

        videoDevice = back
        position = .back

        session.commitConfiguration()

        return true
    }

    private func connect(
        input: AVCaptureDeviceInput,
        to output: AVCaptureOutput
    ) -> Bool {
        guard let port = input.ports.first(where: {
            $0.mediaType == .video
        }) else {
            return false
        }

        let connection = AVCaptureConnection(
            inputPorts: [port],
            output: output
        )

        guard session.canAddConnection(connection) else {
            return false
        }

        session.addConnection(connection)

        return true
    }

    // MARK: - Recording Completion

    private func finishMovies() {
        let recordingID = activeRecordingID
        let primary = primaryURL
        let secondary = secondaryURL
        let secondCamera = dualActive
        let shouldCrop = exportStories
        let crop = videoCrop
        let ratio = videoViewRatio

        // Stay on the recording format while the user remains in video.
        // Rebuilding here changes the field of view and interrupts the look.
        if skipRestore || (previewVideo && dualActive == false) {
            skipRestore = false
        } else {
            restorePhotoSession()
        }

        guard let primary else {
            emit(.message("The recording did not finish."))
            return
        }

        Task {
            // Apply the aspect crop to the master file.
            var master = primary

            if let crop, shouldCrop == false {
                if let cropped = await AspectMovie.export(from: primary, viewRect: crop, viewRatio: ratio) {
                    master = cropped
                } else {
                    self.emit(.message("The aspect crop failed. Saved the full frame."))
                }
            }

            if secondCamera {
                let source = secondary ?? primary
                let stories = await VerticalMovie.exportStories(from: source) ?? source

                self.emit(
                    .movie(
                        primary: master,
                        secondary: stories,
                        kind: .secondCamera, recordingID: recordingID
                    )
                )

            } else if shouldCrop {
                            // Dual shot: one horizontal 16:9 file and one vertical 9:16
                            // file, both cut from the centre of the same recording.
                            let wide = await VerticalMovie.exportHorizontal(from: primary)
                            let tall = await VerticalMovie.exportStories(from: primary)

                            if let wide, let tall {
                                self.emit(
                                    .movie(
                                        primary: wide,
                                        secondary: tall,
                                        kind: .verticalCrop, recordingID: recordingID
                                    )
                                )

                                // The full-frame recording and its aspect crop are not kept.
                                try? FileManager.default.removeItem(at: primary)

                                if master != primary {
                                    try? FileManager.default.removeItem(at: master)
                                }
                            } else {
                                // One of them failed: keep what was made.
                                self.emit(
                                    .movie(
                                        primary: wide ?? master,
                                        secondary: tall,
                                        kind: tall == nil ? .none : .verticalCrop, recordingID: recordingID
                                    )
                                )

                                self.emit(
                                    .message("One of the two Dual shot files could not be made.")
                                )
                            }

            } else {
                self.emit(
                    .movie(
                        primary: master,
                        secondary: nil,
                        kind: .none, recordingID: recordingID
                    )
                )
            }

            // The full-frame original is no longer needed.
            if master != primary {
                try? FileManager.default.removeItem(at: primary)
            }
        }
    }

    // True while the LUT preview is paused for the camera to settle.
    var isMonitorSettling: Bool {
        monitorLock.lock()
        defer { monitorLock.unlock() }

        return CFAbsoluteTimeGetCurrent() < monitorHoldUntil
    }

    // Pause the LUT preview for a moment while the camera restarts.
    private func holdMonitor(_ seconds: Double) {
        monitorLock.lock()
        monitorHoldUntil = CFAbsoluteTimeGetCurrent() + seconds
        monitorLock.unlock()
    }

    private func restorePhotoSession() {
        holdMonitor(0.12)
        session.automaticallyConfiguresCaptureDeviceForWideColor = true
        rebuildSingle()
    }

    // MARK: - Log Profile

    private func applyLog(_ profile: LogProfile) -> Bool {
        guard profile != .off else {
            return true
        }

        guard let device = videoDevice else {
            emit(.message("No camera is available for Log recording."))
            return false
        }

        let target: AVCaptureColorSpace = profile == .log2
            ? .appleLog2
            : .appleLog

        let supportedVideoSubtypes: [OSType] = [
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]

        let matchingFormats = device.formats.filter { format in
            let subtype = CMFormatDescriptionGetMediaSubType(
                format.formatDescription
            )

            return format.supportedColorSpaces.contains(target)
                && supportedVideoSubtypes.contains(subtype)
        }

        let selectedFormat = matchingFormats.sorted { first, second in
            let firstSubtype = CMFormatDescriptionGetMediaSubType(
                first.formatDescription
            )

            let secondSubtype = CMFormatDescriptionGetMediaSubType(
                second.formatDescription
            )

            let firstPriority = firstSubtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? 0 : 1
            let secondPriority = secondSubtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? 0 : 1

            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }

            let firstDimensions = first.formatDescription.dimensions
            let secondDimensions = second.formatDescription.dimensions

            let firstPixels = Int(firstDimensions.width) * Int(firstDimensions.height)
            let secondPixels = Int(secondDimensions.width) * Int(secondDimensions.height)

            return firstPixels > secondPixels
        }.first

        guard let format = selectedFormat else {
            printLogDiagnostics(for: device, requested: target)

            emit(.message(
                "\(profile.title) is advertised by the camera, but no compatible 10-bit video format is available. Recording was stopped to prevent an unsupported RAW recording."
            ))

            return false
        }

        session.beginConfiguration()

        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        do {
            try device.lockForConfiguration()

            device.activeFormat = format
            device.activeColorSpace = target

            device.unlockForConfiguration()

        } catch {
            session.commitConfiguration()

            print("""
            STILLARC LOG CONFIGURATION ERROR
            Requested profile: \(profile.title)
            Error: \(error.localizedDescription)
            """)

            emit(.message(
                "\(profile.title) could not be configured: \(error.localizedDescription)"
            ))

            return false
        }

        session.commitConfiguration()

        let enabled = device.activeColorSpace == target

        let dimensions = format.formatDescription.dimensions
        let subtype = CMFormatDescriptionGetMediaSubType(
            format.formatDescription
        )

        print("""

        ========== STILLARC LOG RESULT ==========
        Requested profile: \(profile.title)
        Requested colour space: \(target)
        Selected resolution: \(dimensions.width)x\(dimensions.height)
        Selected pixel format: \(fourCCString(subtype))
        Active colour space: \(device.activeColorSpace)
        Automatic wide colour: \(session.automaticallyConfiguresCaptureDeviceForWideColor)
        Successfully enabled: \(enabled)
        ==========================================
        """)

        guard enabled else {
            emit(.message(
                "\(profile.title) could not be activated. Recording was stopped."
            ))

            return false
        }

        return true
    }

    private func supports(
        _ format: AVCaptureDevice.Format,
        colorSpace: AVCaptureColorSpace
    ) -> Bool {
        format.supportedColorSpaces.contains(colorSpace)
    }

    private func fourCCString(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]

        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }

    private func printLogDiagnostics(
        for device: AVCaptureDevice,
        requested: AVCaptureColorSpace
    ) {
        print("""

        ========== STILLARC LOG DIAGNOSTICS ==========
        Camera: \(device.localizedName)
        Device type: \(device.deviceType)
        Requested colour space: \(requested)
        Active colour space: \(device.activeColorSpace)

        FORMATS ADVERTISING REQUESTED LOG:
        """)

        let formats = device.formats.filter {
            supports($0, colorSpace: requested)
        }

        if formats.isEmpty {
            print("No formats advertise the requested colour space.")
        } else {
            for format in formats {
                let dimensions = format.formatDescription.dimensions
                let subtype = CMFormatDescriptionGetMediaSubType(
                    format.formatDescription
                )

                print(
                    "\(dimensions.width)x\(dimensions.height) | \(fourCCString(subtype))"
                )
            }
        }

        print("==============================================")
    }

    // MARK: - Camera Capabilities

    private func publishCaps() {
        refreshAnalysisSettings()

        var caps = DeviceCaps(hasCamera: videoDevice != nil)

        caps.supportsMultiCam = multiCam
        caps.supportsNativeRaw = photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        caps.supportsLivePhoto = photoOutput.isLivePhotoCaptureSupported
        caps.supportsDepth = photoOutput.isDepthDataDeliverySupported

        caps.supportsRaw =
            photoOutput.availableRawPhotoPixelFormatTypes.isEmpty == false
            || photoOutput.isAppleProRAWSupported

        if let device = videoDevice {
            let format = device.activeFormat
            caps.usesVirtualCamera = device.isVirtualDevice
            caps.hasTorch = device.hasTorch && device.isTorchModeSupported(.on)
            caps.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported

            print("""

            ========== STILLARC CAMERA DIAGNOSTICS ==========
            Camera name: \(device.localizedName)
            Device type: \(device.deviceType)
            Position: \(device.position.rawValue)
            Unique ID: \(device.uniqueID)

            EXPOSURE
            Custom exposure supported: \(device.isExposureModeSupported(.custom))
            Continuous auto exposure: \(device.isExposureModeSupported(.continuousAutoExposure))
            ISO minimum: \(format.minISO)
            ISO maximum: \(format.maxISO)
            Shutter minimum: \(format.minExposureDuration.seconds)
            Shutter maximum: \(format.maxExposureDuration.seconds)

            WHITE BALANCE
            Locked mode supported: \(device.isWhiteBalanceModeSupported(.locked))
            Custom device gains supported: \(device.isLockingWhiteBalanceWithCustomDeviceGainsSupported)
            Maximum white balance gain: \(device.maxWhiteBalanceGain)

            FOCUS
            Locked mode supported: \(device.isFocusModeSupported(.locked))
            Custom lens position supported: \(device.isLockingFocusWithCustomLensPositionSupported)
            Autofocus supported: \(device.isFocusModeSupported(.autoFocus))
            Continuous autofocus supported: \(device.isFocusModeSupported(.continuousAutoFocus))

            TORCH
            Has torch: \(device.hasTorch)
            Torch available: \(device.isTorchAvailable)

            ================================================

            """)

            let formats = device.formats + device.constituentDevices.flatMap { $0.formats }
            caps.supportsLog = formats.contains { supports($0, colorSpace: .appleLog) }
            caps.supportsLog2 = formats.contains { supports($0, colorSpace: .appleLog2) }

            caps.minISO = format.minISO
            caps.maxISO = format.maxISO

            caps.minShutter = format.minExposureDuration.seconds

            caps.maxShutter = min(
                format.maxExposureDuration.seconds,
                1
            )

            caps.minEV = device.minExposureTargetBias
            caps.maxEV = device.maxExposureTargetBias
        }

        emit(.caps(caps))
    }

    // MARK: - Framing

    private func maximumZoom(on device: AVCaptureDevice) -> CGFloat {
        device.isVirtualDevice ? device.maxAvailableVideoZoomFactor : min(device.maxAvailableVideoZoomFactor, 16)
    }

    private func zoomFactor(on device: AVCaptureDevice, multiplier: Double) -> CGFloat {
        if device.isVirtualDevice {
            return CGFloat(LensTransitionPlan.virtualFactor(
                displayedZoom: lensZoom * multiplier,
                displayMultiplier: Double(device.displayVideoZoomFactorMultiplier),
                minimum: Double(device.minAvailableVideoZoomFactor),
                maximum: Double(maximumZoom(on: device))
            ))
        }
        return min(maximumZoom(on: device), max(device.minAvailableVideoZoomFactor,
                   device.minAvailableVideoZoomFactor * CGFloat(multiplier * lensCrop)))
    }

    private func applyFraming(animated: Bool = false) {
        guard let device = videoDevice else { return }
        let target = zoomFactor(on: device, multiplier: framingRangefinder ? 1 : framingZoom)
        lock(device) {
            if animated { device.ramp(toVideoZoomFactor: target, withRate: 6) }
            else { device.videoZoomFactor = target }
        }
    }

    // MARK: - Photo Settings

    // A preset can switch physical lenses/formats. The output's prior maximum
    // must remain one of the newly active format's supported photo dimensions.
    private func synchronizePhotoDimensions() {
        guard let device = videoDevice else { return }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        let current = photoOutput.maxPhotoDimensions
        guard !sizes.contains(where:{ $0.width == current.width && $0.height == current.height }),
              let largest = sizes.max(by:{ Int($0.width)*Int($0.height) < Int($1.width)*Int($1.height) }) else { return }
        photoOutput.maxPhotoDimensions = largest
    }

    private func makePhotoSettings(
        raw: Bool,
        flash: FlashChoice,
        format: PhotoFormat, nativeRaw: Bool = false
    ) -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType = format == .jpeg ? .jpeg : .hevc
        let processed = [AVVideoCodecKey: codec]

        var settings: AVCapturePhotoSettings

        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let proRaw = rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        let bayer = rawTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let canUseBayer = abs((videoDevice?.videoZoomFactor ?? 0) - 1) < 0.0001
            && abs((photoOutput.connection(with: .video)?.videoScaleAndCropFactor ?? 1) - 1) < 0.0001
        let chosenRaw: OSType?
        if requestedPhotoLive || requestedPhotoDepth {
            chosenRaw = nil
        } else if nativeRaw {
            chosenRaw = canUseBayer ? bayer : nil
        } else {
            chosenRaw = proRaw ?? (canUseBayer ? bayer : nil)
        }
        if raw, let rawType = chosenRaw, photoOutput.availablePhotoCodecTypes.contains(codec) {
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawType,
                processedFormat: processed
            )
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType) { settings.photoQualityPrioritization = .speed }

        } else if photoOutput.availablePhotoCodecTypes.contains(codec) {
            settings = AVCapturePhotoSettings(format: processed)

        } else {
            settings = AVCapturePhotoSettings()
        }

        let mode: AVCaptureDevice.FlashMode

        switch flash {
        case .on:
            mode = .on
        case .auto:
            mode = .auto
        case .off:
            mode = .off
        }

        if videoDevice?.hasFlash == true,
           photoOutput.supportedFlashModes.contains(mode) {
            settings.flashMode = mode
        }

        // The camera's full processing (Deep Fusion and the Photonic Engine),
        // the same natural look as the native Camera app.
        if settings.rawPhotoPixelFormatType == 0, photoOutput.maxPhotoQualityPrioritization.rawValue
            >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
            settings.photoQualityPrioritization = .quality
        }

        // Full resolution: the largest size for HEIF Max, about 24 MP for
        // the others.
        if let size = photoSize(for: format) {
            settings.maxPhotoDimensions = size
        }

        return settings
    }

    // The photo size to ask for, never above what the output allows.
    private func photoSize(for format: PhotoFormat) -> CMVideoDimensions? {
        guard let device = videoDevice else { return nil }

        let allowed = photoOutput.maxPhotoDimensions

        let sizes = device.activeFormat.supportedMaxPhotoDimensions.filter {
            $0.width <= allowed.width && $0.height <= allowed.height
        }

        guard sizes.isEmpty == false else { return nil }

        let sorted = sizes.sorted {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }

        if format == .heifMax {
            return sorted.last
        }

        return sorted.first {
            Int($0.width) * Int($0.height) >= 20_000_000
        } ?? sorted.last
    }

    // MARK: - Audio

    private func addAudioIfAllowed() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else {
            return
        }

        configureAudioSession()

        session.addInput(input)
    }

    // MARK: - Connection Orientation

    // Photos, video and the analysis frames follow how the phone is held.
    private func rotateConnections() {
        updateNativePreviewConnection()
        let captured = captureAngle()
        lastAngle = captured

        for output in session.outputs {
            guard let connection = output.connection(with: .video) else {
                continue
            }

            // The aids and LUT preview follow the portrait viewfinder.
            // Single-output captures turn with the phone. Dual Shot keeps one
            // portrait source for the fixed portrait and landscape crops.
            let angle: CGFloat = output === analysisOutput || (output === writerVideoOutput && dualPreview) ? 90 : captured

            orient(connection, uprightAngle: angle)

            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false

                // Saved output follows the selfie mirror preference. The analysis
                // frames stay raw and are flipped by hand to match the
                // mirrored preview.
                connection.isVideoMirrored = frontMirrorLock.withLock {frontMirrorEnabled} && connection.inputPorts.contains(where:{$0.sourceDevicePosition == .front}) && output !== analysisOutput
            }
        }
    }

    // MARK: - Video Codec

    private func prepareCodec(
        _ output: AVCaptureMovieFileOutput,
        selected: RecordingCodec,
        bitrate: Int? = nil
    ) -> Bool {
        guard let connection = output.connection(with: .video) else {
            print("STILLARC: No video connection available for movie output.")
            return false
        }

        let available = output.availableVideoCodecTypes
        let codec = selected.videoCodec

        guard available.contains(codec) else {
            print("""
            STILLARC CODEC NOT AVAILABLE
            Requested: \(selected.rawValue)
            Available: \(available.map(\.rawValue))
            """)
            return false
        }

        var outputSettings: [String: Any] = [AVVideoCodecKey: codec]

        // ProRes has a fixed data rate, so a custom bitrate only applies to
        // HEVC and H.264, and only if the output reports that it supports it.
        if let bitrate, selected.isProRes == false {
            let keys = output.supportedOutputSettingsKeys(for: connection)

            if keys.contains(AVVideoCompressionPropertiesKey) {
                outputSettings[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: bitrate
                ]

                print("STILLARC BITRATE: \(bitrate / 1_000_000) Mbps")
            } else {
                print("STILLARC: custom bitrate is not supported by this output. Supported keys: \(keys)")

                emit(.message(
                    "This format does not allow a custom bitrate. Using the default."
                ))
            }
        }

        output.setOutputSettings(outputSettings, for: connection)

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = supported(videoStabilization)
        }

        print("STILLARC SELECTED VIDEO CODEC: \(selected.title)")

        return true
    }

    // MARK: - Device Selection

    private func bestDevice(
        position: AVCaptureDevice.Position,
        useChosenLens: Bool = true
    ) -> AVCaptureDevice? {

        if position == .front, requestedPhotoDepth,
           let depth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) { return depth }
        if position == .back, !physicalFocusMode {
            let virtuals = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera],
                mediaType: .video, position: .back
            ).devices
            for kind in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
                if let device = virtuals.first(where: { $0.deviceType == kind }),
                   previewLog == .off || device.formats.contains(where: { $0.supportedColorSpaces.contains(colorSpace(for: previewLog)) }) {
                    return device
                }
            }
        }

        if useChosenLens,
           position == .back,
           let choice = lensChoice,
           let chosen = AVCaptureDevice(uniqueID: choice.deviceID) {
            return chosen
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera
            ],
            mediaType: .video,
            position: position
        )

        if let wideCamera = discovery.devices.first(where: {
            $0.deviceType == .builtInWideAngleCamera
        }) {
            return wideCamera
        }

        return discovery.devices.first
    }

    // MARK: - Recording Format Selection

    private static let standardFrameRates = [24, 25, 30, 48, 50, 60, 100, 120, 240]

    // The original, proven path is kept for plain Standard recording. The
    // format search below is used for Log, or when the person picks a
    // resolution or frame rate.
    private func usesCustomFormat(
        log: LogProfile,
        settings: RecordingSettings
    ) -> Bool {
        log != .off
            || settings.resolution != nil
            || settings.frameRate != nil
    }

    private func colorSpace(for log: LogProfile) -> AVCaptureColorSpace {
        switch log {
        case .off: return .sRGB
        case .log: return .appleLog
        case .log2: return .appleLog2
        }
    }

    private static func formatGroup(
        of format: AVCaptureDevice.Format
    ) -> FormatGroup? {
        let subtype = CMFormatDescriptionGetMediaSubType(
            format.formatDescription
        )

        let ten422: [OSType] = [
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ]

        let ten420: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ]

        let eight420: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        if ten422.contains(subtype) { return .tenBit422 }
        if ten420.contains(subtype) { return .tenBit420 }
        if eight420.contains(subtype) { return .eightBit420 }

        return nil
    }

    private static func formatSupports(
        _ format: AVCaptureDevice.Format,
        frameRate: Int
    ) -> Bool {
        let rate = Double(frameRate)

        return format.videoSupportedFrameRateRanges.contains { range in
            rate >= range.minFrameRate - 0.01
                && rate <= range.maxFrameRate + 0.01
        }
    }

    private static func isSixteenByNine(_ size: CMVideoDimensions) -> Bool {
        guard size.height > 0 else { return false }

        let ratio = Double(size.width) / Double(size.height)

        return abs(ratio - 16.0 / 9.0) < 0.02
    }

    private func bestFormat(
        in group: FormatGroup,
        device: AVCaptureDevice,
        log: LogProfile,
        settings: RecordingSettings
    ) -> AVCaptureDevice.Format? {
        let target = colorSpace(for: log)

        var candidates = device.formats.filter { (format: AVCaptureDevice.Format) -> Bool in
            let size = format.formatDescription.dimensions

            guard size.width >= 1280,
                  CaptureEngine.formatGroup(of: format) == group else {
                return false
            }

            if log != .off,
               format.supportedColorSpaces.contains(target) == false {
                return false
            }

            if let resolution = settings.resolution,
               Int(size.width) != resolution.width
                || Int(size.height) != resolution.height {
                return false
            }

            if let fps = settings.frameRate,
               CaptureEngine.formatSupports(format, frameRate: fps) == false {
                return false
            }

            return true
        }

        guard candidates.isEmpty == false else { return nil }

        // On Auto resolution, stay at or below 4K UHD.
        if settings.resolution == nil {
            let capped = candidates.filter {
                $0.formatDescription.dimensions.width <= 3840
            }

            if capped.isEmpty == false {
                candidates = capped
            }
        }

        let autoResolution = settings.resolution == nil

        let sorted = candidates.sorted { first, second in
            let a = first.formatDescription.dimensions
            let b = second.formatDescription.dimensions

            let aWide = CaptureEngine.isSixteenByNine(a)
            let bWide = CaptureEngine.isSixteenByNine(b)

            if autoResolution, aWide != bWide {
                return aWide
            }

            let aPixels = Int(a.width) * Int(a.height)
            let bPixels = Int(b.width) * Int(b.height)

            if aPixels != bPixels {
                return aPixels > bPixels
            }

            return first.videoFieldOfView > second.videoFieldOfView
        }

        return sorted.first
    }

    private func matchesResolution(_ resolution: RecResolution?, format: AVCaptureDevice.Format) -> Bool {
        guard let resolution else { return true }
        let size = format.formatDescription.dimensions
        return Int(size.width) == resolution.width && Int(size.height) == resolution.height
    }

    private func applyRequestedFrameRate(_ fps: Int, to device: AVCaptureDevice) -> Bool {
        guard Self.formatSupports(device.activeFormat, frameRate: fps) else { return false }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        if CMTimeCompare(device.activeVideoMinFrameDuration, duration) == 0,
           CMTimeCompare(device.activeVideoMaxFrameDuration, duration) == 0 { return true }
        var applied = false
        lock(device) {
            setLockedFrameDuration(duration, on: device)
            applied = true
        }
        return applied
    }

    // Keep min <= max throughout a 60 ↔ 30 change on the same format.
    private func setLockedFrameDuration(_ duration: CMTime, on device: AVCaptureDevice) {
        if device.activeVideoMaxFrameDuration.isNumeric,
           CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    private func activate(
        _ format: AVCaptureDevice.Format,
        fps: Int?,
        colorSpace target: AVCaptureColorSpace,
        log: LogProfile
    ) -> Bool {
        guard let device = videoDevice else { return false }

        var applied = true

        session.beginConfiguration()

        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        do {
            try device.lockForConfiguration()

            device.activeFormat = format

            if format.supportedColorSpaces.contains(target) {
                device.activeColorSpace = target
            }

            if let fps, fps > 0 {
                let duration = CMTime(
                    value: 1,
                    timescale: CMTimeScale(fps)
                )

                setLockedFrameDuration(duration, on: device)
            }

            device.unlockForConfiguration()
        } catch {
            applied = false

            print("STILLARC FORMAT ERROR: \(error.localizedDescription)")
        }

        session.commitConfiguration()

        if applied, log != .off, device.activeColorSpace != target {
            print("STILLARC: \(log.title) did not activate on this format.")
            applied = false
        }

        return applied
    }

    // Codec availability depends on the active format, so each pixel-format
    // family is tried and the codecs it offers are recorded.
    private func probeFormats(
        log: LogProfile,
        settings: RecordingSettings
    ) -> [FormatProbe] {
        guard let device = videoDevice else { return [] }

        let target = colorSpace(for: log)
        var probes: [FormatProbe] = []

        for group in FormatGroup.allCases {
            guard let format = bestFormat(
                in: group,
                device: device,
                log: log,
                settings: settings
            ) else {
                print("STILLARC FORMAT PROBE\nGroup: \(group.label)\nNot offered for \(log.title) on this lens.")
                continue
            }

            guard activate(
                format,
                fps: settings.frameRate,
                colorSpace: target,
                log: log
            ) else {
                continue
            }

            if session.isRunning == false {
                session.startRunning()
            }

            let codecs = settledCodecs()
            let size = format.formatDescription.dimensions

            print("""
            STILLARC FORMAT PROBE
            Group: \(group.label)
            Resolution: \(size.width)x\(size.height)
            Codecs: \(codecs.map(\.rawValue))
            """)

            probes.append(
                FormatProbe(group: group, format: format, codecs: codecs)
            )
        }

        return probes
    }

    private func settledCodecs() -> [RecordingCodec] {
        var codecs: [RecordingCodec] = []

        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.12)

            codecs = safeCodecs(from: movieOutput)

            if codecs.isEmpty == false {
                break
            }
        }

        return codecs
    }

    private func unionCodecs(
        _ probes: [FormatProbe],
        log: LogProfile
    ) -> [RecordingCodec] {
        var seen = Set<String>()
        var merged: [RecordingCodec] = []

        for probe in probes {
            for codec in probe.codecs {
                if seen.insert(codec.rawValue).inserted {
                    merged.append(codec)
                }
            }
        }

        var sorted = merged.sorted { first, second in
            self.codecPriority(first) < self.codecPriority(second)
        }

        // Log HEVC is recorded through the asset writer, so it is offered
        // even though the movie output only lists ProRes. ProRes stays first.
        let hasHEVC = sorted.contains { $0.rawValue == "hvc1" || $0.rawValue == "hev1" }

        if log != .off, probes.isEmpty == false, hasHEVC == false {
            sorted.append(RecordingCodec(rawValue: "hvc1"))
        }

        return sorted
    }

    private func targetBitrate(
        _ preset: RecBitrate,
        codec: RecordingCodec
    ) -> Int? {
        guard preset != .auto,
              codec.isProRes == false,
              let device = videoDevice else {
            return nil
        }

        let size = device.activeFormat.formatDescription.dimensions
        let duration = device.activeVideoMinFrameDuration

        let fps: Double = duration.isValid && duration.seconds > 0
            ? 1.0 / duration.seconds
            : 30

        return preset.bitsPerSecond(
            width: Int(size.width),
            height: Int(size.height),
            fps: fps,
            codec: codec.rawValue
        )
    }

    // MARK: - Recording Options

    private func publishVideoOptions(log: LogProfile) {
        let options = buildVideoOptions(log: log)
        let handler = onVideoOptions

        Task { @MainActor in
            handler?(options)
        }
    }

    private func buildVideoOptions(log: LogProfile) -> RecordingOptions {
        var options = RecordingOptions()

        if dualActive {
            options.locked = true
        }

        if let connection = movieOutput.connection(with: .video) {
            options.bitrateSupported = movieOutput
                .supportedOutputSettingsKeys(for: connection)
                .contains(AVVideoCompressionPropertiesKey)
        }

        guard dualActive == false, let device = videoDevice else {
            return options
        }

        let target = colorSpace(for: log)

        var found: [String: RecResolution] = [:]
        var rates: [String: Set<Int>] = [:]

        for format in device.formats {
            guard CaptureEngine.formatGroup(of: format) != nil else {
                continue
            }

            let size = format.formatDescription.dimensions

            guard size.width >= 1280 else { continue }

            if log != .off,
               format.supportedColorSpaces.contains(target) == false {
                continue
            }

            let resolution = RecResolution(
                width: Int(size.width),
                height: Int(size.height)
            )

            for fps in CaptureEngine.standardFrameRates {
                if CaptureEngine.formatSupports(format, frameRate: fps) {
                    found[resolution.id] = resolution
                    rates[resolution.id, default: []].insert(fps)
                }
            }
        }

        options.resolutions = found.values.sorted { first, second in
            let a = first.width * first.height
            let b = second.width * second.height

            return a > b
        }

        var everything = Set<Int>()

        for (key, value) in rates {
            options.frameRatesByResolution[key] = value.sorted()
            everything.formUnion(value)
        }

        options.allFrameRates = everything.sorted()

        return options
    }

    // MARK: - Orientation

    // Angle that makes captures upright for the way the phone is held.
    private func captureAngle() -> CGFloat {
        deviceAngle
    }

    private func publishOrientation() {
        let angle = Double(lastAngle)
        let handler = onOrientation

        Task { @MainActor in
            handler?(angle)
        }
    }

    // Audio session set so haptics keep working while the mic is open.
    private func configureAudioSession() {
        guard audioConfigured == false else { return }
        audioConfigured = true

        let audio = AVAudioSession.sharedInstance()

        do {
            try audio.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
            )

            try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try audio.setActive(true)

            session.automaticallyConfiguresApplicationAudioSession = false
        } catch {
            print("STILLARC AUDIO SESSION: \(error.localizedDescription)")
        }
    }

    // MARK: - Exposure control, live values and preview Log

    // A rebuilt session must not stay out of focus.
    private func restoreFocus() {
        guard focusLocked == false, let device = videoDevice else { return }

        lock(device) {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    func setFocusAuto() {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            self.focusMeasurementID = UUID()
            self.focusLocked = false

            self.lock(device) {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
        }
    }

    // ISO and shutter can each be manual or automatic. With one of them
    // automatic, the engine meters the scene and moves that value to keep
    // the exposure on target (shutter priority or ISO priority).
    func setExposureControl(
        isoAuto: Bool,
        shutterAuto: Bool,
        iso: Float,
        shutter: Double,
        bias: Float
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.ctlISOAuto = isoAuto
            self.ctlShutterAuto = shutterAuto
            self.ctlISO = iso
            self.ctlShutter = shutter
            self.ctlBias = bias

            guard let device = self.videoDevice else { return }

            if isoAuto && shutterAuto {
                self.lock(device) {
                    guard device.isExposureModeSupported(.continuousAutoExposure) else {
                        return
                    }

                    device.exposureMode = .continuousAutoExposure

                    let clamped = min(
                        max(bias, device.minExposureTargetBias),
                        device.maxExposureTargetBias
                    )

                    device.setExposureTargetBias(clamped)
                }
            } else {
                self.applyCustomExposure(device)
            }
        }
    }

    private func applyCustomExposure(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else {
            emit(.message("Manual exposure is not supported by this camera."))
            return
        }

        let format = device.activeFormat

        let minimum = max(format.minExposureDuration.seconds, 0.0001)
        let maximum = max(format.maxExposureDuration.seconds, minimum)

        ctlShutter = min(max(ctlShutter, minimum), maximum)
        ctlISO = min(max(ctlISO, format.minISO), format.maxISO)

        // One change at a time. While one is in flight the newest values
        // wait and go out when it lands, so dragging a ruler never queues
        // up a pile of camera changes.
        let now = ProcessInfo.processInfo.systemUptime

        if exposureApplying, now - exposureApplyStart < 0.5 {
            exposurePending = true
            return
        }

        exposureApplying = true
        exposureApplyStart = now

        let duration = CMTime(seconds: ctlShutter, preferredTimescale: 1_000_000)
        let iso = ctlISO

        lock(device) {
            device.setExposureModeCustom(
                duration: duration,
                iso: iso
            ) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }

                    self.exposureApplying = false
                    self.lastExposureApplied = ProcessInfo.processInfo.systemUptime

                    if self.exposurePending {
                        self.exposurePending = false

                        if let device = self.videoDevice {
                            self.applyCustomExposure(device)
                        }
                    }
                }
            }
        }
    }

    private func startLiveTimer() {
        guard liveTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)

        timer.schedule(deadline: .now() + 0.5, repeating: 0.1, leeway: .milliseconds(10))

        timer.setEventHandler { [weak self] in
            self?.tick()
        }

        timer.resume()
        liveTimer = timer
    }

    private func tick() {
        guard session.isRunning, let device = videoDevice else { return }

        tickCount += 1

        // Microphone level for the meter, in decibels.
        if !session.outputs.contains(writerAudioOutput), let channels = movieOutput.connection(with: .audio)?.audioChannels,
           channels.isEmpty == false {
            let level = channels.map { $0.averagePowerLevel }.max() ?? -160

            if abs(level - lastAudioDb) >= 1 {
                lastAudioDb = level
                onAudioLevel?(level)
            }
        }

        // Follow the way the phone is held, except while recording.
        if movieOutput.isRecording == false,
           storiesOutput.isRecording == false,
           currentWriter() == nil, currentLiveWriter() == nil {
            let angle = captureAngle()

            if abs(angle - lastAngle) > 1 {
                rotateConnections()
                publishOrientation()
            }
        }

        // Exactly one of ISO and shutter is automatic.
        // The automatic value only moves once the last change has landed and
        // the meter has settled, and in small steps, so it cannot hunt.
        if ctlISOAuto != ctlShutterAuto,
           device.exposureMode == .custom,
           exposureApplying == false,
           ProcessInfo.processInfo.systemUptime - lastExposureApplied > 0.3 {
            let delta = Double(ctlBias) - Double(device.exposureTargetOffset)

            if abs(delta) > 0.15 {
                let step = min(max(delta * 0.35, -0.5), 0.5)
                let factor = pow(2.0, step)

                if ctlISOAuto {
                    ctlISO = Float(Double(ctlISO) * factor)
                } else {
                    ctlShutter *= factor
                }

                applyCustomExposure(device)
            }
        }

        // A picture that stopped updating must not stay on screen.
        if tickCount % 3 == 0, monitorActive {
            monitorLock.lock()
            let age = CFAbsoluteTimeGetCurrent() - lastMonitorEnqueue
            monitorLock.unlock()

            if age > 6 {
                monitorLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
        }

        // Live values change slowly, so they are sent a few times a second
        // and only when they moved.
        guard tickCount % 3 == 0 else { return }

        publishLive(device)
    }

    private func publishLive(_ device: AVCaptureDevice) {
        let maximumGain = device.maxWhiteBalanceGain
        var gains = device.deviceWhiteBalanceGains

        gains.redGain = min(max(gains.redGain, 1), maximumGain)
        gains.greenGain = min(max(gains.greenGain, 1), maximumGain)
        gains.blueGain = min(max(gains.blueGain, 1), maximumGain)

        let kelvin = device.temperatureAndTintValues(for: gains).temperature

        let live = LiveValues(
            iso: device.iso,
            shutter: device.exposureDuration.seconds,
            kelvin: kelvin,
            lensPosition: device.lensPosition
        )

        if let last = lastLive,
           abs(last.iso - live.iso) < 1,
           abs(last.shutter - live.shutter) < last.shutter * 0.02,
           abs(last.kelvin - live.kelvin) < 20,
           abs(last.lensPosition - live.lensPosition) < 0.01 {
            return
        }

        lastLive = live

        let handler = onLive

        Task { @MainActor in
            handler?(live)
        }
    }

    // MARK: - Preview format (matches the recording format)

    // The preview runs in the same format video will record in, so starting
    // a recording does not restart the camera.
    func setPreview(
        video: Bool,
        log: LogProfile,
        settings: RecordingSettings, codec: RecordingCodec? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let photoTransition = !video && (self.previewVideo || self.previewLog != .off)
            self.previewCodec = codec
            self.cameraAudio.setMetering(video)
            self.previewVideo = video
            self.previewLog = video ? log : .off
            self.previewSettings = settings
            if photoTransition, !self.movieOutput.isRecording, self.currentLiveWriter() == nil,
               let device = self.videoDevice {
                // Return the existing connection to the photo pipeline. Do not tear
                // down/re-add inputs merely to leave a Log video format.
                self.session.beginConfiguration()
                self.session.automaticallyConfiguresCaptureDeviceForWideColor = true
                if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
                    self.lock(device) { device.activeColorSpace = .sRGB }
                }
                self.synchronizePhotoDimensions()
                self.session.commitConfiguration()
                self.publishCaps()
            }
        }
    }

    // Follows the way the phone is held.
    func setOrientation(_ angle: Double) {
        queue.async { [weak self] in
            guard let self else { return }

            // Photos and video pick this up when they start. The viewfinder,
            // aids and LUT preview stay portrait.
            self.deviceAngle = CGFloat(angle)
        }
    }

    private func probeKey(log: LogProfile, settings: RecordingSettings) -> String {
        "\(log)|\(String(describing: settings.resolution))|\(String(describing: settings.frameRate))|\(videoDevice?.uniqueID ?? "none")"
    }

    private func applyPreviewFormat() {
        guard let settings = previewSettings,
              (usesCustomFormat(log: previewLog, settings: settings) || previewCodec?.rawValue.hasPrefix("ap") == true),
              let device = videoDevice else {
            return
        }

        let groups: [FormatGroup] = previewLog != .off || previewCodec?.rawValue.hasPrefix("ap") == true
            ? FormatGroup.allCases : [.eightBit420, .tenBit420, .tenBit422]
        for group in groups {
            guard let format = bestFormat(
                in: group,
                device: device,
                log: previewLog,
                settings: settings
            ) else {
                continue
            }

            _ = activate(
                format,
                fps: settings.frameRate,
                colorSpace: colorSpace(for: previewLog),
                log: previewLog
            )

            return
        }

        if previewLog != .off {
            _ = applyLog(previewLog)
        }
    }

    // MARK: - Analysis stream size

    // The aids and the LUT preview do not need a 12 megapixel picture. A
    // smaller stream is much lighter on the camera and removes the stalls,
    // flicker and edge lines the full-size stream caused.
    private func analysisSettings() -> [String: Any] {
        // Keep the native 4:2:0 stream when available. Core Image handles
        // its tagged YUV conversion; RGB scopes use a small separate proxy.
        let native = analysisOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:
            native ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA]

        #if DEBUG
        if dualPreview, ProcessInfo.processInfo.arguments.contains("--verify-compressed-source"),
           analysisOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange) {
            settings[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
        }
        #endif

        guard analysisUnscaled == false,
              let device = videoDevice else {
            analysisApplied = (0, 0)
            return settings
        }

        let dims = device.activeFormat.formatDescription.dimensions
        let long = Double(max(dims.width, dims.height))
        let short = Double(max(1, min(dims.width, dims.height)))

        // Portrait, like the viewfinder.
        // Both crops must retain 1080p detail: the landscape crop in a
        // portrait stream needs at least 1920 pixels across its short edge.
        let target = min(dualPreview ? ceil(1920.0 * long / short) : 2048.0, long)

        var width = target * short / long
        var height = target

        if analysisSwap {
            swap(&width, &height)
        }

        // Match the source aspect exactly, with even YUV dimensions.
        // Rounding width/height independently can be rejected by capture
        // devices with stricter dimension validation. Strides may be padded;
        // Core Image and the analysis reader already honor those strides.
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(Int(short), Int(long))
        var unitW = Int(short) / divisor * 2
        var unitH = Int(long) / divisor * 2
        if analysisSwap { swap(&unitW, &unitH) }
        let requestedSteps = max(width, height) / Double(max(unitW, unitH))
        let steps = max(1, min(divisor / 2, Int(dualPreview ? ceil(requestedSteps) : floor(requestedSteps))))
        let evenW = unitW * steps
        let evenH = unitH * steps

        settings[kCVPixelBufferWidthKey as String] = evenW
        settings[kCVPixelBufferHeightKey as String] = evenH

        analysisApplied = (evenW, evenH)

        return settings
    }

    // Re-applies the size after the camera format changed.
    private func refreshAnalysisSettings() {
        guard session.outputs.contains(analysisOutput) else { return }

        let before = analysisApplied
        let next = analysisSettings()

        guard analysisApplied != before else { return }

        beginScaleTrial()

        session.beginConfiguration()
        analysisOutput.videoSettings = next
        session.commitConfiguration()
    }

    // If a size request ever crashed the app, the next launch notices and
    // never asks for a scaled stream again.
    private func beginScaleTrial() {
        guard analysisUnscaled == false else { return }

        UserDefaults.standard.set(true, forKey: "frameline.scaleTrial")
    }

    private func endScaleTrial() {
        guard UserDefaults.standard.bool(forKey: "frameline.scaleTrial") else {
            return
        }

        UserDefaults.standard.set(false, forKey: "frameline.scaleTrial")
    }

    // Checks that frames arrive in the shape that was asked for. If the
    // size keys are read the other way round, swap them.
    private func validateAnalysisFrame(_ buffer: CVPixelBuffer) {
        endScaleTrial()

        guard analysisApplied.w > 0,
              let device = videoDevice else {
            return
        }

        let dims = device.activeFormat.formatDescription.dimensions
        let expected = Double(min(dims.width, dims.height))
            / Double(max(1, max(dims.width, dims.height)))

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let actual = Double(width) / Double(max(1, height))

        if analysisIgnoredLogged == false,
           min(width, height) > min(analysisApplied.w, analysisApplied.h) * 3 / 2 {
            analysisIgnoredLogged = true
            print("STILLARC ANALYSIS: asked for \(analysisApplied.w)x\(analysisApplied.h) but frames are \(width)x\(height)")
        }

        if abs(actual - expected) / expected < 0.03 {
            analysisMismatch = 0
            return
        }

        analysisMismatch += 1

        guard analysisMismatch >= 6 else { return }

        analysisMismatch = 0
        analysisToggles += 1

        queue.async { [weak self] in
            guard let self else { return }

            if self.analysisToggles <= 1 {
                self.analysisSwap.toggle()
            } else {
                // Give up on scaling and use the camera's own size.
                self.analysisUnscaled = true
                UserDefaults.standard.set(true, forKey: "frameline.scaleDisabled")
            }

            print("STILLARC ANALYSIS: frames were \(width)x\(height), retrying (unscaled: \(self.analysisUnscaled))")

            self.analysisApplied = (-1, -1)
            self.refreshAnalysisSettings()
        }
    }

    // MARK: - Exposure Aids

    func setPeaking(red: UInt8, green: UInt8, blue: UInt8, threshold: Int) {
        aidsLock.lock()
        peakRed = red
        peakGreen = green
        peakBlue = blue
        peakThreshold = max(10, threshold)
        aidsLock.unlock()
    }

    func setAids(
        histogram: Bool,
        zebra: Bool,
        peaking: Bool,
        falseColor: Bool = false,
        waveform: Bool = false
    ) {
        aidsLock.lock()
        aidHistogram = histogram
        aidWaveform = waveform
        aidZebra = zebra
        aidPeaking = peaking
        aidFalseColor = falseColor
        aidsLock.unlock()

        queue.async { [weak self] in
            self?.syncAnalysisOutput()
        }
    }

    private var scopesWanted: Bool {
        aidsLock.lock()
        defer { aidsLock.unlock() }
        return aidHistogram || aidWaveform || aidZebra || aidPeaking || aidFalseColor
    }

    private var aidsWanted: Bool { scopesWanted || monitorActive || loupeActive }

    // Call inside a configuration block.
    private func addAnalysisOutput(force: Bool = false) {
        guard force || aidsWanted || motionExposureID != nil,
              dualActive == false,
              session.outputs.contains(analysisOutput) == false else {
            return
        }

        analysisOutput.alwaysDiscardsLateVideoFrames = true
        analysisOutput.automaticallyConfiguresOutputBufferDimensions = false
        analysisOutput.deliversPreviewSizedOutputBuffers = false

        beginScaleTrial()
        analysisOutput.videoSettings = analysisSettings()

        analysisOutput.setSampleBufferDelegate(self, queue: analysisQueue)

        if session.canAddOutput(analysisOutput) {
            session.addOutput(analysisOutput)
        }
    }

    private func syncAnalysisOutput() {
        guard videoDevice != nil,
              dualActive == false,
              movieOutput.isRecording == false,
              storiesOutput.isRecording == false,
              currentWriter() == nil, currentLiveWriter() == nil else {
            return
        }

        let wanted = aidsWanted || motionExposureID != nil
        let attached = session.outputs.contains(analysisOutput)
        guard wanted != attached else { return }

        session.beginConfiguration()

        if wanted {
            addAnalysisOutput()
            rotateConnections()
        } else if session.outputs.contains(analysisOutput) {
            session.removeOutput(analysisOutput)
        }

        session.commitConfiguration()
        rotateConnections()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if (output === analysisOutput || output === writerVideoOutput), previewSuppressed,
           currentLiveWriter() == nil, currentWriter() == nil, currentTimelapse() == nil { return }
        if output === analysisOutput || output === writerVideoOutput,
           let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let orientation: CGImagePropertyOrientation
            if output === writerVideoOutput { orientation = .up }
            else {
                switch lastAngle {
                case 0: orientation = frontMirrored ? .leftMirrored : .left
                case 180: orientation = frontMirrored ? .rightMirrored : .right
                case 270: orientation = frontMirrored ? .downMirrored : .down
                default: orientation = frontMirrored ? .upMirrored : .up
                }
            }
            subjectTracker.offer(frame, orientation: orientation)
        }
        #if DEBUG
        if output === writerVideoOutput || output === analysisOutput { noteProbeSourceFrame() }
        #endif
        if output === writerVideoOutput {
            currentTimelapse()?.offer(sampleBuffer)
            currentLiveWriter()?.appendVideo(sampleBuffer)
            currentWriter()?.appendVideo(sampleBuffer)

            // While recording, the monitor is fed from these same frames, so
            // the camera only has to deliver one 4K stream.
            let needsMonitor = monitorActive && !usesLivePreview
            let needsScopes = scopesWanted
            if (needsMonitor || needsScopes), !previewSuppressed,
               let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let now = CFAbsoluteTimeGetCurrent()

                monitorLock.lock()
                let free = monitorBusy == false && now - lastMonitor >= 0.02

                if free {
                    monitorBusy = true
                    lastMonitor = now
                }

                monitorLock.unlock()

                if free {
                    analysisQueue.async { [weak self] in
                        guard let self else { return }
                        defer { self.monitorLock.lock(); self.monitorBusy = false; self.monitorLock.unlock() }
                        guard !self.previewSuppressed else { return }
                        if needsMonitor, !self.usesLivePreview { self.renderMonitor(frame) }
                        if needsScopes { self.analyzeIfNeeded(frame, sourceUpright: true) }
                    }
                }
            }

            return
        }

        if output === writerAudioOutput {
            cameraAudio.consume(sampleBuffer)
            currentLiveWriter()?.appendAudio(sampleBuffer)
            currentWriter()?.appendAudio(sampleBuffer)
            return
        }

        guard output === analysisOutput,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if let writer = currentLiveWriter(), writer.usesAnalysisStream {
            writerLock.lock()
            guard liveWriter === writer else { writerLock.unlock(); return }
            let ready = !liveAnalysisBusy
            if ready { liveAnalysisBusy = true }
            else {
                if pendingLiveAnalysis.count == 2 { pendingLiveAnalysis.removeFirst(); liveQueueDrops += 1 }
                pendingLiveAnalysis.append(sampleBuffer)
            }
            writerLock.unlock()
            if ready { renderAnalysisRecording(sampleBuffer, writer: writer) }
        }
        if let motionAccumulator {
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: buffer)
                motionAccumulator.offer(mirrorMotionExposure ? image.oriented(.upMirrored) : image,
                    timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, context: PhotoDeveloper.context)
            }
        }
        validateAnalysisFrame(buffer)
        guard !previewSuppressed else { return }

        let now = CFAbsoluteTimeGetCurrent()

        if loupeActive, now - lastLoupe >= 0.05 {
            lastLoupe = now
            auxiliaryLock.lock(); let free = !loupeBusy; if free { loupeBusy = true }; auxiliaryLock.unlock()
            if free {
                scopesQueue.async { [weak self] in
                    self?.renderLoupe(buffer)
                    self?.auxiliaryLock.lock(); self?.loupeBusy = false; self?.auxiliaryLock.unlock()
                }
            }
        }

        if monitorActive, !usesLivePreview, now - lastMonitor >= 0.02 {
            lastMonitor = now
            renderMonitor(buffer)
        }

        analyzeIfNeeded(buffer)
    }

    private func analyzeIfNeeded(_ buffer: CVPixelBuffer, sourceUpright: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysis >= 0.08 else { return }
        lastAnalysis = now

        aidsLock.lock()
        let histogram = aidHistogram
        let waveform = aidWaveform
        let zebra = aidZebra
        let peaking = aidPeaking
        let falseColor = aidFalseColor
        aidsLock.unlock()

        guard histogram || waveform || zebra || peaking || falseColor else { return }

        auxiliaryLock.lock()
        guard !scopesBusy else { auxiliaryLock.unlock(); return }
        scopesBusy = true
        auxiliaryLock.unlock()
        let mirror = frontMirrored
        scopesQueue.async { [weak self] in
            guard let self else { return }
            defer { self.auxiliaryLock.lock(); self.scopesBusy = false; self.auxiliaryLock.unlock() }
            self.analyze(buffer, histogram: histogram, waveform: waveform, zebra: zebra, peaking: peaking, falseColor: falseColor, sourceUpright: sourceUpright, mirrored: mirror)
        }
    }

    // Samples the luma plane on a coarse grid. Zebras mark near-clipped
    // highlights and peaking marks sharp edges.
    private func analyze(
        _ buffer: CVPixelBuffer,
        histogram: Bool,
        waveform: Bool,
        zebra: Bool,
        peaking: Bool,
        falseColor: Bool,
        sourceUpright: Bool = false,
        mirrored: Bool = false
    ) {
        let compressed = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
        if compressed || (CVPixelBufferGetPlaneCount(buffer) > 0 && (histogram || waveform)) {
            let source = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 320 / source.extent.width)
            let size = CGSize(width: max(2, (Int(source.extent.width * scale) / 2) * 2), height: max(2, (Int(source.extent.height * scale) / 2) * 2))
            if scopesRGBPool == nil || scopesRGBSize != size {
                let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
                CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &scopesRGBPool)
                scopesRGBSize = size
            }
            var rgb: CVPixelBuffer?
            if let pool = scopesRGBPool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 2] as CFDictionary, &rgb) == kCVReturnSuccess, let rgb {
                scopesContext.render(source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: rgb, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
                analyze(rgb, histogram: histogram, waveform: waveform, zebra: zebra, peaking: peaking, falseColor: falseColor, sourceUpright: sourceUpright, mirrored: mirrored)
            }
            return
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        aidsLock.lock()
        let peakR = peakRed
        let peakG = peakGreen
        let peakB = peakBlue
        let threshold = peakThreshold
        aidsLock.unlock()

        let planar = CVPixelBufferGetPlaneCount(buffer) > 0

        guard let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            : CVPixelBufferGetBaseAddress(buffer) else {
            return
        }

        let width = planar
            ? CVPixelBufferGetWidthOfPlane(buffer, 0)
            : CVPixelBufferGetWidth(buffer)
        let height = planar
            ? CVPixelBufferGetHeightOfPlane(buffer, 0)
            : CVPixelBufferGetHeight(buffer)
        let stride = planar
            ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            : CVPixelBufferGetBytesPerRow(buffer)

        guard width > 32, height > 32 else { return }

        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Log formats arrive as 10-bit luma held in 16-bit words.
        let format = CVPixelBufferGetPixelFormatType(buffer)

        let wide = planar && (
            format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        )

        let words = base.assumingMemoryBound(to: UInt16.self)
        let wordStride = stride / 2

        // Brightness of one pixel, from a luma plane or from BGRA.
        func luma(_ x: Int, _ y: Int) -> Int {
            if planar {
                if wide {
                    return Int(words[y * wordStride + x] >> 8)
                }

                return Int(bytes[y * stride + x])
            }

            let index = y * stride + x * 4

            return (Int(bytes[index + 2]) * 54
                + Int(bytes[index + 1]) * 183
                + Int(bytes[index]) * 19) >> 8
        }

        let gridW = 160
        let gridH = max(8, Int((Double(gridW) * Double(height) / Double(width)).rounded()))
        let wantsImage = zebra || peaking || falseColor
        let edge = 3

        var bins = [Int](repeating: 0, count: 64)

        // Red, green and blue bins, when the frame is BGRA.
        let colorBins = histogram && planar == false
        var binsR = [Int](repeating: 0, count: colorBins ? 64 : 0)
        var binsG = [Int](repeating: 0, count: colorBins ? 64 : 0)
        var binsB = [Int](repeating: 0, count: colorBins ? 64 : 0)

        var wave = [Int](repeating: 0, count: waveform ? gridW * 64 * 3 : 0)
        var pixels = [UInt8](repeating: 0, count: wantsImage ? gridW * gridH * 4 : 0)

        for gy in 0..<gridH {
            for gx in 0..<gridW {
                var clipped = false
                var sharp = false
                var sum = 0

                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let px = ((gx * 2 + sx) * width + width / 2) / (gridW * 2)
                        let py = ((gy * 2 + sy) * height + height / 2) / (gridH * 2)

                        let x = min(max(px, edge), width - 1 - edge)
                        let y = min(max(py, edge), height - 1 - edge)
                        let value = luma(x, y)

                        sum += value
                        bins[value >> 2] += 1

                        if colorBins {
                            let pixel = y * stride + x * 4

                            binsB[Int(bytes[pixel]) >> 2] += 1
                            binsG[Int(bytes[pixel + 1]) >> 2] += 1
                            binsR[Int(bytes[pixel + 2]) >> 2] += 1
                        }

                        if waveform {
                            let pixel = y * stride + x * 4
                            for channel in 0..<3 {
                                let component = Int(bytes[pixel + 2 - channel])
                                wave[(gx * 64 + (component >> 2)) * 3 + channel] += 1
                            }
                        }

                        if value >= 224 { clipped = true }

                        if peaking, sharp == false {
                            let dx = abs(luma(x + edge, y) - luma(x - edge, y))
                            let dy = abs(luma(x, y + edge) - luma(x, y - edge))

                            sharp = dx + dy > threshold
                        }
                    }
                }

                guard wantsImage else { continue }

                let index = (gy * gridW + gx) * 4

                if falseColor {
                    // Brightness bands, from crushed blacks (purple) to
                    // clipped highlights (red). Mid grey is green.
                    let percent = (sum / 4) * 100 / 255

                    var red = 0
                    var green = 0
                    var blue = 0
                    var alpha = 0

                    switch percent {
                    case ..<2: (red, green, blue, alpha) = (140, 0, 200, 220)
                    case ..<10: (red, green, blue, alpha) = (0, 70, 255, 200)
                    case ..<33: (red, green, blue, alpha) = (0, 150, 160, 110)
                    case ..<48: (red, green, blue, alpha) = (40, 200, 70, 190)
                    case ..<60: (red, green, blue, alpha) = (0, 0, 0, 0)
                    case ..<72: (red, green, blue, alpha) = (255, 120, 170, 190)
                    case ..<90: (red, green, blue, alpha) = (255, 150, 30, 190)
                    case ..<97: (red, green, blue, alpha) = (255, 230, 40, 210)
                    default: (red, green, blue, alpha) = (235, 30, 30, 230)
                    }

                    // Premultiplied.
                    pixels[index] = UInt8(red * alpha / 255)
                    pixels[index + 1] = UInt8(green * alpha / 255)
                    pixels[index + 2] = UInt8(blue * alpha / 255)
                    pixels[index + 3] = UInt8(alpha)
                } else if zebra, clipped {
                    // Diagonal stripes, alternating white and black.
                    if ((gx + gy) / 2) % 2 == 0 {
                        pixels[index] = 235
                        pixels[index + 1] = 235
                        pixels[index + 2] = 235
                        pixels[index + 3] = 235
                    } else {
                        pixels[index + 3] = 110
                    }
                } else if peaking, sharp {
                    // Premultiplied peaking colour.
                    pixels[index] = peakR
                    pixels[index + 1] = peakG
                    pixels[index + 2] = peakB
                    pixels[index + 3] = 235
                }
            }
        }

        var normalized: [Float] = []

        if histogram {
            let peak = Float(max(bins.max() ?? 1, 1))
            normalized = bins.map { (Float($0) / peak).squareRoot() }
        }

        var channels: [[Float]] = []

        if colorBins {
            let channelPeak = Float(max(
                max(binsR.max() ?? 1, binsG.max() ?? 1),
                max(binsB.max() ?? 1, 1)
            ))

            channels = [binsR, binsG, binsB].map { channel in
                channel.map { (Float($0) / channelPeak).squareRoot() }
            }
        }

        // Zebra and peaking follow the mirrored front preview too.
        if wantsImage, !sourceUpright, mirrored {
            for row in 0..<gridH {
                for column in 0..<(gridW / 2) {
                    let left = (row * gridW + column) * 4
                    let right = (row * gridW + (gridW - 1 - column)) * 4

                    for channel in 0..<4 {
                        pixels.swapAt(left + channel, right + channel)
                    }
                }
            }
        }

        var image: CGImage?

        if wantsImage,
           let provider = CGDataProvider(data: Data(pixels) as CFData) {
            image = CGImage(
                width: gridW,
                height: gridH,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: gridW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        // Luma waveform: one column per grid column, brightness up the side.
        var waveImage: CGImage?

        if waveform {
            let peak = Float(max(wave.max() ?? 1, 1))
            var wavePixels = [UInt8](repeating: 0, count: gridW * 64 * 4)

            for column in 0..<gridW {
                for level in 0..<64 {
                    let source = (column * 64 + level) * 3
                    let index = ((63 - level) * gridW + column) * 4
                    var alpha: UInt8 = 0
                    for channel in 0..<3 {
                        let count = wave[source + channel]
                        let strength = count == 0 ? 0 : min(255, 40 + (Float(count) / peak).squareRoot() * 215)
                        let value = UInt8(strength)
                        wavePixels[index + channel] = value
                        alpha = max(alpha, value)
                    }
                    wavePixels[index + 3] = alpha
                }
            }

            if let provider = CGDataProvider(data: Data(wavePixels) as CFData) {
                waveImage = CGImage(
                    width: gridW,
                    height: 64,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: gridW * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    ),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            }
        }

        let framing = framingSnapshot()
        if let original = image, dualPreview || framing.anamorphic != .off {
            var overlay = CIImage(cgImage: original)
            if !sourceUpright && !dualPreview { overlay = uprightImage(overlay) }
            overlay = overlay.transformed(by: framing.transform)
            if dualPreview {
                let crop = ReelGeometry.crop(in: overlay.extent, ratio: 9.0 / 16, center: reelTrackingState.current)
                overlay = overlay.cropped(to: crop)
            }
            image = scopesContext.createCGImage(overlay, from: overlay.extent)
        }

        let frame = AnalysisFrame(
            histogram: normalized,
            overlay: image,
            waveform: waveImage,
            channels: channels
        )
        // The store's Sendable handler already hops to MainActor.
        onAnalysis?(frame)
    }

    func configureFraming(_ options: FramingOptions, tracking: Bool) {
        monitorLock.lock()
        frameOptions = options
        trackingEnabled = tracking
        monitorLock.unlock()
        subjectTracker.configure(enabled: tracking, framing: options)
        queue.async { [weak self] in self?.syncAnalysisOutput() }
    }

    func selectTrackedSubject(_ point: CGPoint) { subjectTracker.select(point) }

    private var lastTrackingFocusTime = 0.0
    private var lastTrackingFocusPoint = CGPoint(x: -1, y: -1)

    func focusTrackedSubject(_ point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice, device.isFocusPointOfInterestSupported else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastTrackingFocusTime >= 0.25,
                  hypot(point.x - self.lastTrackingFocusPoint.x, point.y - self.lastTrackingFocusPoint.y) >= 0.015 else { return }
            self.lastTrackingFocusTime = now
            self.lastTrackingFocusPoint = point
            var p = point
            if self.frontMirrored { p.x = 1 - p.x }
            let devicePoint: CGPoint
            switch self.lastAngle {
            case 0: devicePoint = p
            case 180: devicePoint = CGPoint(x: 1 - p.x, y: 1 - p.y)
            case 270: devicePoint = CGPoint(x: 1 - p.y, y: p.x)
            default: devicePoint = CGPoint(x: p.y, y: 1 - p.x)
            }
            self.lock(device) {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
        }
    }

    private func framingSnapshot() -> FramingOptions {
        monitorLock.lock(); defer { monitorLock.unlock() }; return frameOptions
    }

    func configureAudio(input: String?, monitoring: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredMicrophone = input
            self.headphonesMonitoring = monitoring
            self.configureAudioSession()
            let audio = AVAudioSession.sharedInstance()
            if self.currentLiveWriter() == nil && self.currentWriter() == nil && !self.movieOutput.isRecording {
                do {
                    let parts = input?.components(separatedBy: "|") ?? []
                    let port = audio.availableInputs?.first(where: { $0.uid == parts.first })
                    try audio.setPreferredInput(port)
                    if parts.count == 2, let id = Int(parts[1]), let source = port?.dataSources?.first(where: { $0.dataSourceID.intValue == id }) {
                        try port?.setPreferredDataSource(source)
                    }
                } catch { self.emit(.message("That microphone could not be selected.")) }
            }
            let hasMicrophone = self.session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }
            let hasOutput = self.session.outputs.contains(self.writerAudioOutput)
            if !hasMicrophone || !hasOutput {
            self.session.beginConfiguration()
            if !self.session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) { self.addAudioIfAllowed() }
            if !self.session.outputs.contains(self.writerAudioOutput), self.session.canAddOutput(self.writerAudioOutput) {
                self.writerAudioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
                self.session.addOutput(self.writerAudioOutput)
            }
            self.session.commitConfiguration()
            }
            self.publishAudioState()
            if !monitoring { self.audioQueue.async { [weak self] in self?.cameraAudio.stop() } }
        }
    }

    private func publishAudioState() {
        let audio = AVAudioSession.sharedInstance()
        let headphoneTypes: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .lineOut]
        let connected = audio.currentRoute.outputs.contains { headphoneTypes.contains($0.portType) }
        var options: [MicrophoneOption] = []
        for port in audio.availableInputs ?? [] {
            if let sources = port.dataSources, sources.count > 1 {
                options += sources.map { MicrophoneOption(id: port.uid + "|" + $0.dataSourceID.stringValue, name: port.portName + " · " + $0.dataSourceName, portUID: port.uid, dataSourceID: $0.dataSourceID.intValue) }
            } else {
                options.append(MicrophoneOption(id: port.uid, name: port.portName, portUID: port.uid, dataSourceID: nil))
            }
        }
        if let preferredMicrophone, !options.isEmpty, !options.contains(where: { $0.id == preferredMicrophone }) { self.preferredMicrophone = nil }
        cameraAudio.configure(monitoring: headphonesMonitoring, headphones: connected)
        if !connected { audioQueue.async { [weak self] in self?.cameraAudio.stop() } }
        onAudioState?(options, preferredMicrophone, connected, audio.isInputGainSettable)
    }

    func setComparison(_ comparing: Bool) {
        monitorLock.lock()
        monitorComparing = comparing
        monitorLock.unlock()
    }

    private var usesLivePreview: Bool {
        guard let writer = currentLiveWriter(), !writer.isFinishing else { return false }
        monitorLock.lock()
        let comparing = monitorComparing
        let revision = monitorRevision
        let known = previewMatchWriter == writer.previewIdentifier && previewMatchRevision == revision
        let cached = previewMatchValue
        let cube = monitorCube, cubeSize = monitorCubeSize, intensity = monitorIntensity
        let style = monitorStyle
        monitorLock.unlock()
        let framing = framingSnapshot()
        guard !comparing && (framing.anamorphic == .off || framing.saveDesqueezed) else { return false }
        if writer.secondary != nil { return true }
        guard framing.anamorphic == .off else { return false }
        if known { return cached }
        let matches = writer.matchesPreview(cube: cube, size: cubeSize, intensity: intensity, style: style)
        monitorLock.lock()
        if monitorRevision == revision {
            previewMatchWriter = writer.previewIdentifier; previewMatchRevision = revision; previewMatchValue = matches
        }
        monitorLock.unlock()
        return matches
    }

    #if DEBUG
    private var reliabilityMovie:[String:Any]?
    func reliabilityMovieResult() async -> [String:Any]? {
        await withCheckedContinuation { c in queue.async { c.resume(returning:self.reliabilityMovie) } }
    }
    func resetReliabilityMovie() async {
        await withCheckedContinuation { c in queue.async {self.reliabilityMovie=nil;c.resume()} }
    }
    func reliabilitySnapshot() async ->[String:Any] {
        await withCheckedContinuation { c in queue.async {
            self.monitorLock.lock()
            let meter=self.previewProbeMeters.first,source=self.sourceProbeMeter.count
            self.monitorLock.unlock()
            let device=self.videoDevice
            c.resume(returning:["running":self.session.isRunning,"virtual":device?.isVirtualDevice ?? false,
                "lens":self.lensChoice?.zoom ?? self.lensZoom,"colorSpace":device?.activeColorSpace.rawValue ?? -1,
                "fps":1/max(0.0001,device?.activeVideoMinFrameDuration.seconds ?? 1),
                "sourceFrames":source,"monitorFrames":meter?.count ?? 0,"monitorSteadyGapMs":(meter?.steadyGap ?? 0)*1000,
                "thermal":ProcessInfo.processInfo.thermalState.rawValue])
        }}
    }
    func beginSingleCadenceProbe() {
        monitorLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        previewProbeMeters = [PreviewProbeMeter(last: now), PreviewProbeMeter(last: now)]
        sourceProbeMeter = PreviewProbeMeter(last: now)
        previewProbeActive = true
        monitorLock.unlock()
    }

    func endSingleCadenceProbe(label: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.monitorLock.lock()
            self.previewProbeActive = false
            let preview = self.previewProbeMeters.first, source = self.sourceProbeMeter.count
            self.monitorLock.unlock()
            NSLog("SINGLE_CADENCE_VERIFY %@ min=%.4f max=%.4f source=%ld preview=%ld steadyGapMs=%.1f shared=%d native=%d thermal=%ld", label,
                  self.videoDevice?.activeVideoMinFrameDuration.seconds ?? -1, self.videoDevice?.activeVideoMaxFrameDuration.seconds ?? -1,
                  source, preview?.count ?? 0, (preview?.steadyGap ?? 0) * 1000, self.usesLivePreview ? 1 : 0, self.movieOutput.isRecording ? 1 : 0, ProcessInfo.processInfo.thermalState.rawValue)
        }
    }

    func galleryResumeProbe() async -> (Bool, Double) {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: (false, 999)); return }
                self.monitorLock.lock()
                let age = CFAbsoluteTimeGetCurrent() - self.lastMonitorEnqueue
                self.monitorLock.unlock()
                continuation.resume(returning: (self.session.isRunning, age))
            }
        }
    }
    private struct PreviewProbeMeter {
        var count = 0
        var last: Double
        var longestGap = 0.0
        var steadyGap = 0.0
    }
    private var previewProbeActive = false
    private var previewProbeMeters: [PreviewProbeMeter] = []
    private var sourceProbeMeter = PreviewProbeMeter(last: 0)

    private func noteProbeSourceFrame() {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        guard previewProbeActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        sourceProbeMeter.longestGap = max(sourceProbeMeter.longestGap, now - sourceProbeMeter.last)
        sourceProbeMeter.last = now
        sourceProbeMeter.count += 1
    }

    private func noteProbeFrame(on layer: AVSampleBufferDisplayLayer) {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        guard previewProbeActive else { return }
        let index = layer === monitorLayer ? 0 : 1
        let now = ProcessInfo.processInfo.systemUptime
        if previewProbeMeters[index].count >= 30 { previewProbeMeters[index].steadyGap = max(previewProbeMeters[index].steadyGap, now - previewProbeMeters[index].last) }
        previewProbeMeters[index].longestGap = max(previewProbeMeters[index].longestGap, now - previewProbeMeters[index].last)
        previewProbeMeters[index].last = now
        previewProbeMeters[index].count += 1
    }

    private var verificationMovieID: UUID?
    private var verificationAngles: [CGFloat] = [0, 180, 270, 90]

    private func verifyTemporaryMovies(_ urls: [URL]) {
        Task.detached(priority: .utility) {
            for url in urls {
                do {
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "Verification", code: 1) }
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let oriented=size.applying(transform),display=CGSize(width:abs(oriented.width),height:abs(oriented.height))
                    let duration = try await asset.load(.duration).seconds
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    reader.add(output)
                    guard reader.startReading() else { throw NSError(domain: "Verification", code: 2) }
                    var count = 0, times: [Double] = []
                    while let sample = output.copyNextSampleBuffer() {
                        // Compressed readers can deliver marker samples with
                        // invalid timestamps. They are not video frames.
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard pts.isNumeric, pts.seconds.isFinite else { continue }
                        count += 1; times.append(pts.seconds)
                    }
                    times.sort()
                    let start = times.first ?? 0
                    var longest = 0.0, buckets: [Int: Int] = [:]
                    for i in times.indices {
                        let time = times[i] - start
                        buckets[Int(time / 5), default: 0] += 1
                        if i > 0 && time > 1 { longest = max(longest, times[i] - times[i - 1]) }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-front-video") {NSLog("FRONT_VIDEO_ORIENTATION display=%@ portrait=%d",String(describing:display),display.height>display.width ? 1:0)}
                    NSLog("FRAME_CADENCE_VERIFY maxGapAfter1sMs=%.1f fiveSecondCounts=%@", longest * 1000, String(describing: buckets.keys.sorted().map { buckets[$0]! }))
                    NSLog("STYLE_FILE_VERIFY %@ size=%@ frames=%ld duration=%.2f valid=%d", url.lastPathComponent, String(describing: size), count, duration, reader.status == .completed && count > 0 ? 1 : 0)
                } catch { NSLog("STYLE_FILE_VERIFY FAIL %@", error.localizedDescription) }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func verifyStyledRecording(style: StyleParams) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            if ProcessInfo.processInfo.arguments.contains("--rotate-dual"), !self.verificationAngles.isEmpty {
                self.deviceAngle = self.verificationAngles.removeFirst()
                self.rotateConnections()
                NSLog("DUAL_ORIENTATION_VERIFY angle=%.0f portraitSource=%.0f", self.deviceAngle, self.analysisOutput.connection(with: .video)?.videoRotationAngle ?? -1)
            }
            self.recordingStyle = style
            self.recordingCube = nil
            let soak = ProcessInfo.processInfo.arguments.contains("--verify-efficiency")
            let interrupt = ProcessInfo.processInfo.arguments.contains("--verify-interruption")
            let duration = ProcessInfo.processInfo.arguments.contains("--long-soak") ? 180.0 : soak ? 60.0 : (ProcessInfo.processInfo.arguments.contains("--verify-throughput") ? 10.0 : 2.0)
            if soak {
                let thermal = ProcessInfo.processInfo.thermalState
                NSLog("EFFICIENCY_VERIFY starting %.0fs, thermal=%ld", duration, thermal.rawValue)
                guard thermal != .serious, thermal != .critical else {
                    NSLog("EFFICIENCY_VERIFY deferred because the device is already hot")
                    return
                }
            }
            self.monitorLock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            self.previewProbeMeters = [PreviewProbeMeter(last: now), PreviewProbeMeter(last: now)]
            self.sourceProbeMeter = PreviewProbeMeter(last: now)
            self.previewProbeActive = true
            self.monitorLock.unlock()
            let format = device.activeFormat
            let zoom = device.videoZoomFactor
            let id = UUID()
            self.verificationMovieID = id
            guard self.startLiveRecording(dual: true, recordingID: id, codec: RecordingCodec(rawValue: AVVideoCodecType.hevc.rawValue), bitrate: nil),
                  let writer = self.currentLiveWriter() else { NSLog("STYLE_VERIFY failed to start"); return }
            self.emit(.recording(true))
            if soak {
                self.queue.asyncAfter(deadline: .now() + 30) {
                    NSLog("EFFICIENCY_VERIFY halfway thermal=%ld", ProcessInfo.processInfo.thermalState.rawValue)
                }
            }
            if interrupt {
                self.queue.asyncAfter(deadline: .now() + 1) {
                    NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: self.session)
                }
                self.queue.asyncAfter(deadline: .now() + 1.5) {
                    NotificationCenter.default.post(name: AVCaptureSession.interruptionEndedNotification, object: self.session)
                }
                self.queue.asyncAfter(deadline: .now() + 2) {
                    let preserved = self.videoDevice === device && device.activeFormat === format && self.currentLiveWriter() == nil && self.session.isRunning
                    NSLog("INTERRUPTION_VERIFY resume=%@", preserved ? "PASS" : "FAIL")
                }
                return
            }
            self.queue.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.currentLiveWriter() === writer else { NSLog("STYLE_VERIFY interrupted before completion"); return }
                if soak { NSLog("EFFICIENCY_VERIFY finished thermal=%ld", ProcessInfo.processInfo.thermalState.rawValue) }
                self.monitorLock.lock()
                self.previewProbeActive = false
                let meters = self.previewProbeMeters
                let sourceFrames = self.sourceProbeMeter.count
                self.monitorLock.unlock()
                self.writerLock.lock(); let dropped = self.liveQueueDrops; self.writerLock.unlock()
                NSLog("STYLE_SOURCE_VERIFY frames=%ld deviceMinFrameDuration=%.4f queuedDrops=%ld", sourceFrames, device.activeVideoMinFrameDuration.seconds, dropped)
                NSLog("STYLE_VERIFY previews frames=%@ gapsMs=%@ steadyGapsMs=%@", String(describing: meters.map { $0.count }), String(describing: meters.map { Int($0.longestGap * 1000) }), String(describing: meters.map { Int($0.steadyGap * 1000) }))
                self.writerQueue.async {
                    writer.finish { success in
                        NSLog("STYLE_VERIFY files=%@", success ? "PASS" : "FAIL")
                        self.queue.async {
                            self.writerLock.lock(); self.liveWriter = nil; self.pendingLiveAnalysis.removeAll(keepingCapacity: true); self.liveAnalysisBusy = false; self.writerLock.unlock()
                            self.verificationMovieID = nil
                            if !writer.usesAnalysisStream {
                                self.session.beginConfiguration()
                                self.session.removeOutput(self.writerVideoOutput)
                                self.session.commitConfiguration()
                            }
                            self.syncAnalysisOutput()
                            if !self.session.isRunning { self.startOnQueue() }
                            self.emit(.recording(false))
                            let same = self.videoDevice === device && device.activeFormat === format && abs(device.videoZoomFactor - zoom) < 0.01
                            NSLog("RESUME_VERIFY preserved input/format/zoom=%@", same ? "PASS" : "FAIL")
                            self.verifyTemporaryMovies([writer.primary] + [writer.secondary].compactMap { $0 })
                            if ProcessInfo.processInfo.arguments.contains("--rotate-dual"), !self.verificationAngles.isEmpty {
                                self.verifyStyledRecording(style: style)
                            }
                        }
                    }
                }
            }
        }
    }

    // Explicit developer launch argument only. Sweeps previews without
    // recording, creating files, or changing the Photos library.
    func verifyUnifiedPreviewZoom() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let device = self.videoDevice, device.isVirtualDevice else {
                print("ZOOM_VERIFY FAIL: unified camera unavailable")
                return
            }
            let options = self.lensOptions()
            guard let tele = options.first(where: { $0.zoom == 8 }), let ultra = options.first(where: { $0.zoom == 0.5 }) else {
                print("ZOOM_VERIFY FAIL: requested stops unavailable")
                return
            }
            print("ZOOM_VERIFY DEVICE: \(device.deviceType.rawValue) virtual=\(device.isVirtualDevice) manualFocus=\(device.isLockingFocusWithCustomLensPositionSupported)")
            if ProcessInfo.processInfo.arguments.contains("--verify-advanced-preview") { self.selectTrackedSubject(CGPoint(x: 0.5, y: 0.5)) }
            self.verifyPreviewPhase(tele) { [weak self] in self?.verifyPreviewPhase(ultra) {} }
        }
    }

    private func verifyPreviewPhase(_ lens: LensOption, completion: @escaping @Sendable () -> Void) {
        monitorLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        previewProbeMeters = [PreviewProbeMeter(last: now), PreviewProbeMeter(last: now)]
        sourceProbeMeter = PreviewProbeMeter(last: now)
        previewProbeActive = true
        monitorLock.unlock()
        selectLens(lens.id)
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.monitorLock.lock()
            self.previewProbeActive = false
            let meters = self.previewProbeMeters
            let source = self.sourceProbeMeter
            self.monitorLock.unlock()
            let actual = Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier)
            let success = meters.allSatisfy { $0.count >= 15 && $0.longestGap < 0.15 } && abs(log2(actual / lens.zoom)) < 0.05
            print("ZOOM_VERIFY \(success ? "PASS" : "FAIL") target=\(lens.zoom)x actual=\(actual)x frames=\(meters.map { $0.count }) maxGapMs=\(meters.map { Int($0.longestGap * 1000) }) sourceGapMs=\(Int(source.longestGap * 1000)) primary=\(device.activePrimaryConstituent?.deviceType.rawValue ?? "unknown")")
            completion()
        }
    }
    #endif

    private func enqueuePreview(_ source: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: source, sampleBufferOut: &copy)
        guard let sample = copy else { return }
        if let entries = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            entries.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(sample)
        #if DEBUG
        noteProbeFrame(on: layer)
        #endif
    }

    func setDualPreview(_ enabled: Bool) {
        monitorLock.lock()
        dualPreview = enabled
        monitorLock.unlock()
        queue.async { [weak self] in self?.syncAnalysisOutput() }
    }

    func setRecordingGrade(cube: Data?, size: Int, intensity: Float, style: StyleParams) {
        queue.async { [weak self] in
            self?.recordingCube = cube
            self?.recordingCubeSize = size
            self?.recordingIntensity = intensity
            self?.recordingStyle = style
        }
    }

    private var liveAnalysisBusy = false
    private var pendingLiveAnalysis: [CMSampleBuffer] = []
    private var liveQueueDrops = 0

    private func renderAnalysisRecording(_ sample: CMSampleBuffer, writer: LiveMovieWriter) {
        writerQueue.async { [weak self] in
            guard let self, self.currentLiveWriter() === writer else { return }
            writer.appendVideo(sample)
            self.writerLock.lock()
            guard self.liveWriter === writer else { self.writerLock.unlock(); return }
            let next = self.pendingLiveAnalysis.isEmpty ? nil : self.pendingLiveAnalysis.removeFirst()
            if next == nil { self.liveAnalysisBusy = false }
            let sameWriter = self.liveWriter === writer
            if !sameWriter { self.liveAnalysisBusy = false }
            self.writerLock.unlock()
            if sameWriter, let next { self.renderAnalysisRecording(next, writer: writer) }
        }
    }

    private func currentLiveWriter() -> LiveMovieWriter? {
        writerLock.lock()
        defer { writerLock.unlock() }
        return liveWriter
    }

    private func startLiveRecording(dual: Bool, recordingID: UUID?, codec: RecordingCodec, bitrate: Int?) -> Bool {
        guard let device = videoDevice else { return false }
        let reuseAnalysis = dual && session.outputs.contains(analysisOutput)
        if !reuseAnalysis {
            session.beginConfiguration()
            if session.outputs.contains(analysisOutput) { session.removeOutput(analysisOutput) }
            let nativeFormat = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
            let preferredFormats: [OSType] = Self.formatGroup(of: device.activeFormat) == .eightBit420
                ? [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nativeFormat] : [nativeFormat]
            let offered = writerVideoOutput.availableVideoPixelFormatTypes
            let pixelFormat = preferredFormats.first { offered.contains($0) && Self.formatGroup(of: device.activeFormat) != nil }
                ?? kCVPixelFormatType_32BGRA
            writerVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            if dual {
                // The two delivered files are 1080p. Ask the camera scaler for
                // a matching stream rather than grading a 12 MP photo stream.
                let dimensions = device.activeFormat.formatDescription.dimensions
                let width = Int(min(dimensions.width, dimensions.height))
                let height = Int(max(dimensions.width, dimensions.height))
                func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
                let divisor = gcd(width, height)
                let unitW = width / divisor * 2, unitH = height / divisor * 2
                let steps = min(divisor / 2, max(1, Int(ceil(1920.0 / Double(unitW)))))
                writerVideoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: unitW * steps,
                    kCVPixelBufferHeightKey as String: unitH * steps
                ]
            }
            writerVideoOutput.alwaysDiscardsLateVideoFrames = true
            writerVideoOutput.setSampleBufferDelegate(self, queue: writerQueue)
            guard session.canAddOutput(writerVideoOutput) else {
                session.commitConfiguration()
                return false
            }
            session.addOutput(writerVideoOutput)
        }
        var audioSettings: [String: Any]?
        if session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
            if !session.outputs.contains(writerAudioOutput), session.canAddOutput(writerAudioOutput) {
                if reuseAnalysis { session.beginConfiguration() }
                writerAudioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                session.addOutput(writerAudioOutput)
                if reuseAnalysis { session.commitConfiguration() }
            }
            audioSettings = writerAudioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        }
        if !reuseAnalysis { rotateConnections(); session.commitConfiguration() }
        let dimensions = device.activeFormat.formatDescription.dimensions
        let landscape = captureAngle() == 0 || captureAngle() == 180
        var size = CGSize(width: CGFloat(landscape ? max(dimensions.width, dimensions.height) : min(dimensions.width, dimensions.height)), height: CGFloat(landscape ? min(dimensions.width, dimensions.height) : max(dimensions.width, dimensions.height)))
        if !dual, previewSettings?.resolution == nil {
            // Auto video stays within 4K's pixel budget even if the camera
            // is currently in a larger photo format. Preserve its aspect.
            let scale = min(1, sqrt((3840.0 * 2160.0) / Double(size.width * size.height)))
            size = CGSize(width: max(2, Int(Double(size.width) * scale) / 2 * 2), height: max(2, Int(Double(size.height) * scale) / 2 * 2))
        }
        let duration = device.activeVideoMinFrameDuration.seconds
        let fps = duration.isFinite && duration > 0 ? 1 / duration : 30
        let previewAngle = captureAngle()
        let previewMirrored = frontMirrored
        guard let writer = LiveMovieWriter(primary: makeURL(prefix: dual ? "Landscape" : "Graded"), secondary: dual ? makeURL(prefix: "Reel") : nil, recordingID: recordingID, completionQueue: writerQueue, resources: renderResources, fps: fps, audioSettings: audioSettings, cube: recordingCube, cubeSize: recordingCubeSize, intensity: recordingIntensity, style: recordingStyle, singleSize: size, framing: framingSnapshot(), tracking: dual ? reelTrackingState : nil, frameCrop: videoCrop, viewRatio: videoViewRatio, codec: dual ? AVVideoCodecType.hevc.rawValue : codec.rawValue, bitrate: bitrate ?? 24_000_000, usesAnalysisStream: reuseAnalysis,
            sourceOrientation: reuseAnalysis && frontMirrored ? .upMirrored : .up, onPreview: { [weak self] wide, tall in
            guard let self, self.usesLivePreview, !self.previewSuppressed else { return }
            if let tall {
                self.enqueuePreview(tall, on: self.monitorLayer)
                self.enqueuePreview(wide, on: self.landscapeMonitorLayer)
            } else if let preview = self.recordedPreviewRenderer.sample(wide, angle: previewAngle, mirrored: previewMirrored, context: self.ciContext) {
                self.enqueuePreview(preview, on: self.monitorLayer)
            }
            self.monitorLock.lock()
            self.lastMonitorEnqueue = CFAbsoluteTimeGetCurrent()
            self.monitorLock.unlock()
        }) else {
            session.beginConfiguration()
            session.removeOutput(writerVideoOutput)
            session.removeOutput(writerAudioOutput)
            session.commitConfiguration()
            return false
        }
        writerLock.lock()
        liveWriter = writer
        liveAnalysisBusy = false; pendingLiveAnalysis.removeAll(keepingCapacity: true)
        liveQueueDrops = 0
        writerLock.unlock()
        if !session.isRunning { session.startRunning() }
        applyTorch()
        retryRequestedTorch()
        return true
    }

    private var finishingLive = false

    private func finishLiveRecording() {
        guard !finishingLive, let writer = currentLiveWriter() else { return }
        finishingLive = true
        // Drain already-delivered frames before marking writer inputs finished.
        writerQueue.async { [weak self] in
            writer.finish { success in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.writerLock.lock()
                    self.liveWriter = nil
                    self.pendingLiveAnalysis.removeAll(keepingCapacity: true); self.liveAnalysisBusy = false
                    self.writerLock.unlock()
                    self.finishingLive = false
                    if !writer.usesAnalysisStream {
                        self.session.beginConfiguration()
                        self.session.removeOutput(self.writerVideoOutput)
                        if !self.headphonesMonitoring { self.session.removeOutput(self.writerAudioOutput) }
                        self.session.commitConfiguration()
                    }
                    self.syncAnalysisOutput()
                    if self.needsSessionRebuild, self.sessionWanted { self.startOnQueue() }
                    self.emit(.recording(false))
                    if success {
                        self.emit(.movie(primary: writer.primary, secondary: writer.secondary, kind: writer.secondary == nil ? .none : .verticalCrop, recordingID: writer.recordingID, baked: true))
                    } else {
                        self.emit(.message("The recording could not be finalized. No incomplete videos were added to Photos."))
                    }
                }
            }
        }
    }

    // MARK: - Log HEVC recording (asset writer)

    // AVCaptureMovieFileOutput only offers ProRes on Apple Log formats, so
    // Log + HEVC is recorded through an asset writer instead.
    private func startWriterRecording(
        codec: RecordingCodec,
        bitrate: Int?
    ) -> Bool {
        guard let device = videoDevice else { return false }

        let duration = device.activeVideoMinFrameDuration

        let fps: Double = duration.isValid && duration.seconds > 0
            ? 1.0 / duration.seconds
            : 30

        let size = device.activeFormat.formatDescription.dimensions

        session.beginConfiguration()

        // A second 4K stream next to the writer can starve it of frames.
        if session.outputs.contains(analysisOutput) {
            session.removeOutput(analysisOutput)
        }

        let preferred: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ]

        let offered = writerVideoOutput.availableVideoPixelFormatTypes.map {
            UInt32(truncatingIfNeeded: ($0 as NSNumber).intValue)
        }

        if let formatType = preferred.first(where: { offered.contains($0) }) {
            writerVideoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: formatType
            ]
        }

        // Bound capture latency if the hardware encoder stalls. Do not retain
        // an unbounded queue of full-resolution 10-bit camera buffers.
        writerVideoOutput.alwaysDiscardsLateVideoFrames = true
        writerVideoOutput.setSampleBufferDelegate(self, queue: writerQueue)

        guard session.canAddOutput(writerVideoOutput) else {
            session.commitConfiguration()
            return false
        }

        session.addOutput(writerVideoOutput)

        var audioSettings: [String: Any]?

        let hasMic = session.inputs.contains {
            ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true
        }

        if hasMic {
            writerAudioOutput.setSampleBufferDelegate(self, queue: audioQueue)

            if !session.outputs.contains(writerAudioOutput), session.canAddOutput(writerAudioOutput) {
                session.addOutput(writerAudioOutput)
            }
            audioSettings = writerAudioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        }

        rotateConnections()
        session.commitConfiguration()

        if session.isRunning == false {
            session.startRunning()
        }

        let target = bitrate
            ?? RecBitrate.high.bitsPerSecond(
                width: Int(size.width),
                height: Int(size.height),
                fps: fps,
                codec: codec.rawValue
            )
            ?? 60_000_000

        let url = makeURL(prefix: "Log")

        primaryURL = url
        secondaryURL = nil
        finishedPrimary = false
        finishedSecondary = true

        setWriter(
            LogWriter(
                url: url,
                codec: codec.rawValue,
                bitrate: target,
                fps: fps,
                audioSettings: audioSettings
            )
        )

        print("""
        STILLARC RECORDING (asset writer)
        Codec: \(codec.title)
        Resolution: \(size.width)x\(size.height)
        Frame rate: \(fps)
        Bitrate: \(target / 1_000_000) Mbps
        """)

        return true
    }

    private func finishWriterRecording() {
        guard let writer = currentWriter() else { return }

        writer.finish { [weak self] success in
            self?.queue.async {
                guard let self else { return }

                self.setWriter(nil)

                self.session.beginConfiguration()
                self.session.removeOutput(self.writerVideoOutput)
                if !self.headphonesMonitoring { self.session.removeOutput(self.writerAudioOutput) }
                self.session.commitConfiguration()

                // Bring the analysis stream back for the monitor and aids.
                self.syncAnalysisOutput()

                if success == false {
                    self.primaryURL = nil
                }

                self.finishedPrimary = true
                self.finishedSecondary = true
                if self.needsSessionRebuild, self.sessionWanted { self.startOnQueue() }
                self.emit(.recording(false))
                self.finishMovies()
            }
        }
    }

    private func currentWriter() -> LogWriter? {
        writerLock.lock()
        defer { writerLock.unlock() }

        return activeWriter
    }

    private func setWriter(_ writer: LogWriter?) {
        writerLock.lock()
        activeWriter = writer
        writerLock.unlock()
    }

    // MARK: - Focus loupe

    // A small zoomed window on the camera picture around the focus point,
    // drawn from the same frames as the LUT preview.
    func setLoupe(on: Bool, point: CGPoint, viewSize: CGSize) {
        loupeLock.lock()
        loupeOn = on
        loupeViewPoint = point
        loupeViewSize = viewSize
        loupeLock.unlock()

        if on == false {
            loupeLayer.sampleBufferRenderer.flush()
        }

        queue.async { [weak self] in
            self?.syncAnalysisOutput()
        }
    }

    private var loupeActive: Bool {
        loupeLock.lock()
        defer { loupeLock.unlock() }

        return loupeOn
    }

    private func renderLoupe(_ source: CVPixelBuffer) {
        loupeLock.lock()
        let viewPoint = loupeViewPoint
        let viewSize = loupeViewSize
        loupeLock.unlock()

        guard viewSize.width > 1, viewSize.height > 1 else { return }

        var width = CGFloat(CVPixelBufferGetWidth(source))
        var height = CGFloat(CVPixelBufferGetHeight(source))

        // A frame that arrives sideways is turned upright.
        let turn = width > height && position != .front

        if turn {
            swap(&width, &height)
        }

        // The viewfinder fills with the frame. Find the touched point in it.
        let fit = max(viewSize.width / width, viewSize.height / height)
        let shownW = width * fit
        let shownH = height * fit

        var fx = (viewPoint.x - (viewSize.width - shownW) / 2) / fit
        var fy = (viewPoint.y - (viewSize.height - shownH) / 2) / fit

        // A 100 pt window at 3x shows this much of the frame.
        let side = min(min(width, height) - 24, (100.0 / 3.0) / fit)

        guard side > 16 else { return }

        let margin: CGFloat = 12 + side / 2

        fx = min(max(fx, margin), width - margin)
        fy = min(max(fy, margin), height - margin)

        // No colour management, like the monitor.
        var image = CIImage(
            cvPixelBuffer: source,
            options: [.colorSpace: NSNull()]
        )

        if frontMirrored {
            image = image.oriented(.upMirrored)
        }

        if turn {
            image = image.oriented(.right)
        }

        let extent = image.extent

        image = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )

        // Core Image counts from the bottom left.
        let crop = CGRect(
            x: fx - side / 2,
            y: (height - fy) - side / 2,
            width: side,
            height: side
        )

        let out = 360
        let scale = CGFloat(out) / side

        image = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(
                translationX: -crop.minX,
                y: -crop.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let frame = CGRect(x: 0, y: 0, width: out, height: out)

        if loupePool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: out,
                kCVPixelBufferHeightKey as String: out,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]

            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            loupePool = pool
        }

        guard let pool = loupePool else { return }

        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)

        guard let destination else { return }

        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil

        do {
            let task = try ciContext.startTask(
                toRender: image.clampedToExtent().cropped(to: frame),
                from: frame,
                to: target,
                at: .zero
            )

            guard waitForRender(task) else { return }
        } catch {
            return
        }

        var description: CMVideoFormatDescription?

        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: destination,
            formatDescriptionOut: &description
        )

        guard let description else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: destination,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )

        guard let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        let renderer = loupeLayer.sampleBufferRenderer

        if renderer.status == .failed {
            renderer.flush()
        }

        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
        }
    }

    // MARK: - Timelapse video

    // Records one frame every `interval` seconds and plays them back at
    // 30 frames a second. Frames come from the same stream the Log writer
    // uses, so no second recording pipeline is needed.
    func startTimelapse(interval: Double) {
        queue.async { [weak self] in
            guard let self else { return }

            guard self.movieOutput.isRecording == false,
                  self.currentWriter() == nil,
                  self.currentLiveWriter() == nil,
                  self.currentTimelapse() == nil,
                  self.videoDevice != nil else {
                return
            }

            self.session.beginConfiguration()

            // One stream is enough. The aids come back afterwards.
            if self.session.outputs.contains(self.analysisOutput) {
                self.session.removeOutput(self.analysisOutput)
            }

            self.writerVideoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]

            self.writerVideoOutput.alwaysDiscardsLateVideoFrames = true
            self.writerVideoOutput.setSampleBufferDelegate(self, queue: self.writerQueue)

            guard self.session.canAddOutput(self.writerVideoOutput) else {
                self.session.commitConfiguration()
                self.syncAnalysisOutput()
                self.emit(.message("The timelapse could not start."))
                return
            }

            self.session.addOutput(self.writerVideoOutput)
            self.rotateConnections()
            self.session.commitConfiguration()

            if self.session.isRunning == false {
                self.session.startRunning()
            }

            let url = self.makeURL(prefix: "Timelapse")
            let handler = self.onTimelapseCount

            self.setTimelapse(
                TimelapseWriter(
                    url: url,
                    interval: max(1, interval),
                    fps: 30,
                    onFrame: { count in
                        Task { @MainActor in
                            handler?(count)
                        }
                    }
                )
            )

            print("STILLARC TIMELAPSE: one frame every \(interval) s")

            self.emit(.recording(true))
        }
    }

    private func finishTimelapse() {
        // One stop at a time. A second press while the file is closing is
        // ignored.
        guard timelapseStopping == false,
              let writer = currentTimelapse() else {
            return
        }

        timelapseStopping = true

        let url = writer.url

        print("STILLARC TIMELAPSE: stopping")

        // No more frames go to the writer from here.
        writerVideoOutput.setSampleBufferDelegate(nil, queue: nil)

        writer.finish { [weak self] frames, success in
            self?.queue.async {
                guard let self else { return }

                print("STILLARC TIMELAPSE: file closed, \(frames) frames")

                self.timelapseStopping = false
                self.setTimelapse(nil)

                self.session.beginConfiguration()

                if self.session.outputs.contains(self.writerVideoOutput) {
                    self.session.removeOutput(self.writerVideoOutput)
                }

                self.session.commitConfiguration()

                print("STILLARC TIMELAPSE: camera restored")

                self.syncAnalysisOutput()

                self.emit(.recording(false))

                if success {
                    print("STILLARC TIMELAPSE: saved \(frames) frames")

                    self.emit(.movie(primary: url, secondary: nil, kind: .none))
                } else {
                    self.emit(.message("The timelapse had no frames to save."))
                }
            }
        }
    }

    private func currentTimelapse() -> TimelapseWriter? {
        writerLock.lock()
        defer { writerLock.unlock() }

        return activeTimelapse
    }

    private func setTimelapse(_ writer: TimelapseWriter?) {
        writerLock.lock()
        activeTimelapse = writer
        writerLock.unlock()
    }

    // MARK: - LUT monitor

    // Shows the live image through a LUT, so Log can be judged corrected
    // while the file keeps recording flat.
    func setMonitor(cube: Data?, size: Int, intensity: Float) {
        monitorLock.lock()
        monitorRevision &+= 1
        monitorCube = cube
        monitorCubeSize = size
        monitorIntensity = intensity
        let idle = monitorCube == nil && monitorStyle == nil
        monitorLock.unlock()

        if idle {
            monitorLayer.sampleBufferRenderer.flush()
        }

        queue.async { [weak self] in
            self?.syncAnalysisOutput()
        }
    }

    // A camera style shown live in the viewfinder, with or without a LUT.
    func setStyle(_ style: StyleParams?, keepPhotoPreviewWarm: Bool = false) {
        let next = (style?.isIdentity == true) ? nil : style
        monitorLock.lock()
        if keepPhotoPreviewWarm, monitorStyle == next {
            monitorLock.unlock()
            return
        }
        monitorRevision &+= 1
        monitorStyle = next
        let idle = monitorCube == nil && monitorStyle == nil
        monitorLock.unlock()

        if idle, keepPhotoPreviewWarm {
            analysisQueue.async { [weak self] in
                guard let self, !self.monitorActive else { return }
                self.monitorLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            // A quick A/B or another look choice can reuse the output without
            // reconfiguring the camera underneath the native preview.
            queue.asyncAfter(deadline: .now() + .milliseconds(850)) { [weak self] in
                guard let self, !self.monitorActive else { return }
                self.syncAnalysisOutput()
            }
            return
        }
        if idle { monitorLayer.sampleBufferRenderer.flush() }

        queue.async { [weak self] in self?.syncAnalysisOutput() }
    }

    private var monitorActive: Bool {
        monitorLock.lock()
        defer { monitorLock.unlock() }

        return monitorCube != nil || monitorStyle != nil || dualPreview || trackingEnabled || frameOptions.anamorphic != .off
    }

    // Waits for a picture to finish drawing, but never for ever. If the
    // camera takes a buffer away mid-draw, the wait gives up and the next
    // frame carries on, instead of the whole preview stopping.
    private func waitForRender(_ task: CIRenderTask) -> Bool {
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInteractive).async {
            _ = try? task.waitUntilCompleted()
            done.signal()
        }

        if done.wait(timeout: .now() + 0.3) == .success {
            return true
        }

        print("STILLARC MONITOR: a frame took too long and was skipped.")
        return false
    }

    private func renderMonitor(_ source: CVPixelBuffer) {
        monitorLock.lock()
        let cube = monitorCube
        let dimension = monitorCubeSize
        let intensity = monitorIntensity
        let style = monitorStyle
        monitorLock.unlock()

        let useCube = cube != nil && dimension > 1

        let framing = framingSnapshot()
        guard useCube || style != nil || dualPreview || framing.anamorphic != .off else { return }

        var sourceW = CVPixelBufferGetWidth(source)
        var sourceH = CVPixelBufferGetHeight(source)

        // Rebuild size-dependent resources when the source format changes.
        // Unified-camera frames remain complete during constituent handoffs;
        // pausing that stream would introduce a visible freeze ourselves.
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)


        if monitorSourceSize.w != sourceW
            || monitorSourceSize.h != sourceH
            || monitorSourceFormat != sourceFormat {

            monitorSourceSize = (sourceW, sourceH)
            monitorSourceFormat = sourceFormat
            monitorEdges = (0, 0, 0, 0)
            edgeHold = 0

            // A complete new-format sample is already safe to render.
            // Holding it when Log switches from proxy to recording buffers
            // inserts a visible freeze at the start of an otherwise live feed.
        }

        monitorLock.lock()
        let holdUntil = monitorHoldUntil
        monitorLock.unlock()

        guard CFAbsoluteTimeGetCurrent() >= holdUntil else { return }

        // If the frame arrives sideways while the phone is upright, turn it.
        let turnFrame = sourceW > sourceH && position != .front

        if turnFrame {
            swap(&sourceW, &sourceH)
        }

        let scale = min(1, 1920.0 / Double(max(sourceW, sourceH)))
        let outW = max(2, (Int(Double(sourceW) * scale) / 2) * 2)
        let outH = max(2, (Int(Double(sourceH) * scale) / 2) * 2)

        // No colour management: the LUT expects the raw Log values.
        var image = CIImage(
            cvPixelBuffer: source,
            options: [.colorSpace: NSNull()]
        )

        // Some frames carry an empty edge (zero chroma shows as bright green),
        // for example when recording starts. Measure it and cut it off.
        let edges = stableEdges(for: source)

        if edges.l + edges.r + edges.t + edges.b > 0 {
            let full = image.extent
            let pad: CGFloat = 6

            let cropRect = CGRect(
                x: full.minX + CGFloat(edges.l) + pad,
                y: full.minY + CGFloat(edges.b) + pad,
                width: full.width - CGFloat(edges.l + edges.r) - pad * 2,
                height: full.height - CGFloat(edges.t + edges.b) - pad * 2
            )

            if cropRect.width > 64, cropRect.height > 64 {
                image = image.cropped(to: cropRect)
            }
        }

        if edges != monitorEdges {
            monitorEdges = edges
            print("STILLARC MONITOR: empty edges left \(edges.l), right \(edges.r), top \(edges.t), bottom \(edges.b), format \(CVPixelBufferGetPixelFormatType(source)), \(CVPixelBufferGetWidth(source))x\(CVPixelBufferGetHeight(source))")
        }

        // Analysis frames arrive unmirrored. The front preview is mirrored
        // like a selfie, so flip the LUT monitor to match it.
        if frontMirrored {
            image = image.oriented(.upMirrored)
        }

        if turnFrame {
            image = image.oriented(lastAngle == 180 ? .left : .right)
        }

        // Camera buffers can carry a few unused or empty pixels along an
        // edge, which show as a flashing green or black line. Trim a small
        // border, then stretch the rest to fill the output exactly.
        let raw = image.extent
        let trim = max(12, min(raw.width, raw.height) * 0.012)
        let inner = dualPreview || framing.anamorphic != .off ? raw : raw.insetBy(dx: trim, dy: trim)

        image = image
            .cropped(to: inner)
            .transformed(by: CGAffineTransform(
                translationX: -inner.minX,
                y: -inner.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(outW) / inner.width,
                y: CGFloat(outH) / inner.height
            ))

        if framing.saveDesqueezed, framing.anamorphic != .off {
            let corrected = (dualPreview ? image : uprightImage(image)).transformed(by: framing.transform)
            let graded = StyleGrade.grade(corrected, cube: useCube ? cube : nil, cubeSize: dimension,
                                          intensity: intensity, style: style ?? .identity)
                .cropped(to: corrected.extent)
            if dualPreview { renderDualUpright(graded, resolveStyle: useCube || !(style ?? .identity).isIdentity) }
            else {
                renderPreview(graded, size: ReelGeometry.previewSize(for: graded.extent), pool: &anamorphicPreviewPool, layer: monitorLayer)
                monitorLock.lock(); lastMonitorEnqueue = CFAbsoluteTimeGetCurrent(); monitorLock.unlock()
            }
            return
        }

        // LUT first, then the camera style on top.
        var result = StyleGrade.grade(
            image,
            cube: useCube ? cube : nil,
            cubeSize: dimension,
            intensity: intensity,
            style: style ?? .identity
        )

        // Pin the picture to the output rectangle and repeat its edge
        // pixels, so no empty column is left (the green edge line).
        let origin = result.extent
        let frame = CGRect(x: 0, y: 0, width: outW, height: outH)

        result = result
            .transformed(by: CGAffineTransform(
                translationX: -origin.minX,
                y: -origin.minY
            ))
            .clampedToExtent()
            .cropped(to: frame)

        if dualPreview {
            renderDualPreview(result, resolveStyle: useCube || style != nil)
            return
        }

        if framing.anamorphic != .off {
            let upright = uprightImage(result).transformed(by: framing.transform)
            renderPreview(upright, size: ReelGeometry.previewSize(for: upright.extent), pool: &anamorphicPreviewPool, layer: monitorLayer)
            monitorLock.lock(); lastMonitorEnqueue = CFAbsoluteTimeGetCurrent(); monitorLock.unlock()
            return
        }

        let renderer = monitorLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        // Never spend GPU time drawing a frame the display will reject.
        guard renderer.isReadyForMoreMediaData else { monitorNotReady += 1; return }

        // Dual/anamorphic branches own their destinations. Allocate this
        // single-preview buffer only after those paths have returned.
        if monitorPool == nil || monitorPoolSize.width != outW || monitorPoolSize.height != outH {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]

            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)

            monitorPool = pool
            monitorPoolSize = (outW, outH)

        }

        guard let pool = monitorPool else { return }

        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary, &destination)

        guard let destination else { return }

        // Wait for the picture to be fully drawn before it is shown, so a
        // half-written frame can never reach the screen.
        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil

        do {
            let task = try ciContext.startTask(
                toRender: result,
                from: frame,
                to: target,
                at: .zero
            )

            guard waitForRender(task) else { return }
        } catch {
            return
        }

        var description: CMVideoFormatDescription?

        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: destination,
            formatDescriptionOut: &description
        )

        guard let description else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: destination,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )

        guard let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }



        if renderer.status == .failed {
            renderer.flush()
        }

        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
            monitorEnqueued += 1
            #if DEBUG
            noteProbeFrame(on: monitorLayer)
            #endif

            monitorLock.lock()
            lastMonitorEnqueue = CFAbsoluteTimeGetCurrent()
            monitorLock.unlock()
        } else {
            monitorNotReady += 1
        }

    }

    private func uprightImage(_ portrait: CIImage) -> CIImage {
        switch lastAngle {
        case 0: portrait.oriented(.left)
        case 180: portrait.oriented(.right)
        case 270: portrait.oriented(.down)
        default: portrait
        }
    }

    private func renderDualPreview(_ portrait: CIImage, resolveStyle: Bool) {
        // The analysis connection is fixed at 90 degrees, including after
        // lifecycle and format changes. Device angle must not rotate it again.
        let image = portrait.transformed(by: framingSnapshot().transform)
        renderDualUpright(image, resolveStyle: resolveStyle)
    }

    private let dualFrameRenderer = CameraFrameRenderer()

    private func renderDualUpright(_ graded: CIImage, resolveStyle: Bool = true) {
        let image: CIImage
        if resolveStyle {
            guard let complete = dualFrameRenderer.materialize(graded, context: ciContext) else { return }
            image = complete
        } else { image = graded }
        renderPreview(image, size: CGSize(width: 640, height: 360), pool: &landscapePreviewPool, layer: landscapeMonitorLayer)
        renderPreview(image, size: CGSize(width: 540, height: 960), pool: &reelPreviewPool, layer: monitorLayer, center: reelTrackingState.advance())
        monitorLock.lock()
        lastMonitorEnqueue = CFAbsoluteTimeGetCurrent()
        monitorLock.unlock()
    }

    private func renderPreview(_ image: CIImage, size: CGSize, pool: inout CVPixelBufferPool?, layer: AVSampleBufferDisplayLayer, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let extent = image.extent
        let ratio = size.width / size.height
        let crop = ReelGeometry.crop(in: extent, ratio: ratio, center: center)
        let output = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: size.height / crop.height))
        let key = ObjectIdentifier(layer)
        if previewPoolSizes[key] != size { pool = nil; previewPoolSizes[key] = size; previewFormats[key] = nil }
        if pool == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        ciContext.render(output, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: previewColorSpace)
        if previewFormats[key] == nil {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
            previewFormats[key] = format
        }
        guard let format = previewFormats[key] else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample { enqueuePreview(sample, on: layer) }
    }

    // Counts empty edge columns and rows (both chroma values near zero) in a
    // camera frame. Handles 8-bit and 10-bit layouts. Order: left, right,
    // top, bottom, in luma pixels.
    private func emptyEdges(of buffer: CVPixelBuffer) -> (l: Int, r: Int, t: Int, b: Int) {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return (0, 0, 0, 0) }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            return (0, 0, 0, 0)
        }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        guard width > 16, height > 16 else { return (0, 0, 0, 0) }

        // 10-bit formats keep each value in 16 bits.
        let format = CVPixelBufferGetPixelFormatType(buffer)

        let wide = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange

        // 4:2:0 halves the rows too; 4:2:2 does not.
        let rowScale = CVPixelBufferGetHeightOfPlane(buffer, 0) == height ? 1 : 2

        func empty(_ x: Int, _ y: Int) -> Bool {
            if wide {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                return (row[x * 2] >> 8) < 4 && (row[x * 2 + 1] >> 8) < 4
            }

            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            return row[x * 2] < 4 && row[x * 2 + 1] < 4
        }

        func emptyColumn(_ x: Int) -> Bool {
            for step in 0..<12 where empty(x, step * (height - 1) / 11) == false {
                return false
            }

            return true
        }

        func emptyRow(_ y: Int) -> Bool {
            for step in 0..<12 where empty(step * (width - 1) / 11, y) == false {
                return false
            }

            return true
        }

        let limitX = width / 4
        let limitY = height / 4

        var left = 0
        while left < limitX, emptyColumn(left) { left += 1 }

        var right = 0
        while right < limitX, emptyColumn(width - 1 - right) { right += 1 }

        // Buffer rows run top to bottom; the image runs bottom to top.
        var top = 0
        while top < limitY, emptyRow(top) { top += 1 }

        var bottom = 0
        while bottom < limitY, emptyRow(height - 1 - bottom) { bottom += 1 }

        return (left * 2, right * 2, top * rowScale, bottom * rowScale)
    }

    // An empty edge is held for a moment once seen, so the framing never
    // jumps between cropped and uncropped frames.
    private func stableEdges(for buffer: CVPixelBuffer) -> (l: Int, r: Int, t: Int, b: Int) {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange { return (0, 0, 0, 0) }
        let found = emptyEdges(of: buffer)

        if found.l + found.r + found.t + found.b > 0 {
            edgeHold = 30

            return (
                max(found.l, monitorEdges.l),
                max(found.r, monitorEdges.r),
                max(found.t, monitorEdges.t),
                max(found.b, monitorEdges.b)
            )
        }

        if edgeHold > 0 {
            edgeHold -= 1
            return monitorEdges
        }

        return found
    }

    // MARK: - Utilities

    private func makeURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).mov")
    }

    private func lock(
        _ device: AVCaptureDevice,
        _ body: () -> Void
    ) {
        do {
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
            }

            body()
        } catch {
            emit(.message("The camera could not apply that setting."))
        }
    }

    private func emit(_ event: EngineEvent) {
        #if DEBUG
        if case .movie(let primary, let secondary, _, _, _) = event,
           ProcessInfo.processInfo.arguments.contains("--verify-camera-reliability") {
            Task.detached(priority:.utility) { [weak self] in
                var result:[String:Any]
                do {result=try await CameraRecordingQA.inspect(primary)} catch {result=["passed":false,"error":error.localizedDescription]}
                for url in [primary]+[secondary].compactMap({$0}) {try? FileManager.default.removeItem(at:url)}
                let report=result
                self?.queue.async { [weak self] in self?.reliabilityMovie=report }
            }
            return
        }
        if case .movie(let primary, let secondary, _, _, _) = event,
           ProcessInfo.processInfo.arguments.contains("--verify-single-recording") {
            verifyTemporaryMovies([primary] + [secondary].compactMap { $0 })
            return
        }
        if case .movie(let primary, let secondary, _, let id, _) = event,
           let verificationMovieID, id == verificationMovieID {
            self.verificationMovieID = nil
            NSLog("INTERRUPTION_VERIFY finalized diagnostic recording")
            verifyTemporaryMovies([primary] + [secondary].compactMap { $0 })
            return
        }
        #endif
        let handler = onEvent

        Task { @MainActor in
            handler?(event)
        }
    }
}


// MARK: - Aspect crop export

// Re-encodes a recording cropped to the chosen aspect, keeping the codec,
// bit depth, colour tags, frame rate and audio of the original.
nonisolated enum AspectMovie {

    static func export(from url: URL, viewRect: CGRect, viewRatio: Double) async -> URL? {
        do {
            return try await run(from: url, viewRect: viewRect, viewRatio: viewRatio)
        } catch {
            print("STILLARC ASPECT CROP ERROR: \(error.localizedDescription)")
            return nil
        }
    }

    private static func run(from url: URL, viewRect: CGRect, viewRatio: Double) async throws -> URL? {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = try await track.load(.nominalFrameRate)
        let minDuration = try await track.load(.minFrameDuration)
        let dataRate = try await track.load(.estimatedDataRate)
        let formats = try await track.load(.formatDescriptions)
        let duration = try await asset.load(.duration)

        guard let description = formats.first else { return nil }

        // Size as displayed, after rotation.
        let displayed = CGRect(origin: .zero, size: natural).applying(transform)
        let displayW = abs(displayed.width)
        let displayH = abs(displayed.height)

        guard displayW > 16, displayH > 16 else { return nil }

        // The viewfinder is 3:4 and fills with the video, so map the frame
        // lines (in viewfinder space) back onto the video.
        let videoRatio = Double(displayW / displayH)

        var visibleW = 1.0
        var visibleH = 1.0

        if videoRatio > viewRatio {
            visibleW = viewRatio / videoRatio
        } else {
            visibleH = videoRatio / viewRatio
        }

        let nx = (1 - visibleW) / 2 + Double(viewRect.minX) * visibleW
        let ny = (1 - visibleH) / 2 + Double(viewRect.minY) * visibleH
        let nw = Double(viewRect.width) * visibleW
        let nh = Double(viewRect.height) * visibleH

        // Nothing to crop.
        if nw > 0.99, nh > 0.99 { return url }

        func even(_ value: Double) -> Double {
            max(2, (value / 2).rounded(.down) * 2)
        }

        // Zero is a valid crop origin; the size helper intentionally has a two-pixel minimum.
        let cropX = max(0, (nx * Double(displayW) / 2).rounded(.down) * 2)
        let cropY = max(0, (ny * Double(displayH) / 2).rounded(.down) * 2)

        let cropW = min(even(nw * Double(displayW)), Double(displayW) - cropX)
        let cropH = min(even(nh * Double(displayH)), Double(displayH) - cropY)

        let outW = even(cropW)
        let outH = even(cropH)

        // Format details of the original.
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let codecString = fourCC(subtype)
        let isProRes = codecString.hasPrefix("ap")

        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]

        let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let matrix = extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let bits = extensions?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int ?? 8

        let isLogOrHDR = transfer.map {
            $0.lowercased().contains("log") || $0.contains("2100") || $0.contains("2084")
        } ?? false

        let tenBit = isProRes || bits > 8 || isLogOrHDR

        // Composition that rotates and crops.
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)

        if minDuration.isValid, minDuration.seconds > 0 {
            composition.frameDuration = minDuration
        } else {
            composition.frameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(max(1, Int(nominalRate.rounded())))
            )
        }

        composition.colorPrimaries = primaries
        composition.colorTransferFunction = transfer
        composition.colorYCbCrMatrix = matrix

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        layer.setTransform(
            transform.concatenating(
                CGAffineTransform(translationX: -cropX, y: -cropY)
            ),
            at: .zero
        )

        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        // Reader.
        let reader = try AVAssetReader(asset: asset)

        let pixelFormat = tenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ]
        )

        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioHint: CMFormatDescription?

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)

            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                audioHint = try await audioTrack.load(.formatDescriptions).first
            }
        }

        // Writer.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stillarc-Crop-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: codecString),
            AVVideoWidthKey: Int(outW),
            AVVideoHeightKey: Int(outH)
        ]

        if isProRes == false {
            let keptArea = (outW * outH) / Double(displayW * displayH)
            let target = max(Int(Double(dataRate) * keptArea), 8_000_000)

            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: target
            ]

            if codecString == "hvc1" || codecString == "hev1", tenBit {
                compression[AVVideoProfileLevelKey] = "HEVC_Main10_AutoLevel"
            }

            settings[AVVideoCompressionPropertiesKey] = compression
        }

        if let primaries, let transfer, let matrix {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix
            ]
        }

        if writer.canApply(outputSettings: settings, forMediaType: .video) == false {
            // Try again without colour tags, then without the profile.
            settings.removeValue(forKey: AVVideoColorPropertiesKey)

            if writer.canApply(outputSettings: settings, forMediaType: .video) == false {
                print("STILLARC ASPECT CROP: the writer rejects \(codecString) settings.")
                return nil
            }

            print("STILLARC ASPECT CROP: colour tags could not be carried over.")
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?

        if audioOutput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audioHint
            )

            input.expectsMediaDataInRealTime = false

            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            print("STILLARC ASPECT CROP: could not start. \(String(describing: writer.error))")
            return nil
        }

        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        var copiers: [SampleCopier] = []

        copiers.append(
            SampleCopier(input: videoInput, output: videoOutput, queue: DispatchQueue(label: "stillarc.crop.video"), group: group)
        )

        if let audioInput, let audioOutput {
            copiers.append(
                SampleCopier(input: audioInput, output: audioOutput, queue: DispatchQueue(label: "stillarc.crop.audio"), group: group)
            )
        }

        copiers.forEach { $0.start() }

        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }

        await writer.finishWriting()

        withExtendedLifetime(copiers) {}

        guard writer.status == .completed, reader.status == .completed else {
            print("STILLARC ASPECT CROP FAILED: \(String(describing: writer.error ?? reader.error))")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        print("STILLARC ASPECT CROP: \(Int(outW))x\(Int(outH)) \(codecString)")

        return outputURL
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]

        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }
}

nonisolated private final class SampleCopier: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let output: AVAssetReaderOutput
    private let queue: DispatchQueue
    private let group: DispatchGroup

    init(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        queue: DispatchQueue,
        group: DispatchGroup
    ) {
        self.input = input
        self.output = output
        self.queue = queue
        self.group = group
    }

    func start() {
        group.enter()

        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer(),
                      input.append(sample) else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }
}

// MARK: - LUT helpers

nonisolated enum LUTMonitor {

    // Converts a LUT's table into the RGBA float data CoreImage expects.
    static func cubeData(from value: Any, size: Int) -> Data? {
        guard size > 1, size <= 65 else { return nil }

        let cells = size * size * size
        var floats: [Float]

        if let data = value as? Data {
            let bytes = data.count
            // Imported and built-in cubes already use RGBA Float32. Share
            // their immutable storage instead of copying megabytes per tap.
            if bytes == cells * 16 { return data }

            if bytes == cells * 16 || bytes == cells * 12 {
                floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else if bytes == cells * 4 || bytes == cells * 3 {
                floats = data.map { Float($0) / 255 }
            } else {
                print("STILLARC LUT: \(bytes) bytes does not fit a \(size) cube")
                return nil
            }
        } else if let array = value as? [Float] {
            floats = array
        } else if let array = value as? [Double] {
            floats = array.map { Float($0) }
        } else if let array = value as? [SIMD3<Float>] {
            floats = array.flatMap { [$0.x, $0.y, $0.z] }
        } else if let array = value as? [SIMD4<Float>] {
            floats = array.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        } else {
            print("STILLARC LUT: unsupported table type \(type(of: value))")
            return nil
        }

        if floats.count == cells * 3 {
            var rgba: [Float] = []
            rgba.reserveCapacity(cells * 4)

            for index in 0..<cells {
                rgba.append(floats[index * 3])
                rgba.append(floats[index * 3 + 1])
                rgba.append(floats[index * 3 + 2])
                rgba.append(1)
            }

            floats = rgba
        }

        guard floats.count == cells * 4 else {
            print("STILLARC LUT: expected \(cells * 4) values, found \(floats.count)")
            return nil
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Asset writer for Log HEVC

nonisolated final class LogWriter: @unchecked Sendable {
    private let url: URL
    private let codec: String
    private let bitrate: Int
    private let fps: Double
    private let audioSettings: [String: Any]?

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime = CMTime.invalid
    private var finishing = false
    private var failed = false
    private var framesWritten = 0

    init(
        url: URL,
        codec: String,
        bitrate: Int,
        fps: Double,
        audioSettings: [String: Any]?
    ) {
        self.url = url
        self.codec = codec
        self.bitrate = bitrate
        self.fps = fps
        self.audioSettings = audioSettings
    }

    var canAcceptVideo: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finishing, !failed else { return false }
        return writer == nil || (writer?.status == .writing && videoInput?.isReadyForMoreMediaData == true)
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard finishing == false, failed == false else { return }

        if writer == nil {
            guard setUp(from: sample) else {
                failed = true
                return
            }
        }

        guard let writer, let videoInput, writer.status == .writing else {
            if writer?.status == .failed {
                failed = true
                print("STILLARC WRITER: failed while recording. \(String(describing: writer?.error))")
            }

            return
        }

        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(sample) == false {
                failed = true
                print("STILLARC WRITER: video append failed. \(String(describing: writer.error))")
            } else {
                framesWritten += 1
            }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard finishing == false, failed == false,
              let writer, writer.status == .writing,
              let audioInput, startTime.isValid else {
            return
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sample)

        guard time >= startTime else { return }

        if audioInput.isReadyForMoreMediaData {
            _ = audioInput.append(sample)
        }
    }

    func finish(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        finishing = true

        let writer = writer
        let video = videoInput
        let audio = audioInput
        let didFail = failed || framesWritten == 0

        lock.unlock()

        guard let writer, writer.status == .writing, didFail == false else {
            print("STILLARC WRITER: not finished. status \(String(describing: writer?.status.rawValue)), error \(String(describing: writer?.error))")
            writer?.cancelWriting()
            completion(false)
            return
        }

        video?.markAsFinished()
        audio?.markAsFinished()

        writer.finishWriting {
            if writer.status != .completed {
                print("STILLARC WRITER: finish failed. \(String(describing: writer.error))")
            }

            completion(writer.status == .completed)
        }
    }

    // Called with the lock held, on the first video frame.
    private func setUp(from sample: CMSampleBuffer) -> Bool {
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else {
            return false
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]

        let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let matrix = extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String

        let logTransfer = extensions?[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String
            ?? (CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) as? String)
        guard let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            print("STILLARC WRITER: could not create the file at \(url.lastPathComponent).")
            return false
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded()))
        ]

        // Apple Log 2 arrives as 10-bit 4:2:2, which needs the 4:2:2
        // profile. 4:2:0 sources use Main10.
        let sourceFormat = CVPixelBufferGetPixelFormatType(buffer)

        let is422 = sourceFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange

        let eightBit = sourceFormat == kCVPixelFormatType_32BGRA
            || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || sourceFormat == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        compression[AVVideoProfileLevelKey] = eightBit ? "HEVC_Main_AutoLevel"
            : (is422 ? "HEVC_Main42210_AutoLevel" : "HEVC_Main10_AutoLevel")

        if codec == AVVideoCodecType.h264.rawValue {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]

        if codec.hasPrefix("ap") {
            settings.removeValue(forKey: AVVideoCompressionPropertiesKey)
        }

        if let primaries, let transfer, let matrix {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix
            ]
        }

        if #available(iOS 27.0, *) {
            if logTransfer == kCVImageBufferLogTransferFunction_AppleLog2 as String {
                settings[AVVideoColorPropertiesKey] = [AVVideoLogTransferFunctionKey:AVVideoLogTransferFunction_AppleLog2,
                    AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_2020]
            } else if logTransfer == kCVImageBufferLogTransferFunction_AppleLog as String {
                settings[AVVideoColorPropertiesKey] = [AVVideoLogTransferFunctionKey:AVVideoLogTransferFunction_AppleLog,
                    AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_2020,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_2020]
            }
        }

        if newWriter.canApply(outputSettings: settings, forMediaType: .video) == false {
            settings.removeValue(forKey: AVVideoColorPropertiesKey)

            print("STILLARC WRITER: colour tags rejected, retrying without them.")

            if newWriter.canApply(outputSettings: settings, forMediaType: .video) == false {
                compression.removeValue(forKey: AVVideoProfileLevelKey)
                settings[AVVideoCompressionPropertiesKey] = compression

                guard newWriter.canApply(outputSettings: settings, forMediaType: .video) else {
                    print("STILLARC WRITER: HEVC settings rejected.")
                    return false
                }
            }
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: description)
        video.expectsMediaDataInRealTime = true

        guard newWriter.canAdd(video) else {
            print("STILLARC WRITER: the video input was rejected.")
            return false
        }

        newWriter.add(video)

        if let audioSettings {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true

            if newWriter.canAdd(audio) {
                newWriter.add(audio)
                audioInput = audio
            }
        }

        guard newWriter.startWriting() else {
            print("STILLARC WRITER: could not start. \(String(describing: newWriter.error))")
            return false
        }

        let start = CMSampleBufferGetPresentationTimeStamp(sample)

        newWriter.startSession(atSourceTime: start)

        writer = newWriter
        videoInput = video
        startTime = start

        print("STILLARC WRITER: started \(width)x\(height) \(codec), source format \(sourceFormat), \(is422 ? "4:2:2" : "4:2:0"), transfer \(logTransfer ?? transfer ?? "untagged")")

        return true
    }
}

// MARK: - Timelapse writer

nonisolated final class TimelapseWriter: @unchecked Sendable {
    let url: URL

    private let interval: Double
    private let fps: Double
    private let onFrame: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastKept = -Double.infinity
    private var frames = 0
    private var failed = false
    private var finishing = false

    init(
        url: URL,
        interval: Double,
        fps: Double,
        onFrame: @escaping @Sendable (Int) -> Void
    ) {
        self.url = url
        self.interval = interval
        self.fps = fps
        self.onFrame = onFrame
    }

    // Keeps one frame per interval and drops the rest.
    func offer(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard finishing == false, failed == false else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds

        guard time - lastKept >= interval else { return }

        if writer == nil {
            guard setUp(from: sample) else {
                failed = true
                return
            }
        }

        guard let writer, let input,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return
        }

        // Frames are placed 1/fps apart, whatever time passed between them.
        let scale = Int32(fps)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: scale),
            presentationTimeStamp: CMTime(value: CMTimeValue(frames), timescale: scale),
            decodeTimeStamp: .invalid
        )

        var retimed: CMSampleBuffer?

        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )

        guard let retimed, input.append(retimed) else {
            failed = true
            print("STILLARC TIMELAPSE: append failed. \(String(describing: writer.error))")
            return
        }

        lastKept = time
        frames += 1

        onFrame(frames)
    }

    func finish(_ completion: @escaping @Sendable (Int, Bool) -> Void) {
        lock.lock()

        // Already finishing: a second stop must not finish the file again.
        if finishing {
            lock.unlock()
            return
        }

        finishing = true

        let writer = writer
        let input = input
        let count = frames
        let didFail = failed

        lock.unlock()

        guard let writer, writer.status == .writing,
              count > 0, didFail == false else {
            writer?.cancelWriting()
            completion(0, false)
            return
        }

        input?.markAsFinished()

        writer.finishWriting {
            completion(count, writer.status == .completed)
        }
    }

    // Called with the lock held, on the first kept frame.
    private func setUp(from sample: CMSampleBuffer) -> Bool {
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return false
        }

        var width = CVPixelBufferGetWidth(buffer)
        var height = CVPixelBufferGetHeight(buffer)

        // Keep the file to 4K at most.
        let longSide = max(width, height)

        if longSide > 3840 {
            let scale = 3840.0 / Double(longSide)
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }

        width = max(2, (width / 2) * 2)
        height = max(2, (height / 2) * 2)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(fps)
            ]
        ]

        guard newWriter.canApply(outputSettings: settings, forMediaType: .video) else {
            print("STILLARC TIMELAPSE: HEVC settings rejected.")
            return false
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true

        guard newWriter.canAdd(video) else { return false }
        newWriter.add(video)

        guard newWriter.startWriting() else {
            print("STILLARC TIMELAPSE: could not start. \(String(describing: newWriter.error))")
            return false
        }

        newWriter.startSession(atSourceTime: .zero)

        writer = newWriter
        input = video

        print("STILLARC TIMELAPSE: started \(width)x\(height)")

        return true
    }
}
