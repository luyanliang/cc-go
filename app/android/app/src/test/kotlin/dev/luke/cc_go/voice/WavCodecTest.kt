package dev.luke.cc_go.voice

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WavCodecTest {
    @Test fun wavHeaderIsCanonical16kMonoPcm16() {
        val wav = WavCodec.wav(shortArrayOf(0, 100, -100))
        assertEquals("RIFF", wav.decodeToString(0, 4))
        assertEquals(44 + 6, wav.size)
        assertEquals(36 + 6, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getInt(4))
        assertEquals("WAVE", wav.decodeToString(8, 12))
        assertEquals(16000, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getInt(24))
        assertEquals(32000, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getInt(28))
        assertEquals(1, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getShort(22).toInt()) // mono
        assertEquals(16, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getShort(34).toInt()) // PCM16
        assertEquals("data", wav.decodeToString(36, 40))
        assertEquals(6, ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN).getInt(40))
    }

    @Test fun wavSamplesRoundTripLittleEndian() {
        val samples = shortArrayOf(0, 1, -1, 32767, -32768)
        val wav = WavCodec.wav(samples)
        val buffer = ByteBuffer.wrap(wav, 44, wav.size - 44).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) assertEquals(s.toInt(), buffer.short.toInt())
    }

    @Test fun levelOfIsZeroForSilence() {
        assertEquals(0.0, WavCodec.levelOf(0.0, 1000), 1e-9)
        assertEquals(0.0, WavCodec.levelOf(0.0, 0), 1e-9)
    }

    @Test fun levelOfSpansSilenceToLoud() {
        // Full-scale square-ish wave is loud: 32768^2 per sample.
        val loud = WavCodec.levelOf(32768.0 * 32768.0, 1)
        assertEquals(1.0, loud, 1e-6)
        // A whisper level (-45 dBFS) is near the bottom of the scale.
        val rms = 32768.0 * Math.pow(10.0, -45.0 / 20.0)
        val quiet = WavCodec.levelOf(rms * rms, 1)
        assertTrue(quiet in 0.0..0.2)
    }

    @Test fun resampleDownsamplesWithSpanAverage() {
        // 2:1 decimation averages each pair.
        val out = WavCodec.resample(shortArrayOf(0, 10, 20, 30), 2, 1)
        assertEquals(listOf(5, 25), out.map { it.toInt() })
    }

    @Test fun resampleSameRateIsIdentityLength() {
        val input = ShortArray(160) { it.toShort() }
        assertEquals(160, WavCodec.resample(input, 16000, 16000).size)
    }
}
