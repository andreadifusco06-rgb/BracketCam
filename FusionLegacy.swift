import UIKit

// Fusione di esposizioni (stile Mertens semplificato): ogni pixel è una media
// pesata degli scatti, con peso più alto dove l'esposizione è "ben esposta".
// I pesi sono calcolati su griglia a blocchi e sfumati per evitare stacchi.
enum Fusion {
    nonisolated static func merge(_ datas: [Data]) -> Data? {
        var bufs: [[UInt8]] = []
        var w = 0, h = 0
        for d in datas {
            guard let ui = UIImage(data: d) else { continue }
            let up = upright(ui)
            if bufs.isEmpty { w = Int(up.size.width); h = Int(up.size.height) }
            bufs.append(pixels(up, w, h))
        }
        guard bufs.count >= 2, w > 0, h > 0 else { return nil }

        let B = 16
        let gw = (w + B - 1) / B, gh = (h + B - 1) / B
        let maps = bufs.map { weightGrid($0, w, h, B, gw, gh) }
        let n = bufs.count
        let xs = (0..<w).map { lerpIdx((Float($0) + 0.5) / Float(B) - 0.5, gw) }

        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let (y0, y1, fy) = lerpIdx((Float(y) + 0.5) / Float(B) - 0.5, gh)
            for x in 0..<w {
                let (x0, x1, fx) = xs[x]
                let i = (y * w + x) * 4
                var r: Float = 0, g: Float = 0, b: Float = 0, sw: Float = 0
                for m in 0..<n {
                    let M = maps[m]
                    let top = M[y0 * gw + x0] * (1 - fx) + M[y0 * gw + x1] * fx
                    let bot = M[y1 * gw + x0] * (1 - fx) + M[y1 * gw + x1] * fx
                    let wt = top * (1 - fy) + bot * fy
                    let p = bufs[m]
                    r += wt * Float(p[i]); g += wt * Float(p[i + 1]); b += wt * Float(p[i + 2]); sw += wt
                }
                out[i] = UInt8(min(255, r / sw))
                out[i + 1] = UInt8(min(255, g / sw))
                out[i + 2] = UInt8(min(255, b / sw))
            }
        }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
    }

    nonisolated static func upright(_ img: UIImage) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: img.size, format: f).image { _ in img.draw(at: .zero) }
    }

    nonisolated static func pixels(_ img: UIImage, _ w: Int, _ h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let cg = img.cgImage {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return buf
    }

    nonisolated static func weightGrid(_ p: [UInt8], _ w: Int, _ h: Int, _ B: Int, _ gw: Int, _ gh: Int) -> [Float] {
        var g = [Float](repeating: 0, count: gw * gh)
        var n = [Float](repeating: 0, count: gw * gh)
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let i = (y * w + x) * 4
                let l = (0.299 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.114 * Float(p[i + 2])) / 255
                let d = l - 0.5
                let k = (y / B) * gw + x / B
                g[k] += exp(-d * d / 0.08)
                n[k] += 1
            }
        }
        for k in 0..<g.count { g[k] = g[k] / max(n[k], 1) + 0.001 }
        for _ in 0..<2 { g = box3(g, gw, gh) }
        return g
    }

    nonisolated static func box3(_ g: [Float], _ gw: Int, _ gh: Int) -> [Float] {
        var o = g
        for y in 0..<gh {
            for x in 0..<gw {
                var s: Float = 0, c: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, xx < gw, yy >= 0, yy < gh { s += g[yy * gw + xx]; c += 1 }
                    }
                }
                o[y * gw + x] = s / c
            }
        }
        return o
    }

    nonisolated static func lerpIdx(_ v: Float, _ n: Int) -> (Int, Int, Float) {
        let f = max(0, min(v, Float(n - 1)))
        let i0 = Int(f)
        return (i0, min(i0 + 1, n - 1), f - Float(i0))
    }
}
