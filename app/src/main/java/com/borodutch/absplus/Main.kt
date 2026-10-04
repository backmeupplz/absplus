package com.borodutch.absplus

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.text.HtmlCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.NestedScrollView
import androidx.core.widget.doAfterTextChanged
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.Util
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.recyclerview.widget.ConcatAdapter
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDragHandleView
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.color.DynamicColors
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.imageview.ShapeableImageView
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.android.material.shape.ShapeAppearanceModel
import com.google.android.material.slider.Slider
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONObject
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min
import com.google.android.material.R as M

class Main : AppCompatActivity() {
    private lateinit var content: FrameLayout
    private lateinit var nav: BottomNavigationView
    private lateinit var banner: View
    private var wasOffline = false
    private var ticks = 0
    private lateinit var mini: MaterialCardView
    private lateinit var miniCover: Cover
    private lateinit var miniTitle: TextView
    private lateinit var miniSub: TextView
    private lateinit var miniPlay: MaterialButton
    private lateinit var miniProg: LinearProgressIndicator
    private lateinit var dlBar: MaterialCardView
    private lateinit var dlCover: Cover
    private lateinit var dlTitle: TextView
    private lateinit var dlSub: TextView
    private lateinit var dlProg: LinearProgressIndicator
    private var dlWas = false
    private var sheet: ((MediaController, Now, Double, Boolean) -> Unit)? = null // updates the open player sheet
    private var fut: ListenableFuture<MediaController>? = null
    private var ctl: MediaController? = null
    private val h = Handler(Looper.getMainLooper())
    private var generation = 0
    private var screen = 0 // visible page identity; retained pages still receive their own results
    // Retain the view, data and controls rather than re-running a list builder on Back.
    private class Page(val render: () -> Unit, val view: View?, val generation: Int,
        val library: String?, val offline: Boolean, val resume: (() -> Unit)?)
    private var retainPage = false
    private var onReturn: (() -> Unit)? = null
    private val stack = ArrayDeque<Page>()
    private var cur: () -> Unit = {}
    private var onDl: (() -> Unit)? = null // current screen's reaction to a download finishing, starting or being cancelled
    private var onDlTick: (() -> Unit)? = null // ...and to download progress (every second while something downloads)
    private val speeds = listOf(1f, 1.25f, 1.5f, 1.75f, 2f, 0.8f)
    private val back = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = pop()
    }

    override fun onCreate(b: Bundle?) {
        enableEdgeToEdge()
        DynamicColors.applyToActivityIfAvailable(this)
        super.onCreate(b)
        Abs.init(this)
        Dl.load()
        content = FrameLayout(this)
        ViewCompat.setOnApplyWindowInsetsListener(content) { v, i ->
            v.setPadding(0, i.getInsets(WindowInsetsCompat.Type.statusBars()).top, 0, 0)
            i
        }
        mini = miniPlayer()
        dlBar = downloadBar()
        nav = BottomNavigationView(this).apply {
            menu.add(0, 0, 0, "Home").setIcon(R.drawable.i_home)
            menu.add(0, 1, 1, "Library").setIcon(R.drawable.i_auto_stories)
            menu.add(0, 2, 2, "Series").setIcon(R.drawable.i_collections_bookmark)
            menu.add(0, 3, 3, "Favorites").setIcon(R.drawable.i_favorite)
            setOnItemSelectedListener { tab(it.itemId); true }
            setOnItemReselectedListener { tab(it.itemId) }
            labelVisibilityMode = com.google.android.material.navigation.NavigationBarView.LABEL_VISIBILITY_LABELED
        }
        banner = row(
            text("Offline · showing downloads only", M.attr.textAppearanceLabelLarge).apply { setTextColor(color(M.attr.colorOnErrorContainer)) }.lp(0, -2, 1f),
            button("Retry", style = androidx.appcompat.R.attr.borderlessButtonStyle) { thread { Abs.ping() } }
                .apply { setTextColor(color(M.attr.colorOnErrorContainer)) },
        ).pad(16, 0).apply { setBackgroundColor(color(M.attr.colorErrorContainer)); visibility = View.GONE }
        setContentView(col(content.lp(-1, 0, 1f), banner, dlBar, mini, nav))
        onBackPressedDispatcher.addCallback(this, back)
        if (Abs.me == null) login() else {
            tab(0)
            Dl.start(this) // pick up downloads left unfinished last time
        }
    }

    override fun onStart() {
        super.onStart()
        Abs.progressSync.wake()
        val f = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlayerService::class.java))).buildAsync()
        fut = f
        f.addListener({ ctl = runCatching { f.get() }.getOrNull(); restore(); tick.run() }, mainExecutor)
        Dl.onChange = { msg ->
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                msg?.let(::toast)
                onDl?.invoke()
                updateDl()
            }
        }
        onDl?.invoke() // downloads may have finished while we were in the background
    }

    override fun onStop() {
        Dl.onChange = null
        h.removeCallbacks(tick)
        fut?.let { MediaController.releaseFuture(it) }
        fut = null
        ctl = null
        super.onStop()
    }

    override fun onConfigurationChanged(c: android.content.res.Configuration) {
        super.onConfigurationChanged(c)
        if (Abs.me != null) {
            fun resize(v: View) {
                if (v is RecyclerView) (v.layoutManager as? GridLayoutManager)?.spanCount = max(4, resources.displayMetrics.widthPixels / dp(96))
                else if (v is ViewGroup) for (i in 0 until v.childCount) resize(v.getChildAt(i))
            }
            stack.forEach { it.view?.let(::resize) }
            if (retainPage) resize(content) else cur()
        } // re-layout retained grids without throwing away their search or viewport
    }

    private val tick = object : Runnable {
        override fun run() {
            updatePlayer()
            updateDl()
            if (Abs.offline != wasOffline) { // connectivity flipped: re-render with/without the downloads-only filter
                wasOffline = Abs.offline
                banner.isVisible = wasOffline
                if (Abs.me != null && nav.isVisible) cur()
            }
            if (Abs.offline && ++ticks % 10 == 0) thread { Abs.ping() }
            h.postDelayed(this, 1000)
        }
    }

    // --- navigation

    private fun tab(i: Int) {
        stack.clear()
        back.isEnabled = false
        cur = when (i) { 0 -> ::home; 1 -> ::library; 2 -> ::series; else -> ::favorites }
        cur()
    }

    private fun push(s: () -> Unit) {
        stack.addLast(Page(cur, content.getChildAt(0).takeIf { retainPage }, screen, Abs.p.getString("lib", null), Abs.offline, onReturn))
        cur = s
        back.isEnabled = true
        s()
    }

    private fun pop() {
        val page = stack.removeLastOrNull() ?: return
        cur = page.render
        back.isEnabled = stack.isNotEmpty()
        if (page.view == null || page.library != Abs.p.getString("lib", null) || page.offline != Abs.offline) {
            cur() // an explicit context change must not reuse the old list
        } else {
            screen = page.generation
            retainPage = true
            onDl = page.resume
            onDlTick = null
            onReturn = page.resume
            show(page.view)
            // Update badges/progress without replacing data, controls or layout managers.
            fun refresh(v: View) {
                if (v is RecyclerView) v.adapter?.notifyDataSetChanged()
                else if (v is ViewGroup) for (i in 0 until v.childCount) refresh(v.getChildAt(i))
            }
            refresh(page.view)
            onReturn?.invoke()
        }
    }

    private fun begin() {
        screen = ++generation
        retainPage = false
        onReturn = null
        onDl = null
        onDlTick = null
        nav.isVisible = true
    }

    private fun show(v: View) {
        content.removeAllViews()
        content.addView(v)
    }

    private fun header(title: String) =
        row(text(title, M.attr.textAppearanceHeadlineMedium).lp(0, -2, 1f), icon(R.drawable.i_settings) { push(::settings) }.apply { contentDescription = "Settings" }).pad(16, 8)

    private fun subHeader(title: String) =
        row(icon(R.drawable.i_arrow_back) { pop() }.apply { contentDescription = "Back" }, text(title, M.attr.textAppearanceTitleLarge, 1).lp(0, -2, 1f)).pad(4, 4)

    private fun section(title: String) = text(title, M.attr.textAppearanceTitleMedium).pad(16, 12)

    // --- login

    private fun login() {
        screen = ++generation
        retainPage = false
        onReturn = null
        stack.clear()
        back.isEnabled = false
        nav.isVisible = false
        val url = field("Server URL", Abs.server, InputType.TYPE_TEXT_VARIATION_URI)
        val user = field("Username")
        val pass = field("Password", "", InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val go = button("Sign in") {}
        go.setOnClickListener {
            go.isEnabled = false
            bg({ Abs.login(url.str(), user.str(), pass.str(), true) }, { go.isEnabled = true; err(it) }) { if (nav.selectedItemId == 0) tab(0) else nav.selectedItemId = 0 }
        }
        val logo = ImageView(this).apply { setImageResource(R.drawable.logo) }.lp(dp(96), dp(96), m = 8)
        val c = col(
            logo, text("ABS+", M.attr.textAppearanceHeadlineMedium).apply { gravity = Gravity.CENTER },
            text("A tiny, fast Audiobookshelf player", muted = true).apply { gravity = Gravity.CENTER }.pad(0, 4).lp(m = 8),
            url.lp(m = 4), user.lp(m = 4), pass.lp(m = 4), go.lp(m = 8), pad = 24,
        ).apply { gravity = Gravity.CENTER_HORIZONTAL }
        show(NestedScrollView(this).apply { addView(c) })
    }

    private fun logout() = confirm("Log out? Downloads are kept.") {
        ctl?.clearMediaItems()
        Abs.logout()
        login()
    }

    // --- home: continue listening (server, all devices) + recently played (this device)

    private fun home() {
        begin()
        var items = listOf<Card>()
        val cont = RecyclerView(this).apply {
            layoutManager = LinearLayoutManager(context, LinearLayoutManager.HORIZONTAL, false)
            clipToPadding = false
            pad(10, 0)
            adapter = Rv({ items.size }, { tile(resources.displayMetrics.widthPixels / 4 - dp(5)) }, { v, i ->
                bindTile(v, items[i])
                v.setOnClickListener { playCard(items[i]) }
                v.setOnLongClickListener { push { item(items[i].id) }; true }
            })
        }
        val contTitle = section("Continue listening")
        val hist = col()
        Abs.history().filter { !Abs.offline || Abs.downloaded(it.first.id) }.forEach { (c, at) ->
            hist.addView(listRow(c, DateUtils.getRelativeTimeSpanString(at), { playCard(c) }) { push { item(c.id) } })
        }
        if (hist.childCount == 0) hist.addView(text("Nothing played on this device yet.", muted = true).pad(16, 4))
        show(NestedScrollView(this).apply { addView(col(header("Home"), contTitle, cont, section("Recently played"), hist).pad(0, 0)) })
        load("/api/me") { Abs.setMe(it); cont.adapter?.notifyDataSetChanged() }
        load("/api/me/items-in-progress?limit=20") { j ->
            val a = j.getJSONArray("libraryItems")
            items = (0 until a.length()).map { a.getJSONObject(it) }.map { li ->
                val c = Card.item(li)
                li.optJSONObject("recentEpisode")?.let { Card(c.id, it.str("title"), c.title, it.getString("id")) } ?: c
            }.let(::avail)
            contTitle.isVisible = items.isNotEmpty()
            cont.isVisible = items.isNotEmpty()
            cont.adapter?.notifyDataSetChanged()
        }
    }

    // --- library

    private fun library() {
        begin()
        retainPage = true
        val chips = ChipGroup(this).apply { isSingleLine = true; isSingleSelection = true }
        val search = field("Search titles & authors").apply {
            startIconDrawable = ContextCompat.getDrawable(context, R.drawable.i_search)
            val r = dp(28).toFloat()
            setBoxCornerRadii(r, r, r, r)
        }
        var all = listOf<Card>()
        var shown = all
        val sel = Abs.p.getString("lib", null)
        val g = grid(Abs.p.getFloat("ratio:$sel", 1f)) { shown }
        fun filter(preservePosition: Boolean = true) {
            val lm = g.layoutManager as GridLayoutManager
            val first = lm.findFirstVisibleItemPosition()
            val key = (lm.findViewByPosition(first)?.tag as? Tile)?.key
            val offset = lm.findViewByPosition(first)?.let { lm.getDecoratedTop(it) - g.paddingTop }
            val q = search.str().trim()
            shown = avail(if (q.isEmpty()) all else all.filter { it.title.contains(q, true) || it.sub.contains(q, true) })
            g.adapter?.notifyDataSetChanged()
            if (!preservePosition) lm.scrollToPositionWithOffset(0, 0)
            else if (key != null && offset != null) {
                val at = shown.indexOfFirst { it.key == key }
                if (at >= 0) lm.scrollToPositionWithOffset(at, offset)
            }
        }
        search.editText!!.doAfterTextChanged { filter(preservePosition = false) }
        if (Abs.offline) { // every downloaded item, whatever its library
            show(col(header("Downloaded"), search.lp(m = 0).pad(16, 4), g.lp(-1, 0, 1f)))
            onReturn = {
                all = Abs.downloads().map { Abs.cachedCard(it.name) }
                filter()
            }
            onDl = onReturn
            return onReturn!!.invoke()
        }
        show(col(header("Library"), HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(chips) }.pad(16, 0),
            search.lp(m = 0).pad(16, 4), g.lp(-1, 0, 1f)))
        load("/api/libraries", retained = sel != null) { j ->
            val libs = j.getJSONArray("libraries")
            chips.removeAllViews()
            for (i in 0 until libs.length()) {
                val l = libs.getJSONObject(i)
                val id = l.getString("id")
                // ABS coverAspectRatio: 1 = square, 0 = book (1.6)
                Abs.p.edit().putFloat("ratio:$id", if (l.optJSONObject("settings")?.optInt("coverAspectRatio", 1) == 0) 1.6f else 1f).apply()
                chips.addView(Chip(this).apply {
                    text = l.getString("name")
                    isCheckable = true
                    isChecked = id == sel
                    setOnClickListener { Abs.p.edit().putString("lib", id).apply(); library() }
                })
            }
            if (sel == null && libs.length() > 0) {
                Abs.p.edit().putString("lib", libs.getJSONObject(0).getString("id")).apply()
                library()
            }
        }
        if (sel == null) return
        load("/api/libraries/$sel/items?minified=1&sort=media.metadata.title", retained = true) { j ->
            val r = j.getJSONArray("results")
            all = (0 until r.length()).map { Card.item(r.getJSONObject(it)) }
            filter()
        }
        load("/api/me") { Abs.setMe(it); g.adapter?.notifyDataSetChanged() }
    }

    // --- series (from the server's book libraries)

    private fun series() {
        begin()
        val box = col()
        val empty = text("No series on the server yet.", muted = true).pad(16, 4)
        show(NestedScrollView(this).apply { addView(col(header("Series"), box, empty)) })
        load("/api/libraries") { j ->
            val libs = j.getJSONArray("libraries").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }.filter { it.str("mediaType") == "book" }
            val boxes = libs.map { col() }
            box.removeAllViews()
            boxes.forEach { box.addView(it) }
            libs.forEachIndexed { i, l ->
                val id = l.getString("id")
                val ratio = Abs.p.getFloat("ratio:$id", 1f)
                load("/api/libraries/$id/series?limit=1000&sort=name") { sj ->
                    val a = sj.getJSONArray("results")
                    boxes[i].removeAllViews()
                    if (libs.size > 1 && a.length() > 0) boxes[i].addView(section(l.getString("name")))
                    for (k in 0 until a.length()) {
                        val se = a.getJSONObject(k)
                        val books = cards(se.getJSONArray("books"))
                        val name = se.getString("name")
                        boxes[i].addView(listRow(Card(books.firstOrNull()?.id ?: "", name, ""), "${books.size} books", null) { push { shelf(name, books, ratio) } })
                    }
                    empty.isVisible = boxes.all { it.childCount == 0 }
                }
            }
        }
    }

    private fun cards(a: org.json.JSONArray) = (0 until a.length()).map { Card.item(a.getJSONObject(it)) }

    private fun shelf(name: String, cards: List<Card>, ratio: Float) {
        begin()
        retainPage = true
        var shown = avail(cards)
        val g = grid(ratio) { shown }
        onReturn = {
            val lm = g.layoutManager as GridLayoutManager
            val first = lm.findFirstVisibleItemPosition()
            val key = (lm.findViewByPosition(first)?.tag as? Tile)?.key
            val offset = lm.findViewByPosition(first)?.let { lm.getDecoratedTop(it) - g.paddingTop }
            shown = avail(cards)
            g.adapter?.notifyDataSetChanged()
            val at = shown.indexOfFirst { it.key == key }
            if (at >= 0 && offset != null) lm.scrollToPositionWithOffset(at, offset)
        }
        onDl = onReturn
        show(col(subHeader(name), g.lp(-1, 0, 1f)))
    }

    // --- favorites (synced via the server, see Abs.favs)

    private fun favorites() {
        begin()
        retainPage = true
        val owner = screen
        var favs = avail(Abs.favs())
        val empty = text("Tap ♡ on a book or podcast to keep it here.", muted = true).pad(16, 4)
        val g = grid(1f) { favs }
        fun refresh() {
            val lm = g.layoutManager as GridLayoutManager
            val first = lm.findFirstVisibleItemPosition()
            val key = (lm.findViewByPosition(first)?.tag as? Tile)?.key
            val offset = lm.findViewByPosition(first)?.let { lm.getDecoratedTop(it) - g.paddingTop }
            favs = avail(Abs.favs())
            empty.isVisible = favs.isEmpty()
            g.adapter?.notifyDataSetChanged()
            val at = favs.indexOfFirst { it.key == key }
            if (at >= 0 && offset != null) lm.scrollToPositionWithOffset(at, offset)
        }
        onReturn = { refresh() }
        onDl = onReturn
        show(col(header("Favorites"), empty, g.lp(-1, 0, 1f)))
        refresh()
        load("/api/me", retained = true) { me ->
            Abs.setMe(me)
            refresh()
            favs.filter { it.title.isEmpty() }.forEach { c -> bg({ Abs.fillFav(c.id) }, {}) { if (ownsPage(owner, true)) refresh() } }
        }
    }

    // --- settings

    private fun settings() {
        begin()
        val body = col(subHeader("Settings"))
        body.addView(section("Account"))
        body.addView(row(
            col(text(Abs.me ?: "", M.attr.textAppearanceTitleSmall), text(Abs.server, M.attr.textAppearanceBodySmall, 1, muted = true)).lp(0, -2, 1f),
            button("Log out", style = M.attr.materialButtonOutlinedStyle) { logout() },
        ).pad(16, 4))

        body.addView(section("Linked accounts"))
        body.addView(text("Accounts you can share progress with, per book or podcast (share button on its page). " +
            "They sign in here once; only their login token is kept.", M.attr.textAppearanceBodySmall, muted = true).pad(16, 0))
        val accts = Abs.accounts()
        if (accts.isEmpty()) body.addView(text("None yet.", muted = true).pad(16, 8))
        accts.forEach { a ->
            val n = Abs.p.all.keys.count { it.startsWith("share:") && a in Abs.p.getStringSet(it, emptySet())!! }
            body.addView(row(
                col(text(a, M.attr.textAppearanceTitleSmall), text("Shared on $n title${if (n == 1) "" else "s"}", M.attr.textAppearanceBodySmall, muted = true)).lp(0, -2, 1f),
                icon(R.drawable.i_delete) {
                    confirm("Unlink $a? Progress sharing with them stops on all titles. Their existing progress is not changed.") { Abs.unlink(a); settings() }
                },
            ).pad(16, 4))
        }
        body.addView(button("Link account", R.drawable.i_group, M.attr.materialButtonOutlinedStyle) { addAccount { settings() } }.lp(-2, -2)
            .also { (it.layoutParams as LinearLayout.LayoutParams).marginStart = dp(16) })

        body.addView(section("Storage"))
        val dls = Abs.downloads()
        val busy = Dl.jobs.size.takeIf { it > 0 }?.let { " · $it downloading" } ?: ""
        body.addView(row(
            col(text("Downloads", M.attr.textAppearanceTitleSmall),
                text("${dls.size} item${if (dls.size == 1) "" else "s"} · ${mb(dls.sumOf { d -> d.listFiles()?.sumOf { it.length() } ?: 0L })}$busy", M.attr.textAppearanceBodySmall, muted = true)).lp(0, -2, 1f),
        ).pad(16, 10).apply {
            setBackgroundResource(res(android.R.attr.selectableItemBackground))
            setOnClickListener { push(::downloads) }
        })
        show(NestedScrollView(this).apply { addView(body) })
    }

    // --- downloads on this device (deleting never touches the server)

    private fun downloads() {
        begin()
        val body = col(subHeader("Downloads"))
        val jobs = Dl.jobs.toList()
        if (jobs.isNotEmpty()) {
            body.addView(row(
                section("Downloading").lp(0, -2, 1f),
                button("Cancel all", style = androidx.appcompat.R.attr.borderlessButtonStyle) {
                    confirm("Cancel all ${jobs.size} downloads?") { jobs.forEach { Dl.cancel(it.n) }; Abs.dlChanged(); downloads() }
                }.apply { isVisible = jobs.size > 1 },
            ).apply { setPadding(0, 0, dp(8), 0) })
            val rows = jobs.map { jobRow(it).also { (v, _) -> body.addView(v) } }
            onDlTick = { rows.forEach { it.second() } }
        }
        onDl = { downloads() }
        val items = Abs.downloads().map { d -> d to (d.listFiles()?.sumOf { it.length() } ?: 0L) }
        val total = items.sumOf { it.second }
        if (jobs.isNotEmpty() && items.isNotEmpty()) body.addView(section("On this device"))
        if (items.isEmpty() && jobs.isEmpty()) body.addView(text("Nothing downloaded on this device.", muted = true).pad(16, 4))
        if (items.isNotEmpty()) {
            body.addView(row(
                text("${items.size} items · ${mb(total)}", muted = true).lp(0, -2, 1f),
                button("Remove all", R.drawable.i_delete, M.attr.materialButtonOutlinedStyle) {
                    confirm("Remove all ${items.size} downloads (${mb(total)}) from this device? Nothing is deleted on the server.") {
                        items.forEach { Abs.removeAll(it.first) }
                        downloads()
                    }
                },
            ).pad(16, 4))
            items.forEach { (d, size) ->
                val c = Abs.cachedCard(d.name)
                body.addView(listRow(c, "${c.sub} · ${mb(size)}", R.drawable.i_delete, {
                    confirm("Remove the download of “${c.title}” from this device?") { Abs.removeAll(d); downloads() }
                }) { push { item(c.id) } })
            }
        }
        show(NestedScrollView(this).apply { addView(body) })
    }

    /** a title in the download queue, with live progress and a cancel button; returns the view and its updater */
    private fun jobRow(j: Dl.Job): Pair<View, () -> Unit> {
        val cover = Cover(this).lp(dp(56), dp(56))
        Covers.load(cover, j.n.item)
        val meta = text("", M.attr.textAppearanceBodySmall, 1, muted = true)
        val prog = LinearProgressIndicator(this).apply { max = 1000; trackThickness = dp(4); trackCornerRadius = dp(2) }.lp(m = 0)
        (prog.layoutParams as LinearLayout.LayoutParams).topMargin = dp(6)
        val r = row(
            cover,
            col(text(j.n.title, M.attr.textAppearanceTitleSmall, 2), meta, prog).pad(14, 0).lp(0, -2, 1f),
            icon(R.drawable.i_close) { confirm("Cancel downloading “${j.n.title}”?") { Dl.cancel(j.n); Abs.dlChanged(); downloads() } }
                .apply { contentDescription = "Cancel download" },
        ).pad(16, 8)
        r.setBackgroundResource(res(android.R.attr.selectableItemBackground))
        r.setOnClickListener { push { item(j.n.item) } }
        val upd = {
            meta.text = dlStatus(j)
            progress(prog, j)
        }
        upd()
        return r to upd
    }

    /** "45% · 47 of 105 MB", "Queued" or "Waiting for connection" */
    private fun dlStatus(j: Dl.Job) = when {
        j !== Dl.jobs.firstOrNull() -> "Queued"
        j.waiting -> "Waiting for connection"
        else -> "${(Dl.pct(j) * 100).toInt()}% · ${mb(j.got)} of ${mb(j.total)}"
    }

    /** determinate while bytes are coming in, indeterminate while queued or waiting */
    private fun progress(p: com.google.android.material.progressindicator.BaseProgressIndicator<*>, j: Dl.Job) {
        val known = j === Dl.jobs.firstOrNull() && !j.waiting && j.total > 0
        if (p.isIndeterminate == known) { // can't switch modes while shown
            val v = p.visibility
            p.visibility = View.INVISIBLE
            p.isIndeterminate = !known
            p.visibility = v
        }
        if (known) p.setProgressCompat((Dl.pct(j) * 1000).toInt(), true)
    }

    private fun mb(b: Long) = if (b >= 1 shl 30) "%.1f GB".format(b / 1073741824.0) else "${b shr 20} MB"

    // --- tiles & rows

    private class Tile(val cover: Cover, val badge: View, val prog: LinearProgressIndicator, val title: TextView, val sub: TextView, var key: String = "")

    /** offline: only what's playable without the server */
    private fun avail(cards: List<Card>) = if (Abs.offline) cards.filter { Abs.downloaded(it.id) } else cards

    // Each page owns its filtered snapshot and refreshes it with its viewport anchor.
    private fun grid(ratio: Float, cards: () -> List<Card>) = RecyclerView(this).apply {
        layoutManager = GridLayoutManager(context, max(4, resources.displayMetrics.widthPixels / dp(96)))
        clipToPadding = false
        pad(10, 4)
        adapter = Rv({ cards().size }, { tile(-1, ratio) }, { v, i ->
            val c = cards()[i]
            bindTile(v, c)
            v.setOnClickListener { push { item(c.id) } }
        })
    }

    private fun tile(width: Int, ratio: Float = 1f): View {
        val cover = Cover(this, ratio)
        val badge = ImageView(this).apply {
            setImageResource(R.drawable.i_download_done_fill)
            imageTintList = android.content.res.ColorStateList.valueOf(color(M.attr.colorOnPrimary))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color(androidx.appcompat.R.attr.colorPrimary)) }
            pad(3)
        }
        val frame = FrameLayout(this).apply {
            addView(cover)
            addView(badge, FrameLayout.LayoutParams(dp(18), dp(18), Gravity.TOP or Gravity.END).apply { setMargins(dp(4), dp(4), dp(4), dp(4)) })
        }
        val prog = LinearProgressIndicator(this).apply { max = 1000; trackThickness = dp(3); trackCornerRadius = dp(2) }.lp(m = 0)
        (prog.layoutParams as LinearLayout.LayoutParams).topMargin = dp(4)
        val title = text("", M.attr.textAppearanceLabelLarge, 2).pad(0, 4)
        val sub = text("", M.attr.textAppearanceBodySmall, 1, muted = true)
        return col(frame, prog, title, sub).apply {
            pad(4)
            layoutParams = RecyclerView.LayoutParams(width, -2)
            tag = Tile(cover, badge, prog, title, sub)
            setBackgroundResource(res(android.R.attr.selectableItemBackground))
        }
    }

    private fun bindTile(v: View, c: Card) = (v.tag as Tile).run {
        key = c.key
        Covers.load(cover, c.id)
        title.text = c.title
        sub.text = c.sub
        badge.isVisible = Abs.downloaded(c.id)
        val p = Abs.pct(c.key) ?: 0.0
        prog.visibility = if (p > 0) View.VISIBLE else View.INVISIBLE
        prog.progress = (p * 1000).toInt()
    }

    private fun listRow(c: Card, meta: CharSequence, play: (() -> Unit)?, open: () -> Unit) =
        listRow(c, meta, R.drawable.i_play_arrow_fill, play, open)

    private fun listRow(c: Card, meta: CharSequence, actionIcon: Int, action: (() -> Unit)?, open: () -> Unit): View {
        val cover = Cover(this).lp(dp(56), dp(56))
        if (c.id.isNotEmpty()) Covers.load(cover, c.id)
        val r = row(cover, col(text(c.title, M.attr.textAppearanceTitleSmall, 2), text(meta, M.attr.textAppearanceBodySmall, 1, muted = true)).pad(14, 0).lp(0, -2, 1f))
        if (action != null) r.addView(icon(actionIcon, M.attr.materialIconButtonFilledTonalStyle) { action() })
        r.pad(16, 8)
        r.setBackgroundResource(res(android.R.attr.selectableItemBackground))
        r.setOnClickListener { open() }
        return r
    }

    // --- item page

    private fun item(id: String) {
        begin()
        val rv = RecyclerView(this).apply { layoutManager = LinearLayoutManager(context) }
        show(col(subHeader(""), rv.lp(-1, 0, 1f)))
        load("/api/items/$id?expanded=1") { renderItem(rv, it) }
    }

    private fun renderItem(rv: RecyclerView, j: JSONObject) {
        val c = Card.item(j)
        val m = j.getJSONObject("media")
        val md = m.getJSONObject("metadata")
        val book = j.getString("mediaType") == "book"
        val cover = ShapeableImageView(this).apply {
            adjustViewBounds = true
            maxHeight = dp(300)
            minimumWidth = dp(200)
            minimumHeight = dp(200)
            shapeAppearanceModel = ShapeAppearanceModel().withCornerSize(dp(16).toFloat())
            elevation = dp(6).toFloat()
        }
        Covers.load(cover, c.id)
        val head = col(
            cover.lp(-2, -2, m = 8),
            text(c.title, M.attr.textAppearanceHeadlineSmall).apply { gravity = Gravity.CENTER }.pad(0, 4),
            text(c.sub, M.attr.textAppearanceTitleMedium, 2, muted = true).apply { gravity = Gravity.CENTER },
            pad = 16,
        ).apply { gravity = Gravity.CENTER_HORIZONTAL }

        val fav = icon(if (Abs.isFav(c.id)) R.drawable.i_favorite_fill else R.drawable.i_favorite) {}
        fav.setOnClickListener {
            val on = Abs.toggleFav(c)
            thread { Abs.pushFavs() }
            fav.icon = ContextCompat.getDrawable(this, if (on) R.drawable.i_favorite_fill else R.drawable.i_favorite)
            toast(if (on) "Added to favorites" else "Removed from favorites")
        }
        val share = icon(R.drawable.i_group) { share(c.id, c.title) }
        var eps = listOf<Now>()
        var epAdapter: Rv? = null

        if (book) {
            val ts = Abs.tracks(m.optJSONArray("tracks") ?: org.json.JSONArray())
            val n = Now(c.id, null, c.title, c.sub, ts)
            val p = Abs.pct(c.id) ?: 0.0
            val meta = listOfNotNull(Abs.fmt(n.duration), "${ts.size} files".takeIf { ts.size > 1 },
                if (p >= 1) "Finished" else if (p > 0) "${(p * 100).toInt()}% done" else null)
            head.addView(text(meta.joinToString(" · "), muted = true).apply { gravity = Gravity.CENTER }.pad(0, 6))
            val dl = dlView()
            fun updDl() = bindDl(dl, n)
            updDl()
            onDl = { updDl() }
            onDlTick = { updDl() }
            val play = button(if (p > 0 && p < 1) "Resume" else "Play", R.drawable.i_play_arrow_fill) { play(n) }
            play.isEnabled = ts.isNotEmpty()
            head.addView(row(play.lp(-2, -2), dl, fav, share).apply { gravity = Gravity.CENTER }.pad(0, 8))
        } else {
            val a = m.getJSONArray("episodes")
            val list = (0 until a.length()).map { a.getJSONObject(it) }.filter { it.has("audioFile") }
                .filter { !Abs.offline || Abs.done(c.id, Abs.track(it.getJSONObject("audioFile"), 0.0)) }.sortedByDescending { it.optLong("publishedAt") }
            eps = list.map { Now(c.id, it.getString("id"), it.str("title"), c.title, listOf(Abs.track(it.getJSONObject("audioFile"), 0.0))) }
            val dates = list.map { it.optLong("publishedAt").takeIf { t -> t > 0 }?.let { t -> DateUtils.formatDateTime(this, t, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH) } }
            head.addView(text("${eps.size} episodes", muted = true).apply { gravity = Gravity.CENTER }.pad(0, 6))
            head.addView(row(fav, share).apply { gravity = Gravity.CENTER })
            val ad = Rv({ eps.size }, { episodeRow() }, { v, i -> bindEpisode(v, eps[i], dates[i]) })
            onDl = { ad.notifyDataSetChanged() }
            onDlTick = { if (Dl.jobs.any { it.n.item == c.id }) ad.notifyDataSetChanged() }
            epAdapter = ad
        }
        val desc = HtmlCompat.fromHtml(md.str("description"), HtmlCompat.FROM_HTML_MODE_COMPACT).trim()
        if (desc.isNotEmpty()) head.addView(text(desc, M.attr.textAppearanceBodyMedium, 4).apply {
            setOnClickListener { maxLines = if (maxLines == 4) Int.MAX_VALUE else 4 }
        }.pad(4, 8))
        if (!book) head.addView(text("Episodes", M.attr.textAppearanceTitleMedium).lp().pad(0, 8))
        head.layoutParams = RecyclerView.LayoutParams(-1, -2)
        val one = Rv({ 1 }, { head.also { (it.parent as? ViewGroup)?.removeView(it) } }, { _, _ -> })
        rv.adapter = epAdapter?.let { ConcatAdapter(one, it) } ?: one
    }

    private class EpRow(val title: TextView, val meta: TextView, val dl: View, val play: MaterialButton)

    private fun episodeRow(): View {
        val title = text("", M.attr.textAppearanceTitleSmall, 2)
        val meta = text("", M.attr.textAppearanceBodySmall, 1, muted = true)
        val dl = dlView()
        val play = icon(R.drawable.i_play_arrow_fill, M.attr.materialIconButtonFilledTonalStyle) {}
        return row(col(title, meta).lp(0, -2, 1f), dl, play).apply {
            pad(16, 6)
            layoutParams = RecyclerView.LayoutParams(-1, -2)
            setBackgroundResource(res(android.R.attr.selectableItemBackground))
            tag = EpRow(title, meta, dl, play)
        }
    }

    private fun bindEpisode(v: View, n: Now, date: String?) = (v.tag as EpRow).run {
        val t = n.tracks[0]
        val p = Abs.pct(n.key)
        title.text = n.title
        meta.text = listOfNotNull(date, Abs.fmt(n.duration), p?.let { if (it >= 1) "Finished" else "${(it * 100).toInt()}%" }).joinToString(" · ")
        bindDl(dl, n)
        play.setOnClickListener { play(n) }
        v.setOnClickListener { play(n) }
    }

    private class DlView(val btn: MaterialButton, val ring: CircularProgressIndicator)

    /** download button; while the title downloads, a ring around a stop icon shows its progress */
    private fun dlView(): View {
        val btn = icon(R.drawable.i_download) {}
        val ring = CircularProgressIndicator(this).apply { max = 1000; indicatorSize = dp(30); trackThickness = dp(3); isVisible = false }
        return FrameLayout(this).apply {
            addView(btn)
            addView(ring, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
            tag = DlView(btn, ring)
        }
    }

    /** done -> remove, queued or downloading -> cancel, otherwise (incl. partial) -> download what's missing */
    private fun bindDl(v: View, n: Now) = (v.tag as DlView).run {
        val done = n.tracks.all { Abs.done(n.item, it) }
        val j = if (done) null else Dl.job(n.key)
        btn.icon = ContextCompat.getDrawable(this@Main, if (done) R.drawable.i_download_done_fill else if (j != null) R.drawable.i_stop else R.drawable.i_download)
        btn.contentDescription = if (done) "Remove download" else if (j != null) "Cancel download" else "Download"
        ring.isVisible = j != null
        if (j != null) progress(ring, j)
        btn.setOnClickListener { if (done || j != null) removeDl(n, j != null) else download(n) }
    }

    private fun download(n: Now) {
        // Android 13+ hides the download progress notification until the app may post notifications
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        Dl.add(this, n)
        toast("Downloading…")
        onDl?.invoke()
        updateDl()
    }

    private fun removeDl(n: Now, busy: Boolean = false) = confirm(if (busy) "Cancel downloading “${n.title}”?" else "Remove the download of “${n.title}”?") {
        if (busy) Dl.cancel(n) else Abs.remove(n.tracks.map { Abs.file(n.item, it) })
        Abs.dlChanged()
        onDl?.invoke()
        updateDl()
    }

    // --- the bar above the mini player while something downloads; tapping it opens the downloads screen

    private fun downloadBar(): MaterialCardView {
        dlCover = Cover(this).lp(dp(36), dp(36))
        dlTitle = text("", M.attr.textAppearanceTitleSmall, 1)
        dlSub = text("", M.attr.textAppearanceBodySmall, 1, muted = true)
        dlProg = LinearProgressIndicator(this).apply { max = 1000; trackThickness = dp(2) }
        val arrow = ImageView(this).apply {
            setImageResource(R.drawable.i_download)
            imageTintList = android.content.res.ColorStateList.valueOf(color(M.attr.colorOnSurfaceVariant))
        }
        return MaterialCardView(this, null, M.attr.materialCardViewFilledStyle).apply {
            addView(col(row(dlCover, col(dlTitle, dlSub).pad(12, 0).lp(0, -2, 1f), arrow.lp(dp(24), dp(24), m = 8)).pad(8, 4), dlProg))
            setOnClickListener { if (cur != this@Main::downloads) push(::downloads) }
            visibility = View.GONE
        }.lp(m = 8).also { (it.layoutParams as LinearLayout.LayoutParams).bottomMargin = 0 }
    }

    private fun updateDl() {
        val j = Dl.jobs.firstOrNull()
        dlBar.isVisible = j != null && Abs.me != null && nav.isVisible
        if (j != null) {
            if (dlCover.tag != j.n.item) Covers.load(dlCover, j.n.item)
            dlTitle.text = j.n.title
            dlSub.text = dlStatus(j) + (Dl.jobs.size - 1).let { if (it > 0) " · $it more" else "" }
            progress(dlProg, j)
        }
        if (j != null || dlWas) onDlTick?.invoke()
        dlWas = j != null
    }

    // --- progress sharing

    private fun share(id: String, name: String) {
        val accts = Abs.accounts()
        val cur = Abs.shares(id)
        val checked = BooleanArray(accts.size) { accts[it] in cur }
        val d = MaterialAlertDialogBuilder(this).setTitle("Share progress of “$name”")
            .setNeutralButton("Link account") { _, _ -> addAccount { share(id, name) } }
            .setNegativeButton("Cancel", null)
        if (accts.isEmpty()) d.setMessage("Link another account on this server to keep your progress on this title in sync with it.")
        else d.setMultiChoiceItems(accts.toTypedArray(), checked) { _, i, c -> checked[i] = c }
            .setPositiveButton("Save") { _, _ ->
                val sel = accts.filterIndexed { i, _ -> checked[i] }.toSet()
                val added = sel - cur
                if (added.isEmpty()) Abs.setShares(id, sel)
                else confirm("Share progress of “$name” with ${added.joinToString()}?\n\nListening here will update their progress too, and you'll be offered their position when they're ahead.") {
                    Abs.setShares(id, sel)
                    toast("Progress shared")
                }
            }
        d.show()
    }

    private fun addAccount(then: () -> Unit) {
        val user = field("Username")
        val pass = field("Password", "", InputType.TYPE_TEXT_VARIATION_PASSWORD)
        MaterialAlertDialogBuilder(this).setTitle("Link another account")
            .setMessage("They sign in here once to allow it.")
            .setView(col(user, pass, pad = 20))
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Link") { _, _ ->
                bg({ Abs.login(Abs.server, user.str(), pass.str(), false) }) {
                    if (it == Abs.me) toast("That's you") else { toast("Linked $it"); then() }
                }
            }.show()
    }

    // --- playback

    private fun playCard(c: Card) = bg({
        val path = "/api/items/${c.id}?expanded=1"
        val j = JSONObject(Abs.cached(path) ?: Abs.get(path))
        val m = j.getJSONObject("media")
        if (c.ep == null) Now(c.id, null, c.title, c.sub, Abs.tracks(m.getJSONArray("tracks")))
        else {
            val a = m.getJSONArray("episodes")
            val e = (0 until a.length()).map { a.getJSONObject(it) }.first { it.getString("id") == c.ep }
            Now(c.id, c.ep, e.str("title"), Card.item(j).title, listOf(Abs.track(e.getJSONObject("audioFile"), 0.0)))
        }
    }) { play(it) }

    private fun play(n: Now) {
        if (n.tracks.isEmpty()) return toast("No audio")
        bg({ Abs.positions(n) }) { ps ->
            if (ps.size == 1) start(n, ps[0].time)
            else MaterialAlertDialogBuilder(this).setTitle("Resume “${n.title}” from")
                .setItems(ps.map { "${it.who} — ${Abs.fmt(it.time)}" }.toTypedArray()) { _, i -> start(n, ps[i].time) }
                .show()
        }
    }

    /** After an app restart: put the last title back in the player, paused, at its latest position. */
    private fun restore() {
        val c = ctl ?: return
        if (c.mediaItemCount > 0 || Abs.me == null) return
        val n = Abs.now ?: Abs.loadNow() ?: return
        bg({ Abs.positions(n).first().time }) { t -> if (ctl === c && c.mediaItemCount == 0) start(n, t, play = false) }
    }

    private fun start(n: Now, t: Double, play: Boolean = true) {
        val c = ctl ?: return toast("Player not ready")
        Abs.now?.let { old -> if (old.key != n.key && c.mediaItemCount > 0) Abs.pos(c, old).let { p -> Abs.push(old, p, false) } }
        Abs.now = n
        Abs.saveNow(n)
        if (play) Abs.addHistory(n)
        val art = "${Abs.server}/api/items/${n.item}/cover?width=400&format=webp"
        val items = n.tracks.mapIndexed { i, tr ->
            MediaItem.Builder().setMediaId("${n.key}#$i").setUri(Abs.uri(n.item, tr))
                .setMediaMetadata(MediaMetadata.Builder().setTitle(n.title).setArtist(n.author).setArtworkUri(android.net.Uri.parse(art)).build()).build()
        }
        val (i, ms) = n.at(if (t > n.duration - 5) 0.0 else t)
        c.setMediaItems(items, i, ms)
        c.setPlaybackSpeed(Abs.p.getFloat("speed", 1f))
        c.prepare()
        if (!play) return updatePlayer()
        c.play()
        updatePlayer()
        if (stack.isEmpty() && nav.selectedItemId == 0) home()
    }

    private fun seek(t: Double) {
        val n = Abs.now ?: return
        val (i, ms) = n.at(t)
        ctl?.seekTo(i, ms)
    }

    private fun miniPlayer(): MaterialCardView {
        miniCover = Cover(this).lp(dp(44), dp(44))
        miniTitle = text("", M.attr.textAppearanceTitleSmall, 1)
        miniSub = text("", M.attr.textAppearanceBodySmall, 1, muted = true)
        miniPlay = icon(R.drawable.i_play_arrow_fill) { ctl?.let { Util.handlePlayPauseButtonAction(it) } }
        miniProg = LinearProgressIndicator(this).apply { max = 1000; trackThickness = dp(2) }
        return MaterialCardView(this, null, M.attr.materialCardViewFilledStyle).apply {
            addView(col(row(miniCover, col(miniTitle, miniSub).pad(12, 0).lp(0, -2, 1f), miniPlay).pad(8, 6), miniProg))
            setOnClickListener { openSheet() }
            visibility = View.GONE
        }.lp(m = 8)
    }

    private fun updatePlayer() {
        val c = ctl
        val n = Abs.now
        mini.isVisible = c != null && n != null && c.mediaItemCount > 0 && Abs.me != null && nav.isVisible
        if (c == null || n == null || c.mediaItemCount == 0) return
        val pos = Abs.pos(c, n)
        val playing = !Util.shouldShowPlayButton(c)
        if (miniCover.tag != n.item) Covers.load(miniCover, n.item)
        miniTitle.text = n.title
        miniSub.text = n.author
        miniPlay.icon = ContextCompat.getDrawable(this, if (playing) R.drawable.i_pause_fill else R.drawable.i_play_arrow_fill)
        miniProg.progress = (pos / n.duration * 1000).toInt()
        sheet?.invoke(c, n, pos, playing)
    }

    private fun openSheet() {
        val n = Abs.now ?: return
        val d = BottomSheetDialog(this)
        val w = min(resources.displayMetrics.widthPixels - dp(64), dp(360))
        val cover = Cover(this).lp(w, w, m = 8)
        Covers.load(cover, n.item)
        val title = text(n.title, M.attr.textAppearanceHeadlineSmall, 2).apply { gravity = Gravity.CENTER }
        val sub = text(n.author, M.attr.textAppearanceTitleMedium, 1, muted = true).apply { gravity = Gravity.CENTER }
        var dragging = false
        val slider = Slider(this).apply {
            valueTo = max(1f, n.duration.toFloat())
            setLabelFormatter { Abs.fmt(it.toDouble()) }
            addOnSliderTouchListener(object : Slider.OnSliderTouchListener {
                override fun onStartTrackingTouch(s: Slider) { dragging = true }
                override fun onStopTrackingTouch(s: Slider) { dragging = false; seek(s.value.toDouble()) }
            })
        }
        val el = text("", M.attr.textAppearanceLabelMedium, muted = true)
        val rem = text("", M.attr.textAppearanceLabelMedium, muted = true)
        val play = icon(R.drawable.i_play_arrow_fill, M.attr.materialIconButtonFilledStyle) { ctl?.let { Util.handlePlayPauseButtonAction(it) } }.apply {
            iconSize = dp(36)
            iconPadding = 0
            iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START // with no text this centers the icon
            setPadding(0, 0, 0, 0)
            insetTop = 0
            insetBottom = 0
        }
        val speed = button("1×", style = androidx.appcompat.R.attr.borderlessButtonStyle) {}
        speed.setOnClickListener {
            val c = ctl ?: return@setOnClickListener
            val s = speeds[(speeds.indexOf(c.playbackParameters.speed) + 1) % speeds.size]
            c.setPlaybackSpeed(s)
            Abs.p.edit().putFloat("speed", s).apply()
        }
        val controls = row(
            speed.lp(dp(72), -2),
            icon(R.drawable.i_replay_30) { ctl?.seekBack() }.apply { iconSize = dp(32) },
            play.lp(dp(80), dp(80), m = 12),
            icon(R.drawable.i_forward_30) { ctl?.seekForward() }.apply { iconSize = dp(32) },
            View(this).lp(dp(72), 1),
        ).apply { gravity = Gravity.CENTER }
        val body = col(
            BottomSheetDragHandleView(this), cover, title.pad(16, 4), sub.pad(16, 0),
            slider.lp(m = 0).pad(8, 12), row(el.lp(0, -2, 1f), rem).pad(24, 0), controls.pad(0, 12),
        ).apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(0, 0, 0, dp(24)) }
        d.setContentView(NestedScrollView(this).apply { addView(body) })
        d.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        d.behavior.skipCollapsed = true
        sheet = { c, now, pos, playing ->
            if (now.key != n.key) d.dismiss()
            if (!dragging) slider.value = pos.toFloat().coerceIn(0f, slider.valueTo)
            el.text = Abs.fmt(pos)
            rem.text = "-" + Abs.fmt(max(0.0, now.duration - pos))
            play.icon = ContextCompat.getDrawable(this, if (playing) R.drawable.i_pause_fill else R.drawable.i_play_arrow_fill)
            speed.text = "${c.playbackParameters.speed}×".replace(".0×", "×")
        }
        d.setOnDismissListener { sheet = null }
        d.show()
        updatePlayer()
    }

    // --- helpers

    private fun ownsPage(gen: Int, retained: Boolean) = gen == screen || retained && stack.any {
        it.generation == gen && it.offline == Abs.offline && it.library == Abs.p.getString("lib", null)
    }

    /** Renders cached JSON instantly, then refreshes from the server. */
    private fun load(path: String, retained: Boolean = false, render: (JSONObject) -> Unit) {
        val gen = screen
        val old = Abs.cached(path)?.also { render(JSONObject(it)) }
        bg({ Abs.get(path) }, { if ((old == null && !Abs.offline) || it is Expired) err(it) }) {
            if (ownsPage(gen, retained) && it != old) render(JSONObject(it))
        }
    }

    private fun <T> bg(work: () -> T, fail: (Throwable) -> Unit = ::err, done: (T) -> Unit) = thread {
        val r = runCatching(work)
        runOnUiThread { if (!isDestroyed) r.fold(done, fail) }
    }

    private fun err(e: Throwable) {
        toast(e.message ?: e.toString())
        if (e is Expired) login()
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()

    private fun confirm(msg: String, yes: () -> Unit) = MaterialAlertDialogBuilder(this).setMessage(msg)
        .setNegativeButton("Cancel", null).setPositiveButton("OK") { _, _ -> yes() }.show()

    private fun field(hint: String, v: String = "", type: Int = 0) = TextInputLayout(this).apply {
        this.hint = hint
        addView(TextInputEditText(context).apply {
            setText(v)
            inputType = InputType.TYPE_CLASS_TEXT or type
            isSingleLine = true
        })
        if (type == InputType.TYPE_TEXT_VARIATION_PASSWORD) endIconMode = TextInputLayout.END_ICON_PASSWORD_TOGGLE
    }

    private fun TextInputLayout.str() = editText!!.text.toString()
}
