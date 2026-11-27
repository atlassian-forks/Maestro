package maestro.android.chromedevtools

import com.google.common.truth.Truth.assertThat
import dadb.AdbShellResponse
import dadb.AdbStream
import dadb.Dadb
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import maestro.TreeNode
import maestro.android.AndroidDeviceConnection
import maestro.drivers.AndroidDriver
import maestro_android.MaestroAndroid
import maestro_android.MaestroDriverGrpc
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.buffer
import okio.sink
import okio.source
import org.junit.jupiter.api.Test
import java.io.IOException
import java.net.Socket
import java.util.concurrent.CountDownLatch

class VisibleWebViewSocketTest {
    @Test
    fun `an unresponsive background WebView cannot hide a foreground link`() {
        val server = MockWebServer()
        val viewport = """{\"visible\":true,\"attached\":true,\"empty\":false,\"screenX\":0,\"screenY\":0,\"width\":100,\"height\":100}"""
        val target = """[{"description":"$viewport","webSocketDebuggerUrl":"ws://localhost:9222/devtools/page/foreground"}]"""
        server.enqueue(MockResponse().setBody(target))
        val socketListener = object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                webSocket.send(
                    """{"id":1,"result":{"result":{"type":"object","value":{"attributes":{"text":"Open details","bounds":"[0,0][100,100]"},"children":[]}}}}"""
                )
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
            }
        }
        server.enqueue(MockResponse().withWebSocketUpgrade(socketListener))
        server.start()
        val connection = mockk<AndroidDeviceConnection>()
        every { connection.shell("cat /proc/net/unix") } returns reply(
            """
                0: 2 0 10000 1 01 100 @webview_devtools_remote_100
                0: 2 0 10000 1 01 101 @webview_devtools_remote_200
            """.trimIndent()
        )
        // The work-profile app uses a custom process name for its WebView.
        every { connection.shell("dumpsys activity processes com.example.foreground") } returns reply(
            """
              *APP* UID 1010200 ProcessRecord{a67 199:com.example.foreground/u10a200}
              *APP* UID 1010200 ProcessRecord{db5 200:com.example.web.worker/u10a200}
            """.trimIndent()
        )
        val releaseBackground = CountDownLatch(1)
        every { connection.open("localabstract:webview_devtools_remote_100") } answers {
            releaseBackground.await()
            throw IOException("Background endpoint unavailable")
        }
        every { connection.open("localabstract:webview_devtools_remote_200") } answers {
            val socket = Socket("127.0.0.1", server.port)
            object : AdbStream {
                override val source = socket.source().buffer()
                override val sink = socket.sink().buffer()
                override fun close() = socket.close()
            }
        }
        val base = foregroundWebView()
        val client = AndroidWebViewHierarchyClient(DadbChromeDevToolsClient(connection))

        try {
            val hierarchy = client.augmentHierarchy(base, chromeDevToolsEnabled = true)

            assertThat(hierarchy.aggregate().map { it.attributes["text"] })
                .contains("Open details")
            verify(exactly = 0) { connection.open("localabstract:webview_devtools_remote_100") }
        } finally {
            releaseBackground.countDown()
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `native WebView ownership reaches the client hierarchy`() {
        val response = MaestroAndroid.ViewHierarchyResponse.newBuilder().setHierarchy(
            """<hierarchy><node class="android.webkit.WebView" package="com.example.foreground" bounds="[0,0][100,100]" /></hierarchy>"""
        ).build()
        val stub = mockk<MaestroDriverGrpc.MaestroDriverBlockingStub>()
        every { stub.viewHierarchy(any()) } returns response
        AndroidDeviceConnection.forTest(
            dadb = mockk<Dadb>(relaxed = true),
            blockingStubProvider = { stub },
        ).use { connection ->
            val hierarchy = AndroidDriver(connection).contentDescriptor(excludeKeyboardElements = false)

            val webView = hierarchy.aggregate().single { it.attributes["class"] == "android.webkit.WebView" }
            assertThat(webView.attributes["package"]).isEqualTo("com.example.foreground")
        }
    }

    @Test
    fun `unknown foreground package ownership does not probe other applications`() {
        val connection = mockk<AndroidDeviceConnection>()
        every { connection.shell("cat /proc/net/unix") } returns reply(
            "0: 2 0 10000 1 01 100 @webview_devtools_remote_100"
        )
        every { connection.shell("dumpsys activity processes com.example.foreground") } returns
            AdbShellResponse("", "service unavailable", 1)
        val base = foregroundWebView()

        AndroidWebViewHierarchyClient(DadbChromeDevToolsClient(connection)).use { client ->
            assertThat(client.augmentHierarchy(base, chromeDevToolsEnabled = true)).isEqualTo(base)
        }

        verify(exactly = 0) { connection.open(any()) }
    }

    private fun foregroundWebView() = TreeNode(
        attributes = mutableMapOf(
            "class" to "android.webkit.WebView",
            "package" to "com.example.foreground",
            "bounds" to "[0,0][100,100]",
        ),
    )

    private fun reply(output: String) = AdbShellResponse(output, "", 0)
}
