
import SwiftUI

struct CameraSettingsView: View {

    @Binding var showGrid: Bool
    @Binding var showLevel: Bool

    var body: some View {
        NavigationStack {
            Form {

                Section("Composizione") {
                    Toggle("Griglia fotografica", isOn: $showGrid)
                    Toggle("Livella elettronica", isOn: $showLevel)
                }

                Section("Fotografia") {
                    HStack {
                        Label("Formato", systemImage: "photo")
                        Spacer()
                        Text("JPEG / HEIF")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Risoluzione", systemImage: "viewfinder")
                        Spacer()
                        Text("Massima supportata")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Bracketing HDR", systemImage: "camera.aperture")
                        Spacer()
                        Text("Automatico")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Informazioni") {
                    HStack {
                        Text("Applicazione")
                        Spacer()
                        Text("BracketCam")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Versione")
                        Spacer()
                        Text("2.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
