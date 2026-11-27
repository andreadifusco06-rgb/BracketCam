
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct HDROptions {
    var heif = false
    var quality: Double = 0.97

    // Risoluzione di elaborazione sicura
    var maxLongSide = 4032
    var maxTotalPixels = 62_000_000

    // Riduzione rumore e nitidezza conservative
    var denoise: Float = 0.008
    var sharpen: Float = 0.25

    // Parametri di fusione
    var core = FCParams()
}

enum HDRPipeline {

    struct Info {
        let w: Int
        let h: Int
        let props: [String: Any]?
    }

    nonisolated static func process(
        _ datas: [Data],
        options: HDROptions = HDROptions()
    ) -> Data? {

        guard datas.count >= 2,
              let first = info(datas[0]) else {
            return nil
        }

        let n = datas.count

        // Calcolo della risoluzione di elaborazione
        var maxSide = min(
            options.maxLongSide,
            max(first.w, first.h)
        )

        let totalPixels =
            Double(n) *
            Double(first.w) *
            Double(first.h)

        if totalPixels > Double(options.maxTotalPixels) {
            let scale = (
                Double(options.maxTotalPixels) / totalPixels
            ).squareRoot()

            maxSide = min(
                maxSide,
                Int(Double(max(first.w, first.h)) * scale)
            )
        }

        maxSide = max(maxSide, 256)

        // Decodifica immagini
        var frames: [RGBA8] = []
        var properties: [[String: Any]?] = []

        for data in datas {
            autoreleasepool {
                if let frame = decode(data, maxSide: maxSide) {
                    if frames.isEmpty ||
                        (frame.w == frames[0].w &&
                         frame.h == frames[0].h) {

                        frames.append(frame)
                        properties.append(info(data)?.props)
                    }
                }
            }
        }

        guard frames.count >= 2 else {
            return nil
        }

        // Allineamento MTB
        let reference = FC.refIndex(frames)

        let width = frames[0].w
        let height = frames[0].h

        let referenceGray = FC.grayU8(frames[reference])

        for index in 0..<frames.count where index != reference {
            let gray = FC.grayU8(frames[index])

            let (dx, dy) = FC.mtbShift(
                ref: referenceGray,
                mov: gray,
                w: width,
                h: height
            )

            if dx != 0 || dy != 0 {
                frames[index] = FC.shifted(
                    frames[index],
                    dx,
                    dy
                )
            }
        }

        // Fusione HDR Mertens
        let fused = FC.fuse(
            frames,
            ref: reference,
            options.core
        )

        frames.removeAll()

        // Finitura colore e luminosità
        let result = FC.finish(
            fused,
            options.core
        )

        // Esportazione
        return export(
            result,
            props: properties[reference],
            options: options
        )
    }

    // MARK: - Informazioni immagine

    nonisolated static func info(_ data: Data) -> Info? {

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [String: Any] else {
            return nil
        }

        let width = (
            properties[kCGImagePropertyPixelWidth as String]
            as? NSNumber
        )?.intValue ?? 0

        let height = (
            properties[kCGImagePropertyPixelHeight as String]
            as? NSNumber
        )?.intValue ?? 0

        guard width > 0, height > 0 else {
            return nil
        }

        return Info(
            w: width,
            h: height,
            props: properties
        )
    }

    // MARK: - Decodifica

    nonisolated static func decode(
        _ data: Data,
        maxSide: Int
    ) -> RGBA8? {

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
        let colorSpace = CGColorSpace(
            name: CGColorSpace.displayP3
        ) else {
            return nil
        }

        let output = RGBA8(
            cgImage.width,
            cgImage.height
        )

        guard let context = CGContext(
            data: output.p,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high

        context.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: cgImage.width,
                height: cgImage.height
            )
        )

        return output
    }

    // MARK: - Finitura fotografica

    nonisolated static func enhance(
        _ image: CGImage,
        options: HDROptions,
        colorSpace: CGColorSpace
    ) -> CGImage {

        var current = CIImage(cgImage: image)

        // Riduzione rumore leggera
        if options.denoise > 0,
           let filter = CIFilter(name: "CINoiseReduction") {

            filter.setValue(
                current,
                forKey: kCIInputImageKey
            )

            filter.setValue(
                options.denoise,
                forKey: "inputNoiseLevel"
            )

            filter.setValue(
                0.35,
                forKey: "inputSharpness"
            )

            if let result = filter.outputImage {
                current = result
            }
        }

        // Nitidezza moderata
        if options.sharpen > 0,
           let filter = CIFilter(name: "CISharpenLuminance") {

            filter.setValue(
                current,
                forKey: kCIInputImageKey
            )

            filter.setValue(
                options.sharpen,
                forKey: "inputSharpness"
            )

            if let result = filter.outputImage {
                current = result
            }
        }

        let context = CIContext(
            options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace,
                .cacheIntermediates: false
            ]
        )

        let rect = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )

        return context.createCGImage(
            current,
            from: rect,
            format: .RGBA8,
            colorSpace: colorSpace
        ) ?? image
    }

    // MARK: - Esportazione

    nonisolated static func export(
        _ image: RGBA8,
        props: [String: Any]?,
        options: HDROptions
    ) -> Data? {

        guard let colorSpace = CGColorSpace(
            name: CGColorSpace.displayP3
        ),
        let context = CGContext(
            data: image.p,
            width: image.w,
            height: image.h,
            bitsPerComponent: 8,
            bytesPerRow: image.w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
        let baseImage = context.makeImage() else {
            return nil
        }

        // Elaborazione finale
        let finalImage = enhance(
            baseImage,
            options: options,
            colorSpace: colorSpace
        )

        // Conservazione metadati
        var metadata = props ?? [:]

        let keysToRemove: [String] = [
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImagePropertyDepth as String,
            kCGImagePropertyColorModel as String,
            kCGImagePropertyHasAlpha as String,
            kCGImagePropertyProfileName as String,
            kCGImagePropertyMakerAppleDictionary as String
        ]

        for key in keysToRemove {
            metadata.removeValue(forKey: key)
        }

        metadata[kCGImagePropertyOrientation as String] = 1

        if var tiff = metadata[
            kCGImagePropertyTIFFDictionary as String
        ] as? [String: Any] {

            tiff[kCGImagePropertyTIFFOrientation as String] = 1

            metadata[
                kCGImagePropertyTIFFDictionary as String
            ] = tiff
        }

        if var exif = metadata[
            kCGImagePropertyExifDictionary as String
        ] as? [String: Any] {

            exif[
                kCGImagePropertyExifPixelXDimension as String
            ] = image.w

            exif[
                kCGImagePropertyExifPixelYDimension as String
            ] = image.h

            metadata[
                kCGImagePropertyExifDictionary as String
            ] = exif
        }

        metadata[
            kCGImageDestinationLossyCompressionQuality as String
        ] = options.quality

        // JPEG o HEIF
        let type = options.heif
            ? UTType.heic.identifier
            : UTType.jpeg.identifier

        let output = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            output,
            type as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            finalImage,
            metadata as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return output as Data
    }
}
