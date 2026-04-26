package com.yettiqanot.driver

import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()

        // Prefer the device's highest refresh rate (90/120Hz) when supported.
        // Safe no-op on older Android versions / devices.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val d = display ?: return
                val modes: Array<Display.Mode> = d.supportedModes ?: return
                if (modes.isEmpty()) return
                val best = modes.maxByOrNull { it.refreshRate } ?: return
                val lp = window.attributes
                if (lp.preferredDisplayModeId != best.modeId) {
                    lp.preferredDisplayModeId = best.modeId
                    window.attributes = lp
                }
            } catch (_: Throwable) {
                // Ignore: refresh-rate hint is best-effort.
            }
        }
    }
}
