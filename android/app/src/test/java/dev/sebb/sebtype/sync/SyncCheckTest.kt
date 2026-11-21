package dev.sebb.sebtype.sync

import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.BeforeClass
import org.junit.ClassRule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.Socket
import java.net.URL

/**
 * The connection check (#452) against the real sync-server/sebtype_sync.py on a free local port, with a made-up
 * login. It speaks plain HTTP there, so the test's [SyncServer] opens http:// for the https:// address.
 */
class SyncCheckTest {
    companion object {
        @get:ClassRule @JvmStatic val tmp = TemporaryFolder()
        private lateinit var server: Process
        private var port = 0
        private val script = File("../../sync-server/sebtype_sync.py").absoluteFile

        private fun freePort() = ServerSocket(0).use { it.localPort }

        @BeforeClass @JvmStatic
        fun start() {
            val data = tmp.newFolder("server").path
            val add = ProcessBuilder("python3", "-I", script.path, "adduser", "--data", data, "--password-stdin", "alice")
                .redirectErrorStream(true).start()
            add.outputStream.bufferedWriter().use { it.write("made-up-pass\n") }
            assertEquals(0, add.waitFor())
            port = freePort()
            server = ProcessBuilder("python3", "-I", script.path, "serve", "--data", data, "--port", "$port")
                .redirectErrorStream(true).redirectOutput(File(tmp.root, "server.log")).start()
            val end = System.currentTimeMillis() + 15_000
            while(runCatching { Socket("127.0.0.1", port).close() }.isFailure) {
                check(System.currentTimeMillis() < end && server.isAlive) { "the sync server didn't start" }
                Thread.sleep(100)
            }
        }

        @AfterClass @JvmStatic
        fun stop() { server.destroy() }
    }

    private fun check(port: Int, password: String) = Sync.check(SyncServer(
        SyncAccount("https://127.0.0.1:$port", "alice", password, enabled = true),
    ) { URL("http", it.host, it.port, it.file).openConnection() as HttpURLConnection })

    @Test
    fun aGoodLoginConnects() = assertEquals(Sync.Check.Connected, check(port, "made-up-pass"))

    /** The two failures a user most needs told apart: fix the password, or the address and network. */
    @Test
    fun aWrongPasswordIsNotAnUnreachableServer() {
        assertEquals(Sync.Check.LoginFailed, check(port, "wrong-pass"))
        assertEquals(Sync.Check.Unreachable, check(freePort(), "made-up-pass"))
    }
}
