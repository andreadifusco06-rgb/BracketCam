import AVFoundation
import Photos
import UIKit

@MainActor
final class CameraModel: NSObject, ObservableObject {
    // Esposizioni del bracketing, in EV. Cambia qui se vuoi più o meno range.
    let evSteps: [Float] = [-2, 0, 2]

    nonisolated(unsafe) let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "bracketcam.session")
    private var device: AVCaptureDevice?
    private var shots: [Data] = []

    @Published var status = "Pronto"
    @Published var busy = false
    @Published var lastImage: UIImage?
    @Published var saveSingles = false

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

    func capture() {
        guard !busy, let dev = device else { return }
        let biases = evSteps.map { min(max($0, dev.minExposureTargetBias), dev.maxExposureTargetBias) }
        guard biases.count <= output.maxBracketedCapturePhotoCount else {
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
        output.capturePhoto(with: settings, delegate: self)
    }

    fileprivate func received(_ data: Data?) {
        if let data { shots.append(data) }
    }

    fileprivate func finished() {
        let captured = shots
        guard captured.count >= 2 else {
            status = "Scatto fallito, riprova"
            busy = false
            return
        }
        status = "Fusione in corso…"
        let singles = saveSingles
        Task.detached(priority: .userInitiated) {
            let merged = Fusion.merge(captured)
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
