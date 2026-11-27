
import SwiftUI
import AVFoundation
import CoreMotion

struct Preview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct ContentView: View {

    @StateObject private var cam = CameraModel()
    @StateObject private var motion = HorizonManager()

    @State private var showSettings = false
    @State private var showGrid = true
    @State private var showLevel = true

    var body: some View {
        ZStack {
            Preview(session: cam.session)
                .ignoresSafeArea()

            // Griglia fotografica
            if showGrid {
                CameraGrid()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Livella elettronica
            if showLevel {
                HorizonOverlay(angle: motion.roll)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {

                // Barra superiore
                HStack {
                    Text("BRACKETCAM")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white)

                    Spacer()

                    Button {
                        showGrid.toggle()
                    } label: {
                        Image(systemName: "grid")
                            .font(.system(size: 19))
                            .foregroundStyle(showGrid ? .yellow : .white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }

                    Button {
                        showLevel.toggle()
                    } label: {
                        Image(systemName: "level")
                            .font(.system(size: 19))
                            .foregroundStyle(showLevel ? .yellow : .white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                // Stato fotocamera
                Text(cam.status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.top, 14)

                Spacer()

                // Anteprima ultima fotografia
                if let image = cam.lastImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 75)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .padding(.bottom, 12)
                }

                // Selettore zoom
                HStack(spacing: 18) {
                    ForEach(cam.availableZoomFactors, id: \.self) { factor in
                        Button {
                            cam.setZoom(factor)
                        } label: {
                            Text(zoomLabel(factor))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(
                                    abs(cam.zoomFactor - factor) < 0.08
                                    ? .yellow
                                    : .white
                                )
                                .frame(width: 42, height: 42)
                                .background(
                                    .black.opacity(0.65),
                                    in: Circle()
                                )
                        }
                        .disabled(cam.busy)
                    }
                }
                .padding(.bottom, 15)

                // Zoom manuale
                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(.white)

                    Slider(
                        value: Binding(
                            get: { Double(cam.zoomFactor) },
                            set: { cam.setZoom(CGFloat($0)) }
                        ),
                        in: 1.0...max(1.01, Double(
                            cam.availableZoomFactors.last ?? 5.0
                        ))
                    )
                    .tint(.yellow)

                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 35)
                .padding(.bottom, 15)

                // Impostazioni rapide
                HStack {
                    Toggle("Singoli", isOn: $cam.saveSingles)
                    Toggle("HEIF", isOn: $cam.saveHEIF)
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    .black.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .padding(.horizontal, 35)
                .padding(.bottom, 18)

                // Pulsante di scatto
                Button {
                    cam.capture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 82, height: 82)

                        Circle()
                            .fill(cam.busy ? Color.gray : Color.white)
                            .frame(width: 66, height: 66)
                    }
                }
                .disabled(cam.busy)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await cam.start()
            motion.start()
        }
        .sheet(isPresented: $showSettings) {
            CameraSettingsView(
                showGrid: $showGrid,
                showLevel: $showLevel
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func zoomLabel(_ factor: CGFloat) -> String {
        if factor == 0.5 {
            return "0,5x"
        }

        return "\(factor.formatted(.number.precision(.fractionLength(0))))x"
    }
}

// MARK: - Griglia fotografica

struct CameraGrid: View {

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height

                for i in 1...2 {
                    let x = width * CGFloat(i) / 3
                    let y = height * CGFloat(i) / 3

                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))

                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(.white.opacity(0.55), lineWidth: 0.7)
        }
    }
}

// MARK: - Indicatore orizzonte

struct HorizonOverlay: View {

    let angle: Double

    var body: some View {
        GeometryReader { geometry in
            let isLevel = abs(angle) < 0.025

            VStack {
                Spacer()

                Rectangle()
                    .fill(isLevel ? .green : .yellow)
                    .frame(height: 1.5)
                    .overlay {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(.white)
                                .frame(width: 35, height: 3)

                            Spacer()

                            Rectangle()
                                .fill(.white)
                                .frame(width: 35, height: 3)
                        }
                    }
                    .rotationEffect(.radians(angle))
                    .frame(width: geometry.size.width * 0.72)

                Text(isLevel ? "LIVELLATO" : "\(Int(angle * 180 / .pi))°")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isLevel ? .green : .yellow)
                    .padding(.top, 7)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
