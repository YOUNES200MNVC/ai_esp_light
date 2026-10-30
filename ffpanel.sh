#!/usr/bin/env bash
set -euo pipefail
ROOT="FFPanel"
rm -rf "$ROOT"
mkdir -p "$ROOT/app/src/main/java/com/vanta/light" \
         "$ROOT/app/src/main/res/xml" \
         "$ROOT/app/src/main/assets"

cat > "$ROOT/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application") version "8.2.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
}
EOF
cat > "$ROOT/settings.gradle.kts" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "LightPanel"
include(":app")
EOF
cat > "$ROOT/gradle.properties" <<'EOF'
android.useAndroidX=true
kotlin.code.style=official
android.nonTransitiveRClass=true
EOF

cat > "$ROOT/app/build.gradle.kts" <<'EOF'
plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.vanta.light"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.vanta.light"
        minSdk = 26; targetSdk = 34
        versionCode = 1; versionName = "1.0"
    }
    buildTypes { release { isMinifyEnabled = false } }
    androidResources { noCompress += "tflite" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("org.tensorflow:tensorflow-lite:2.16.1")
}
EOF

cat > "$ROOT/app/src/main/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <application android:allowBackup="false" android:label="Light AI" android:theme="@style/Theme.AppCompat.DayNight.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <service android:name=".ScreenCaptureService" android:exported="false" android:foregroundServiceType="mediaProjection"/>
        <service android:name=".OverlayService" android:exported="false" android:foregroundServiceType="specialUse">
            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="overlay"/>
        </service>
        <service android:name=".AimService" android:exported="true" android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService"/></intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/accessibility_config"/>
        </service>
    </application>
</manifest>
EOF

cat > "$ROOT/app/src/main/res/xml/accessibility_config.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:canRetrieveWindowContent="false"
    android:canPerformGestures="true"
    android:description="Aim Assist" />
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/Bridge.kt" <<'EOF'
package com.vanta.light
data class Box(val l: Float, val t: Float, val r: Float, val b: Float)
object Bridge {
    @Volatile var list: List<Box> = emptyList()
    @Volatile var w: Int = 0
    @Volatile var h: Int = 0
    @Volatile var aim: Boolean = false
    @Volatile var esp: Boolean = true
}
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/Detector.kt" <<'EOF'
package com.vanta.light
import android.content.Context
import android.graphics.Bitmap
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

class Detector(context: Context) : AutoCloseable {
    private val interpreter: Interpreter
    private val inputBuffer: ByteBuffer
    private val isQuantInput: Boolean
    private val locOut = Array(1) { Array(10) { FloatArray(4) } }
    private val catOut = Array(1) { FloatArray(10) }
    private val scoreOut = Array(1) { FloatArray(10) }
    private val numOut = FloatArray(1)
    private val outMap = HashMap<Int, Any>()
    private var lastTime = 0L

    init {
        // 1 Thread only to save RAM and CPU
        interpreter = Interpreter(loadModel(context), Interpreter.Options().apply { setNumThreads(1) })
        isQuantInput = interpreter.getInputTensor(0).dataType() == DataType.UINT8
        inputBuffer = ByteBuffer.allocateDirect(300 * 300 * 3 * 4).order(ByteOrder.nativeOrder())
        outMap[0] = locOut; outMap[1] = catOut; outMap[2] = scoreOut; outMap[3] = numOut
    }

