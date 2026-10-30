package com.deepseekmonitor.deepseek_monitor

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.widget.RemoteViews
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Shows what the app last knew, and says when it knew it.
 *
 * The widget never fetches on its own: it has no token of its own, and a
 * launcher redraw is not a reason to hit DeepSeek. The app writes one snapshot
 * after each successful fetch (see `lib/services/widget_bridge.dart`) and this
 * provider renders exactly that, timestamp included — so a number here is
 * always a number the app actually saw.
 */
class DeepSeekWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, buildViews(context)) }
    }

    /** First placement on the launcher: go get a number instead of showing a
     *  dash until the next scheduled run. */
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        WidgetRefreshWorker.refreshNow(context)
    }

    /** Last placement removed: stop spending calls on a widget nobody has.
     *  Both sizes share one background schedule, so the real question is not
     *  "did I just go away" but "is anything still on a launcher". */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        if (!WidgetRegistry.anyPlaced(context)) WidgetRefreshWorker.stop(context)
    }

    companion object {
        /** Redraw every placed widget, in either size, from the snapshot on disk. */
        fun refresh(context: Context) = WidgetRegistry.refreshAll(context)

        internal fun buildViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_dashboard)
            val json = WidgetFormat.snapshot(context)

            if (json == null) {
                // Nothing to show yet. Say what to do instead of printing a
                // zero, which would read as "your balance is empty".
                fill(views, "—", "还没连接", emptyColumns())
                views.setTextViewText(R.id.widget_footer_left, "打开应用连接后显示你的账单")
                views.setTextViewText(R.id.widget_footer_right, "")
                views.setImageViewBitmap(R.id.widget_chart, emptyChart(context))
                WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
                return views
            }

            try {
                val balance = WidgetFormat.optDouble(json, "balance")
                val month = WidgetFormat.optDouble(json, "monthCost")
                val daily = WidgetFormat.optDouble(json, "dailyAvg")
                val left = WidgetFormat.optDouble(json, "daysLeft")
                val hit = WidgetFormat.optDouble(json, "cacheHitRate")
                val requests = if (json.has("requests") && !json.isNull("requests"))
                    json.getLong("requests") else null
                val connected = json.optBoolean("connected", false)

                val today = WidgetFormat.optDouble(json, "todayCost")
                fill(
                    views,
                    if (balance == null) "—" else "¥" + WidgetFormat.money(balance),
                    if (connected) "● 已连接" else "● 示例",
                    listOf(
                        "今日消费" to (if (today == null) "—" else "¥" + WidgetFormat.money(today)),
                        "本月消费" to (if (month == null) "—" else "¥" + WidgetFormat.money(month)),
                        "本月请求" to (if (requests == null) "—" else WidgetFormat.grouped(requests)),
                        "本月命中" to (if (hit == null) "—"
                            else String.format(Locale.CHINA, "%.1f%%", hit)),
                    ),
                )

                // Same judgement the two small sizes make, so a day running hot
                // is amber in all three widgets rather than only two of them.
                views.setTextColor(
                    R.id.widget_col1_value,
                    Color.parseColor(WidgetFormat.todayColor(today, daily)),
                )

                val at = json.optLong("updatedAt", 0L)
                if (at > 0L) {
                    views.setTextViewText(
                        R.id.widget_footer_right,
                        WidgetFormat.updatedLabel(json)
                    )
                } else {
                    views.setTextViewText(R.id.widget_footer_right, "")
                }

                // The left footer is the one line a user can act on, so it
                // carries the arithmetic rather than a restatement of the top.
                val footerLeft = when {
                    daily != null && daily > 0 && left != null ->
                        "日均 ¥" + WidgetFormat.money(daily) + " · 可用约 " + WidgetFormat.trimDays(left) + " 天"
                    else -> ""
                }
                views.setTextViewText(R.id.widget_footer_left, footerLeft)

                views.setImageViewBitmap(
                    R.id.widget_chart,
                    chart(context, json.optJSONArray("trend"))
                )
            } catch (e: Exception) {
                // A malformed snapshot is stale, not fatal: fall back to the
                // disconnected face rather than crashing the launcher.
                fill(views, "—", "读不出来", emptyColumns())
                views.setTextViewText(R.id.widget_footer_left, "打开应用刷新一下")
                views.setTextViewText(R.id.widget_footer_right, "")
                views.setImageViewBitmap(R.id.widget_chart, emptyChart(context))
            }
            WidgetFormat.attachOpenIntent(context, views, R.id.widget_root)
            return views
        }

        /**
         * Four columns, in the order a person actually asks the questions:
         * what have I spent today, this month, how many calls, how much of it
         * was cache. Labels and values are paired so a missing one can never
         * shift the rest out of alignment.
         */
        private fun fill(
            views: RemoteViews,
            balance: String,
            badge: String,
            columns: List<Pair<String, String>>,
        ) {
            views.setTextViewText(R.id.widget_balance, balance)
            views.setTextViewText(R.id.widget_badge, badge)
            val labelIds = intArrayOf(
                R.id.widget_col1_label, R.id.widget_col2_label,
                R.id.widget_col3_label, R.id.widget_col4_label,
            )
            val valueIds = intArrayOf(
                R.id.widget_col1_value, R.id.widget_col2_value,
                R.id.widget_col3_value, R.id.widget_col4_value,
            )
            for (i in labelIds.indices) {
                val (label, value) = columns.getOrElse(i) { "" to "—" }
                views.setTextViewText(labelIds[i], label)
                views.setTextViewText(valueIds[i], value)
            }
        }

        /** Seven bars, one per day of spend. Drawn here because RemoteViews has
         *  no chart view, and a static picture would describe an older week. */
        private fun chart(context: Context, trend: JSONArray?): Bitmap {
            val dm = context.resources.displayMetrics
            val w = (250 * dm.density).toInt().coerceAtLeast(240)
            val h = (40 * dm.density).toInt().coerceAtLeast(80)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val radius = 1.5f * dm.density

            val costs = ArrayList<Float>()
            if (trend != null) {
                for (i in 0 until trend.length()) {
                    val row = trend.optJSONObject(i) ?: continue
                    costs.add(row.optDouble("c", 0.0).toFloat())
                }
            }
            if (costs.isEmpty()) return emptyChart(context)

            // A baseline first: it is what makes seven bars read as one chart
            // instead of seven detached blocks.
            val baselineY = h - 1f * dm.density
            paint.color = Color.parseColor("#26324E")
            canvas.drawRect(0f, baselineY, w.toFloat(), h.toFloat(), paint)

            val gap = 7f * dm.density
            val barW = (w - gap * (costs.size - 1)) / costs.size
            val max = costs.maxOrNull() ?: 0f
            val plot = baselineY - 2f * dm.density

            for ((i, cost) in costs.withIndex()) {
                val left = i * (barW + gap)
                if (max <= 0f || cost <= 0f) continue
                val ratio = (cost / max).coerceIn(0f, 1f)
                val barH = (ratio * plot).coerceAtLeast(2.5f * dm.density)
                // The latest day is the one being asked about: only it gets the
                // bright bar, so the eye lands there without a legend.
                paint.color = Color.parseColor(
                    if (i == costs.size - 1) "#5B7CFF" else "#36538F"
                )
                canvas.drawRoundRect(
                    RectF(left, baselineY - barH, left + barW, baselineY),
                    radius, radius, paint
                )
            }
            return bmp
        }

        private fun emptyChart(context: Context): Bitmap {
            val dm = context.resources.displayMetrics
            val w = (250 * dm.density).toInt().coerceAtLeast(240)
            val h = (40 * dm.density).toInt().coerceAtLeast(80)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color = Color.parseColor("#22304F")
            canvas.drawRoundRect(
                RectF(0f, h - 3f * dm.density, w.toFloat(), h.toFloat()),
                2f * dm.density, 2f * dm.density, paint
            )
            return bmp
        }

        private fun emptyColumns(): List<Pair<String, String>> = listOf(
            "今日消费" to "—",
            "本月消费" to "—",
            "本月请求" to "—",
            "本月命中" to "—",
        )

    }
}
