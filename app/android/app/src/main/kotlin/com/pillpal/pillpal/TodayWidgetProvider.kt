package com.pillpal.pillpal

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Today's next dose and "N из M сегодня" on the home screen (TZ §2.6).
 *
 * The app stores the open doses of today and tomorrow with their instants
 * and each day's progress (already localized and privacy-filtered,
 * lib/src/home_widget/today_widget_snapshot.dart) after every write; this
 * provider picks the current day and the first dose still ahead. Launchers
 * do not redraw a widget on their own (`updatePeriodMillis` is 0), so each
 * update arms ONE inexact, non-wakeup alarm (`AlarmManager.RTC`) for the
 * next transition — the next dose leaving its 30-minute grace, or the end
 * of the current day — that replaces the previous one. It never uses exact
 * alarms (that quota belongs to reminders) and is cancelled when the last
 * widget is removed. Clock and time-zone changes redraw at once. A tap
 * opens the app on Today.
 */
class TodayWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        val stored = Stored.read(widgetData)
        val content = content(context, widgetData, stored, now)
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
        scheduleNextRedraw(context, stored.nextTransition(now))
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            // The stored instants are absolute; the current day and the
            // shown local times depend on the clock.
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_TIME_CHANGED -> redrawAll(context)
            else -> super.onReceive(context, intent)
        }
    }

    /**
     * The last widget was removed: no stale dose data (medication names)
     * stays in the widget storage, and no redraw alarm stays armed. The app
     * stops writing while no widget is placed.
     */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        alarmManager(context)?.cancel(redrawIntent(context))
        val editor = HomeWidgetPlugin.getData(context).edit()
        for (key in ALL_KEYS) {
            editor.remove(key)
        }
        editor.apply()
    }

    private fun redrawAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java))
        if (ids.isNotEmpty()) {
            onUpdate(context, manager, ids, HomeWidgetPlugin.getData(context))
        }
    }

    /** Arms (or with null cancels) the single inexact redraw alarm. */
    private fun scheduleNextRedraw(context: Context, at: Long?) {
        val alarms = alarmManager(context) ?: return
        val intent = redrawIntent(context)
        if (at == null) {
            alarms.cancel(intent)
        } else {
            alarms.set(AlarmManager.RTC, at, intent)
        }
    }

    private fun alarmManager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager?

    /** An explicit APPWIDGET_UPDATE to this provider; one request code, so it replaces itself. */
    private fun redrawIntent(context: Context): PendingIntent {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java))
        val intent = Intent(context, TodayWidgetProvider::class.java)
            .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        return PendingIntent.getBroadcast(
            context,
            REDRAW_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private data class Content(
        val label: String,
        val time: String,
        val title: String,
        val progress: String,
    )

    private data class Day(val start: Long, val end: Long, val progress: String)

    private data class Dose(val due: Long, val time: String, val title: String)

    /** What the app stored: days (today, tomorrow) and their open doses. */
    private class Stored(val days: List<Day>, val doses: List<Dose>) {
        fun dayAt(now: Long) = days.firstOrNull { now in it.start until it.end }

        fun nextDose(day: Day, now: Long) =
            doses.firstOrNull { it.due + MISSED_GRACE_MILLIS > now && it.due < day.end }

        /** When the shown content changes next, or null when nothing is stored ahead. */
        fun nextTransition(now: Long): Long? {
            val day = dayAt(now) ?: return days.map { it.start }.filter { it > now }.minOrNull()
            val dose = nextDose(day, now)?.let { it.due + MISSED_GRACE_MILLIS }
            return listOfNotNull(dose, day.end).minOrNull()
        }

        companion object {
            fun read(data: SharedPreferences) = Stored(
                lines(data, KEY_DAYS).mapNotNull { fields ->
                    val start = fields.getOrNull(0)?.toLongOrNull()
                    val end = fields.getOrNull(1)?.toLongOrNull()
                    if (start == null || end == null) null else Day(start, end, fields.getOrElse(2) { "" })
                },
                lines(data, KEY_ENTRIES).mapNotNull { fields ->
                    val due = fields.getOrNull(0)?.toLongOrNull()
                    if (due == null || fields.size < 3) null else Dose(due, fields[1], fields[2])
                },
            )

            private fun lines(data: SharedPreferences, key: String): List<List<String>> =
                data.getString(key, null).orEmpty()
                    .split(ENTRY_SEPARATOR)
                    .filter { it.isNotEmpty() }
                    .map { it.split(FIELD_SEPARATOR) }
        }
    }

    private fun visibleIf(text: String) = if (text.isEmpty()) View.GONE else View.VISIBLE

    private fun content(context: Context, data: SharedPreferences, stored: Stored, now: Long): Content {
        val stale = data.getString(KEY_STALE, null)
            ?: context.getString(R.string.today_widget_open_app)
        // Nothing stored, signed out, or the stored days are over.
        val day = stored.dayAt(now) ?: return Content("", "", stale, "")
        val next = stored.nextDose(day, now)
            ?: return Content("", "", data.getString(KEY_NONE_LEFT, null).orEmpty(), day.progress)
        val label = data.getString(KEY_NEXT_LABEL, null).orEmpty()
        return Content(label, next.time, next.title, day.progress)
    }

    private companion object {
        // Keys and separators of TodayWidgetKeys (today_widget_snapshot.dart).
        const val KEY_NEXT_LABEL = "today_next_label"
        const val KEY_DAYS = "today_days"
        const val KEY_ENTRIES = "today_entries"
        const val KEY_NONE_LEFT = "today_none_left"
        const val KEY_STALE = "today_stale"
        const val KEY_VALID_UNTIL = "today_valid_until"
        val ALL_KEYS = listOf(
            KEY_NEXT_LABEL, KEY_DAYS, KEY_ENTRIES, KEY_NONE_LEFT, KEY_STALE, KEY_VALID_UNTIL,
        )
        const val FIELD_SEPARATOR = "\u001f"
        const val ENTRY_SEPARATOR = "\n"
        const val REDRAW_REQUEST_CODE = 4417

        // DoseTiming.missedGrace: a dose stops being "next" 30 minutes after its time.
        const val MISSED_GRACE_MILLIS = 30L * 60L * 1000L
    }
}
