package ru.rustore.sdk.pushclient.messaging.model

import android.net.Uri

class Notification(
    val title: String? = null,
    val body: String? = null,
    val channelId: String? = null,
    val clickAction: String? = null,
    val icon: String? = null,
    val color: String? = null,
    val imageUrl: Uri? = null,
)

class RemoteMessage(
    val messageId: String? = null,
    val priority: Int = 0,
    val ttl: Int = 0,
    val collapseKey: String? = null,
    val data: Map<String, String> = emptyMap(),
    val notification: Notification? = null,
)
