import Foundation

// Motore di fusione HDR di BracketCam: Exposure Fusion di Mertens a piramide di Laplace,
// allineamento MTB, deghosting prudente e finitura. Solo Foundation, nessuna dipendenza esterna.
// Tutti i parametri sono in `FCParams`, tarati con un prototipo di riferimento (numpy/OpenCV).
//
// Richiede Xcode 16.3 o successivo (annotazione `nonisolated` sui tipi).

// MARK: - Buffer

/// Immagine float a canali interleaved. Memoria gestita a mano per evitare copie.
nonisolated final class FImg {
    let w: Int
    let h: Int
    let c: Int
    let p: UnsafeMutablePointer<Float>
    init(_ w: Int, _ h: Int, _ c: Int) {
        self.w = w; self.h = h; self.c = c
        let n = max(1, w * h * c)
        p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n)
    }
    deinit { p.deallocate() }
}

/// Immagine 8 bit RGBX (4 byte per pixel, il quarto byte è ignorato).
nonisolated final class RGBA8 {
    let w: Int
    let h: Int
    let p: UnsafeMutablePointer<UInt8>
    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        let n = max(1, w * h * 4)
        p = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        p.initialize(repeating: 255, count: n)
    }
    deinit { p.deallocate() }
}

// MARK: - Parametri

nonisolated struct FCParams {
    // Pesi di Mertens: contrasto * saturazione * esposizione ben centrata.
    var wellExposedCenter: Float = 0.6      // centro della gaussiana di "buona esposizione"
    var wellExposedSigma: Float = 0.2
    var weightEpsilon: Float = 1e-3         // evita pesi nulli nelle zone piatte (finestre)
    var weightBlurFraction: Float = 0.005   // sigma sfocatura pesi = frazione della larghezza (riduce aloni)
    // Deghosting
    var deghost = true
    var ghostK: Float = 3.0
    // Finitura
    var whiteBalance = true
    var wbStrength: Float = 0.5
    var wbMaxGain: Float = 1.14
    var autoLevel = true
    var targetMedian: Float = 0.48
    var contrast: Float = 0.2
}

// MARK: - Motore

