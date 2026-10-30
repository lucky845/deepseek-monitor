package com.deepseekmonitor.deepseek_monitor

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * What both widget sizes need: the snapshot the app wrote, and one way to write
 * a number down.
 *
 * Kept here so the 2x2 and the 4x2 can never drift into rendering the same
 * figure two different ways -- a balance that reads "¥6.57" in one place and
 * "6.6" in the other is two widgets disagreeing about one account.
 */
internal object WidgetFormat {

    // shared_preferences writes its keys with this prefix, so the Dart side
    // stores `widget_snapshot` and the launcher side reads the prefixed name.
    // One palette for every size, so the three widgets cannot drift apart.
    const val CALM = "#8A93A8"
    const val VALUE = "#E6EAF2"
    const val WARN = "#F59E0B"
    const val LIVE = "#10B981"

    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY = "flutter.widget_snapshot"

    /** The last snapshot, or null when the app has never managed to write one. */
    fun snapshot(context: Context): JSONObject? {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return null
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            null
        }
    }

    /** A JSON null (the API-key path leaves fields it cannot know) reads as absent. */
    fun optDouble(json: JSONObject, key: String): Double? {
        if (!json.has(key) || json.isNull(key)) return null
        return json.optDouble(key, Double.NaN).takeIf { !it.isNaN() }
    }

    fun money(value: Double): String = String.format(Locale.CHINA, "%.2f", value)

    fun grouped(value: Long): String = String.format(Locale.CHINA, "%,d", value)

    /** Past ten days the decimal is noise; below it, "0.6" is the point. */
    fun trimDays(value: Double): String = when {
        value >= 99.5 -> "99+"
        value >= 10 -> value.toInt().toString()
        else -> String.format(Locale.CHINA, "%.1f", value)
    }

    /** Quiet, normal, or amber — the one judgement both small sizes make, so
     *  the two of them can never disagree about whether today is running hot. */
    fun todayColor(today: Double?, daily: Double?, hot: Double = 1.5): String = when {
        today == null || today <= 0.0 -> CALM
        daily != null && daily > 0 && today >= daily * hot -> WARN
        else -> VALUE
    }

    /**
     * Zero spend is a state, not a number: "还没花钱" says more than "¥0.00".
     *
     * The 2x1 has a "今日" label sitting in front of this string, so it asks for
     * the brief form: "今日 今天还没花钱" reads as a stutter.
     */
    fun todayValue(today: Double?, brief: Boolean = false): String = when {
        today == null -> if (brief) "—" else "打开应用看看"
        today <= 0.0 -> if (brief) "还没花钱" else "今天还没花钱"
        else -> "¥" + money(today)
    }

    /**
     * The status word every size shows in its top-right corner. Written once,
     * here, because three widgets that say this three different ways are three
     * widgets rather than one product.
     */
    fun statusBadge(connected: Boolean): String =
        if (connected) "● 已连接" else "● 示例"

    /** The one way a refresh time is written; empty when the snapshot carries none. */
    fun updatedLabel(json: JSONObject?): String {
        val at = json?.optLong("updatedAt", 0L) ?: 0L
        if (at <= 0L) return ""
        return "更新于 " + SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(at))
    }

    fun attachOpenIntent(context: Context, views: RemoteViews, rootId: Int) {
        val intent = Intent(context, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val pending = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(rootId, pending)
    }
}
