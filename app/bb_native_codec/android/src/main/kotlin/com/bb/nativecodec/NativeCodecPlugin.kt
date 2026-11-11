package com.bb.nativecodec

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Native JPEG codec for PrintCollageTool. All heavy work runs on a small
 * thread pool (NEVER the platform/UI thread); results are posted back on
 * the main looper as the channel contract requires.
 *
 * Registered automatically in BOTH engines (activity + foreground-service)
 * via GeneratedPluginRegistrant.
 */
class NativeCodecPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    // 2 threads: matches the app's two concurrent sheet workers.
    private val executor = Executors.newFixedThreadPool(2)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "bb_native_codec")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        if (args == null) {
            result.error("codec", "missing arguments", null)
            return
        }
        executor.execute {
            try {
                val out: Any = when (call.method) {
                    "encodeRgba" -> encodeRgba(args)
                    "decodeRgba" -> decodeRgba(args)
                    "encodeRgbaFile" -> encodeRgbaFile(args)
                    "decodeRgbaFile" -> decodeRgbaFile(args)
                    "transcodeFit" -> transcodeFit(args)
                    else -> {
                        mainHandler.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainHandler.post { result.success(out) }
            } catch (e: Throwable) {
                // OutOfMemory included — Dart side falls back to pure-Dart.
                mainHandler.post { result.error("codec", e.toString(), null) }
            }
        }
    }

    /** Raw RGBA bytes -> JPEG. */
    private fun encodeRgba(args: Map<*, *>): ByteArray {
        val w = (args["width"] as Number).toInt()
        val h = (args["height"] as Number).toInt()
        val rgba = args["rgba"] as ByteArray
        val q = (args["quality"] as Number).toInt()
        require(rgba.size >= w * h * 4) { "buffer too small" }
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        try {
            bmp.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
            val bos = ByteArrayOutputStream(rgba.size / 16)
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, q, bos)) {
                throw IllegalStateException("JPEG compress failed")
            }
            return bos.toByteArray()
        } finally {
            bmp.recycle()
        }
    }

    /** Encoded image -> raw RGBA + dimensions. */
    private fun decodeRgba(args: Map<*, *>): Map<String, Any> {
        val src = args["src"] as ByteArray
        val opts = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bmp = BitmapFactory.decodeByteArray(src, 0, src.size, opts)
            ?: throw IllegalArgumentException("decode failed")
        try {
            val buf = ByteBuffer.allocate(bmp.width * bmp.height * 4)
            bmp.copyPixelsToBuffer(buf)
            return mapOf(
                "width" to bmp.width,
                "height" to bmp.height,
                "rgba" to buf.array(),
            )
        } finally {
            bmp.recycle()
        }
    }

    /**
     * File-based twin of encodeRgba for HUGE buffers (the 106 MB sheet).
     * Passing that through the method channel spikes the Java heap 2x per
     * call and OOMs with two workers — via files, the pixels live in a
     * DIRECT (native) buffer and the Java heap barely notices.
     */
    private fun encodeRgbaFile(args: Map<*, *>): Int {
        val w = (args["width"] as Number).toInt()
        val h = (args["height"] as Number).toInt()
        val rgbaPath = args["rgbaPath"] as String
        val outPath = args["outPath"] as String
        val q = (args["quality"] as Number).toInt()
        val size = w * h * 4
        val buf = ByteBuffer.allocateDirect(size)
        java.io.FileInputStream(rgbaPath).channel.use { ch ->
            while (buf.hasRemaining()) {
                if (ch.read(buf) < 0) break
            }
        }
        require(!buf.hasRemaining()) { "rgba file too small" }
        buf.rewind()
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        try {
            bmp.copyPixelsFromBuffer(buf)
            java.io.FileOutputStream(outPath).use { os ->
                if (!bmp.compress(Bitmap.CompressFormat.JPEG, q, os)) {
                    throw IllegalStateException("JPEG compress failed")
                }
            }
        } finally {
            bmp.recycle()
        }
        return java.io.File(outPath).length().toInt()
    }

    /**
     * File-based twin of decodeRgba: image file in, raw RGBA file out.
     * With fitW/fitH > 0 the bitmap is also scaled (up OR down, aspect
     * kept) to fit that box — the formula mirrors Dart's _resizeToFit
     * exactly. Native scaling takes ~100 ms; the same upscale in pure
     * Dart cubic took ~20 s per design and was the hidden sheet killer.
     */
    private fun decodeRgbaFile(args: Map<*, *>): Map<String, Any> {
        val srcPath = args["srcPath"] as String
        val outPath = args["outPath"] as String
        val fitW = ((args["fitW"] as? Number)?.toInt()) ?: 0
        val fitH = ((args["fitH"] as? Number)?.toInt()) ?: 0
        val opts = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bmp = BitmapFactory.decodeFile(srcPath, opts)
            ?: throw IllegalArgumentException("decode failed: $srcPath")
        if (fitW > 0 && fitH > 0) {
            val srcAspect = bmp.width.toDouble() / bmp.height
            val dstAspect = fitW.toDouble() / fitH
            val nw: Int
            val nh: Int
            if (srcAspect > dstAspect) {
                nw = fitW
                nh = Math.round(fitW / srcAspect).toInt()
            } else {
                nh = fitH
                nw = Math.round(fitH * srcAspect).toInt()
            }
            if (nw != bmp.width || nh != bmp.height) {
                val scaled = Bitmap.createScaledBitmap(
                    bmp, nw.coerceAtLeast(1), nh.coerceAtLeast(1), true)
                if (scaled !== bmp) {
                    bmp.recycle()
                    bmp = scaled
                }
            }
        }
        try {
            val buf = ByteBuffer.allocateDirect(bmp.width * bmp.height * 4)
            bmp.copyPixelsToBuffer(buf)
            buf.rewind()
            java.io.FileOutputStream(outPath).channel.use { ch ->
                while (buf.hasRemaining()) ch.write(buf)
            }
            return mapOf("width" to bmp.width, "height" to bmp.height)
        } finally {
            bmp.recycle()
        }
    }

    /**
     * Encoded image -> JPEG that fits within maxW x maxH (aspect kept,
     * never upscaled). inSampleSize pre-scaling keeps peak memory low on
     * absurdly large sources.
     */
    private fun transcodeFit(args: Map<*, *>): ByteArray {
        val src = args["src"] as ByteArray
        val maxW = (args["maxW"] as Number).toInt()
        val maxH = (args["maxH"] as Number).toInt()
        val q = (args["quality"] as Number).toInt()

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(src, 0, src.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalArgumentException("unreadable image header")
        }
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxW &&
            bounds.outHeight / (sample * 2) >= maxH
        ) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bmp = BitmapFactory.decodeByteArray(src, 0, src.size, opts)
            ?: throw IllegalArgumentException("decode failed")
        try {
            if (bmp.width > maxW || bmp.height > maxH) {
                val scale = minOf(
                    maxW.toFloat() / bmp.width,
                    maxH.toFloat() / bmp.height,
                )
                val nw = (bmp.width * scale).toInt().coerceAtLeast(1)
                val nh = (bmp.height * scale).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(bmp, nw, nh, true)
                if (scaled !== bmp) {
                    bmp.recycle()
                    bmp = scaled
                }
            }
            val bos = ByteArrayOutputStream()
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, q, bos)) {
                throw IllegalStateException("JPEG compress failed")
            }
            return bos.toByteArray()
        } finally {
            bmp.recycle()
        }
    }
}
