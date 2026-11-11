import Flutter
import UIKit
import ImageIO
import MobileCoreServices

/// iOS twin of the Android NativeCodecPlugin. Same method channel
/// ("bb_native_codec") and the same method names / argument shapes, so the
/// Dart side (collage.dart hooks) is identical on both platforms. All heavy
/// work runs off the platform thread on a background queue; results are
/// posted back on the main queue, matching the channel contract.
///
/// Every pixel buffer is RGBA8888 (R,G,B,A byte order in memory) to match
/// the Dart canvas (numChannels: 4) and the Kotlin side — so no per-pixel
/// channel juggling is ever needed.
public class NativeCodecPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "bb.nativecodec", qos: .userInitiated, attributes: .concurrent)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "bb_native_codec", binaryMessenger: registrar.messenger())
    let instance = NativeCodecPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "codec", message: "missing arguments", details: nil))
      return
    }
    let method = call.method
    queue.async {
      do {
        let out: Any
        switch method {
        case "encodeRgba":     out = try self.encodeRgba(args)
        case "decodeRgba":     out = try self.decodeRgba(args)
        case "encodeRgbaFile": out = try self.encodeRgbaFile(args)
        case "decodeRgbaFile": out = try self.decodeRgbaFile(args)
        case "transcodeFit":   out = try self.transcodeFit(args)
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(out) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "codec", message: "\(error)", details: nil))
        }
      }
    }
  }

  // MARK: - helpers

  private enum CodecError: Error { case bad(String) }

  private let rgbaBitmapInfo: UInt32 =
    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

  /// Build a CGImage from a straight-RGBA buffer (alpha is 255 everywhere
  /// in our use, so premultiplied == straight).
  private func cgImage(fromRGBA data: Data, width: Int, height: Int) throws -> CGImage {
    let bytesPerRow = width * 4
    guard data.count >= bytesPerRow * height else { throw CodecError.bad("buffer too small") }
    guard let provider = CGDataProvider(data: data as CFData) else { throw CodecError.bad("provider") }
    guard let img = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: rgbaBitmapInfo),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else { throw CodecError.bad("cgimage") }
    return img
  }

  /// Render any CGImage into a fresh straight-RGBA byte buffer at the given
  /// size (R,G,B,A order), the inverse of `cgImage(fromRGBA:)`.
  private func rgbaBytes(from image: CGImage, width: Int, height: Int) throws -> Data {
    let bytesPerRow = width * 4
    var buf = Data(count: bytesPerRow * height)
    try buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: rgbaBitmapInfo
      ) else { throw CodecError.bad("context") }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buf
  }

  /// JPEG-encode a CGImage at [quality] (0..100 → 0..1).
  private func jpegData(from image: CGImage, quality: Int) throws -> Data {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, kUTTypeJPEG, 1, nil) else {
      throw CodecError.bad("jpeg dest")
    }
    let q = max(0.0, min(1.0, Double(quality) / 100.0))
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CodecError.bad("jpeg finalize") }
    return out as Data
  }

  /// Aspect-fit target size (up OR down), mirroring Dart _resizeToFit and
  /// the Kotlin fit math exactly.
  private func fitSize(srcW: Int, srcH: Int, boxW: Int, boxH: Int) -> (Int, Int) {
    let srcAspect = Double(srcW) / Double(srcH)
    let dstAspect = Double(boxW) / Double(boxH)
    if srcAspect > dstAspect {
      return (boxW, max(1, Int((Double(boxW) / srcAspect).rounded())))
    } else {
      return (max(1, Int((Double(boxH) * srcAspect).rounded())), boxH)
    }
  }

  private func decodeFile(_ path: String) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      throw CodecError.bad("decode failed: \(path)")
    }
    return img
  }

  private func decodeData(_ data: Data) throws -> CGImage {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      throw CodecError.bad("decode failed")
    }
    return img
  }

  // MARK: - channel methods

  private func encodeRgba(_ a: [String: Any]) throws -> FlutterStandardTypedData {
    let w = a["width"] as! Int, h = a["height"] as! Int, q = a["quality"] as! Int
    let rgba = (a["rgba"] as! FlutterStandardTypedData).data
    let img = try cgImage(fromRGBA: rgba, width: w, height: h)
    return FlutterStandardTypedData(bytes: try jpegData(from: img, quality: q))
  }

  private func decodeRgba(_ a: [String: Any]) throws -> [String: Any] {
    let img = try decodeData((a["src"] as! FlutterStandardTypedData).data)
    let bytes = try rgbaBytes(from: img, width: img.width, height: img.height)
    return ["width": img.width, "height": img.height,
            "rgba": FlutterStandardTypedData(bytes: bytes)]
  }

  /// File-based twin of encodeRgba for the huge sheet buffer (~106 MB):
  /// raw RGBA read from a file, JPEG written to a file — keeps the giant
  /// payload off the method channel.
  private func encodeRgbaFile(_ a: [String: Any]) throws -> Int {
    let w = a["width"] as! Int, h = a["height"] as! Int, q = a["quality"] as! Int
    let rgbaPath = a["rgbaPath"] as! String, outPath = a["outPath"] as! String
    let rgba = try Data(contentsOf: URL(fileURLWithPath: rgbaPath), options: .mappedIfSafe)
    let img = try cgImage(fromRGBA: rgba, width: w, height: h)
    let jpeg = try jpegData(from: img, quality: q)
    try jpeg.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    return jpeg.count
  }

  /// File-based twin of decodeRgba with optional aspect-fit scaling
  /// (fitW/fitH > 0). Native scaling is ~instant; this is what keeps the
  /// per-design upscale off the slow Dart path on iOS too.
  private func decodeRgbaFile(_ a: [String: Any]) throws -> [String: Any] {
    let srcPath = a["srcPath"] as! String, outPath = a["outPath"] as! String
    let fitW = (a["fitW"] as? Int) ?? 0, fitH = (a["fitH"] as? Int) ?? 0
    let img = try decodeFile(srcPath)
    var outW = img.width, outH = img.height
    if fitW > 0 && fitH > 0 { (outW, outH) = fitSize(srcW: img.width, srcH: img.height, boxW: fitW, boxH: fitH) }
    let bytes = try rgbaBytes(from: img, width: outW, height: outH)
    try bytes.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    return ["width": outW, "height": outH]
  }

  /// Encoded image -> JPEG downscaled (never upscaled) to fit maxW×maxH.
  private func transcodeFit(_ a: [String: Any]) throws -> FlutterStandardTypedData {
    let maxW = a["maxW"] as! Int, maxH = a["maxH"] as! Int, q = a["quality"] as! Int
    let img = try decodeData((a["src"] as! FlutterStandardTypedData).data)
    var outImg = img
    if img.width > maxW || img.height > maxH {
      let (nw, nh) = fitSize(srcW: img.width, srcH: img.height, boxW: maxW, boxH: maxH)
      let rgba = try rgbaBytes(from: img, width: nw, height: nh)
      outImg = try cgImage(fromRGBA: rgba, width: nw, height: nh)
    }
    return FlutterStandardTypedData(bytes: try jpegData(from: outImg, quality: q))
  }
}
