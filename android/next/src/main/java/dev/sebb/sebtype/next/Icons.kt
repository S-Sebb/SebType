package dev.sebb.sebtype.next

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/** The keyboard's icons, drawn as square-cornered strokes on a 24-unit grid, so they suit the pixel look. */
object Icons {
    enum class Icon { SHIFT, SHIFT_ON, SHIFT_LOCKED, DELETE, ENTER, GLOBE, SEARCH, SEND, NEXT, PREVIOUS, DONE, MENU, MENU_OPEN, EXPAND, COLLAPSE, INCOGNITO,
        MORE, EMOJI, UNDO, REDO, CLIPBOARD, MODES, SELECT_ALL, COPY, CUT, PASTE, PIN, CLOSE, RECENT,
        STANDARD, ONE_HANDED, SPLIT, FLOATING, SWAP, PLUS, MINUS, DRAG }

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
            Icon.MORE -> {
                paint.style = Paint.Style.FILL
                for (x in listOf(6f, 12f, 18f)) canvas.drawCircle(x, 12f, 1.6f, paint)
            }
            Icon.EMOJI -> {
                canvas.drawCircle(12f, 12f, 9f, paint)
                path.moveTo(8f, 14f); path.quadTo(12f, 18f, 16f, 14f)
                canvas.drawPath(path, paint)
                paint.style = Paint.Style.FILL
                canvas.drawCircle(9f, 9.5f, 1.2f, paint)
                canvas.drawCircle(15f, 9.5f, 1.2f, paint)
            }
            Icon.UNDO, Icon.REDO -> {
                if (icon == Icon.REDO) canvas.scale(-1f, 1f, 12f, 12f)
                path.moveTo(9f, 5f); path.lineTo(5f, 9f); path.lineTo(9f, 13f)
                canvas.drawPath(path, paint)
                path.reset(); path.moveTo(5f, 9f); path.lineTo(14f, 9f); path.quadTo(19f, 9f, 19f, 14f); path.lineTo(19f, 19f)
                canvas.drawPath(path, paint)
            }
            Icon.CLIPBOARD, Icon.PASTE -> {
                canvas.drawRect(5f, 5f, 19f, 21f, paint)
                canvas.drawRect(9f, 3f, 15f, 7f, paint)
                if (icon == Icon.CLIPBOARD) for (y in listOf(11f, 14f, 17f)) canvas.drawLine(8.5f, y, 15.5f, y, paint)
            }
            Icon.MODES -> {
                canvas.drawRect(2.5f, 6f, 21.5f, 18f, paint)
                for (x in listOf(6f, 9.5f, 13f)) canvas.drawLine(x, 10f, x + 0.5f, 10f, paint)
                canvas.drawLine(7f, 14.5f, 17f, 14.5f, paint)
                canvas.drawCircle(18f, 10f, 1.6f, paint)
            }
            Icon.SELECT_ALL -> {
                paint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(2f, 2f), 0f)
                canvas.drawRect(4f, 4f, 20f, 20f, paint)
                paint.pathEffect = null
                canvas.drawRect(8f, 8f, 16f, 16f, paint)
            }
            Icon.COPY -> {
                canvas.drawRect(8f, 8f, 20f, 21f, paint)
                path.moveTo(5f, 17f); path.lineTo(5f, 4f); path.lineTo(16f, 4f)
                canvas.drawPath(path, paint)
            }
            Icon.CUT -> {
                canvas.drawCircle(7f, 17f, 3f, paint)
                canvas.drawCircle(17f, 17f, 3f, paint)
                canvas.drawLine(9f, 15f, 17f, 3f, paint)
                canvas.drawLine(15f, 15f, 7f, 3f, paint)
            }
            Icon.PIN -> {
                path.moveTo(9f, 3.5f); path.lineTo(15f, 3.5f); path.lineTo(14f, 10f); path.lineTo(17.5f, 14f)
                path.lineTo(6.5f, 14f); path.lineTo(10f, 10f); path.close()
                canvas.drawPath(path, paint)
                canvas.drawLine(12f, 14f, 12f, 21f, paint)
            }
            Icon.CLOSE -> {
                canvas.drawLine(6f, 6f, 18f, 18f, paint)
                canvas.drawLine(18f, 6f, 6f, 18f, paint)
            }
            Icon.RECENT -> {
                canvas.drawCircle(12f, 12f, 9f, paint)
                path.moveTo(12f, 6.5f); path.lineTo(12f, 12f); path.lineTo(16f, 14.5f)
                canvas.drawPath(path, paint)
            }
            // The modes: the keys' outline in the frame of the keyboard's space
            Icon.STANDARD, Icon.ONE_HANDED, Icon.SPLIT, Icon.FLOATING -> {
                canvas.drawRect(2.5f, 4f, 21.5f, 20f, paint)
                paint.style = Paint.Style.FILL
                when (icon) {
                    Icon.STANDARD -> canvas.drawRect(4.5f, 10f, 19.5f, 18f, paint)
                    Icon.ONE_HANDED -> canvas.drawRect(4.5f, 10f, 14.5f, 18f, paint)
                    Icon.SPLIT -> { canvas.drawRect(4.5f, 10f, 10f, 18f, paint); canvas.drawRect(14f, 10f, 19.5f, 18f, paint) }
                    else -> canvas.drawRect(7f, 8f, 17f, 14f, paint)
                }
            }
            Icon.SWAP -> {
                canvas.drawLine(4f, 9f, 19f, 9f, paint)
                path.moveTo(15f, 5f); path.lineTo(19f, 9f); path.lineTo(15f, 13f)
                canvas.drawPath(path, paint)
                canvas.drawLine(5f, 15f, 20f, 15f, paint)
                path.reset(); path.moveTo(9f, 11f); path.lineTo(5f, 15f); path.lineTo(9f, 19f)
                canvas.drawPath(path, paint)
            }
            Icon.PLUS, Icon.MINUS -> {
                canvas.drawLine(5f, 12f, 19f, 12f, paint)
                if (icon == Icon.PLUS) canvas.drawLine(12f, 5f, 12f, 19f, paint)
            }
            Icon.DRAG -> for (y in listOf(9f, 15f)) canvas.drawLine(5f, y, 19f, y, paint)
        }
        canvas.restore()
    }
}
