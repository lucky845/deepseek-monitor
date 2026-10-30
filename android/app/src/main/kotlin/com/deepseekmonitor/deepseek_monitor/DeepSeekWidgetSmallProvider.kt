package com.deepseekmonitor.deepseek_monitor

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Color
import android.util.TypedValue
import android.widget.RemoteViews
import java.util.Locale
import org.json.JSONObject

/**
 * The 2x2. Answers two questions -- how much is left, and how busy the account
 * has been -- and refuses to answer any others.
 *
 * Everything the 4x2 carries beyond those two is left out on purpose: at this
 * size a chart is noise, "本月消费" is a second thought, and the timestamp is
 * only legible when it has room to be. Shrinking the big widget would have
 * produced a smaller unreadable one; this is a different widget that happens to
 * read the same snapshot.
 */
class DeepSeekWidgetSmallProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, build(context)) }
    }

    /** Placed: go get a number instead of showing a dash until the next run. */
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        WidgetRefreshWorker.refreshNow(context)
    }

    /** Removed: the other size may still be on the launcher, so ask before stopping. */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        if (!WidgetRegistry.anyPlaced(context)) WidgetRefreshWorker.stop(context)
    }

    companion object {

        /** Today counts as hot at this multiple of the user's own daily average. */
        private const val HOT = 1.5

        private const val CALM = "#8A93A8"
        private const val VALUE = "#E6EAF2"
        private const val WARN = "#F59E0B"
        private const val LIVE = "#10B981"

        fun build(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_small)
            val json = WidgetFormat.snapshot(context)

            if (json == null) {
                face(
                    views, "", "—", "打开应用连接",
                    "本月请求 —  ·  命中 —", "● 示例", WidgetFormat.CALM, "",
                )
                WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
                return views
            }

            val connected = json.optBoolean("connected", false)
            val balance = WidgetFormat.optDouble(json, "balance")
            val today = WidgetFormat.optDouble(json, "todayCost")
            val daily = WidgetFormat.optDouble(json, "dailyAvg")
            val requests = WidgetFormat.optDouble(json, "requests")
            val hit = WidgetFormat.optDouble(json, "cacheHitRate")

            // "示例" is the honest label: whatever sits under it is not the
            // user's money, and at this size there is no room to explain.
            val label = if (connected) "余额" else "示例"

            val todayText = when {
                today == null -> "打开应用看看"
                today <= 0.0 -> "今天还没花钱"
                else -> "今日 ¥" + WidgetFormat.money(today)
            }

            // What the extra row buys over the 2x1: how busy the account is.
            // The month is named because these two numbers are a month of
            // traffic sitting under a balance: unlabelled they read as today's.
            val stats = "本月请求 " + (requests?.let { WidgetFormat.grouped(it.toLong()) } ?: "—") +
                "  ·  命中 " + (hit?.let { String.format(Locale.CHINA, "%.1f%%", it) } ?: "—")

            face(
                views,
                label,
                if (balance == null) "—" else "¥" + WidgetFormat.money(balance),
                todayText,
                stats,
                WidgetFormat.statusBadge(connected),
                WidgetFormat.todayColor(today, daily, HOT),
                WidgetFormat.updatedLabel(json),
            )
            WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
            return views
        }

        private fun face(
            views: RemoteViews,
            label: String,
            balance: String,
            todayText: String,
            stats: String,
            badge: String,
            valueColor: String,
            updated: String,
        ) {
            views.setTextViewText(R.id.small_label, label)
            views.setTextViewText(R.id.small_balance, balance)
            // A long balance should shrink, never lose its currency mark.
            views.setTextViewTextSize(
                R.id.small_balance, TypedValue.COMPLEX_UNIT_SP, sizeFor(balance)
            )
            views.setTextViewText(R.id.small_today, todayText)
            views.setTextColor(R.id.small_today, Color.parseColor(valueColor))
            views.setTextViewText(R.id.small_stats, stats)
            views.setTextViewText(R.id.small_badge, badge)
            views.setTextViewText(R.id.small_updated, updated)
        }

        /** 38sp holds "¥9999.99"; past that the number steps down instead of clipping. */
        private fun sizeFor(text: String): Float = when {
            text.length <= 8 -> 38f
            text.length <= 10 -> 31f
            else -> 25f
        }
    }
}
