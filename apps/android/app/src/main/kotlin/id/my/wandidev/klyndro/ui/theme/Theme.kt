package id.my.wandidev.klyndro.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight

// A single brand palette on both platforms: a calm teal that reads as "connection"
// without borrowing another ecosystem's identity. Dynamic colour is deliberately not
// used, so the Android and macOS apps look like the same product.
private val LightColors = lightColorScheme(
    primary = Color(0xFF0B6E6E),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFB6E7E5),
    onPrimaryContainer = Color(0xFF00201F),
    secondary = Color(0xFF4A6572),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFCDE7F5),
    onSecondaryContainer = Color(0xFF001F2A),
    background = Color(0xFFF7FAFA),
    onBackground = Color(0xFF171D1D),
    surface = Color(0xFFF7FAFA),
    onSurface = Color(0xFF171D1D),
    surfaceVariant = Color(0xFFDAE5E4),
    onSurfaceVariant = Color(0xFF3F4948),
    outline = Color(0xFF6F7979),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF80D5D3),
    onPrimary = Color(0xFF003736),
    primaryContainer = Color(0xFF00504F),
    onPrimaryContainer = Color(0xFFB6E7E5),
    secondary = Color(0xFFB1CBD8),
    onSecondary = Color(0xFF1C3440),
    secondaryContainer = Color(0xFF334B57),
    onSecondaryContainer = Color(0xFFCDE7F5),
    background = Color(0xFF0E1514),
    onBackground = Color(0xFFDDE4E3),
    surface = Color(0xFF0E1514),
    onSurface = Color(0xFFDDE4E3),
    surfaceVariant = Color(0xFF3F4948),
    onSurfaceVariant = Color(0xFFBEC9C8),
    outline = Color(0xFF889392),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005)
)

private val KlyndroTypography = Typography().let { base ->
    base.copy(
        headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold)
    )
}

@Composable
fun KlyndroTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = KlyndroTypography,
        content = content
    )
}
