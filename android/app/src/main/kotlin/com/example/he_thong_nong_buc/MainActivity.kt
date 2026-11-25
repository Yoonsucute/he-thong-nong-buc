package com.example.he_thong_nong_buc

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val permissionCode = 4201
    private val settingsCode = 4202
    private val handler = Handler(Looper.getMainLooper())
    private val preferences by lazy { getSharedPreferences("location_flow", MODE_PRIVATE) }
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationTokenSource? = null
    private var deadline: Runnable? = null
    private var platformListener: LocationListener? = null
    private val locationManager by lazy { getSystemService(LOCATION_SERVICE) as LocationManager }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heatwatch/location")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "locate" -> {
                        if (pending != null) {
                            result.success(mapOf("status" to "busy"))
                        } else {
                            val automatic = call.argument<Boolean>("automatic") == true
                            // Remember only dismissal, never coordinates. A deferred
                            // launch may silently locate if permission/settings were
                            // subsequently enabled, but it never reopens a dialog.
                            if (automatic && preferences.getBoolean("dismissed", false)) {
                                if (hasPermission() && deviceLocationEnabled()) {
                                    pending = result
                                    getFix()
                                } else result.success(mapOf("status" to "deferred"))
                            } else {
                                pending = result
                                ensurePermission()
                            }
                        }
                    }
                    "openAppSettings" -> {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPermission() = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun deviceLocationEnabled(): Boolean {
        val manager = getSystemService(LOCATION_SERVICE) as android.location.LocationManager
        return if (android.os.Build.VERSION.SDK_INT >= 28) manager.isLocationEnabled else
            manager.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) || manager.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER)
    }

    private fun finish(status: String, values: Map<String, Any> = emptyMap()) {
        val response = pending ?: return
        pending = null
        deadline?.let { handler.removeCallbacks(it) }
        deadline = null
        cancellation?.cancel()
        cancellation = null
        platformListener?.let {
            try { locationManager.removeUpdates(it) } catch (_: SecurityException) { }
        }
        platformListener = null
        response.success(mapOf("status" to status) + values)
    }

    private fun dismissed(status: String) {
        preferences.edit().putBoolean("dismissed", true).apply()
        finish(status)
    }

    private fun ensurePermission() {
        if (hasPermission()) {
            preferences.edit().putBoolean("permanent_denial", false).apply()
            ensureSettings(); return
        }
        // Persist only an observed permanent denial. A one-time permission can
        // expire without a user denial and must remain requestable on retry.
        if (preferences.getBoolean("permanent_denial", false)) {
            dismissed("permission_denied_forever")
            return
        }
        preferences.edit().putBoolean("permission_requested", true).apply()
        requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), permissionCode)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionCode || pending == null) return
        if (hasPermission()) ensureSettings() else {
            val permanent = grantResults.isNotEmpty() && !shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION) &&
                !shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)
            preferences.edit().putBoolean("permanent_denial", permanent).apply()
            dismissed(if (permanent) "permission_denied_forever" else "permission_denied")
        }
    }

    private fun ensureSettings() {
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L).build()
        val settings = LocationSettingsRequest.Builder().addLocationRequest(request).setAlwaysShow(true).build()
        LocationServices.getSettingsClient(this).checkLocationSettings(settings)
            .addOnSuccessListener { if (pending != null) getFix() }
            .addOnFailureListener { error ->
                if (pending == null) return@addOnFailureListener
                if (error is ResolvableApiException) {
                    try { error.startResolutionForResult(this, settingsCode) }
                    catch (_: Exception) { dismissed("services_unavailable") }
                } else dismissed("services_unavailable")
            }
    }

    @Deprecated("Android callback required by Google Play services settings resolution")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != settingsCode || pending == null) return
        if (resultCode == Activity.RESULT_OK && deviceLocationEnabled()) getFix()
        else dismissed("services_declined")
    }

    @Suppress("MissingPermission")
    private fun getFix() {
        if (pending == null) return
        if (!hasPermission()) { dismissed("permission_denied"); return }
        if (!deviceLocationEnabled()) { dismissed("services_declined"); return }
        preferences.edit().putBoolean("dismissed", false).putBoolean("permanent_denial", false).apply()
        val token = CancellationTokenSource()
        cancellation = token
        val timeout = Runnable { if (cancellation === token) finish("timeout") }
        deadline = timeout
        handler.postDelayed(timeout, 22000)
        // A single framework fix also works on emulators/devices where the
        // Play-services fused provider has no fresh fix. Both stop on first
        // result, timeout or onStop; neither is background tracking.
        platformFix(token)
        val request = CurrentLocationRequest.Builder().setPriority(Priority.PRIORITY_HIGH_ACCURACY)
            .setMaxUpdateAgeMillis(0).setDurationMillis(20000).build()
        try {
            LocationServices.getFusedLocationProviderClient(this).getCurrentLocation(request, token.token)
                .addOnSuccessListener { location ->
                    if (pending == null || cancellation !== token) return@addOnSuccessListener
                    if (location != null) deliverFix(location)
                }.addOnFailureListener { error ->
                    android.util.Log.w("HeatWatchLocation", "Fused current fix unavailable; waiting for one framework fix", error)
                    // The framework one-shot request remains bounded by deadline.
                }
        } catch (_: SecurityException) { dismissed("permission_denied") }
    }

    private fun deliverFix(location: Location) {
        finish("success", mapOf("latitude" to location.latitude, "longitude" to location.longitude,
            "accuracy" to location.accuracy.toDouble(), "timestamp" to location.time))
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun platformFix(token: CancellationTokenSource) {
        val provider = if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        if (!locationManager.isProviderEnabled(provider)) return
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (pending != null && cancellation === token) deliverFix(location)
            }
            override fun onProviderDisabled(provider: String) { }
            override fun onProviderEnabled(provider: String) { }
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) { }
        }
        platformListener = listener
        try { locationManager.requestSingleUpdate(provider, listener, Looper.getMainLooper()) }
        catch (_: Exception) { platformListener = null }
    }

    override fun onStop() {
        // No location acquisition while the application is in the background.
        if (cancellation != null) finish("interrupted")
        super.onStop()
    }

    override fun onDestroy() {
        if (pending != null) finish("interrupted")
        super.onDestroy()
    }
}
