package id.my.wandidev.klyndro

import android.app.Application

/**
 * Process-wide entry point.
 *
 * M0 keeps this intentionally thin: the networking service, trust store, and clipboard
 * pipeline each get an explicit owner when they exist, rather than a speculative
 * dependency-injection graph.
 */
class KlyndroApplication : Application()
