import AVFoundation
import Photos
import UIKit

@MainActor
final class CameraModel: NSObject, ObservableObject {
    // Esposizioni del bracketing, in EV. Se il dispositivo accetta 5 scatti si usa l'elenco largo
    // (finestre + ombre), altrimenti quello a 3 scatti originale.
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

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Permesso fotocamera negato"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        configure()
        sessionQueue.async { [session] in session.startRunning() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            status = "Fotocamera non disponibile"
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        device = dev
    }

    /// Blocca (o sblocca) il bilanciamento del bianco: senza il blocco i colori possono
    /// cambiare tra uno scatto e l'altro della sequenza.
    private func setWhiteBalanceLock(_ lock: Bool) {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            if lock {
                if dev.isWhiteBalanceModeSupported(.locked) {
                    var g = dev.deviceWhiteBalanceGains
                    let m = dev.maxWhiteBalanceGain
                    g.redGain = min(max(g.redGain, 1), m)
                    g.greenGain = min(max(g.greenGain, 1), m)
                    g.blueGain = min(max(g.blueGain, 1), m)
                    dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
                }
            } else if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            dev.unlockForConfiguration()
        } catch {
            // se il blocco non riesce si scatta comunque con bilanciamento automatico
        }
    }

    func capture() {
        guard !busy, let dev = device else { return }
        let maxCount = output.maxBracketedCapturePhotoCount
        let wanted = (maxCount >= evStepsWide.count) ? evStepsWide : evSteps
        let biases = wanted.map { min(max($0, dev.minExposureTargetBias), dev.maxExposureTargetBias) }
        guard biases.count <= maxCount else {
            status = "Bracketing non supportato"
            return
        }
        let bracket = biases.map {
            AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: $0)
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
            bracketedSettings: bracket)
        shots = []
        busy = true
        status = "Scatto… tieni fermo"
        setWhiteBalanceLock(true)
        output.capturePhoto(with: settings, delegate: self)
    }

    fileprivate func received(_ data: Data?) {
        if let data { shots.append(data) }
    }

    fileprivate func finished() {
        setWhiteBalanceLock(false)
        let captured = shots
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
            // motore nuovo; se fallisce per qualunque motivo si ripiega sulla fusione originale
            let merged = HDRPipeline.process(captured, options: opts) ?? Fusion.merge(captured)
            let ok = await CameraModel.save((merged.map { [$0] } ?? []) + (singles ? captured : []))
            await MainActor.run {
                if let merged { self.lastImage = UIImage(data: merged) }
                self.status = (merged != nil && ok) ? "Salvata in Foto ✓" : "Errore nel salvataggio"
                self.busy = false
            }
        }
    }

    nonisolated static func save(_ datas: [Data]) async -> Bool {
        guard !datas.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for d in datas {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil)
                }
            }
            return true
        } catch {
            return false
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in self.received(data) }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        Task { @MainActor in self.finished() }
    }
}
