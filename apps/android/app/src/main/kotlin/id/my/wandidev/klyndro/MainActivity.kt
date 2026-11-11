package id.my.wandidev.klyndro

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
        setContent {
            KlyndroTheme {
                KlyndroApp(viewModel = viewModel)
            }
        }
    }

    // Android only allows clipboard access to a focused app, so the clipboard loop is tied to the
    // Activity's visibility rather than to the service.
    override fun onResume() {
        super.onResume()
        viewModel.onResumed()
    }

    override fun onPause() {
        viewModel.onPaused()
        super.onPause()
    }
}
