package co.ke.hometunnel.client

import android.content.Intent
import android.net.VpnService
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets

class MainActivity: FlutterActivity() {
    private val CHANNEL = "co.ke.hometunnel/wireguard"
    private var backend: GoBackend? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        backend = GoBackend(context)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTunnel" -> {
                    val configQuick = call.argument<String>("config")
                    if (configQuick != null) {
                        val intent = VpnService.prepare(context)
                        if (intent != null) {
                            startActivityForResult(intent, 100)
                            result.error("VPN_PERMISSION_REQUIRED", "Permission needed", null)
                        } else {
                            startWireGuard(configQuick, result)
                        }
                    } else {
                        result.error("BAD_ARGS", "Config missing", null)
                    }
                }
                "stopTunnel" -> {
                    try {
                        backend?.setState(SimpleTunnel(), Tunnel.State.DOWN, null)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startWireGuard(configText: String, result: MethodChannel.Result) {
        try {
            val config = Config.parse(ByteArrayInputStream(configText.toByteArray(StandardCharsets.UTF_8)))
            backend?.setState(SimpleTunnel(), Tunnel.State.UP, config)
            result.success(true)
        } catch (e: Exception) {
            result.error("TUNNEL_ERROR", e.message, null)
        }
    }

    class SimpleTunnel : Tunnel {
        override fun getName(): String = "HomeTunnel"
        override fun onStateChange(newState: Tunnel.State) {}
    }
}
