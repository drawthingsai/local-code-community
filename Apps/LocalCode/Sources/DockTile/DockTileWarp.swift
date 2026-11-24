#if targetEnvironment(macCatalyst)
  import Foundation
  import simd

  /// Samples a render at twice the tile's size into the tile through a fixed warp: 2 × 2 samples a
  /// tile pixel, each read bilinearly from where the field says. The icon's body is a shorter, more
  /// compact drawing than the rig's, so from the chin down the field pulls the rig up (most at the
  /// bottom of the suit, about 12 tile pixels) and a little left; the head is untouched. The sampling
  /// positions are worked out once.
  struct DockTileWarp {
    /// Every 8 tile pixels (33 × 33 points, row by row), the offset from a tile point to the point of
    /// the render it shows, x then y, in 1/256 tile pixels: little-endian Int16s, base64. Between the
    /// points it is interpolated (within 0.31 px of the fitted field, 0.015 px on average). Written
    /// by Debug/DockTileProbe/fit_warp.py.
    private static let field = """
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      8/+H//j/jv/9/5b/AQCe/wUAp/8IALH/CgC9/wkAyf8IANX/BgDg/wMA6v8AAPP//f/8//n/AwD2/wkA9P8OAPT/EgD1/xQA
      +P8UAPz/FAAAABIAAwAQAAYADQAHAAoABgAFAAMAAAD///v/+v/1//T/8P/u/+r/6P/l/+P/4f/d/9z/rf90/cn/m/3m/8b9
      BQD1/SIAK/46AGn+SQCx/k8AAf9OAFL/SgCe/0QA4v88AB4AMQBRACEAfgAOAKYA///IAPv/4QAEAO4AGADvADIA5gBLANcA
      YADDAGoAqgBoAIsAVgBoADcAPwAQABQA5f/q/7v/wv+R/53/af98/0L/Xv8e/0L/QP9G+3f/nvu0/wH89P9w/DQA8vxtAI39
      mgBB/rkABf/QAML/5ABlAPgA5QAKAUEBEQGCAQgBtQHwAOcB1gAWAskAOwLTAEoC7ABEAg0BLwIqARECOwHsATkBvwEdAYUB
      5QA+AZcA6gA8AJEA3/86AIX/6v8v/6L/3v5h/5D+Jv9F/vD+wv4e+hD/yfph/4b7tv9b/AoATP1bAFL+pQBi/+UAYgAfATcB
      VwHVAZABOwLGAWwC7wF4AgACewL3AYgC4AGjAssBvQLEAcgCxwHAAs4BqwLQAZECxgFyAqoBSwJ1ARQCJQHKAcAAcAFRAA8B
      4f+wAHj/WgAV/w4Atf7J/1j+iv/9/U//hP5n+8/+N/wa/w/9aP/1/b3/7/4fAP3/jAAPAfgABAJcAcUCuQFIAxUCjANuAo4D
      vQJgA/MCKQMIAwgD/QIHA+MCFQPHAhwDqwIWA40CBQNoAvACOgLYAv0BuQKsAYcCRwE9AtEA4QFXAIAB4/8lAXj/1QAV/5EA
      t/5VAFv+HwAB/u3/Wv4b/aD+7/3m/sv+Mv+1/5D/sgAMAMUBnwDSAjABswOxAVgEIwK/BJAC5AT/Ar8EbgNhBM4D8wMKBKED
      FwR+A/8DdwPRA3UDlANtA0wDXwP9Ak8DpQI/A0UCJQPYAfUCXwGtAt4AVAJgAPkB6v+mAX7/YAEb/yUBvf7yAGL+xQAI/pwA
      Q/70/o3+zf/c/q0AN/+YAa7/lgJJAKED9wCVBJUBUwUaAtQFjgIaBvwCIgZwA+gF8AN2BXME6gTcBHMEDQUrBAUFBwTOBPED
      dgTeAwcEygOLA7oDCAOqA4ICkQP7AWQDdAEhA+8A0QJwAIMC+/8+ApD/AwIs/9EBzP6mAXD+gQEV/l4BRv7vAKL+ygEI/6sC
      gf+VAxgAiATJAHQFeQE6Bg4CygaIAiQH8QJJB1cDOwfGA/oGSASQBtwEDAZsBY4FywUtBeAF6gSuBbcERAWJBLUEYQQPBEQE
      YgMuBLkCFAQcAusDiwGxAwcBbQOMACwDGADzAqz/wgJG/5gC5P5zAob+UgIp/jQCZ/4GA9z+3ANf/7UE9v+PBaAAYgZTAR4H
      +AGzB34CGAjqAk4ISQNZCKcDPAgPBP0HigSmByIFQgfGBd4GSgaEBoEGNAZhBuYF9wWYBVQFUQWNBBwFugP3BPEC2QQ/ArIE
      qQF8BCgBPASyAAEEQADOA9L/ogNp/3wDBP9aA6L+OwNC/h4DpP4tBTL/9AXM/7YGcwBwByEBFwjLAaMIYwILCdwCTAk/A2cJ
      mANeCfEDOAlUBP4IygS7CFwFfQj/BUcIjwYRCOEGzQffBnQHhgYQB+EFsgYIBWkGHAQ1BjoDCwZ1AtoF1QGaBVQBUQXgAA4F
      bwDXBAAAqASU/4AEK/9cBMX+OgRi/hoE+P5aB5j/BAg+AKUI6AA2CZABsgktAhIKtwJVCikDeQqKA38K4wNqCjsEQAqbBAoK
      CgXYCZAFuwkkBrIJrQakCQoHeQkiBywJ4wbPCE0GdAh3BSkIhgTpB5oDqwfIAmIHHAIKB5EBrAYYAVcGpAAQBjMA1gXE/6QF
      WP93Be7+TwWH/ikFWf+DCQIACAqrAIEKUQHpCu4BPAt/AngLAAOdC28DqQvSA6ALLgSFC4gEXQvmBDILTgURC8YFCQtGBhYL
      vAYfCxEHDQsuB9wKAAeZCoIGUwrGBQ4K6QTHCQgEdQk2AxQJgAKnCOYBNghgAc4H5QBzB28AJwf8/+YGi/+sBh3/eAax/kgG
      wv+iC2sA/QsPAU0MrQGODEECvgzJAtsMRAPnDLQD4wwZBNEMeAS1DNUElQwzBXgMlgVnDP8FawxpBn0MxgaODAYHjAwYB3UM
      8AZMDIoGFwzwBdcLNgWKC28ELQurA8AK9AJJClACzwm8AVsJNQHxCLcAkwg9AEAIxv/3B1H/tAff/nUHLAC4Dc4A5w1rAQ4O
      AAIqDo0COw4QAz8OiAM4DvgDKA5hBBIOwwT5DSIF4w1/BdQN2wXQDTUG2g2HBuwNygb9DfMGBA73BvwN0QbiDX4Gtw0EBnsN
      bgUsDcUEzQwVBF8MZwPnC8ECawsmAvEKlAF8CgsBEAqIAK0JCABTCYv//wgQ/7AIlQDEDy0Bxw/BAcYPTgLBD9UCtQ9UA6QP
      zQOPDz4EeA+oBGAPDQVND2sFQA/EBTwPFwZBD2EGTw+eBmEPygZxD98Gew/YBngPswZlD3AGQA8PBggPlgW9DgoFYA5xBPYN
      0gOCDTEDBw2UAooM/AEPDGkBmAvcACYLUgC7Csv/VgpG//UJ
      """
    private static let gridSize = 33
    private static let gridStep: Float = 8
    private var base = [Int32]()  // for each sample, the top-left of the four render pixels it mixes
    private var fractions = [SIMD2<Float>]()

    init() {
      let n = DockTileRenderer.pixels
      let m = 2 * n
      let g = Self.gridSize
      let field: [Float] =
        Data(base64Encoded: Self.field, options: .ignoreUnknownCharacters).map { data in
          data.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 256 }
          }
        } ?? []
      assert(field.count == g * g * 2, "The warp field doesn't decode to \(g) × \(g) points")
      base.reserveCapacity(n * n * 4)
      fractions.reserveCapacity(n * n * 4)
      for y in 0..<n {
        for x in 0..<n {
          for sub in [SIMD2<Float>(0.25, 0.25), [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]] {
            var point = SIMD2(Float(x), Float(y)) + sub
            if field.count == g * g * 2 {
              let grid = (point / Self.gridStep).clamped(
                lowerBound: SIMD2(repeating: 0), upperBound: SIMD2(repeating: Float(g - 1) - 0.001))
              let i = Int(grid.x)
              let j = Int(grid.y)
              let t = grid - SIMD2(Float(i), Float(j))
              func at(_ i: Int, _ j: Int) -> SIMD2<Float> {
                SIMD2(field[(j * g + i) * 2], field[(j * g + i) * 2 + 1])
              }
              point +=
                (at(i, j) * (1 - t.x) + at(i + 1, j) * t.x) * (1 - t.y)
                + (at(i, j + 1) * (1 - t.x) + at(i + 1, j + 1) * t.x) * t.y
            }
            // Pixel centers of the render sit at k + 0.5.
            let source = point * 2 - 0.5
            let i = min(max(Int(source.x.rounded(.down)), 0), m - 2)
            let j = min(max(Int(source.y.rounded(.down)), 0), m - 2)
            base.append(Int32(j * m + i))
            fractions.append(
              (source - SIMD2(Float(i), Float(j))).clamped(
                lowerBound: SIMD2(repeating: 0), upperBound: SIMD2(repeating: 1)))
          }
        }
      }
    }

    /// The tile from `render`, premultiplied RGBA at twice the tile's size.
    func sample(_ render: [UInt8]) -> [UInt8] {
      let n = DockTileRenderer.pixels
      let row = 2 * n * 4
      var tile = [UInt8](repeating: 0, count: n * n * 4)
      render.withUnsafeBufferPointer { source in
        tile.withUnsafeMutableBufferPointer { tile in
          func pixel(_ offset: Int) -> SIMD4<Float> {
            SIMD4(
              Float(source[offset]), Float(source[offset + 1]), Float(source[offset + 2]),
              Float(source[offset + 3]))
          }
          for p in 0..<n * n {
            var sum = SIMD4<Float>(repeating: 0)
            for k in p * 4..<p * 4 + 4 {
              let b = Int(base[k]) * 4
              let f = fractions[k]
              sum +=
                pixel(b) * ((1 - f.x) * (1 - f.y)) + pixel(b + 4) * (f.x * (1 - f.y))
                + pixel(b + row) * ((1 - f.x) * f.y) + pixel(b + row + 4) * (f.x * f.y)
            }
            let value = (sum * 0.25).rounded(.toNearestOrAwayFromZero)
            for c in 0..<4 { tile[p * 4 + c] = UInt8(min(max(value[c], 0), 255)) }
          }
        }
      }
      return tile
    }
  }
#endif
