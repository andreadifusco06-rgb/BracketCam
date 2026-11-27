import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Pipeline completa: decodifica -> allineamento -> fusione Mertens -> finitura -> export con EXIF.
// Tutto offline, solo framework di sistema.

struct HDROptions {
    var heif = false                       // false = JPEG, true = HEIF
    var quality: Double = 0.95
    var maxLongSide = 4032                 // lato lungo massimo di lavoro (12 MP dell'iPhone)
    var maxTotalPixels = 62_000_000        // tetto di memoria: n scatti x pixel
    var denoise: Float = 0.015             // 0 = spento (CINoiseReduction)
    var sharpen: Float = 0.35              // 0 = spento (CISharpenLuminance)
    var core = FCParams()
}

enum HDRPipeline {

    struct Info { let w: Int; let h: Int; let props: [String: Any]? }

    /// Fonde gli scatti AEB in una sola immagine. Restituisce i byte JPEG/HEIF oppure nil in caso di errore.
    nonisolated static func process(_ datas: [Data], options: HDROptions = HDROptions()) -> Data? {
        guard datas.count >= 2, let first = info(datas[0]) else { return nil }
        let n = datas.count

        // tetto di risoluzione: lato lungo e memoria totale
        var maxSide = min(options.maxLongSide, max(first.w, first.h))
        let total = Double(n) * Double(first.w) * Double(first.h)
        if total > Double(options.maxTotalPixels) {
            let k = (Double(options.maxTotalPixels) / total).squareRoot()
            maxSide = min(maxSide, Int(Double(max(first.w, first.h)) * k))
        }
        maxSide = max(maxSide, 256)

        // 1) decodifica (orientamento applicato, spazio Display P3)
        var frames: [RGBA8] = []
        var props: [[String: Any]?] = []
        for d in datas {
            autoreleasepool {
                if let f = decode(d, maxSide: maxSide) {
                    if frames.isEmpty || (f.w == frames[0].w && f.h == frames[0].h) {
                        frames.append(f)
                        props.append(info(d)?.props)
                    }
                }
            }
        }
        guard frames.count >= 2 else { return nil }

        // 2) riferimento + allineamento MTB
        let ref = FC.refIndex(frames)
        let w = frames[0].w, h = frames[0].h
        let grayRef = FC.grayU8(frames[ref])
        for i in 0..<frames.count where i != ref {
            let g = FC.grayU8(frames[i])
            let (dx, dy) = FC.mtbShift(ref: grayRef, mov: g, w: w, h: h)
            if dx != 0 || dy != 0 {
                frames[i] = FC.shifted(frames[i], dx, dy)
            }
        }

        // 3) fusione + 4) finitura
        let fused = FC.fuse(frames, ref: ref, options.core)
        frames.removeAll()
        let result = FC.finish(fused, options.core)

        // 5) esportazione
        return export(result, props: props[ref], options: options)
    }

    // MARK: decodifica

    nonisolated static func info(_ data: Data) -> Info? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        let pw = (p[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let ph = (p[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        guard pw > 0, ph > 0 else { return nil }
        return Info(w: pw, h: ph, props: p)
    }

    nonisolated static func decode(_ data: Data, maxSide: Int) -> RGBA8? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let cs = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let out = RGBA8(cg.width, cg.height)
        guard let ctx = CGContext(data: out.p, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return out
    }

    // MARK: esportazione

    nonisolated static func export(_ img: RGBA8, props: [String: Any]?, options: HDROptions) -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: img.p, width: img.w, height: img.h,
                                  bitsPerComponent: 8, bytesPerRow: img.w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = ctx.makeImage() else { return nil }

        // rifinitura con Core Image: riduzione del rumore leggera + nitidezza sulla sola luminanza
        var outImg = base
        if options.denoise > 0 || options.sharpen > 0 {
            var ci = CIImage(cgImage: base)
            if options.denoise > 0, let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(options.denoise, forKey: "inputNoiseLevel")
                f.setValue(0.2, forKey: "inputSharpness")
                if let o = f.outputImage { ci = o }
            }
            if options.sharpen > 0, let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(options.sharpen, forKey: "inputSharpness")
                if let o = f.outputImage { ci = o }
            }
            let cictx = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])
            let rect = CGRect(x: 0, y: 0, width: img.w, height: img.h)
            if let rendered = cictx.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: cs) {
                outImg = rendered
            }
        }

        // metadati: copia gli originali, orientamento già applicato
        var p: [String: Any] = props ?? [:]
        let drop: [String] = [
            kCGImagePropertyPixelWidth as String, kCGImagePropertyPixelHeight as String,
            kCGImagePropertyDepth as String, kCGImagePropertyColorModel as String,
            kCGImagePropertyHasAlpha as String, kCGImagePropertyProfileName as String,
            kCGImagePropertyMakerAppleDictionary as String
        ]
        for k in drop { p.removeValue(forKey: k) }
        p[kCGImagePropertyOrientation as String] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            p[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = img.w
            exif[kCGImagePropertyExifPixelYDimension as String] = img.h
            p[kCGImagePropertyExifDictionary as String] = exif
        }
        p[kCGImageDestinationLossyCompressionQuality as String] = options.quality

        let type = options.heif ? UTType.heic.identifier : UTType.jpeg.identifier
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, outImg, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        withExtendedLifetime(img) {}
        return out as Data
    }
}