    fun detect(frame: Bitmap): List<Box> {
        val now = System.currentTimeMillis()
        // 1 FPS throttle to prevent lag
        if (now - lastTime < 1000) return Bridge.list
        lastTime = now

        val scaled = Bitmap.createScaledBitmap(frame, 300, 300, true)
        inputBuffer.rewind()
        val pixels = IntArray(300 * 300)
        scaled.getPixels(pixels, 0, 300, 0, 0, 300, 300)
        if (isQuantInput) {
            for (p in pixels) { inputBuffer.put(((p shr 16) and 0xFF).toByte()); inputBuffer.put(((p shr 8) and 0xFF).toByte()); inputBuffer.put((p and 0xFF).toByte()) }
        } else {
            for (p in pixels) { inputBuffer.putFloat(((p shr 16) and 0xFF) / 255f); inputBuffer.putFloat(((p shr 8) and 0xFF) / 255f); inputBuffer.putFloat((p and 0xFF) / 255f) }
        }
        inputBuffer.rewind()
        interpreter.runForMultipleInputsOutputs(arrayOf(inputBuffer), outMap)
        if (scaled !== frame) scaled.recycle()

        val count = numOut[0].toInt().coerceIn(0, 10)
        val sw = Bridge.w; val sh = Bridge.h
        if (sw <= 0 || sh <= 0) return emptyList()
        val out = ArrayList<Box>(count)
        for (i in 0 until count) {
            if (scoreOut[0][i] < 0.55f || catOut[0][i].toInt() != 0) continue
            val b = locOut[0][i]
            out.add(Box(b[1] * sw, b[0] * sh, b[3] * sw, b[2] * sh))
        }
        return out
    }
    private fun loadModel(context: Context): MappedByteBuffer {
        context.assets.openFd("ssd.tflite").use { fd ->
            FileInputStream(fd.fileDescriptor).use { fis -> return fis.channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength) }
        }
    }
    override fun close() { try { interpreter.close() } catch (_: Throwable) {} }
}
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/ScreenCaptureService.kt" <<'EOF'
package com.vanta.light
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import androidx.core.app.NotificationCompat

class ScreenCaptureService : Service() {
    companion object {
        private const val ID = "ai_cap"
        const val CODE = "code"
        const val DATA = "data"
    }
    private var proj: MediaProjection? = null
    private var vd: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var detector: Detector? = null
    private var w = 0; private var h = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        val code = intent.getIntExtra(CODE, 0)
        val data = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(DATA, Intent::class.java) else @Suppress("DEPRECATION") intent.getParcelableExtra(DATA)
        if (data == null) { stopSelf(); return START_NOT_STICKY }

        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(ID, "AI", NotificationManager.IMPORTANCE_LOW)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
        val notif = NotificationCompat.Builder(this, ID).setContentTitle("AI Active").setSmallIcon(android.R.drawable.ic_menu_view).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(2, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) else startForeground(2, notif)

        val dm = resources.displayMetrics
        w = dm.widthPixels; h = dm.heightPixels
        Bridge.w = w; Bridge.h = h

        thread = HandlerThread("cap").also { it.start() }
        handler = Handler(thread!!.looper)
        detector = Detector(this)

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        proj = mpm.getMediaProjection(code, data)
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader!!.setOnImageAvailableListener({ r ->
            val img = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val p = img.planes[0]
                val pad = p.rowStride - p.pixelStride * w
                val pw = w + pad / p.pixelStride
                val bmp = Bitmap.createBitmap(pw, h, Bitmap.Config.ARGB_8888)
                bmp.copyPixelsFromBuffer(p.buffer)
                val crop = if (pw != w) Bitmap.createBitmap(bmp, 0, 0, w, h) else bmp
                Bridge.list = detector?.detect(crop) ?: emptyList()
                if (crop !== bmp) crop.recycle()
                bmp.recycle()
            } catch (_: Throwable) {} finally { img.close() }
        }, handler)
        vd = proj!!.createVirtualDisplay("vd", w, h, dm.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, handler)
        return START_STICKY
    }

    override fun onDestroy() {
        try { vd?.release(); reader?.close(); proj?.stop(); detector?.close(); thread?.quitSafely() } catch (_: Throwable) {}
        super.onDestroy()
    }
}
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/AimService.kt" <<'EOF'
package com.vanta.light
import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import kotlin.math.hypot

class AimService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastMs = 0L

    private val tick = object : Runnable {
        override fun run() {
            if (Bridge.aim) tryAim()
            handler.postDelayed(this, 250) // Slow tick to prevent lag
        }
    }
    override fun onServiceConnected() { super.onServiceConnected(); handler.post(tick) }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    private fun tryAim() {
        val now = System.currentTimeMillis()
        if (now - lastMs < 250) return 
        val sw = Bridge.w; val sh = Bridge.h
        val cx = sw / 2f; val cy = sh / 2f
        var best: Box? = null; var bestD = 200f // Small FOV
        
        for (b in Bridge.list) {
            val dist = hypot((b.l + b.r) / 2f - cx, (b.t + (b.b - b.t) * 0.1f) - cy)
            if (dist < bestD) { bestD = dist; best = b }
        }
        
        val target = best ?: return
        val dx = ((target.l + target.r) / 2f - cx) * 0.3f
        val dy = ((target.t + (target.b - target.t) * 0.1f) - cy) * 0.3f
        if (hypot(dx, dy) < 5f) return
        
        val path = Path().apply { moveTo(cx, cy); lineTo(cx + dx, cy + dy) }
        dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 40)).build(), null, null)
        lastMs = now
    }
    override fun onDestroy() { handler.removeCallbacks(tick); super.onDestroy() }
}
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/OverlayService.kt" <<'EOF'
package com.vanta.light
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.*
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import androidx.core.app.NotificationCompat

