package com.deepseekmonitor.deepseek_monitor

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * Keeps the widget's numbers current while the app is closed.
 *
 * Everything the widget shows used to arrive only when someone opened the app,
 * which made a launcher glance a look at history. This worker fetches the same
 * four windows the dashboard uses — balance, this month, today — writes the
 * same snapshot shape the Dart side writes, and asks for a repaint.
 *
 * It deliberately does **not** invent a number when a call fails: a failure
 * leaves the previous snapshot untouched, timestamp and all, so the widget goes
 * on saying what it last actually knew.
 */
class WidgetRefreshWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val prefs = applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        val token = prefs.getString(KEY_TOKEN, null)?.takeIf { it.isNotBlank() }
        val apiKey = prefs.getString(KEY_API_KEY, null)?.takeIf { it.isNotBlank() }
        if (token == null && apiKey == null) {
            // Nobody is connected: nothing to fetch, and no reason to be woken
            // again. The scheduler is cancelled at the same moment.
            return Result.success()
        }

        val base = prefs.getString(KEY_PLATFORM_BASE, null)
            ?.takeIf { it.isNotBlank() } ?: DEFAULT_PLATFORM_BASE
        // Lengths only: the log is readable without leaking a credential.
        Log.i(TAG, "start token=${token?.length ?: 0} apiKey=${apiKey?.length ?: 0} base=$base")

        return try {
            val snapshot = if (token != null) {
                snapshotFromPlatform(token, base)
            } else {
                snapshotFromApiKey(apiKey!!, prefs.getString(KEY_API_BASE, null)
                    ?.takeIf { it.isNotBlank() } ?: DEFAULT_API_BASE)
            }
            prefs.edit()
                .putString(KEY_SNAPSHOT, snapshot.toString())
                .apply()
            DeepSeekWidgetProvider.refresh(applicationContext)
            Log.i(TAG, "ok snapshot=${snapshot.toString().take(120)}")
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "widget refresh failed: ${e.message}")
            // Keep the old snapshot. Retrying twice more covers a flaky network
            // without turning into a loop that burns the API all night.
            if (runAttemptCount < 2) Result.retry() else Result.success()
        }
    }

    /** Platform token: the full picture, using the same windows as the app. */
    private fun snapshotFromPlatform(token: String, base: String): JSONObject {
        val tz = tzOffsetSeconds()
        val monthStart = startOfMonthSeconds()
        val monthEnd = startOfNextMonthSeconds()
        val dayStart = startOfTodaySeconds()
        val dayEnd = dayStart + 86_400L

        val summary = getJson("$base/api/v0/users/get_user_summary", token)
        val monthAmount = getJson(
            "$base/api/v0/usage/by_api_key/amount?start=$monthStart&end=$monthEnd&tz=$tz", token
        )
        val monthCost = getJson(
            "$base/api/v0/usage/by_api_key/cost?start=$monthStart&end=$monthEnd&tz=$tz", token
        )
        val todayCost = getJson(
            "$base/api/v0/usage/by_api_key/cost?start=$dayStart&end=$dayEnd&tz=$tz", token
        )

        val biz = summary.optJSONObject("data")?.optJSONObject("biz_data")
        val paid = walletBalance(biz?.optJSONArray("normal_wallets"))
        val gift = walletBalance(biz?.optJSONArray("bonus_wallets"))
        val balance = paid + gift

        val month = sumCost(monthCost)
        val today = sumCost(todayCost)
        val usage = sumUsage(monthAmount)

        val now = System.currentTimeMillis()
        val monthDays = Calendar.getInstance().get(Calendar.DAY_OF_MONTH).toDouble()
        val daily = if (monthDays > 0) month / monthDays else 0.0
        val daysLeft = if (daily > 0) balance / daily else 0.0

        return JSONObject().apply {
            put("connected", true)
            put("balance", balance)
            put("granted", gift)
            put("todayCost", today)
            put("monthCost", month)
            put("requests", usage.requests)
            put("cacheHitRate", usage.hitRate())
            put("dailyAvg", round2(daily))
            put("daysLeft", round1(daysLeft))
            put("trend", buildTrend(monthCost, monthAmount))
            put("updatedAt", now)
        }
    }

    /**
     * API key only: the official endpoint exposes the balance and nothing else.
     * The usage fields go out as null rather than 0, so the widget prints a dash
     * instead of claiming a month with no spend.
     */
    private fun snapshotFromApiKey(apiKey: String, apiBase: String): JSONObject {
        val json = getJsonRaw("$apiBase/user/balance", apiKey)
        val infos = json.optJSONArray("balance_infos")
        var balance = 0.0
        var gift = 0.0
        if (infos != null && infos.length() > 0) {
            val first = infos.optJSONObject(0)
            balance = first?.optString("total_balance")?.toDoubleOrNull() ?: 0.0
            gift = first?.optString("granted_balance")?.toDoubleOrNull() ?: 0.0
        }
        return JSONObject().apply {
            put("connected", true)
            put("balance", balance)
            put("granted", gift)
            put("todayCost", JSONObject.NULL)
            put("monthCost", JSONObject.NULL)
            put("requests", JSONObject.NULL)
            put("cacheHitRate", JSONObject.NULL)
            put("dailyAvg", JSONObject.NULL)
            put("daysLeft", JSONObject.NULL)
            put("trend", JSONArray())
            put("updatedAt", System.currentTimeMillis())
        }
    }

    // ---- reading the platform's shapes -------------------------------------

    private class UsageTotals {
        var requests: Long = 0
        var hitTokens: Long = 0
        var missTokens: Long = 0
        fun hitRate(): Double {
            val total = hitTokens + missTokens
            return if (total <= 0) 0.0 else hitTokens * 100.0 / total
        }
    }

    private fun walletBalance(wallets: JSONArray?): Double {
        if (wallets == null || wallets.length() == 0) return 0.0
        return wallets.optJSONObject(0)?.optString("balance")?.toDoubleOrNull() ?: 0.0
    }

    /** Cost is per bucket as a decimal string; the widget wants the window sum. */
    private fun sumCost(json: JSONObject): Double {
        var total = 0.0
        val data = json.optJSONObject("data")?.optJSONObject("biz_data")
            ?.optJSONArray("data") ?: return 0.0
        for (i in 0 until data.length()) {
            val series = data.optJSONObject(i)?.optJSONArray("series") ?: continue
            for (j in 0 until series.length()) {
                val buckets = series.optJSONObject(j)?.optJSONArray("buckets") ?: continue
                for (k in 0 until buckets.length()) {
                    val cost = buckets.optJSONObject(k)?.optString("cost")?.toDoubleOrNull()
                    if (cost != null) total += cost
                }
            }
        }
        return total
    }

    private fun sumUsage(json: JSONObject): UsageTotals {
        val totals = UsageTotals()
        val series = json.optJSONObject("data")?.optJSONObject("biz_data")
            ?.optJSONArray("series") ?: return totals
        for (i in 0 until series.length()) {
            val buckets = series.optJSONObject(i)?.optJSONArray("buckets") ?: continue
            for (j in 0 until buckets.length()) {
                val usage = buckets.optJSONObject(j)?.optJSONObject("usage") ?: continue
                totals.requests += usage.optLong("REQUEST", 0)
                totals.hitTokens += usage.optLong("PROMPT_CACHE_HIT_TOKEN", 0)
                totals.missTokens += usage.optLong("PROMPT_CACHE_MISS_TOKEN", 0)
            }
        }
        return totals
    }

    /**
     * The last seven days that have actually happened.
     *
     * The month window ends on the 1st, so the reply carries a bucket for every
     * remaining day of the month — all zero. Keeping them would draw a cliff and
     * put the "latest day" marker on a date in the future, so anything after
     * today is dropped before the trend is built.
     */
    private fun buildTrend(costJson: JSONObject, amountJson: JSONObject): JSONArray {
        val costs = bucketTotals(costJson) { it.optString("cost")?.toDoubleOrNull() }
        val counts = bucketTotals(amountJson) {
            it.optJSONObject("usage")?.optLong("REQUEST", 0)?.toDouble()
        }
        val today = startOfTodaySeconds()
        val recent = costs.keys
            .filter { it <= today }
            .sorted()
            .takeLast(7)

        val out = JSONArray()
        for (day in recent) {
            out.put(JSONObject().apply {
                put("c", round4(costs[day] ?: 0.0))
                put("r", (counts[day] ?: 0.0).toLong())
                put("t", day * 1000L)
            })
        }
        return out
    }

    /**
     * Buckets keyed by their own start time, in seconds, summed across keys and
     * models. Zero-cost buckets keep their slot: the chart needs a bar for every
     * day, and the Dart side sends the same shape.
     */
    private fun bucketTotals(json: JSONObject, value: (JSONObject) -> Double?): Map<Long, Double> {
        val out = HashMap<Long, Double>()
        val biz = json.optJSONObject("data")?.optJSONObject("biz_data") ?: return out
        val lists = ArrayList<JSONArray>()
        biz.optJSONArray("data")?.let { lists.add(it) }
        biz.optJSONArray("series")?.let { lists.add(it) }
        for (list in lists) {
            for (i in 0 until list.length()) {
                val series = list.optJSONObject(i)?.optJSONArray("series")
                val holder = if (series != null) series else list
                for (j in 0 until holder.length()) {
                    val buckets = holder.optJSONObject(j)?.optJSONArray("buckets") ?: continue
                    for (k in 0 until buckets.length()) {
                        val bucket = buckets.optJSONObject(k) ?: continue
                        val v = value(bucket) ?: 0.0
                        val day = dayStartSeconds(bucket.optLong("time", 0L))
                        out[day] = (out[day] ?: 0.0) + v
                    }
                }
            }
        }
        return out
    }

    // ---- HTTP --------------------------------------------------------------

    private fun getJson(url: String, token: String): JSONObject {
        val json = getJsonRaw(url, token)
        // The platform answers 200 even when it rejected the call, so the only
        // trustworthy signal is the envelope's own code.
        val code = json.optInt("code", -1)
        if (code != 0) throw IOException("platform refused the call (code $code)")
        return json
    }

    private fun getJsonRaw(url: String, credential: String): JSONObject {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 20_000
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", USER_AGENT)
            setRequestProperty("x-client-platform", "web")
            setRequestProperty("x-client-version", "1.0.0")
            setRequestProperty("x-app-version", "1.0.0")
            // Both credential kinds travel as a bearer token: the platform
            // token and the API key differ in what they authorize, not in how
            // they are presented.
            setRequestProperty("Authorization", "Bearer $credential")
        }
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) throw IOException("HTTP $code")
            return JSONObject(body)
        } finally {
            conn.disconnect()
        }
    }

    // ---- calendar helpers (all local time, matching the app's windows) ------

    private fun tzOffsetSeconds(): Long {
        val offset = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L
        // The platform only accepts multiples of 900.
        return (offset / 900L) * 900L
    }

    private fun startOfTodaySeconds(): Long = dayStartSeconds(System.currentTimeMillis() / 1000L)

    private fun dayStartSeconds(epochSeconds: Long): Long {
        val cal = Calendar.getInstance().apply { timeInMillis = epochSeconds * 1000L }
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis / 1000L
    }

    private fun startOfMonthSeconds(): Long {
        val cal = Calendar.getInstance()
        cal.set(Calendar.DAY_OF_MONTH, 1)
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis / 1000L
    }

    private fun startOfNextMonthSeconds(): Long {
        val cal = Calendar.getInstance()
        cal.add(Calendar.MONTH, 1)
        cal.set(Calendar.DAY_OF_MONTH, 1)
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis / 1000L
    }

    private fun round2(v: Double) = Math.round(v * 100.0) / 100.0
    private fun round1(v: Double) = Math.round(v * 10.0) / 10.0
    private fun round4(v: Double) = Math.round(v * 10000.0) / 10000.0

    companion object {
        private const val TAG = "WidgetRefresh"
        private const val PREFS = "FlutterSharedPreferences"
        private const val KEY_TOKEN = "flutter.token"
        private const val KEY_API_KEY = "flutter.api_key"
        private const val KEY_SNAPSHOT = "flutter.widget_snapshot"
        private const val KEY_PLATFORM_BASE = "flutter.widget_platform_base"
        private const val KEY_API_BASE = "flutter.widget_api_base"
        private const val DEFAULT_PLATFORM_BASE = "https://platform.deepseek.com"
        private const val DEFAULT_API_BASE = "https://api.deepseek.com"
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

        /** How often the widget may spend API calls on its own. */
        private const val INTERVAL_MINUTES = 30L

        private const val UNIQUE_NAME = "deepseek-widget-refresh"

        /**
         * Arm or disarm the background refresher to match what the app holds.
         * Called whenever the app publishes a snapshot, so the schedule can
         * never outlive the credentials it runs on.
         */
        /**
         * Fetch once, right now.
         *
         * Used the moment the widget is first placed: waiting the full interval
         * for the first number would make a fresh widget look broken. Nothing
         * is fetched if no credential is stored — the worker checks that itself.
         */
        fun refreshNow(context: Context) {
            // No network constraint on purpose -- see the class comment.
            val request = OneTimeWorkRequestBuilder<WidgetRefreshWorker>().build()
            WorkManager.getInstance(context).enqueue(request)
        }

        /**
         * The last widget was removed, so nothing is on screen to keep current.
         * Leaving the schedule armed would spend API calls for an audience of
         * nobody.
         */
        fun stop(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_NAME)
        }

        fun sync(context: Context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val connected = !prefs.getString(KEY_TOKEN, null).isNullOrBlank() ||
                !prefs.getString(KEY_API_KEY, null).isNullOrBlank()
            val manager = WorkManager.getInstance(context)
            if (!connected) {
                manager.cancelUniqueWork(UNIQUE_NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<WidgetRefreshWorker>(
                INTERVAL_MINUTES, TimeUnit.MINUTES
            )
                .build()
            manager.enqueueUniquePeriodicWork(
                UNIQUE_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }
    }
}
