package com.borodutch.absplus

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlin.concurrent.thread

class PlayerService : MediaSessionService() {
    private var session: MediaSession? = null
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
        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) {
                if (!playing && player.playbackState != Player.STATE_ENDED) sync(player)
            }
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) sync(player, true)
            }
        })
        session = MediaSession.Builder(this, player)
            .setSessionActivity(PendingIntent.getActivity(this, 0, Intent(this, Main::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()
        h.post(tick)
    }

    private fun sync(p: Player, finished: Boolean = false) {
        val n = Abs.now ?: return
        if (p.currentMediaItem?.mediaId?.startsWith(n.key + "#") != true) return
        val pos = if (finished) n.duration else Abs.pos(p, n)
        val epoch = Abs.mediaEpoch
        thread { runCatching { Abs.push(n, pos, finished, epoch) } }
    }

    override fun onGetSession(info: MediaSession.ControllerInfo) = session

    override fun onDestroy() {
        h.removeCallbacksAndMessages(null)
        session?.run { player.release(); release() }
        session = null
        super.onDestroy()
    }
}
