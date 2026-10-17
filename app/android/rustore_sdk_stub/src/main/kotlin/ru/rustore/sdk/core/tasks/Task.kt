package ru.rustore.sdk.core.tasks

/** The result of an SDK call; the stub's calls have finished before they return. */
class Task<T> private constructor(
    private val value: T?,
    private val error: Throwable?,
) {
    fun addOnSuccessListener(listener: (T) -> Unit): Task<T> {
        if (error == null) {
            @Suppress("UNCHECKED_CAST")
            listener(value as T)
        }
        return this
    }

    fun addOnFailureListener(listener: (Throwable) -> Unit): Task<T> {
        if (error != null) {
            listener(error)
        }
        return this
    }

    companion object {
        fun <T> success(value: T): Task<T> = Task(value, null)

        fun <T> failure(error: Throwable): Task<T> = Task(null, error)
    }
}