class OverlayService : Service() {
    private lateinit var wm: WindowManager
    private lateinit var esp: ESPView
    private lateinit var panel: LinearLayout

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel("ov", "AI", NotificationManager.IMPORTANCE_LOW)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
        val notif = NotificationCompat.Builder(this, "ov").setContentTitle("AI").setSmallIcon(android.R.drawable.ic_menu_view).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, notif)

        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        esp = ESPView(this)
        wm.addView(esp, WindowManager.LayoutParams(-1, -1, if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT))

        panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.parseColor("#AA000000")); setPadding(20, 20, 20, 20) }
        panel.addView(TextView(this).apply { text = "LIGHT AI"; setTextColor(Color.GREEN); textSize = 12f })
        panel.addView(Switch(this).apply { text = "ESP"; setTextColor(Color.WHITE); textSize = 10f; isChecked = Bridge.esp; setOnCheckedChangeListener { _, b -> Bridge.esp = b } })
        panel.addView(Switch(this).apply { text = "AIM"; setTextColor(Color.WHITE); textSize = 10f; isChecked = Bridge.aim; setOnCheckedChangeListener { _, b -> Bridge.aim = b } })

        val p = WindowManager.LayoutParams(300, WindowManager.LayoutParams.WRAP_CONTENT, if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT)
        p.gravity = Gravity.TOP or Gravity.START; p.x = 20; p.y = 100
        panel.setOnTouchListener(object : View.OnTouchListener {
            var ix = 0; var iy = 0; var itx = 0f; var ity = 0f
            override fun onTouch(v: View, e: MotionEvent): Boolean {
                if (e.action == MotionEvent.ACTION_DOWN) { ix = p.x; iy = p.y; itx = e.rawX; ity = e.rawY; return true }
                if (e.action == MotionEvent.ACTION_MOVE) { p.x = ix + (e.rawX - itx).toInt(); p.y = iy + (e.rawY - ity).toInt(); wm.updateViewLayout(panel, p); return true }
                return false
            }
        })
        wm.addView(panel, p)
        return START_STICKY
    }
    override fun onDestroy() {
        if (::esp.isInitialized) wm.removeView(esp)
        if (::panel.isInitialized) wm.removeView(panel)
        super.onDestroy()
    }
}
class ESPView(c: Context) : View(c) {
    private val b = Paint().apply { color = Color.GREEN; style = Paint.Style.STROKE; strokeWidth = 2f }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!Bridge.esp) return
        for (box in Bridge.list) canvas.drawRect(box.l, box.t, box.r, box.b, b)
        invalidate()
    }
}
EOF

cat > "$ROOT/app/src/main/java/com/vanta/light/MainActivity.kt" <<'EOF'
package com.vanta.light
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.*
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        val l = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(50, 50, 50, 50) }
        l.addView(Button(this).apply { text = "START LIGHT AI"; setOnClickListener { 
            if (!Settings.canDrawOverlays(this@MainActivity)) startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))) 
            else { val i = (getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager).createScreenCaptureIntent(); startActivityForResult(i, 1) }
        } })
        l.addView(Button(this).apply { text = "Accessibility Settings"; setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) } })
        setContentView(l)
    }
    override fun onActivityResult(r: Int, c: Int, d: Intent?) {
        if (r == 1 && c == Activity.RESULT_OK && d != null) {
            startService(Intent(this, ScreenCaptureService::class.java).putExtra("code", c).putExtra("data", d))
            startService(Intent(this, OverlayService::class.java))
        }
    }
}
EOF

MODEL="$ROOT/app/src/main/assets/ssd.tflite"
URL="https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/object_detection/android/lite-model_ssd_mobilenet_v1_1_metadata_2.tflite"
if command -v curl >/dev/null 2>&1; then curl -L -o "$MODEL" "$URL"; fi

echo "[✓] Project ready: $ROOT/"