nonisolated enum FC {

    // MARK: parallelismo

    /// Esegue body(i) per i in 0..<n su più core.
    nonisolated static func parallelFor(_ n: Int, _ body: (Int) -> Void) {
        if n <= 0 { return }
        let chunks = min(n, 32)
        if chunks == 1 {
            for i in 0..<n { body(i) }
            return
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
            let a = n * ci / chunks
            let b = n * (ci + 1) / chunks
            if a < b {
                for i in a..<b { body(i) }
            }
        }
    }

    // MARK: piramidi gaussiane / laplaciane

    /// Riduzione a metà con filtro gaussiano 5 tap [1 4 6 4 1]/16 (bordi replicati).
    nonisolated static func pyrDown(_ s: FImg) -> FImg {
        let sw = s.w, sh = s.h, c = s.c
        let ow = (sw + 1) / 2, oh = (sh + 1) / 2
        let tmp = FImg(ow, sh, c)
        let out = FImg(ow, oh, c)
        let sp = s.p, tp = tmp.p, op = out.p
        parallelFor(sh) { y in
            let rowS = sp + y * sw * c
            let rowT = tp + y * ow * c
            for ox in 0..<ow {
                let cx = 2 * ox
                let i0 = max(cx - 2, 0) * c
                let i1 = max(cx - 1, 0) * c
                let i2 = min(cx, sw - 1) * c
                let i3 = min(cx + 1, sw - 1) * c
                let i4 = min(cx + 2, sw - 1) * c
                for ch in 0..<c {
                    let a: Float = rowS[i0 + ch] + rowS[i4 + ch]
                    let b: Float = 4 * (rowS[i1 + ch] + rowS[i3 + ch])
                    let m: Float = 6 * rowS[i2 + ch]
                    rowT[ox * c + ch] = (a + b + m) * (1.0 / 16.0)
                }
            }
        }
        let stride = ow * c
        parallelFor(oh) { oy in
            let cy = 2 * oy
            let r0 = tp + max(cy - 2, 0) * stride
            let r1 = tp + max(cy - 1, 0) * stride
            let r2 = tp + min(cy, sh - 1) * stride
            let r3 = tp + min(cy + 1, sh - 1) * stride
            let r4 = tp + min(cy + 2, sh - 1) * stride
            let o = op + oy * stride
            for i in 0..<stride {
                let a: Float = r0[i] + r4[i]
                let b: Float = 4 * (r1[i] + r3[i])
                let m: Float = 6 * r2[i]
                o[i] = (a + b + m) * (1.0 / 16.0)
            }
        }
        withExtendedLifetime(s) {}
        withExtendedLifetime(tmp) {}
        return out
    }

    @inline(__always)
    nonisolated static func upTaps(_ x: Int, _ n: Int) -> (Int, Int, Int, Float, Float, Float) {
        let i = x >> 1
        if x & 1 == 0 {
            return (max(i - 1, 0), min(i, n - 1), min(i + 1, n - 1), 0.125, 0.75, 0.125)
        } else {
            return (min(i, n - 1), min(i + 1, n - 1), min(i + 1, n - 1), 0.5, 0.5, 0.0)
        }
    }

    /// Ingrandimento a (toW x toH): inserimento di zeri + filtro 5 tap (equivalente a cv::pyrUp).
    nonisolated static func pyrUp(_ s: FImg, _ toW: Int, _ toH: Int) -> FImg {
        let sw = s.w, sh = s.h, c = s.c
        let tmp = FImg(toW, sh, c)
        let out = FImg(toW, toH, c)
        let sp = s.p, tp = tmp.p, op = out.p
        parallelFor(sh) { y in
            let rowS = sp + y * sw * c
            let rowT = tp + y * toW * c
            for x in 0..<toW {
                let t = upTaps(x, sw)
                for ch in 0..<c {
                    let v0: Float = t.3 * rowS[t.0 * c + ch]
                    let v1: Float = t.4 * rowS[t.1 * c + ch]
                    let v2: Float = t.5 * rowS[t.2 * c + ch]
                    rowT[x * c + ch] = v0 + v1 + v2
                }
            }
        }
        let stride = toW * c
        parallelFor(toH) { y in
            let t = upTaps(y, sh)
            let r0 = tp + t.0 * stride
            let r1 = tp + t.1 * stride
            let r2 = tp + t.2 * stride
            let o = op + y * stride
            for i in 0..<stride {
                let v0: Float = t.3 * r0[i]
                let v1: Float = t.4 * r1[i]
                let v2: Float = t.5 * r2[i]
                o[i] = v0 + v1 + v2
            }
        }
        withExtendedLifetime(s) {}
        withExtendedLifetime(tmp) {}
        return out
    }

    // MARK: sfocatura box (3 passate ~ gaussiana) su un piano a 1 canale

    nonisolated static func boxBlurOnce(_ a: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int, _ r: Int) {
        if r < 1 { return }
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { tmp.deallocate() }
        let inv: Float = 1.0 / Float(2 * r + 1)
        parallelFor(h) { y in
            let row = a + y * w
            let out = tmp + y * w
            var sum: Float = 0
            for k in -r...r { sum += row[min(max(k, 0), w - 1)] }
            for x in 0..<w {
                out[x] = sum * inv
                let addI = min(x + r + 1, w - 1)
                let subI = max(x - r, 0)
                sum += row[addI] - row[subI]
            }
        }
        let nChunk = 16
        parallelFor(nChunk) { ci in
            let x0 = w * ci / nChunk
            let x1 = w * (ci + 1) / nChunk
            if x1 <= x0 { return }
            var sums = [Float](repeating: 0, count: x1 - x0)
            for k in -r...r {
                let yy = min(max(k, 0), h - 1)
                for x in x0..<x1 { sums[x - x0] += tmp[yy * w + x] }
            }
            for y in 0..<h {
                let addY = min(y + r + 1, h - 1)
                let subY = max(y - r, 0)
                for x in x0..<x1 {
                    a[y * w + x] = sums[x - x0] * inv
                    sums[x - x0] += tmp[addY * w + x] - tmp[subY * w + x]
                }
            }
        }
    }

    /// Approssima una gaussiana di deviazione `sigma` con tre box blur.
    nonisolated static func gaussApprox(_ a: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int, sigma: Float) {
        if sigma < 0.8 { return }
        let boxW = (4 * sigma * sigma + 1).squareRoot()
        let r = max(1, Int(((boxW - 1) / 2).rounded()))
        for _ in 0..<3 { boxBlurOnce(a, w, h, r) }
    }

    // MARK: pesi di Mertens

    nonisolated static func weightMap(_ f: RGBA8, _ prm: FCParams) -> FImg {
        let w = f.w, h = f.h
        let gray = FImg(w, h, 1)
        let out = FImg(w, h, 1)
        let fp = f.p, gp = gray.p, op = out.p
        let inv255: Float = 1.0 / 255.0
        parallelFor(h) { y in
            for x in 0..<w {
                let i = y * w + x
                let r = Float(fp[i * 4]), g = Float(fp[i * 4 + 1]), b = Float(fp[i * 4 + 2])
                gp[i] = (0.299 * r + 0.587 * g + 0.114 * b) * inv255
            }
        }
        let mu = prm.wellExposedCenter
        let inv2s: Float = 1.0 / (2.0 * prm.wellExposedSigma * prm.wellExposedSigma)
        let eps = prm.weightEpsilon
        parallelFor(h) { y in
            let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
            for x in 0..<w {
                let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                let i = y * w + x
                let lap: Float = abs(gp[ym * w + x] + gp[yp * w + x] + gp[y * w + xm] + gp[y * w + xp] - 4 * gp[i])
                let r = Float(fp[i * 4]) * inv255
                let g = Float(fp[i * 4 + 1]) * inv255
                let b = Float(fp[i * 4 + 2]) * inv255
                let m = (r + g + b) * (1.0 / 3.0)
                let var3: Float = ((r - m) * (r - m) + (g - m) * (g - m) + (b - m) * (b - m)) * (1.0 / 3.0)
                let sat = var3.squareRoot()
                let dev: Float = (r - mu) * (r - mu) + (g - mu) * (g - mu) + (b - mu) * (b - mu)
                let e = exp(-dev * inv2s)
                op[i] = (lap + eps) * (sat + eps) * (e + 1e-12)
            }
        }
        withExtendedLifetime(f) {}
        withExtendedLifetime(gray) {}
        return out
    }

    // MARK: conversioni

    nonisolated static func toFloat(_ f: RGBA8) -> FImg {
        let w = f.w, h = f.h
        let out = FImg(w, h, 3)
        let fp = f.p, op = out.p
        let inv255: Float = 1.0 / 255.0
        parallelFor(h) { y in
            for x in 0..<w {
                let i = y * w + x
                op[i * 3] = Float(fp[i * 4]) * inv255
                op[i * 3 + 1] = Float(fp[i * 4 + 1]) * inv255
                op[i * 3 + 2] = Float(fp[i * 4 + 2]) * inv255
            }
        }
        withExtendedLifetime(f) {}
        return out
    }

    nonisolated static func grayU8(_ f: RGBA8) -> [UInt8] {
        let n = f.w * f.h
        var g = [UInt8](repeating: 0, count: n)
        let fp = f.p
        g.withUnsafeMutableBufferPointer { gb in
            let gp = gb.baseAddress!
            parallelFor(f.h) { y in
                for x in 0..<f.w {
                    let i = y * f.w + x
                    let v = 77 * Int(fp[i * 4]) + 150 * Int(fp[i * 4 + 1]) + 29 * Int(fp[i * 4 + 2])
                    gp[i] = UInt8(v >> 8)
                }
            }
        }
        withExtendedLifetime(f) {}
        return g
    }

    // MARK: scelta del frame di riferimento

    /// Sceglie il frame con la maggior quota di pixel ben esposti meno quelli bruciati.
    nonisolated static func refIndex(_ fr: [RGBA8]) -> Int {
        var best = 0
        var bestScore: Float = -10
        for (k, f) in fr.enumerated() {
            var good = 0, blown = 0, total = 0
            var y = 0
            while y < f.h {
                var x = 0
                while x < f.w {
                    let i = y * f.w + x
                    let v = 77 * Int(f.p[i * 4]) + 150 * Int(f.p[i * 4 + 1]) + 29 * Int(f.p[i * 4 + 2])
                    let l = v >> 8
                    if l > 25 && l < 230 { good += 1 }
                    if l > 250 { blown += 1 }
                    total += 1
                    x += 4
                }
                y += 4
            }
            let score = Float(good - blown) / Float(max(total, 1))
            if score > bestScore { bestScore = score; best = k }
        }
        return best
    }

    // MARK: allineamento MTB (traslazione intera)

    nonisolated static func downU8(_ a: [UInt8], _ w: Int, _ h: Int) -> ([UInt8], Int, Int) {
        let ow = max(1, w / 2), oh = max(1, h / 2)
        var o = [UInt8](repeating: 0, count: ow * oh)
        for y in 0..<oh {
            let y0 = min(2 * y, h - 1), y1 = min(2 * y + 1, h - 1)
            for x in 0..<ow {
                let x0 = min(2 * x, w - 1), x1 = min(2 * x + 1, w - 1)
                let s = Int(a[y0 * w + x0]) + Int(a[y0 * w + x1]) + Int(a[y1 * w + x0]) + Int(a[y1 * w + x1])
                o[y * ow + x] = UInt8((s + 2) >> 2)
            }
        }
        return (o, ow, oh)
    }

    /// Bitmap di soglia mediana e bitmap di esclusione (pixel vicini alla mediana).
    nonisolated static func mtbBitmaps(_ g: [UInt8]) -> ([UInt8], [UInt8]) {
        var hist = [Int](repeating: 0, count: 256)
        for v in g { hist[Int(v)] += 1 }
        var acc = 0, med = 0
        let half = g.count / 2
        for i in 0..<256 {
            acc += hist[i]
            if acc > half { med = i; break }
        }
        var tb = [UInt8](repeating: 0, count: g.count)
        var eb = [UInt8](repeating: 0, count: g.count)
        for i in 0..<g.count {
            let v = Int(g[i])
            tb[i] = v > med ? 1 : 0
            eb[i] = abs(v - med) > 4 ? 1 : 0
        }
        return (tb, eb)
    }

    /// Spostamento intero (dx, dy) che porta `mov` sopra `ref`: out(x, y) = mov(x - dx, y - dy).
    nonisolated static func mtbShift(ref: [UInt8], mov: [UInt8], w: Int, h: Int) -> (Int, Int) {
        var pr = [ref], pm = [mov]
        var dims = [(w, h)]
        var cw = w, ch = h
        while min(cw, ch) >= 32 && pr.count < 7 {
            let (r2, nw, nh) = downU8(pr[pr.count - 1], cw, ch)
            let (m2, _, _) = downU8(pm[pm.count - 1], cw, ch)
            pr.append(r2); pm.append(m2)
            cw = nw; ch = nh
            dims.append((cw, ch))
        }
        var dx = 0, dy = 0
        var lv = pr.count - 1
        while lv >= 0 {
            dx *= 2; dy *= 2
            let (lw, lh) = dims[lv]
            let (tbR, ebR) = mtbBitmaps(pr[lv])
            let (tbM, ebM) = mtbBitmaps(pm[lv])
            var bestDiff = Int.max
            var bx = dx, by = dy
            for oy in -1...1 {
                for ox in -1...1 {
                    let sx = dx + ox, sy = dy + oy
                    let y0 = max(0, sy), y1 = min(lh, lh + sy)
                    let x0 = max(0, sx), x1 = min(lw, lw + sx)
                    var diff = 0
                    if y0 < y1 && x0 < x1 {
                        for y in y0..<y1 {
                            let rowR = y * lw
                            let rowM = (y - sy) * lw - sx
                            for x in x0..<x1 {
                                let d = (tbR[rowR + x] ^ tbM[rowM + x]) & ebR[rowR + x] & ebM[rowM + x]
                                diff += Int(d)
                            }
                        }
                    } else {
                        diff = Int.max - 1
                    }
                    if diff < bestDiff { bestDiff = diff; bx = sx; by = sy }
                }
            }
            dx = bx; dy = by
            lv -= 1
        }
        return (dx, dy)
    }

    nonisolated static func shifted(_ f: RGBA8, _ dx: Int, _ dy: Int) -> RGBA8 {
        if dx == 0 && dy == 0 { return f }
        let w = f.w, h = f.h
        let out = RGBA8(w, h)
        let sp = f.p, op = out.p
        parallelFor(h) { y in
            let sy = min(max(y - dy, 0), h - 1)
            for x in 0..<w {
                let sx = min(max(x - dx, 0), w - 1)
                let si = (sy * w + sx) * 4
                let oi = (y * w + x) * 4
                op[oi] = sp[si]; op[oi + 1] = sp[si + 1]; op[oi + 2] = sp[si + 2]; op[oi + 3] = 255
            }
        }
        withExtendedLifetime(f) {}
        return out
    }

    // MARK: deghosting (riduce il peso dei frame dove qualcosa si è mosso)

    nonisolated static let ghostScale = 4

    nonisolated static func smallGray(_ f: RGBA8) -> FImg {
        let s = ghostScale
        let sw = max(1, f.w / s), sh = max(1, f.h / s)
        let out = FImg(sw, sh, 1)
        let fp = f.p, op = out.p
        let fw = f.w, fh = f.h
        let norm: Float = 1.0 / (Float(s * s) * 255.0)
        parallelFor(sh) { y in
            for x in 0..<sw {
                var acc: Float = 0
                for yy in 0..<s {
                    let py = min(y * s + yy, fh - 1)
                    for xx in 0..<s {
                        let px = min(x * s + xx, fw - 1)
                        let i = (py * fw + px) * 4
                        acc += 0.299 * Float(fp[i]) + 0.587 * Float(fp[i + 1]) + 0.114 * Float(fp[i + 2])
                    }
                }
                op[y * sw + x] = acc * norm
            }
        }
        withExtendedLifetime(f) {}
        return out
    }

    nonisolated static func cdf(_ a: FImg, _ bins: Int) -> [Float] {
        var hst = [Float](repeating: 0, count: bins)
        let n = a.w * a.h
        for i in 0..<n {
            let b = min(bins - 1, max(0, Int(a.p[i] * Float(bins))))
            hst[b] += 1
        }
        var acc: Float = 0
        let inv = 1.0 / Float(max(n, 1))
        for b in 0..<bins { acc += hst[b]; hst[b] = acc * inv }
        return hst
    }

    nonisolated static func median(_ v: [Float]) -> Float {
        if v.isEmpty { return 0 }
        var s = v
        s.sort()
        return s[s.count / 2]
    }

    /// Per ogni frame diverso dal riferimento restituisce una mappa piccola (1 = tiene, ~0 = fantasma).
    nonisolated static func ghostMaps(_ fr: [RGBA8], ref: Int, k: Float) -> [FImg?] {
        let n = fr.count
        var out = [FImg?](repeating: nil, count: n)
        let r = smallGray(fr[ref])
        let bins = 1024
        let cdfR = cdf(r, bins)
        let cnt = r.w * r.h
        for i in 0..<n where i != ref {
            let f = smallGray(fr[i])
            let cdfF = cdf(f, bins)
            var lut = [Float](repeating: 0, count: bins)
            var j = 0
            for b in 0..<bins {
                while j < bins - 1 && cdfF[j] < cdfR[b] { j += 1 }
                lut[b] = (Float(j) + 0.5) / Float(bins)
            }
            var res = [Float](repeating: 0, count: cnt)
            for q in 0..<cnt {
                let bi = min(bins - 1, max(0, Int(r.p[q] * Float(bins))))
                res[q] = abs(f.p[q] - lut[bi])
            }
            let med = median(res)
            var dev = [Float](repeating: 0, count: cnt)
            for q in 0..<cnt { dev[q] = abs(res[q] - med) }
            let mad = median(dev) + 1e-4
            let thr = med + k * 1.4826 * mad
            let mask = FImg(r.w, r.h, 1)
            for q in 0..<cnt {
                let rv = r.p[q], fv = f.p[q]
                let valid = rv > 0.05 && rv < 0.95 && fv > 0.03 && fv < 0.97
                mask.p[q] = (res[q] > thr && valid) ? 1 : 0
            }
            boxBlurOnce(mask.p, mask.w, mask.h, 3)
            for q in 0..<cnt {
                let m = min(1, mask.p[q] * 3)
                mask.p[q] = 1 - 0.97 * m
            }
            out[i] = mask
        }
        return out
    }

    /// Moltiplica la mappa dei pesi per la mappa fantasmi (interpolazione bilineare).
    nonisolated static func applyMult(_ wmap: FImg, _ m: FImg) {
        let w = wmap.w, h = wmap.h, sw = m.w, sh = m.h
        let wp = wmap.p, mp = m.p
        let scale = Float(ghostScale)
        parallelFor(h) { y in
            let fy = min(max((Float(y) + 0.5) / scale - 0.5, 0), Float(sh - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, sh - 1)
            let ty = fy - Float(y0)
            for x in 0..<w {
                let fx = min(max((Float(x) + 0.5) / scale - 0.5, 0), Float(sw - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, sw - 1)
                let tx = fx - Float(x0)
                let a: Float = mp[y0 * sw + x0] * (1 - tx) + mp[y0 * sw + x1] * tx
                let b: Float = mp[y1 * sw + x0] * (1 - tx) + mp[y1 * sw + x1] * tx
                wp[y * w + x] *= a * (1 - ty) + b * ty
            }
        }
        withExtendedLifetime(wmap) {}
        withExtendedLifetime(m) {}
    }

    // MARK: fusione di Mertens

    nonisolated static func levelCount(_ w: Int, _ h: Int) -> Int {
        let m = Float(min(w, h)) / 8.0
        return max(1, min(8, Int(log2(max(m, 2)))))
    }

    /// Fusione a piramide di Laplace, un frame alla volta per contenere la memoria.
    /// I frame devono essere già allineati. Restituisce RGB float 0...1.
    nonisolated static func fuse(_ fr: [RGBA8], ref: Int, _ prm: FCParams) -> FImg {
        let w = fr[0].w, h = fr[0].h, n = fr.count
        let L = levelCount(w, h)
        let sigma = prm.weightBlurFraction * Float(w)

        let ghosts: [FImg?] = (prm.deghost && n > 1) ? ghostMaps(fr, ref: ref, k: prm.ghostK)
                                                        : [FImg?](repeating: nil, count: n)

        // 1) pesi di tutti i frame + somma per la normalizzazione
        var wm = [FImg?](repeating: nil, count: n)
        let sum = FImg(w, h, 1)
        for i in 0..<n {
            let wi = weightMap(fr[i], prm)
            gaussApprox(wi.p, w, h, sigma: sigma)
            if let g = ghosts[i] { applyMult(wi, g) }
            let sp = sum.p, ip = wi.p
            parallelFor(h) { y in
                for x in 0..<w { sp[y * w + x] += ip[y * w + x] }
            }
            withExtendedLifetime(wi) {}
            wm[i] = wi
        }

        // dimensioni dei livelli
        var dims: [(Int, Int)] = [(w, h)]
        for _ in 0..<L {
            let last = dims[dims.count - 1]
            dims.append(((last.0 + 1) / 2, (last.1 + 1) / 2))
        }
        var acc: [FImg] = dims.map { FImg($0.0, $0.1, 3) }

        // 2) accumulo dei contributi di ogni frame
        for i in 0..<n {
            let wi = wm[i]!
            let sp = sum.p, ip = wi.p
            parallelFor(h) { y in
                for x in 0..<w { ip[y * w + x] /= (sp[y * w + x] + 1e-20) }
            }
            let img = toFloat(fr[i])
            var gi: [FImg] = [img]
            var gw: [FImg] = [wi]
            for _ in 0..<L {
                gi.append(pyrDown(gi[gi.count - 1]))
                gw.append(pyrDown(gw[gw.count - 1]))
            }
            for lv in 0..<L {
                let up = pyrUp(gi[lv + 1], gi[lv].w, gi[lv].h)
                let lw = gi[lv].w, lh = gi[lv].h
                let ap = acc[lv].p, gp = gi[lv].p, upp = up.p, wp = gw[lv].p
                parallelFor(lh) { y in
                    for x in 0..<lw {
                        let q = y * lw + x
                        let wt = wp[q]
                        ap[q * 3] += (gp[q * 3] - upp[q * 3]) * wt
                        ap[q * 3 + 1] += (gp[q * 3 + 1] - upp[q * 3 + 1]) * wt
                        ap[q * 3 + 2] += (gp[q * 3 + 2] - upp[q * 3 + 2]) * wt
                    }
                }
                withExtendedLifetime(up) {}
                withExtendedLifetime(gi[lv]) {}
                withExtendedLifetime(gw[lv]) {}
            }
            // livello più grossolano: immagine gaussiana pesata
            let top = L
            let tw = gi[top].w, th = gi[top].h
            let atp = acc[top].p, gtp = gi[top].p, wtp = gw[top].p
            parallelFor(th) { y in
                for x in 0..<tw {
                    let q = y * tw + x
                    let wt = wtp[q]
                    atp[q * 3] += gtp[q * 3] * wt
                    atp[q * 3 + 1] += gtp[q * 3 + 1] * wt
                    atp[q * 3 + 2] += gtp[q * 3 + 2] * wt
                }
            }
            withExtendedLifetime(gi[top]) {}
            withExtendedLifetime(gw[top]) {}
            wm[i] = nil
        }
        withExtendedLifetime(sum) {}

        // 3) ricostruzione
        var cur = acc[L]
        var lv = L - 1
        while lv >= 0 {
            let up = pyrUp(cur, acc[lv].w, acc[lv].h)
            let cnt = up.w * up.h * 3
            let upp = up.p, ap = acc[lv].p
            parallelFor(up.h) { y in
                let base = y * up.w * 3
                for i in 0..<(up.w * 3) { upp[base + i] += ap[base + i] }
            }
            _ = cnt
            withExtendedLifetime(acc[lv]) {}
            cur = up
            acc[lv] = FImg(1, 1, 3)   // libera il livello già usato
            lv -= 1
        }
        let result = cur
        let o = result.p
        let rw = result.w, rh = result.h
        parallelFor(rh) { y in
            let base = y * rw * 3
            for i in 0..<(rw * 3) { o[base + i] = min(max(o[base + i], 0), 1) }
        }
        withExtendedLifetime(result) {}
        return result
    }

    // MARK: finitura

    @inline(__always)
    nonisolated static func rnd(_ i: Int, _ k: UInt32) -> Float {
        var x = UInt32(truncatingIfNeeded: i) &* 2654435761 &+ k &* 40503
        x ^= x >> 15
        x = x &* 2246822519
        x ^= x >> 13
        x = x &* 3266489917
        x ^= x >> 16
        return Float(x & 0xFFFF) * (1.0 / 65536.0)
    }

    /// Bilanciamento del bianco prudente, livello automatico, contrasto morbido, conversione a 8 bit con dithering.
    nonisolated static func finish(_ img: FImg, _ prm: FCParams) -> RGBA8 {
        let w = img.w, h = img.h
        let ip = img.p
        var gains: [Float] = [1, 1, 1]

        // bilanciamento del bianco: grigio medio sui pixel neutri e a tono medio
        if prm.whiteBalance {
            var sumC: [Double] = [0, 0, 0]
            var cnt = 0, total = 0
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 3
                    let r = ip[i], g = ip[i + 1], b = ip[i + 2]
                    let m = (r + g + b) / 3
                    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                    let sat = (mx - mn) / (mx + 1e-6)
                    if m > 0.2 && m < 0.85 && sat < 0.35 {
                        sumC[0] += Double(r); sumC[1] += Double(g); sumC[2] += Double(b)
                        cnt += 1
                    }
                    total += 1
                    x += 3
                }
                y += 3
            }
            if cnt > total / 100 {
                let mr = Float(sumC[0] / Double(cnt)), mg = Float(sumC[1] / Double(cnt)), mb = Float(sumC[2] / Double(cnt))
                let avg = (mr + mg + mb) / 3
                let raw: [Float] = [avg / max(mr, 1e-4), avg / max(mg, 1e-4), avg / max(mb, 1e-4)]
                let lo = 1 / prm.wbMaxGain
                for c in 0..<3 {
                    gains[c] = min(max(pow(raw[c], prm.wbStrength), lo), prm.wbMaxGain)
                }
            }
        }

        // livello automatico: solleva i mezzi toni solo se l'immagine è scura
        var gamma: Float = 1
        if prm.autoLevel {
            var hst = [Int](repeating: 0, count: 1024)
            var count = 0
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 3
                    let l = (ip[i] * gains[0] + ip[i + 1] * gains[1] + ip[i + 2] * gains[2]) / 3
                    hst[min(1023, max(0, Int(l * 1023)))] += 1
                    count += 1
                    x += 3
                }
                y += 3
            }
            var acc = 0, medBin = 0
            for b in 0..<1024 {
                acc += hst[b]
                if acc * 2 >= count { medBin = b; break }
            }
            let med = max((Float(medBin) + 0.5) / 1024, 0.02)
            if med < prm.targetMedian {
                gamma = min(max(log(prm.targetMedian) / log(med), 0.7), 1.0)
            }
        }
        var lut = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { lut[i] = pow(Float(i) / 4095, gamma) }

        let out = RGBA8(w, h)
        let op = out.p
        let a = prm.contrast
        let g0 = gains[0], g1 = gains[1], g2 = gains[2]
        lut.withUnsafeBufferPointer { lb in
            let lp = lb.baseAddress!
            parallelFor(h) { y in
                for x in 0..<w {
                    let q = y * w + x
                    let i = q * 3
                    let r0 = lp[Int(min(max(ip[i] * g0, 0), 1) * 4095 + 0.5)]
                    let g_ = lp[Int(min(max(ip[i + 1] * g1, 0), 1) * 4095 + 0.5)]
                    let b0 = lp[Int(min(max(ip[i + 2] * g2, 0), 1) * 4095 + 0.5)]
                    let l = (r0 + g_ + b0) / 3
                    let s: Float = (1 - a) * l + a * (l * l * (3 - 2 * l))
                    let k: Float = s / max(l, 1e-4)
                    let d: Float = (rnd(q, 1) - rnd(q, 2)) * 0.75
                    let r8 = min(max(r0 * k * 255 + d + 0.5, 0), 255)
                    let g8 = min(max(g_ * k * 255 + d + 0.5, 0), 255)
                    let b8 = min(max(b0 * k * 255 + d + 0.5, 0), 255)
                    op[q * 4] = UInt8(r8)
                    op[q * 4 + 1] = UInt8(g8)
                    op[q * 4 + 2] = UInt8(b8)
                    op[q * 4 + 3] = 255
                }
            }
        }
        withExtendedLifetime(img) {}
        return out
    }
}
