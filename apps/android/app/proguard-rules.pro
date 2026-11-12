# Klyndro release build rules.

# Wire messages are built and read through Gson JsonObject trees with explicit property names, so
# R8 renaming cannot change the JSON on the wire and no model class needs a keep rule. If a
# message ever moves to reflective Gson binding, its classes MUST be kept here.

# Registered by name in the manifest; the framework instantiates them reflectively.
-keep class id.my.wandidev.klyndro.service.KlyndroService
-keep class id.my.wandidev.klyndro.notifications.KlyndroNotificationListener

# BouncyCastle is used only to encode the identity certificate; it registers providers by
# class name.
-keep class org.bouncycastle.jcajce.provider.** { *; }
-keep class org.bouncycastle.jce.provider.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn javax.naming.**
