package com.deepseekmonitor.deepseek_monitor

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context

/**
 * Every app widget this package ships, in one place.
 *
 * Two sizes exist, and they read one snapshot and mean one account, so the only
 * things that must never disagree are which of them are on a launcher: a redraw
 * has to reach all of them, and the background schedule may only be cancelled
 * when the launcher holds none of them. Placing a 2x2 next to a 4x2 and then
 * removing one of them is a normal thing to do, and it must not silence the
 * refresh for the one that is still there.
 */
internal object WidgetRegistry {

    private fun types() = listOf(
        DeepSeekWidgetProvider::class.java,
        DeepSeekWidgetSmallProvider::class.java,
        DeepSeekWidgetMiniProvider::class.java,
    )

    /** True while at least one widget of any size sits on a launcher. */
    fun anyPlaced(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        return types().any {
            manager.getAppWidgetIds(ComponentName(context, it)).isNotEmpty()
        }
    }

    /** Redraw every placed widget from the snapshot already on disk. */
    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)

        val small = manager.getAppWidgetIds(
            ComponentName(context, DeepSeekWidgetSmallProvider::class.java)
        )
        if (small.isNotEmpty()) {
            val views = DeepSeekWidgetSmallProvider.build(context)
            small.forEach { manager.updateAppWidget(it, views) }
        }

        val mini = manager.getAppWidgetIds(
            ComponentName(context, DeepSeekWidgetMiniProvider::class.java)
        )
        if (mini.isNotEmpty()) {
            val views = DeepSeekWidgetMiniProvider.build(context)
            mini.forEach { manager.updateAppWidget(it, views) }
        }
        val large = manager.getAppWidgetIds(
            ComponentName(context, DeepSeekWidgetProvider::class.java)
        )
        if (large.isNotEmpty()) {
            val views = DeepSeekWidgetProvider.buildViews(context)
            large.forEach { manager.updateAppWidget(it, views) }
        }
    }
}
