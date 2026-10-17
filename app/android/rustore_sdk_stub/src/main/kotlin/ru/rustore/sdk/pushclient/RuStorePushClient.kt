package ru.rustore.sdk.pushclient

import ru.rustore.sdk.core.feature.model.FeatureAvailabilityResult
import ru.rustore.sdk.core.tasks.Task

/** RuStore is reported as unavailable: this build has no RuStore project. */
object RuStorePushClient {
    private const val REASON = "RuStore Push is not part of this build"

    val isInitialized: Boolean
        get() = false

    fun checkPushAvailability(): Task<FeatureAvailabilityResult> =
        Task.success(FeatureAvailabilityResult.Unavailable(UnsupportedOperationException(REASON)))

    fun getToken(): Task<String> = Task.failure(UnsupportedOperationException(REASON))

    fun deleteToken(): Task<Unit> = Task.success(Unit)

    fun subscribeToTopic(topicName: String): Task<Unit> =
        Task.failure(UnsupportedOperationException(REASON))

    fun unsubscribeFromTopic(topicName: String): Task<Unit> =
        Task.failure(UnsupportedOperationException(REASON))
}
