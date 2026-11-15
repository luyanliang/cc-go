package dev.luke.cc_go.voice

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Pure-JVM pieces of the voice recorder, split out of [WavRecorder] so the
 * WAV framing, resampling and level math are unit-testable without Android.
 */
object WavCodec {
    const val TARGET_RATE = 16000

    /** 44-byte canonical PCM16 WAV header. */
    fun header(dataLength: Int): ByteArray {
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(36 + dataLength)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16) // PCM fmt chunk size
        buffer.putShort(1.toShort()) // PCM
        buffer.putShort(1.toShort()) // mono
        buffer.putInt(TARGET_RATE)
        buffer.putInt(TARGET_RATE * 2) // byte rate
        buffer.putShort(2.toShort()) // block align
        buffer.putShort(16.toShort()) // bits per sample
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataLength)
        return buffer.array()
    }

    /** Full WAV: header + little-endian PCM16 samples. */
    fun wav(samples: ShortArray): ByteArray {
        val dataLength = samples.size * 2
        val body = ByteArray(dataLength)
        val buffer = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buffer.putShort(s)
        return header(dataLength) + body
    }

    /** RMS in dBFS mapped from -50..-10 dB to 0..1 (silence → 0). */
    fun levelOf(sumOfSquares: Double, count: Int): Double {
        if (count <= 0) return 0.0
        val rms = sqrt(sumOfSquares / count) / 32768.0
        if (rms <= 0.0) return 0.0
        val db = 20 * log10(rms)
        return ((db + 50) / 40).coerceIn(0.0, 1.0)
    }

    /** Averages the source span of each output sample: a cheap low-pass before decimating. */
    fun resample(input: ShortArray, from: Int, to: Int): ShortArray {
        val outLength = (input.size.toLong() * to / from).toInt()
        val out = ShortArray(outLength)
        val step = from.toDouble() / to
        for (i in 0 until outLength) {
            val start = (i * step).toInt()
            val end = minOf(input.size, max(start + 1, ((i + 1) * step).toInt()))
            var sum = 0L
            for (j in start until end) sum += input[j]
            out[i] = (sum / (end - start)).toInt().toShort()
        }
        return out
    }
}
