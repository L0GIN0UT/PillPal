package com.pillpal.pillpal

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Today's next dose and "N из M сегодня" on the home screen (TZ §2.6).
 *
 * The app stores today's open doses with their instants (already localized
 * and privacy-filtered, lib/src/home_widget/today_widget_snapshot.dart) and
 * schedules redraws at those instants; this provider only picks the first
 * dose that is still ahead. A tap opens the app on Today.
 */
class TodayWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val content = content(context, widgetData, System.currentTimeMillis())
        val open = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.today_widget)
            views.setTextViewText(R.id.today_widget_label, content.label)
            views.setTextViewText(R.id.today_widget_time, content.time)
            views.setTextViewText(R.id.today_widget_title, content.title)
            views.setTextViewText(R.id.today_widget_progress, content.progress)
            views.setViewVisibility(R.id.today_widget_label, visibleIf(content.label))
            views.setViewVisibility(R.id.today_widget_time, visibleIf(content.time))
            views.setViewVisibility(R.id.today_widget_progress, visibleIf(content.progress))
            views.setOnClickPendingIntent(R.id.today_widget_root, open)
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private data class Content(
        val label: String,
        val time: String,
        val title: String,
        val progress: String,
    )

    private fun visibleIf(text: String) = if (text.isEmpty()) View.GONE else View.VISIBLE

    private fun content(context: Context, data: SharedPreferences, now: Long): Content {
        val validUntil = data.getString(KEY_VALID_UNTIL, null)?.toLongOrNull()
        if (validUntil == null || now >= validUntil) {
            // Nothing stored yet, or yesterday's doses: the app refreshes on start.
            val stale = data.getString(KEY_STALE, null)
                ?: context.getString(R.string.today_widget_open_app)
            return Content("", "", stale, "")
        }
        val progress = data.getString(KEY_PROGRESS, null).orEmpty()
        val next = data.getString(KEY_ENTRIES, null).orEmpty()
            .split(ENTRY_SEPARATOR)
            .mapNotNull { line ->
                val fields = line.split(FIELD_SEPARATOR)
                val due = fields.getOrNull(0)?.toLongOrNull()
                if (due == null || fields.size < 3) null else Triple(due, fields[1], fields[2])
            }
            .firstOrNull { (due, _, _) -> due + MISSED_GRACE_MILLIS > now }
        if (next == null) {
            return Content("", "", data.getString(KEY_NONE_LEFT, null).orEmpty(), progress)
        }
        val label = data.getString(KEY_NEXT_LABEL, null).orEmpty()
        return Content(label, next.second, next.third, progress)
    }

    private companion object {
        // Keys and separators of TodayWidgetKeys (today_widget_snapshot.dart).
        const val KEY_NEXT_LABEL = "today_next_label"
        const val KEY_PROGRESS = "today_progress"
        const val KEY_ENTRIES = "today_entries"
        const val KEY_NONE_LEFT = "today_none_left"
        const val KEY_VALID_UNTIL = "today_valid_until"
        const val KEY_STALE = "today_stale"
        const val FIELD_SEPARATOR = "\u001f"
        const val ENTRY_SEPARATOR = "\n"

        // DoseTiming.missedGrace: a dose stops being "next" 30 minutes after its time.
        const val MISSED_GRACE_MILLIS = 30L * 60L * 1000L
    }
}
