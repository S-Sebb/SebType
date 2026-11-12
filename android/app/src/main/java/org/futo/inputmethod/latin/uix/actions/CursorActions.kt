package org.futo.inputmethod.latin.uix.actions

import android.view.KeyEvent
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.Action

// SebType: the cursor keys of the Japanese layouts; they are not action-bar buttons (#182).

val ArrowLeftAction = Action(
    icon = R.drawable.chevron_left,
    name = R.string.action_cursor_left_title,
    simplePressImpl = { manager, _ ->
        manager.sendKeyEvent(KeyEvent.KEYCODE_DPAD_LEFT, 0)
    },
    windowImpl = null,
    shownInEditor = false,
)

val ArrowRightAction = Action(
    icon = R.drawable.chevron_right,
    name = R.string.action_cursor_right_title,
    simplePressImpl = { manager, _ ->
        manager.sendKeyEvent(KeyEvent.KEYCODE_DPAD_RIGHT, 0)
    },
    windowImpl = null,
    shownInEditor = false,
)
