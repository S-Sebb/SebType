package dev.sebb.sebtype.settext;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;
import java.util.List;

/**
 * Sets the text of the active window's index-th text field with ACTION_SET_TEXT, which bypasses
 * whichever keyboard is active:
 *   am instrument -w -e index N -e text T dev.sebb.sebtype.settext/.SetText
 * Prints result=set on success.
 */
public class SetText extends Instrumentation {
    private Bundle args;

    @Override
    public void onCreate(Bundle arguments) {
        args = arguments;
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        int code = 1;
        try {
            AccessibilityNodeInfo root = null;
            for (int i = 0; i < 20 && root == null; i++) {
                root = getUiAutomation().getRootInActiveWindow();
                if (root == null) SystemClock.sleep(250);
            }
            List<AccessibilityNodeInfo> fields = new ArrayList<>();
            collect(root, fields);
            Bundle text = new Bundle();
            text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, args.getString("text"));
            boolean set = fields.get(Integer.parseInt(args.getString("index")))
                    .performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text);
            result.putString("result", set ? "set" : "refused");
            if (set) code = 0;
        } catch (Exception e) {
            result.putString("result", e.toString());
        }
        finish(code, result);
    }

    private static void collect(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> fields) {
        if (node == null) return;
        if ("android.widget.EditText".contentEquals(String.valueOf(node.getClassName()))) fields.add(node);
        for (int i = 0; i < node.getChildCount(); i++) collect(node.getChild(i), fields);
    }
}
