package com.borodutch.absplus

import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import java.io.File
import java.net.InetSocketAddress
import java.security.KeyStore
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import org.junit.Assert.assertEquals

/** An HTTPS server on 127.0.0.1 with a fresh self-signed certificate that the device doesn't trust (not started). */
fun untrustedHttps(dir: File): HttpsServer {
    val store = File(dir, "server.p12")
    val keytool = File(System.getProperty("java.home"), "bin/keytool").path
    val made = ProcessBuilder(keytool, "-genkeypair", "-alias", "s", "-keyalg", "RSA", "-keysize", "2048", "-dname", "CN=127.0.0.1",
        "-validity", "2", "-storetype", "PKCS12", "-keystore", store.path, "-storepass", "fixture", "-keypass", "fixture")
        .redirectErrorStream(true).start()
    assertEquals(0, made.waitFor())
    val keys = KeyStore.getInstance("PKCS12").apply { store.inputStream().use { load(it, "fixture".toCharArray()) } }
    val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, "fixture".toCharArray()) }
    val ssl = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
    return HttpsServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply { httpsConfigurator = HttpsConfigurator(ssl) }
}
