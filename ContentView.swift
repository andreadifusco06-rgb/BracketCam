import SwiftUI
import AVFoundation

struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    var body: some View {
        ZStack {
            Preview(session: cam.session).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(cam.status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                Spacer()
                if let img = cam.lastImage {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Toggle("Salva anche i singoli scatti", isOn: $cam.saveSingles)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)
                Button(action: { cam.capture() }) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(cam.busy ? Color.gray : Color.white).frame(width: 64, height: 64)
                    }
                }
                .disabled(cam.busy)
                .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .task { await cam.start() }
    }
}
