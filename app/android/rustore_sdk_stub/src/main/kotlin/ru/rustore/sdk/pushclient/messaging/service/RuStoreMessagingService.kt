package ru.rustore.sdk.pushclient.messaging.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import ru.rustore.sdk.pushclient.messaging.exception.RuStorePushClientException
import ru.rustore.sdk.pushclient.messaging.model.RemoteMessage

/** Never started: nothing delivers to the stub. */
abstract class RuStoreMessagingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    open fun onNewToken(token: String) {}

    open fun onMessageReceived(message: RemoteMessage) {}

    open fun onDeletedMessages() {}

    open fun onError(errors: List<RuStorePushClientException>) {}
}
