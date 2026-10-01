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

    fun load(iv: ImageView, id: String) {
        iv.tag = id
        mem.get(id)?.let { iv.setImageBitmap(it); return }
        iv.setImageDrawable(null)
        if (id in missing) return
        val dir = File(iv.context.cacheDir, "covers")
        pool.execute {
            val b = runCatching {
                val f = File(dir, id)
                if (f.length() == 0L) { // also drops empty "no cover" markers written by older versions
                    f.delete()
                    dir.mkdirs()
                    val tmp = File(dir, "$id.tmp")
                    val c = URL("${Abs.server}/api/items/$id/cover?width=400&format=webp").openConnection() as HttpURLConnection
                    if (c.responseCode == 200) {
                        c.inputStream.use { i -> tmp.outputStream().use { i.copyTo(it) } }
                        tmp.renameTo(f)
                    } else if (c.responseCode == 404) missing += id
                    c.disconnect()
                }
                BitmapFactory.decodeFile(f.path)
            }.getOrNull()
            if (b != null) mem.put(id, b)
            iv.post { if (iv.tag == id && b != null) iv.setImageBitmap(b) }
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

fun Context.icon(id: Int, style: Int = M.attr.materialIconButtonStyle, f: () -> Unit) =
    MaterialButton(this, null, style).apply {
        icon = ContextCompat.getDrawable(context, id)
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
