package id.my.wandidev.klyndro.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.ProtocolLimits

/**
 * Publishes this device and browses for peers over Android NSD.
 *
 * Not covered by the JVM test suite: `NsdManager` needs a device. The TXT field layout is shared
 * with macOS and is covered there, so a mismatch shows up as "device never appears", not as a
 * silent trust failure. Verify on hardware before claiming discovery works.
 */
class NsdDiscovery(context: Context) {

    /** A device seen on the network, before any trust decision. */
    data class DiscoveredPeer(
        val deviceId: DeviceId,
        val name: String,
        val fingerprint: Fingerprint,
        val capabilities: List<Capability>,
        val host: String?,
        val port: Int,
        val hostName: String? = null
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = context.applicationContext
        .getSystemService(Context.WIFI_SERVICE) as WifiManager

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun publish(deviceId: DeviceId, name: String, fingerprint: Fingerprint, port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = "$name [${deviceId.hex.takeLast(6)}]"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", deviceId.hex)
            setAttribute("name", name.take(ProtocolLimits.MAX_DEVICE_NAME_BYTES))
            setAttribute("proto", Envelope.CURRENT_VERSION.toString())
            setAttribute("fp", fingerprint.hex)
            setAttribute("caps", Capability.entries.joinToString(",") { it.wireName })
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        registrationListener = listener
        nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopPublishing() {
        registrationListener?.let { runCatching { nsdManager.unregisterService(it) } }
        registrationListener = null
    }

    /**
     * Starts browsing. The multicast lock is required to receive mDNS responses on Wi-Fi; without
     * it the radio may filter them and discovery looks broken.
     */
    fun browse(onPeer: (DiscoveredPeer) -> Unit, onError: (String) -> Unit = {}) {
        acquireMulticastLock()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                onError("discovery failed to start ($errorCode)")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceType != SERVICE_TYPE) return
                nsdManager.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = Unit

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        parse(info)?.let(onPeer)
                    }
                })
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
        }
        discoveryListener = listener
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopBrowsing() {
        discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
        discoveryListener = null
        releaseMulticastLock()
    }

    private fun parse(info: NsdServiceInfo): DiscoveredPeer? {
        fun attribute(key: String): String? =
            runCatching { info.attributes[key]?.toString(Charsets.UTF_8) }.getOrNull()

        val deviceId = attribute("id")?.let { DeviceId.parse(it) } ?: return null
        val name = attribute("name")?.takeIf { it.isNotEmpty() } ?: return null
        val fingerprint = attribute("fp")?.let { Fingerprint.parse(it) } ?: return null
        if (attribute("proto") != Envelope.CURRENT_VERSION.toString()) return null

        return DiscoveredPeer(
            deviceId = deviceId,
            name = name,
            fingerprint = fingerprint,
            capabilities = Capability.parse(
                attribute("caps")?.split(",")?.map { it.trim() } ?: emptyList()
            ),
            host = info.host?.hostAddress,
            port = info.port,
            hostName = info.host?.hostName
        )
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        multicastLock = wifiManager.createMulticastLock("klyndro-discovery").apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { runCatching { if (it.isHeld) it.release() } }
        multicastLock = null
    }

    companion object {
        const val SERVICE_TYPE = "_klyndro._tcp."
        const val DEFAULT_PORT = 47_823
    }
}
