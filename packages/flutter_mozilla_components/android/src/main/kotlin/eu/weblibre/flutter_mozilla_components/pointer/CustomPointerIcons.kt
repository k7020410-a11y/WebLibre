/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package eu.weblibre.flutter_mozilla_components.pointer

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.MotionEvent
import android.view.PointerIcon
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One cursor image as Dart sends it: PNG bytes and the hotspot in source pixels. */
class CustomCursorFrame(val png: ByteArray, val hotX: Int, val hotY: Int)

/**
 * The user's custom mouse cursor, as Android [PointerIcon]s.
 *
 * Android has no API for an animated pointer icon, so the two places the
 * cursor can be seen are handled differently:
 *
 *  * **Browser UI (Flutter).** Dart picks which frame to show and calls
 *    [frame]; the host sets it on the Flutter view. That is how an animated
 *    cursor plays there.
 *  * **Web pages (Gecko).** [resolveForPage] swaps in the first frame, and
 *    only where the page is asking for the plain arrow. Every other cursor a
 *    page asks for (text, hand, resize, grab, none, ...) is returned untouched.
 *
 * The icons only ever apply to this app's window: nothing here touches the
 * system pointer.
 */
object CustomPointerIcons {
    /** One source pixel in dp, so that a 32 px Windows cursor is about 19 dp. */
    private const val DP_PER_SOURCE_PIXEL = 0.6f

    /** Longest edge of a drawn icon. Larger ones are scaled down to fit. */
    private const val MAX_EDGE_DP = 64f

    private const val MIN_PERCENT = 25
    private const val MAX_PERCENT = 800
    private const val MAX_FRAMES = 512

    @Volatile
    private var frames: List<PointerIcon> = emptyList()

    /** What web pages get in place of the arrow; null while the feature is off. */
    @Volatile
    private var pageIcon: PointerIcon? = null

    @Volatile
    private var arrowIcon: PointerIcon? = null

    /**
     * Whether Samsung DeX, or Android's desktop UI mode, is active.
     *
     * DeX sets `Configuration.semDesktopModeEnabled`, a Samsung field read by
     * reflection because it is not part of the SDK; other devices report
     * [Configuration.UI_MODE_TYPE_DESKTOP].
     */
    fun isDesktopMode(context: Context): Boolean {
        val configuration = context.resources.configuration
        try {
            val field = configuration.javaClass.getField("semDesktopModeEnabled")
            if (field.getInt(configuration) == 1) return true
        } catch (_: ReflectiveOperationException) {
            // Not a Samsung build.
        } catch (_: RuntimeException) {
            // Blocked or unreadable: fall through to the standard check.
        }
        val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_DESKTOP
    }

    /**
     * Builds the icons for [specs] at [sizePercent] of the reference size and
     * starts overriding page cursors with the first one.
     *
     * Everything is decoded before anything is replaced, so a bad frame leaves
     * the previous cursor in place and throws instead.
     *
     * @throws IllegalArgumentException if a frame cannot be decoded.
     */
    fun configure(context: Context, specs: List<CustomCursorFrame>, sizePercent: Int) {
        require(specs.isNotEmpty()) { "No cursor frames" }
        require(specs.size <= MAX_FRAMES) { "Too many cursor frames" }

        val density = context.resources.displayMetrics.density
        val scale = sizePercent.coerceIn(MIN_PERCENT, MAX_PERCENT) / 100f *
            DP_PER_SOURCE_PIXEL * density
        val maxEdgePx = MAX_EDGE_DP * density

        // An animation that reuses a frame sends it more than once.
        val built = HashMap<FrameKey, PointerIcon>()
        val icons = specs.map { spec ->
            built.getOrPut(FrameKey(ByteBuffer.wrap(spec.png), spec.hotX, spec.hotY)) {
                buildIcon(spec, scale, maxEdgePx)
            }
        }

        frames = icons
        pageIcon = icons.first()
    }

    /** Stops overriding page cursors and drops the frames. */
    fun clear() {
        pageIcon = null
        frames = emptyList()
    }

    /** Frame [index] for the browser UI, wrapping; null while nothing is configured. */
    fun frame(index: Int): PointerIcon? {
        val current = frames
        if (current.isEmpty()) return null
        return current[Math.floorMod(index, current.size)]
    }

    /**
     * The icon a page's cursor should show.
     *
     * [resolved] is what the page itself asked for, as resolved by the view
     * hierarchy (null when it did not set one). Only the default arrow, which
     * is also what "no icon" means, is replaced. Mouse only: a stylus keeps its
     * own behaviour.
     */
    fun resolveForPage(
        context: Context,
        event: MotionEvent,
        pointerIndex: Int,
        resolved: PointerIcon?,
    ): PointerIcon? {
        val custom = pageIcon ?: return resolved
        if (event.getToolType(pointerIndex) != MotionEvent.TOOL_TYPE_MOUSE) return resolved
        if (resolved == null) return custom
        return if (resolved == arrow(context)) custom else resolved
    }

    private fun arrow(context: Context): PointerIcon {
        arrowIcon?.let { return it }
        return PointerIcon.getSystemIcon(context, PointerIcon.TYPE_ARROW).also { arrowIcon = it }
    }

    private fun buildIcon(spec: CustomCursorFrame, scale: Float, maxEdgePx: Float): PointerIcon {
        val source = BitmapFactory.decodeByteArray(spec.png, 0, spec.png.size)
            ?: throw IllegalArgumentException("Cursor frame is not a decodable image")

        val longest = max(source.width, source.height)
        val effective = min(scale, maxEdgePx / longest)
        val width = max(1, (source.width * effective).roundToInt())
        val height = max(1, (source.height * effective).roundToInt())

        // Nearest-neighbour when enlarging keeps pixel-art cursors crisp;
        // smoothing is only wanted when shrinking.
        val bitmap = if (width == source.width && height == source.height) {
            source
        } else {
            Bitmap.createScaledBitmap(source, width, height, width < source.width)
        }

        // The hotspot has to lie inside the bitmap or Android throws.
        val hotX = (spec.hotX.toFloat() * width / source.width).coerceIn(0f, (width - 1).toFloat())
        val hotY = (spec.hotY.toFloat() * height / source.height).coerceIn(0f, (height - 1).toFloat())
        return PointerIcon.create(bitmap, hotX, hotY)
    }

    private data class FrameKey(val png: ByteBuffer, val hotX: Int, val hotY: Int)
}
