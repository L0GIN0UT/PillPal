package ru.rustore.sdk.core.feature.model

sealed class FeatureAvailabilityResult {
    class Available : FeatureAvailabilityResult()

    class Unavailable(val cause: Throwable) : FeatureAvailabilityResult()
}
