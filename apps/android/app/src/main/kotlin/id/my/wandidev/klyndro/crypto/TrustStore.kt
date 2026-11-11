package id.my.wandidev.klyndro.crypto

/**
 * A device the user has explicitly paired with.
 *
 * Only public identity data is stored: device id, display name, platform, public-key
 * fingerprint, and last known address.
 */
data class TrustedPeer(
    val deviceId: String,
    val name: String,
    val platform: String,
    val fingerprint: String,
    val lastHost: String? = null,
    val lastPort: Int? = null,
    val pairedAtMillis: Long = System.currentTimeMillis()
) {
    val fingerprintValue: Fingerprint? get() = Fingerprint.parse(fingerprint)

    /** True when this record authorises a peer presenting [candidate]. */
    fun authorises(candidate: Fingerprint): Boolean =
        fingerprintValue?.matches(candidate) ?: false
}

/** Persistence for paired devices. */
interface TrustStore {
    fun allPeers(): List<TrustedPeer>
    fun peer(id: String): TrustedPeer?
    fun upsert(peer: TrustedPeer)
    fun remove(id: String)
    fun removeAll()
}

/** Non-persistent store for tests and previews. */
class InMemoryTrustStore(initial: List<TrustedPeer> = emptyList()) : TrustStore {
    private val peers = initial.toMutableList()

    override fun allPeers(): List<TrustedPeer> = synchronized(peers) { peers.toList() }

    override fun peer(id: String): TrustedPeer? = allPeers().firstOrNull { it.deviceId == id }

    override fun upsert(peer: TrustedPeer) = synchronized(peers) {
        val index = peers.indexOfFirst { it.deviceId == peer.deviceId }
        if (index >= 0) peers[index] = peer else peers.add(peer)
        Unit
    }

    override fun remove(id: String) = synchronized(peers) {
        peers.removeAll { it.deviceId == id }
        Unit
    }

    override fun removeAll() = synchronized(peers) {
        peers.clear()
        Unit
    }
}

/** JSON codec shared by the persistent store and its tests. */
object TrustStoreCodec {
    fun encode(peers: List<TrustedPeer>): String {
        val array = com.google.gson.JsonArray()
        peers.forEach { peer ->
            array.add(com.google.gson.JsonObject().apply {
                addProperty("device_id", peer.deviceId)
                addProperty("name", peer.name)
                addProperty("platform", peer.platform)
                addProperty("fingerprint", peer.fingerprint)
                peer.lastHost?.let { addProperty("last_host", it) }
                peer.lastPort?.let { addProperty("last_port", it) }
                addProperty("paired_at", peer.pairedAtMillis)
            })
        }
        return com.google.gson.Gson().toJson(array)
    }

    /** A corrupt record yields an empty list: the user can always pair again. */
    fun decode(json: String): List<TrustedPeer> = runCatching {
        com.google.gson.JsonParser.parseString(json).asJsonArray.map { element ->
            val obj = element.asJsonObject
            TrustedPeer(
                deviceId = obj.get("device_id").asString,
                name = obj.get("name").asString,
                platform = obj.get("platform").asString,
                fingerprint = obj.get("fingerprint").asString,
                lastHost = obj.get("last_host")?.takeUnless { it.isJsonNull }?.asString,
                lastPort = obj.get("last_port")?.takeUnless { it.isJsonNull }?.asInt,
                pairedAtMillis = obj.get("paired_at")?.takeUnless { it.isJsonNull }?.asLong
                    ?: System.currentTimeMillis()
            )
        }
    }.getOrDefault(emptyList())
}
