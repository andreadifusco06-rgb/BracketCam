
import Foundation
import CoreMotion
import Combine

@MainActor
final class HorizonManager: ObservableObject {

    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false

    private let motionManager = CMMotionManager()
    private let updateInterval = 1.0 / 30.0

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            return
        }

        guard !motionManager.isDeviceMotionActive else {
            return
        }

        motionManager.deviceMotionUpdateInterval = updateInterval

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: .main
        ) { [weak self] motion, error in

            guard let motion, error == nil else {
                return
            }

            Task { @MainActor in
                guard let self else { return }

                self.roll = motion.attitude.roll
                self.pitch = motion.attitude.pitch

                self.isLevel =
                    abs(self.roll) < 0.025 &&
                    abs(self.pitch) < 0.05
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}
