package com.borodutch.absplus

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import java.io.EOFException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** Media3's default transport follows cross-host redirects. Authenticated media must not.
 * A stream whose file has since been downloaded is read from the phone instead (Abs.downloadedStream). */
class SessionDataSource : BaseDataSource(true) {
    private var connection: HttpURLConnection? = null
    private var input: InputStream? = null
    private var local: FileDataSource? = null
    private var epoch = -1L
    private lateinit var captured: Abs.Scope
    private var remaining = C.LENGTH_UNSET.toLong()
    private var opened = false

    override fun open(spec: DataSpec): Long {
        transferInitializing(spec)
        epoch = spec.key?.toLongOrNull() ?: throw StaleSession()
        captured = Abs.scope(playback = true)
        if (epoch != captured.generation) throw StaleSession()
        Abs.downloadedStream(spec.uri, captured)?.let { f ->
            // Same bytes at the same offsets, so the extractor carries on where the stream left off.
            val file = FileDataSource().also { local = it }
            try {
                remaining = file.open(spec.buildUpon().setUri(Uri.fromFile(f)).build())
                opened = true
                transferStarted(spec)
                return remaining
            } catch (e: Exception) { close(); throw e }
        }
        val token = Abs.streamToken(spec.uri, captured)
        val c = (URL(spec.uri.toString()).openConnection() as HttpURLConnection).also { connection = it }
        try {
            c.instanceFollowRedirects = false
            c.connectTimeout = 15_000; c.readTimeout = 30_000
            c.setRequestProperty("Authorization", "Bearer " + token)
            c.setRequestProperty("Accept-Encoding", "identity")
            if (spec.position > 0 || spec.length != C.LENGTH_UNSET.toLong()) {
                val end = if (spec.length == C.LENGTH_UNSET.toLong()) "" else (spec.position + spec.length - 1).toString()
                c.setRequestProperty("Range", "bytes=" + spec.position + "-" + end)
            }
            val code = c.responseCode
            Abs.inScope(captured) {}
            if (code !in 200..299) throw HttpErr(code)
            val stream = c.inputStream.also { input = it }
            // Servers ignoring Range are safe, but must be skipped to the requested offset.
            var skip = if (code == 200) spec.position else 0
            while (skip > 0) {
                Abs.inScope(captured) {}
                val n = stream.skip(skip)
                if (n > 0) skip -= n else if (stream.read() < 0) throw EOFException() else skip--
            }
            remaining = if (spec.length != C.LENGTH_UNSET.toLong()) spec.length else
                c.contentLengthLong.let { if (it < 0) C.LENGTH_UNSET.toLong() else it - if (code == 200) spec.position else 0 }
            opened = true
            transferStarted(spec)
            return remaining
        } catch (e: Exception) { close(); throw e }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        Abs.inScope(captured) {}
        if (length == 0) return 0
        local?.let { file ->
            val n = file.read(buffer, offset, length)
            Abs.inScope(captured) {}
            if (n > 0) bytesTransferred(n)
            return n
        }
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val n = input!!.read(buffer, offset, if (remaining < 0) length else minOf(length.toLong(), remaining).toInt())
        Abs.inScope(captured) {}
        if (n < 0) return C.RESULT_END_OF_INPUT
        if (remaining >= 0) remaining -= n
        bytesTransferred(n)
        return n
    }
    override fun getUri(): Uri? = local?.uri ?: connection?.url?.toString()?.let(Uri::parse)
    override fun close() {
        try { local?.close() } finally { try { input?.close() } finally {
            local = null; input = null; connection?.disconnect(); connection = null
            if (opened) { opened = false; transferEnded() }
        } }
    }
}
