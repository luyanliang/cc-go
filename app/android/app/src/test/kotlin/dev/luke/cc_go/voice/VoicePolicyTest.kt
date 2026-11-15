package dev.luke.cc_go.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VoicePolicyTest {
    private val environment = VoiceEnvironment(35, "vendor/build/one", "voice.vendor/.Recognition", "voice.vendor", 42, 123456, true, false)

    @Test fun sameServiceAndOsRememberFailureAcrossInstances() {
        val saved = environment.identity
        assertNotNull(saved)
        assertEquals(64, saved!!.length)
        assertTrue(VoicePolicy.isUnreliable(environment.copy(), saved))
    }

    @Test fun osUpgradeReevaluatesService() {
        assertFalse(VoicePolicy.isUnreliable(environment.copy(osBuild = "vendor/build/two"), environment.identity))
        assertFalse(VoicePolicy.isUnreliable(environment.copy(sdk = 36), environment.identity))
    }

    @Test fun serviceReplacementAndApkUpdateReevaluate() {
        val changed = listOf(
            environment.copy(service = "other.voice/.Recognizer", servicePackage = "other.voice"),
            environment.copy(service = "voice.vendor/.OtherRecognizer"),
            environment.copy(serviceVersion = 43),
            environment.copy(serviceUpdatedAt = 123457),
        )
        for (next in changed) assertFalse(VoicePolicy.isUnreliable(next, environment.identity))
    }

    @Test fun unknownIdentityNeverBecomesPermanentlyUnreliable() {
        val unknown = listOf(
            environment.copy(osBuild = ""), environment.copy(osBuild = "unknown"), environment.copy(service = null),
            environment.copy(servicePackage = null), environment.copy(serviceVersion = null),
            environment.copy(serviceUpdatedAt = null),
        )
        for (next in unknown) {
            assertNull(next.identity)
            assertFalse(VoicePolicy.isUnreliable(next, null))
            assertFalse(VoicePolicy.isUnreliable(next, environment.identity))
        }
    }

    @Test fun noSpeechAndPermissionNeverPoisonHealth() {
        for (code in listOf(6, 7, 9)) assertFalse(VoicePolicy.serviceFailure(code))
        for (code in listOf(1, 2, 3, 4, 5, 8, 10, 11, 12, 13, 14, 15, 777)) assertTrue(VoicePolicy.serviceFailure(code))
    }

    @Test fun allPublicErrorCodesHaveDistinctDiagnosticNames() {
        val names = (1..15).map(VoicePolicy::errorName)
        assertEquals(15, names.toSet().size)
        assertFalse(names.contains("UNKNOWN"))
        assertEquals("UNKNOWN", VoicePolicy.errorName(777))
        assertEquals("RECORDER_FAILED", VoicePolicy.errorName(100))
    }

    @Test fun diagnosticsDoNotExportOsFingerprintOrSpeechContent() {
        val fields = VoicePolicy.failureFields(environment, 5, "listen", 800, "ClientException")
        assertEquals(
            setOf(
                "sdk", "defaultService", "servicePackage", "serviceVersion", "serviceUpdatedAt",
                "recognizerAvailable", "onDeviceFactoryApiAvailable", "onDeviceAvailable", "environmentId",
                "at", "code", "name", "stage", "exceptionType",
            ),
            fields.keys,
        )
        // No OS build fingerprint, no request payload.
        assertTrue(fields.values.none { it is String && it.contains("vendor/build/one") })
        // Unknown stage is dropped.
        assertNull(VoicePolicy.failureFields(environment, 5, "elsewhere", 800)["stage"])
    }
}
