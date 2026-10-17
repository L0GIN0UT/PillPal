package com.pillpal.alerts;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.service.notification.StatusBarNotification;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Posts the alerts about relatives (docs/adr/0008-push-delivery.md, section 2).
 *
 * Why native: a notification with private visibility needs a public version,
 * which a secure lock screen shows instead of the names and the text, and no
 * Flutter notification plugin can attach one. A local plugin is also
 * registered in the background engine that a data-only push starts when the
 * app is terminated, where MainActivity does not exist.
 *
 * Channel "pillpal/alerts": prepare, show, isShown, launchPayload (Dart to
 * native) and tap (native to Dart). The payload is opaque here.
 */
public final class AlertsPlugin
    implements FlutterPlugin,
        MethodChannel.MethodCallHandler,
        ActivityAware,
        PluginRegistry.NewIntentListener {
  private static final String CHANNEL = "pillpal/alerts";

  /** Intent extra that carries the payload of a tapped alert. */
  private static final String EXTRA_PAYLOAD = "pillpal.alert_payload";

  private Context context;
  private MethodChannel channel;
  private ActivityPluginBinding activity;
  private String launchPayload;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "prepare":
          prepare(call);
          result.success(null);
          break;
        case "show":
          show(call);
          result.success(null);
          break;
        case "isShown":
          result.success(isShown(requiredInt(call, "id")));
          break;
        case "launchPayload":
          String payload = launchPayload;
          launchPayload = null;
          result.success(payload);
          break;
        default:
          result.notImplemented();
      }
    } catch (RuntimeException error) {
      // The message is never forwarded: it could carry the alert text.
      result.error("alerts_failed", error.getClass().getSimpleName(), null);
    }
  }

  private NotificationManager manager() {
    return (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
  }

  private static int requiredInt(MethodCall call, String key) {
    Integer value = call.argument(key);
    if (value == null) {
      throw new IllegalArgumentException(key);
    }
    return value;
  }

  private static String requiredString(MethodCall call, String key) {
    String value = call.argument(key);
    if (value == null) {
      throw new IllegalArgumentException(key);
    }
    return value;
  }

  private void prepare(MethodCall call) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return;
    }
    NotificationChannel created =
        new NotificationChannel(
            requiredString(call, "channelId"),
            requiredString(call, "name"),
            NotificationManager.IMPORTANCE_HIGH);
    created.setDescription(requiredString(call, "description"));
    created.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
    manager().createNotificationChannel(created);
  }

  @SuppressWarnings("deprecation")
  private Notification.Builder builder(String channelId) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      return new Notification.Builder(context, channelId);
    }
    return new Notification.Builder(context);
  }

  @SuppressWarnings("deprecation")
  private void show(MethodCall call) {
    int id = requiredInt(call, "id");
    String channelId = requiredString(call, "channelId");
    String payload = requiredString(call, "payload");
    boolean quiet = Boolean.TRUE.equals(call.argument("quiet"));
    int icon = context.getApplicationInfo().icon;

    // What a secure lock screen shows: neutral text, no names.
    Notification publicVersion =
        builder(channelId)
            .setSmallIcon(icon)
            .setContentTitle(requiredString(call, "publicTitle"))
            .setContentText(requiredString(call, "publicBody"))
            .build();

    Notification.Builder notification =
        builder(channelId)
            .setSmallIcon(icon)
            .setContentTitle(requiredString(call, "title"))
            .setContentText(requiredString(call, "body"))
            .setStyle(new Notification.BigTextStyle().bigText(requiredString(call, "body")))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            // A repeat or a follow-up replaces what is shown without a sound.
            .setOnlyAlertOnce(quiet);
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      notification.setPriority(Notification.PRIORITY_HIGH);
      if (!quiet) {
        notification.setDefaults(Notification.DEFAULT_ALL);
      }
    }
    PendingIntent tap = tapIntent(id, payload);
    if (tap != null) {
      notification.setContentIntent(tap);
    }
    manager().notify(id, notification.build());
  }

  private PendingIntent tapIntent(int id, String payload) {
    Intent launch =
        context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    if (launch == null) {
      return null;
    }
    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    launch.putExtra(EXTRA_PAYLOAD, payload);
    return PendingIntent.getActivity(
        context, id, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
  }

  private boolean isShown(int id) {
    for (StatusBarNotification active : manager().getActiveNotifications()) {
      if (active.getId() == id) {
        return true;
      }
    }
    return false;
  }

  // The tap on an alert launches the app with the payload in the intent.

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding;
    binding.addOnNewIntentListener(this);
    String payload = takePayload(binding.getActivity().getIntent());
    if (payload != null) {
      launchPayload = payload;
    }
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  @Override
  public void onDetachedFromActivity() {
    if (activity != null) {
      activity.removeOnNewIntentListener(this);
      activity = null;
    }
  }

  @Override
  public boolean onNewIntent(@NonNull Intent intent) {
    String payload = takePayload(intent);
    if (payload != null && channel != null) {
      channel.invokeMethod("tap", payload);
    }
    // Other listeners (deep links) look at the intent as well.
    return false;
  }

  private static String takePayload(Intent intent) {
    if (intent == null) {
      return null;
    }
    String payload = intent.getStringExtra(EXTRA_PAYLOAD);
    if (payload != null) {
      intent.removeExtra(EXTRA_PAYLOAD);
    }
    return payload;
  }
}
