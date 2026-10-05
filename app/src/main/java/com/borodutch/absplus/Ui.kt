package com.borodutch.absplus

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.text.TextUtils
import android.util.LruCache
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.imageview.ShapeableImageView
import com.google.android.material.shape.ShapeAppearanceModel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import com.google.android.material.R as M

/** Covers from the server (resized to 400px webp), cached in memory and on disk. */
object Covers {
    private val mem = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(k: String, b: Bitmap) = b.byteCount
    }
    private val pool = Executors.newFixedThreadPool(4)
    private val missing = java.util.Collections.synchronizedSet(HashSet<String>()) // no cover on the server (this run only)

    private val pending = HashMap<String, MutableList<Pair<java.lang.ref.WeakReference<ImageView>, Any>>>()

    private data class Binding(val epoch: Long, val id: String)
    fun isBound(iv: ImageView, id: String) = iv.tag == Binding(Abs.mediaEpoch, id)

    fun load(iv: ImageView, id: String) {
        val epoch = Abs.mediaEpoch
        val (server, owner) = Abs.inSession(epoch) { Abs.server to Abs.mediaDir.path }
        iv.tag = Binding(epoch, id)
        // A distinct bind token also protects against A → B → A reuse and server switches.
        val binding = Any()
        iv.setTag(R.id.cover_request, binding)
        if (server.isBlank() || id.isBlank()) { iv.setImageResource(R.drawable.i_auto_stories); iv.contentDescription = "No cover available"; return }
        val key = "$epoch|$owner|$id"
        mem.get(key)?.let { iv.setImageBitmap(it); iv.contentDescription = "Cover"; return }
        iv.setImageResource(R.drawable.i_auto_stories)
        iv.contentDescription = "Loading cover"
        if (key in missing) { iv.contentDescription = "No cover available"; return }
        synchronized(pending) {
            val waiting = pending[key]
            if (waiting != null) { waiting += java.lang.ref.WeakReference(iv) to binding; return }
            pending[key] = mutableListOf(java.lang.ref.WeakReference(iv) to binding)
        }
        val dir = File(iv.context.cacheDir, "account-covers/" + java.security.MessageDigest.getInstance("SHA-256")
            .digest(owner.toByteArray()).joinToString("") { "%02x".format(it) })
        pool.execute {
            val active = synchronized(pending) { pending[key]?.any { (ref, token) -> ref.get()?.let { it.getTag(R.id.cover_request) === token } == true } == true }
            if (!active || epoch != Abs.mediaEpoch) { synchronized(pending) { pending.remove(key) }; return@execute }
            val b = runCatching {
                val f = File(dir, id)
                var bitmap = if (f.length() > 0L) BitmapFactory.decodeFile(f.path) else null
                if (bitmap == null) {
                    dir.mkdirs()
                    val tmp = File.createTempFile("cover", ".tmp", dir)
                    val c = URL("$server/api/items/$id/cover?width=400&format=webp").openConnection() as HttpURLConnection
                    try {
                        Abs.checkSession(epoch)
                        c.instanceFollowRedirects = false
                        c.connectTimeout = 10_000; c.readTimeout = 15_000
                        if (c.responseCode == 200) {
                            c.inputStream.use { i -> tmp.outputStream().use { i.copyTo(it) } }
                            bitmap = BitmapFactory.decodeFile(tmp.path)
                            if (bitmap != null) Abs.inSession(epoch) { tmp.renameTo(f) }
                        } else if (c.responseCode == 404) Abs.inSession(epoch) { missing += key }
                    } finally { c.disconnect(); tmp.delete() }
                }
                bitmap
            }.getOrNull()
            if (b != null) runCatching { Abs.inSession(epoch) { mem.put(key, b) } }
            val targets = synchronized(pending) { pending.remove(key).orEmpty() }
            targets.forEach { (ref, token) -> ref.get()?.let { target ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    if (epoch == Abs.mediaEpoch && target.tag == Binding(epoch, id) && target.getTag(R.id.cover_request) === token) {
                        if (b != null) { target.setImageBitmap(b); target.contentDescription = "Cover" }
                        else target.contentDescription = if (key in missing) "No cover available" else "Cover unavailable"
                    }
                }
            } }
        }
    }

}

/** Rounded cover image; height = width * ratio (ratio 0 = natural size). */
class Cover(c: Context, private val ratio: Float = 1f) : ShapeableImageView(c) {
    init {
        scaleType = ScaleType.CENTER_CROP
        shapeAppearanceModel = ShapeAppearanceModel().withCornerSize(c.dp(8).toFloat())
        setBackgroundColor(c.color(M.attr.colorSurfaceContainerHighest))
    }

    override fun onMeasure(w: Int, h: Int) {
        if (ratio == 0f) return super.onMeasure(w, h)
        val width = MeasureSpec.getSize(w)
        setMeasuredDimension(width, (width * ratio).toInt())
    }
}

class Rv(private val n: () -> Int, private val make: (ViewGroup) -> View, private val bind: (View, Int) -> Unit) :
    RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    override fun getItemCount() = n()
    override fun onCreateViewHolder(p: ViewGroup, t: Int) = object : RecyclerView.ViewHolder(make(p)) {}
    override fun onBindViewHolder(h: RecyclerView.ViewHolder, i: Int) = bind(h.itemView, i)
}

fun Context.dp(x: Int) = (x * resources.displayMetrics.density).toInt()
fun Context.color(attr: Int) = TypedValue().also { theme.resolveAttribute(attr, it, true) }.data
fun Context.res(attr: Int) = TypedValue().also { theme.resolveAttribute(attr, it, true) }.resourceId

fun Context.text(s: CharSequence, appearance: Int = M.attr.textAppearanceBodyMedium, lines: Int = 0, muted: Boolean = false) =
    TextView(this).apply {
        setTextAppearance(res(appearance))
        text = s
        if (muted) setTextColor(color(M.attr.colorOnSurfaceVariant))
        if (lines > 0) { maxLines = lines; ellipsize = TextUtils.TruncateAt.END }
    }

fun Context.icon(id: Int, description: String, style: Int = M.attr.materialIconButtonStyle, f: () -> Unit) =
    MaterialButton(this, null, style).apply {
        icon = ContextCompat.getDrawable(context, id)
        contentDescription = description
        setOnClickListener { f() }
    }

fun Context.button(s: String, iconId: Int = 0, style: Int = M.attr.materialButtonStyle, f: () -> Unit) =
    MaterialButton(this, null, style).apply {
        text = s
        if (iconId != 0) icon = ContextCompat.getDrawable(context, iconId)
        setOnClickListener { f() }
    }

fun Context.col(vararg v: View, pad: Int = 0) = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(pad), dp(pad), dp(pad), dp(pad))
    v.forEach { addView(it) }
}

fun Context.row(vararg v: View) = LinearLayout(this).apply {
    gravity = android.view.Gravity.CENTER_VERTICAL
    v.forEach { addView(it) }
}

fun <T : View> T.lp(w: Int = -1, h: Int = -2, weight: Float = 0f, m: Int = 0): T = apply {
    layoutParams = LinearLayout.LayoutParams(w, h, weight).apply { val px = context.dp(m); setMargins(px, px, px, px) }
}

fun <T : View> T.pad(h: Int, v: Int = h): T = apply { setPadding(context.dp(h), context.dp(v), context.dp(h), context.dp(v)) }
