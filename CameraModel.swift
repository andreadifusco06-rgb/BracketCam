
import AVFoundation
import Photos
import UIKit
import Combine

@MainActor
final class CameraModel: NSObject, ObservableObject {

    let evSteps: [Float] = [-2, 0, 2]
    let evStepsWide: [Float] = [-3, -1.5, 0, 1.5, 3]

    nonisolated(unsafe) let session = AVCaptureSession()

    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "bracketcam.session")

    private var device: AVCaptureDevice?
    private var shots: [Data] = []

    @Published var status = "Pronto"
    @Published var busy = false
    @Published var lastImage: UIImage?

    @Published var saveSingles = false
    @Published var saveHEIF = false

    @Published var zoomFactor: CGFloat = 1.0
    @Published var availableZoomFactors: [CGFloat] = [1.0]

    @Published var selectedLens = "1x"

    private var isConfigured = false

    // MARK: - Avvio fotocamera

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Permesso fotocamera negato"
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        configure()

        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    // MARK: - Configurazione

    private func configure() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .back
        )

        let selectedDevice =
            discovery.devices.first(where: { $0.deviceType == .builtInTripleCamera }) ??
            discovery.devices.first(where: { $0.deviceType == .builtInDualWideCamera }) ??
            discovery.devices.first(where: { $0.deviceType == .builtInDualCamera }) ??
            discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })

        guard
            let dev = selectedDevice,
            let input = try? AVCaptureDeviceInput(device: dev),
            session.canAddInput(input),
            session.canAddOutput(output)
        else {
            session.commitConfiguration()
            status = "Fotocamera non disponibile"
            return
        }

        session.addInput(input)
        session.addOutput(output)

        output.isHighResolutionCaptureEnabled = true

        session.commitConfiguration()

        device = dev
        isConfigured = true

        updateZoomOptions()
    }

    // MARK: - Zoom e obiettivi

    private func updateZoomOptions() {
        guard let dev = device else { return }

        let minZoom = dev.minAvailableVideoZoomFactor
        let maxZoom = min(dev.maxAvailableVideoZoomFactor, 10.0)

        let presets: [CGFloat] = [0.5, 1.0, 2.0, 5.0]

        availableZoomFactors = presets.filter {
            $0 >= minZoom && $0 <= maxZoom
        }

        if availableZoomFactors.isEmpty {
            availableZoomFactors = [minZoom]
        }

        zoomFactor = min(max(dev.videoZoomFactor, minZoom), maxZoom)
        updateSelectedLens()
    }

    func setZoom(_ factor: CGFloat) {
        guard let dev = device, !busy else { return }

        let safeFactor = min(
            max(factor, dev.minAvailableVideoZoomFactor),
            min(dev.maxAvailableVideoZoomFactor, 10.0)
        )

        do {
            try dev.lockForConfiguration()

            dev.videoZoomFactor = safeFactor

            dev.unlockForConfiguration()

            zoomFactor = safeFactor
            updateSelectedLens()

        } catch {
            status = "Impossibile modificare lo zoom"
        }
    }

    private func updateSelectedLens() {
        switch zoomFactor {
        case ..<0.75:
            selectedLens = "0,5x"
        case 0.75..<1.5:
            selectedLens = "1x"
        case 1.5..<3.5:
            selectedLens = "2x"
        default:
            selectedLens = "5x"
        }
    }

    // MARK: - Blocco bilanciamento bianco

    private func setWhiteBalanceLock(_ lock: Bool) {
        guard let dev = device else { return }

        do {
            try dev.lockForConfiguration()

            if lock {
                if dev.isWhiteBalanceModeSupported(.locked) {
                    var gains = dev.deviceWhiteBalanceGains
                    let maxGain = dev.maxWhiteBalanceGain

                    gains.redGain = min(max(gains.redGain, 1), maxGain)
                    gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                    gains.blueGain = min(max(gains.blueGain, 1), maxGain)

                    dev.setWhiteBalanceModeLocked(
                        with: gains,
                        completionHandler: nil
                    )
                }
            } else if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            dev.unlockForConfiguration()

        } catch {
            // Si continua con il bilanciamento automatico.
        }
    }

    // MARK: - Blocco messa a fuoco

    private func setFocusLock(_ lock: Bool) {
        guard let dev = device else { return }

        do {
            try dev.lockForConfiguration()

            if lock {
                if dev.isFocusModeSupported(.locked) {
                    let position = dev.lensPosition

                    dev.setFocusModeLocked(
                        lensPosition: position,
                        completionHandler: nil
                    )
                }
            } else if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }

            dev.unlockForConfiguration()

        } catch {
            // Si mantiene la messa a fuoco disponibile.
        }
    }

    // MARK: - Scatto HDR AEB

    func capture() {
        guard !busy, let dev = device, isConfigured else {
            return
        }

        let maxCount = output.maxBracketedCapturePhotoCount

        guard maxCount >= 2 else {
            status = "Bracketing non supportato"
            return
        }

        let wanted = maxCount >= evStepsWide.count
            ? evStepsWide
            : evSteps

        let biases = wanted.map {
            min(max($0, dev.minExposureTargetBias), dev.maxExposureTargetBias)
        }

        let bracket = biases.map {
            AVCaptureAutoExposureBracketedStillImageSettings
                .autoExposureSettings(exposureTargetBias: $0)
        }

        var processedFormat: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ]

        if saveHEIF,
           output.availablePhotoCodecTypes.contains(.heic) {
            processedFormat[AVVideoCodecKey] = AVVideoCodecType.heic
        }

        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: processedFormat,
            bracketedSettings: bracket
        )

        settings.isHighResolutionPhotoEnabled = true

        shots.removeAll(keepingCapacity: true)

        busy = true
        status = "Scatto… tieni fermo"

        setFocusLock(true)
        setWhiteBalanceLock(true)

        output.capturePhoto(
            with: settings,
            delegate: self
        )
    }

    // MARK: - Ricezione immagini

    fileprivate func received(_ data: Data?) {
        guard let data else { return }
        shots.append(data)
    }

    fileprivate func finished() {
        setWhiteBalanceLock(false)
        setFocusLock(false)

        let captured = shots
        shots.removeAll(keepingCapacity: true)

        guard captured.count >= 2 else {
            status = "Scatto fallito, riprova"
            busy = false
            return
        }

        status = "Fusione in corso…"

        let singles = saveSingles

        var options = HDROptions()
        options.heif = saveHEIF

        let opts = options

        Task.detached(priority: .userInitiated) {

            let merged =
                HDRPipeline.process(captured, options: opts)
                ?? Fusion.merge(captured)

            let imagesToSave =
                (merged.map { [$0] } ?? []) +
                (singles ? captured : [])

            let ok = await CameraModel.save(imagesToSave)

            await MainActor.run {
                if let merged {
                    self.lastImage = UIImage(data: merged)
                }

                self.status =
                    (merged != nil && ok)
                    ? "Salvata in Foto ✓"
                    : "Errore nel salvataggio"

                self.busy = false
            }
        }
    }

    // MARK: - Salvataggio

    nonisolated static func save(_ datas: [Data]) async -> Bool {
        guard !datas.isEmpty else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for data in datas {
                    PHAssetCreationRequest
                        .forAsset()
                        .addResource(
                            with: .photo,
                            data: data,
                            options: nil
                        )
                }
            }

            return true

        } catch {
            return false
        }
    }
}

// MARK: - Delegate fotocamera

extension CameraModel: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = error == nil
            ? photo.fileDataRepresentation()
            : nil

        Task { @MainActor in
            self.received(data)
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        Task { @MainActor in
            self.finished()
        }
    }
}
