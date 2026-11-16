package dev.sebb.sebtype.next

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/** The keyboard's icons, drawn as square-cornered strokes on a 24-unit grid, so they suit the pixel look. */
object Icons {
    enum class Icon { SHIFT, SHIFT_ON, SHIFT_LOCKED, DELETE, ENTER, GLOBE, SEARCH, SEND, NEXT, PREVIOUS, DONE, MENU, MENU_OPEN, EXPAND, COLLAPSE, INCOGNITO }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeJoin = Paint.Join.MITER
        strokeCap = Paint.Cap.SQUARE
    }
    private val path = Path()

    /** Draws [icon] centred at ([x], [y]), [size] pixels across. */
    fun draw(canvas: Canvas, icon: Icon, x: Float, y: Float, size: Float, color: Int) {
        val u = size / 24f
        canvas.save()
        canvas.translate(x - 12 * u, y - 12 * u)
        canvas.scale(u, u)
        paint.color = color
        paint.strokeWidth = 1.6f
        paint.style = Paint.Style.STROKE
        path.reset()
        when (icon) {
            Icon.SHIFT -> {
                path.moveTo(12f, 4f); path.lineTo(20f, 12f); path.lineTo(15.5f, 12f); path.lineTo(15.5f, 19f)
                path.lineTo(8.5f, 19f); path.lineTo(8.5f, 12f); path.lineTo(4f, 12f); path.close()
                canvas.drawPath(path, paint)
            }
            // On for one capital: a shorter arrow over a bar. Locked: the arrow filled.
            Icon.SHIFT_ON, Icon.SHIFT_LOCKED -> {
                path.moveTo(12f, 4f); path.lineTo(19.5f, 11f); path.lineTo(15.5f, 11f); path.lineTo(15.5f, 15.5f)
                path.lineTo(8.5f, 15.5f); path.lineTo(8.5f, 11f); path.lineTo(4.5f, 11f); path.close()
                if (icon == Icon.SHIFT_LOCKED) paint.style = Paint.Style.FILL_AND_STROKE
                canvas.drawPath(path, paint)
                canvas.drawLine(8.5f, 19f, 15.5f, 19f, paint)
            }
            Icon.DELETE -> {
                path.moveTo(8f, 5f); path.lineTo(21f, 5f); path.lineTo(21f, 19f); path.lineTo(8f, 19f); path.lineTo(2.5f, 12f); path.close()
                canvas.drawPath(path, paint)
                canvas.drawLine(11.5f, 9f, 17.5f, 15f, paint)
                canvas.drawLine(17.5f, 9f, 11.5f, 15f, paint)
            }
            Icon.ENTER -> {
                path.moveTo(19.5f, 8.5f); path.lineTo(19.5f, 13.5f); path.lineTo(4.5f, 13.5f)
                canvas.drawPath(path, paint)
                path.reset(); path.moveTo(8.5f, 9.5f); path.lineTo(4.5f, 13.5f); path.lineTo(8.5f, 17.5f)
                canvas.drawPath(path, paint)
            }
            Icon.GLOBE -> {
                canvas.drawCircle(12f, 12f, 9f, paint)
                canvas.drawOval(RectF(8f, 3f, 16f, 21f), paint)
                canvas.drawLine(3f, 12f, 21f, 12f, paint)
            }
            Icon.SEARCH -> {
                canvas.drawCircle(10f, 10f, 6f, paint)
                canvas.drawLine(14.5f, 14.5f, 20f, 20f, paint)
            }
            Icon.SEND -> {
                path.moveTo(3.5f, 4f); path.lineTo(21f, 12f); path.lineTo(3.5f, 20f); path.lineTo(6.5f, 12f); path.close()
                canvas.drawPath(path, paint)
                canvas.drawLine(6.5f, 12f, 13f, 12f, paint)
            }
            Icon.NEXT, Icon.PREVIOUS -> {
                if (icon == Icon.PREVIOUS) canvas.scale(-1f, 1f, 12f, 12f)
                canvas.drawLine(4f, 12f, 19f, 12f, paint)
                path.moveTo(13f, 6f); path.lineTo(19f, 12f); path.lineTo(13f, 18f)
                canvas.drawPath(path, paint)
            }
            Icon.DONE -> {
                path.moveTo(4f, 12.5f); path.lineTo(9.5f, 18f); path.lineTo(20f, 6.5f)
                canvas.drawPath(path, paint)
            }
            Icon.MENU, Icon.MENU_OPEN -> {
                if (icon == Icon.MENU_OPEN) canvas.scale(-1f, 1f, 12f, 12f)
                path.moveTo(9f, 5f); path.lineTo(16f, 12f); path.lineTo(9f, 19f)
                canvas.drawPath(path, paint)
            }
            Icon.EXPAND, Icon.COLLAPSE -> {
                if (icon == Icon.COLLAPSE) canvas.scale(1f, -1f, 12f, 12f)
                path.moveTo(5f, 9f); path.lineTo(12f, 16f); path.lineTo(19f, 9f)
                canvas.drawPath(path, paint)
            }
            Icon.INCOGNITO -> {
                // A hat over a pair of round glasses
                paint.style = Paint.Style.FILL
                path.moveTo(6f, 10f); path.lineTo(8f, 3.5f); path.lineTo(16f, 3.5f); path.lineTo(18f, 10f); path.close()
                canvas.drawPath(path, paint)
                canvas.drawRect(2f, 10f, 22f, 12f, paint)
                paint.style = Paint.Style.STROKE
                canvas.drawCircle(7.5f, 17f, 3.2f, paint)
                canvas.drawCircle(16.5f, 17f, 3.2f, paint)
                canvas.drawLine(10.7f, 17f, 13.3f, 17f, paint)
            }
        }
        canvas.restore()
    }
}
