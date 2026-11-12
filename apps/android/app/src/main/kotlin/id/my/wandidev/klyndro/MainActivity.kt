package id.my.wandidev.klyndro

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import id.my.wandidev.klyndro.ui.KlyndroApp
import id.my.wandidev.klyndro.ui.KlyndroViewModel
import id.my.wandidev.klyndro.ui.theme.KlyndroTheme

class MainActivity : ComponentActivity() {

    private val viewModel: KlyndroViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleShareIntent(intent)
        setContent {
            KlyndroTheme {
                KlyndroApp(viewModel = viewModel)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    // Android only allows clipboard access to a focused app, so the clipboard loop is tied to the
    // Activity's visibility rather than to the service.
    override fun onResume() {
        super.onResume()
        viewModel.onResumed()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            viewModel.onWindowFocused()
        }
    }

    override fun onPause() {
        viewModel.onPaused()
        super.onPause()
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val shared = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            viewModel.sendTextToMac(shared)
            intent.action = null
        }
    }
}
