
import Foundation
import SwiftUI

struct CameraSettings: Codable {
    var showGrid: Bool = true
    var showLevel: Bool = true
    var saveSingles: Bool = false
    var saveHEIF: Bool = false
    var useHighResolution: Bool = true
    var bracketCount: Int = 5
    var exposureRange: Float = 3.0
}
