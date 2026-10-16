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
 * The app stores the open doses of today and tomorrow with their instants
 * and each day's progress (already localized and privacy-filtered,
 * lib/src/home_widget/today_widget_snapshot.dart) after every write; this
 * provider only picks the current day and the first dose still ahead
 * whenever it is drawn. It arms no alarms of its own (the exact-alarm quota
 * belongs to reminders). A tap opens the app on Today.
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
        val stale = data.getString(KEY_STALE, null)
            ?: context.getString(R.string.today_widget_open_app)
        // The stored day (today or tomorrow) that contains now.
        val day = lines(data, KEY_DAYS)
            .mapNotNull { fields ->
                val start = fields.getOrNull(0)?.toLongOrNull()
                val end = fields.getOrNull(1)?.toLongOrNull()
                if (start == null || end == null) null else Triple(start, end, fields.getOrElse(2) { "" })
            }
            .firstOrNull { (start, end, _) -> now in start until end }
            // Nothing stored, signed out, or the stored days are over.
            ?: return Content("", "", stale, "")
        val next = lines(data, KEY_ENTRIES)
            .mapNotNull { fields ->
                val due = fields.getOrNull(0)?.toLongOrNull()
                if (due == null || fields.size < 3) null else Triple(due, fields[1], fields[2])
            }
            .firstOrNull { (due, _, _) -> due + MISSED_GRACE_MILLIS > now && due < day.second }
            ?: return Content("", "", data.getString(KEY_NONE_LEFT, null).orEmpty(), day.third)
        val label = data.getString(KEY_NEXT_LABEL, null).orEmpty()
        return Content(label, next.second, next.third, day.third)
    }

    private fun lines(data: SharedPreferences, key: String): List<List<String>> =
        data.getString(key, null).orEmpty()
            .split(ENTRY_SEPARATOR)
            .filter { it.isNotEmpty() }
            .map { it.split(FIELD_SEPARATOR) }

    private companion object {
        // Keys and separators of TodayWidgetKeys (today_widget_snapshot.dart).
        const val KEY_NEXT_LABEL = "today_next_label"
        const val KEY_DAYS = "today_days"
        const val KEY_ENTRIES = "today_entries"
        const val KEY_NONE_LEFT = "today_none_left"
        const val KEY_STALE = "today_stale"
        const val FIELD_SEPARATOR = "\u001f"
        const val ENTRY_SEPARATOR = "\n"

        // DoseTiming.missedGrace: a dose stops being "next" 30 minutes after its time.
        const val MISSED_GRACE_MILLIS = 30L * 60L * 1000L
    }
}
