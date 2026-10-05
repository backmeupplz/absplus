package com.borodutch.absplus

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.MediaItem
import com.google.common.util.concurrent.Futures
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

class PlayerService : MediaSessionService() {
    companion object {
        @Volatile private var active: PlayerService? = null
        fun invalidateSession() {
            val service = active ?: return
            if (Looper.myLooper() == Looper.getMainLooper()) service.checkQueue()
            else service.h.post { service.checkQueue() }
        }
    }

    private var queueEpoch = -1L
    private fun checkQueue() {
        val player = session?.player ?: return
        if (queueEpoch != Abs.scope(playback = true).generation || Abs.me == null) {
            // Keep the old epoch while stop callbacks fire: never push the old queue as the new user.
            player.stop()
            player.clearMediaItems()
            queueEpoch = Abs.scope(playback = true).generation
        }
    }
    private var session: MediaSession? = null
    private val accountChanged = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == null || key == "me" || key == "server") h.post {
            session?.player?.let { player ->
                val captured = Abs.nowScope
                val n = Abs.now
                if (captured == null || n == null || player.currentMediaItem?.mediaId != Abs.mediaId(n, captured, player.currentMediaItemIndex)) {
                    player.stop()
                    player.clearMediaItems()
                }
            }
        }
    }
    private val h = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            session?.player?.let { if (it.isPlaying) sync(it) }
            h.postDelayed(this, 20_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Abs.init(this)
        queueEpoch = Abs.scope(playback = true).generation
        active = this
        // token is resolved per request on the loader thread, so it gets refreshed when it expires mid-book
        val http = DataSource.Factory { SessionDataSource() }
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(DefaultDataSource.Factory(this, http)))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setSeekBackIncrementMs(30_000)
            .setSeekForwardIncrementMs(30_000)
            .build()
        player.addListener(progressListener(player))
        session = MediaSession.Builder(this, player)
            .setCallback(object : MediaSession.Callback {
                override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo, items: List<MediaItem>) =
                    Futures.immediateFuture(if (Abs.me == null || Abs.loginPending) emptyList() else items.filter {
                        it.localConfiguration?.customCacheKey == Abs.scope(playback = true).generation.toString()
                    })
            })
            .setSessionActivity(PendingIntent.getActivity(this, 0, Intent(this, Main::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()
        Abs.p.registerOnSharedPreferenceChangeListener(accountChanged)
        h.post(tick)
    }

    // Shared by app controls and notification/headset play commands. Preparing a paused
    // restore never emits playing=true, so only actual playback clears a finished title.
    internal fun progressListener(player: Player) = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            if (playing) sync(player, intentionalPlayback = true)
            else if (player.playbackState != Player.STATE_ENDED) sync(player)
        }
        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) sync(player, true)
        }
    }

    private fun sync(p: Player, finished: Boolean = false, intentionalPlayback: Boolean = false) {
        // The bound scope remains authorized while reauthentication is pending.
        val captured = Abs.nowScope ?: return
        Abs.ifCurrent(captured) {
            val n = Abs.now ?: return@ifCurrent
            if (p.currentMediaItem?.mediaId != Abs.mediaId(n, captured, p.currentMediaItemIndex)) return@ifCurrent
            val pos = if (finished) n.duration else Abs.pos(p, n)
            Abs.push(n, pos, finished, intentionalPlayback)
        }
    }

    override fun onGetSession(info: MediaSession.ControllerInfo) = session

    override fun onDestroy() {
        if (active === this) active = null
        Abs.p.unregisterOnSharedPreferenceChangeListener(accountChanged)
        h.removeCallbacksAndMessages(null)
        session?.run { player.release(); release() }
        session = null
        super.onDestroy()
    }
}
