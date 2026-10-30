package com.deepseekmonitor.deepseek_monitor

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Color
import android.util.TypedValue
import android.widget.RemoteViews

/**
 * The 2x1. Two numbers stacked, and nothing else: what is left, and what today
 * has cost. It exists because the everyday glance is not "how is the month
 * going" but "am I still fine" -- and that question fits in one cell.
 */
class DeepSeekWidgetMiniProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, build(context)) }
    }

    /** Placed: go get a number instead of showing a dash until the next run. */
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        WidgetRefreshWorker.refreshNow(context)
    }

    /** Removed: another size may still be on the launcher, so ask before stopping. */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        if (!WidgetRegistry.anyPlaced(context)) WidgetRefreshWorker.stop(context)
    }

    companion object {

        fun build(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_mini)
            val json = WidgetFormat.snapshot(context)

            if (json == null) {
                fill(
                    views, "示例", "—", "—", "● 示例",
                    WidgetFormat.CALM, "", WidgetFormat.CALM,
                )
                WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
                return views
            }

            val connected = json.optBoolean("connected", false)
            val balance = WidgetFormat.optDouble(json, "balance")
            val today = WidgetFormat.optDouble(json, "todayCost")
            val daily = WidgetFormat.optDouble(json, "dailyAvg")

            fill(
                views,
                if (connected) "余额" else "示例",
                if (balance == null) "—" else "¥" + WidgetFormat.money(balance),
                WidgetFormat.todayValue(today, brief = true),
                WidgetFormat.statusBadge(connected),
                if (connected) WidgetFormat.LIVE else WidgetFormat.CALM,
                WidgetFormat.todayColor(today, daily),
                WidgetFormat.updatedLabel(json),
            )
            WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
            return views
        }

        private fun fill(
            views: RemoteViews,
            label: String,
            balance: String,
            today: String,
            badge: String,
            badgeColor: String,
            todayColor: String,
            updated: String,
        ) {
            views.setTextViewText(R.id.mini_label, label)
            views.setTextViewText(R.id.mini_balance, balance)
            views.setTextViewTextSize(
                R.id.mini_balance, TypedValue.COMPLEX_UNIT_SP, sizeFor(balance)
            )
            views.setTextViewText(R.id.mini_today, today)
            views.setTextColor(R.id.mini_today, Color.parseColor(todayColor))
            views.setTextViewText(R.id.mini_badge, badge)
            views.setTextColor(R.id.mini_badge, Color.parseColor(badgeColor))
            views.setTextViewText(R.id.mini_updated, updated)
        }

        /** Two cells are about 150dp; past "¥9999.99" the digits step down. */
        private fun sizeFor(text: String): Float = when {
            text.length <= 8 -> 17f
            text.length <= 10 -> 16f
            else -> 14f
        }
    }
}
