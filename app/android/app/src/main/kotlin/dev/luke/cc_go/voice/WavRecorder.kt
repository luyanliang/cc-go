package dev.luke.cc_go.voice

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/**
 * Records the microphone as canonical 16 kHz mono PCM16 WAV for the daemon's
 * transcription provider (ported from dsh-Go's WavRecorder).
 *
 * Captures at 16 kHz when the device offers it, otherwise at 48 / 44.1 kHz and
 * resamples on [finish]. Reports the input level about every 60 ms and stops
 * capturing by itself after [maxSeconds].
 */
class WavRecorder(
    private val maxSeconds: Int,
    private val onLevel: (Double) -> Unit,
    private val onLimit: () -> Unit,
    private val onError: () -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var rate = WavCodec.TARGET_RATE
    private val pcm = ByteArrayOutputStream()
    private val captureState = Any()

    @Volatile
    private var running = false
    private var captureError: IOException? = null

    /** Opens the microphone and starts capturing; false when it cannot be opened. */
    @SuppressLint("MissingPermission") // VoicePlugin checks RECORD_AUDIO first.
    fun start(): Boolean {
        // Some devices refuse the recognition source; the plain mic then.
        val sources = intArrayOf(MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC)
        for (source in sources) for (candidate in intArrayOf(WavCodec.TARGET_RATE, 48000, 44100)) {
            val min = AudioRecord.getMinBufferSize(candidate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val r = runCatching {
                AudioRecord(
                    source,
                    candidate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    max(min, candidate / 5 * 2), // at least 200 ms
                )
            }.getOrNull() ?: continue
            if (r.state != AudioRecord.STATE_INITIALIZED) {
                r.release()
                continue
            }
            val started = runCatching { r.startRecording() }.isSuccess &&
                r.recordingState == AudioRecord.RECORDSTATE_RECORDING
            if (!started) {
                r.release()
                continue
            }
            record = r
            rate = candidate
            synchronized(captureState) { running = true }
            thread = Thread({ capture() }, "cc-go-voice-recorder").also { it.start() }
            return true
        }
        return false
    }

    private fun capture() {
        val r = record ?: return
        val chunk = ShortArray(rate * 60 / 1000) // ~60 ms
        val bytes = ByteBuffer.allocate(chunk.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        val limit = maxSeconds.toLong() * rate
        var captured = 0L
        while (running) {
            val n = try {
                r.read(chunk, 0, chunk.size)
            } catch (error: RuntimeException) {
                failCapture(IOException("Could not read microphone", error))
                break
            }
            if (n < 0) {
                failCapture(IOException("Could not read microphone ($n)"))
                break
            }
            if (n == 0) continue
            val take = minOf(n.toLong(), limit - captured).toInt()
            bytes.clear()
            var sum = 0.0
            for (i in 0 until take) {
                val s = chunk[i]
                bytes.putShort(s)
                sum += s.toDouble() * s
            }
            synchronized(pcm) { pcm.write(bytes.array(), 0, take * 2) }
            captured += take
            onLevel(WavCodec.levelOf(sum, take))
            if (captured >= limit) {
                val reached = synchronized(captureState) {
                    if (!running) false else {
                        running = false
                        true
                    }
                }
                if (reached) onLimit()
                break
            }
        }
    }

    private fun failCapture(error: IOException) {
        // stopCapture retires the read before calling AudioRecord.stop(). Its
        // interrupted read must not turn an ordinary stop into a capture error.
        synchronized(captureState) {
            if (!running) return
            captureError = error
            running = false
        }
        onError()
    }

    /** Stops capturing and returns the WAV, or null when nothing was captured.
     * A failed or still-running capture cannot be returned as a finished recording. */
    fun finish(): ByteArray? {
        if (!stopCapture()) throw IOException("Microphone capture did not stop")
        synchronized(captureState) { captureError }?.let { throw it }
        val raw = synchronized(pcm) { pcm.toByteArray() }
        if (raw.size < 2) return null
        val samples = ShortArray(raw.size / 2)
        ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
        val pcm16k = if (rate == WavCodec.TARGET_RATE) samples else WavCodec.resample(samples, rate, WavCodec.TARGET_RATE)
        return WavCodec.wav(pcm16k)
    }

    /** Stops capturing and drops the audio. */
    fun discard() {
        stopCapture()
        synchronized(pcm) { pcm.reset() }
    }

    private fun stopCapture(): Boolean {
        synchronized(captureState) { running = false }
        val r = record
        record = null
        runCatching { r?.stop() }
        val t = thread
        runCatching { t?.join(1000) }
        thread = null
        runCatching { r?.release() }
        return t?.isAlive != true
    }
}
