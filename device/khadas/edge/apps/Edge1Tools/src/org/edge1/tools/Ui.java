package org.edge1.tools;

import android.view.View;
import android.widget.ImageView;
import android.widget.Switch;
import android.widget.TextView;

/** Small helpers for the Material 3 rows and tiles (res/layout/row_*.xml, item_*.xml). */
final class Ui {
    private Ui() {}

    /**
     * What the remote is on grows a little and comes forward, over its neighbours:
     * with the focus ring (res/drawable/bg_tile.xml), Material's focus state at TV
     * distance.
     */
    static void zoomOnFocus(View v) {
        final float lift = 6 * v.getResources().getDisplayMetrics().density;
        v.setOnFocusChangeListener((view, focused) -> view.animate()
                .scaleX(focused ? 1.03f : 1f)
                .scaleY(focused ? 1.03f : 1f)
                .translationZ(focused ? lift : 0f)
                .setDuration(120)
                .start());
    }

    /** Fills in a row_nav or row_switch and makes it a control. */
    static View row(View row, CharSequence title, CharSequence summary, int icon,
            View.OnClickListener onClick) {
        text(row, R.id.title, title);
        text(row, R.id.summary, summary);
        ImageView iv = row.findViewById(R.id.icon);
        if (iv != null && icon != 0) {
            iv.setImageResource(icon);
            iv.setVisibility(View.VISIBLE);
        }
        row.setOnClickListener(onClick);
        zoomOnFocus(row);
        return row;
    }

    static void text(View row, int id, CharSequence s) {
        TextView t = row.findViewById(id);
        if (t == null) return;
        t.setText(s);
        t.setVisibility(s == null || s.length() == 0 ? View.GONE : View.VISIBLE);
    }

    static void checked(View row, boolean on) {
        Switch s = row.findViewById(R.id.toggle);
        if (s != null) s.setChecked(on);
    }

    /** The trailing label of a row_nav or item_app; null hides it. */
    static void action(View row, CharSequence s) {
        text(row, R.id.action, s);
    }
}
