package app.donottype.ui

import android.content.Context
import android.graphics.Typeface
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.TextViewCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.color.MaterialColors
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import app.donottype.R

/**
 * The one place the Android app decides what a screen looks like.
 *
 * Before this file the four activities each carried their own copy of `heading()` / `body()` /
 * `button()`, with the same magic numbers pasted four times -- so there was nowhere to make a
 * change that applied to the app. Worse, those copies measured in raw pixels: `setPadding(56, 64,
 * 56, 96)` is 21dp of gutter on a 2.6x screen and less on a denser one, which is most of why the
 * app read as cramped next to iOS. Everything here is dp from res/values/dimens.xml, and every
 * colour is a theme attribute so the DayNight theme actually reaches it.
 *
 * The vocabulary deliberately mirrors what SwiftUI's `Form` gives iOS for free -- section title,
 * grouped card of rows, section footer -- because matching the iOS information architecture was
 * the point. It is expressed in Material 3, not in a SwiftUI impression: an Android user should
 * recognise the controls, and only the layout and generosity should feel familiar from the phone
 * in the other pocket.
 */

// MARK: - Units

/** dp to px. Every dimension in this file goes through here or through a dimen resource. */
fun Context.dp(value: Int): Int =
    TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics,
    ).toInt()

private fun Context.dimen(id: Int): Int = resources.getDimensionPixelSize(id)

/** A theme attribute's colour, with the surface colour as the fallback if a theme omits it. */
fun Context.themeColor(attr: Int): Int =
    MaterialColors.getColor(this, attr, 0xFF000000.toInt())

private fun Context.themeStyle(attr: Int): Int {
    val out = TypedValue()
    return if (theme.resolveAttribute(attr, out, true)) out.resourceId else 0
}

private fun TextView.appearance(attr: Int) {
    val style = context.themeStyle(attr)
    if (style != 0) TextViewCompat.setTextAppearance(this, style)
}

// MARK: - Screen scaffold

/**
 * The scrolling column every screen is built into -- the equivalent of the `Form` iOS screens open
 * with. Returns the scroll view to set as the content view; add rows to the [column] it passes to
 * [content].
 *
 * The window insets are applied to the scroll view rather than to the column inside it, so that
 * clipToPadding keeps scrolled rows out from under the system bars too. Padding the column fixes
 * only the resting position: scroll down and the text runs under the clock. Android 15 draws every
 * app edge to edge whether it asked to or not, and a layout built in code gets no insets applied
 * for it -- without this the heading sits behind the status bar and the last row behind the
 * navigation bar, which is exactly how these screens looked on an API 35 device.
 */
fun Context.screenScaffold(content: (LinearLayout) -> Unit): ScrollView {
    val gutter = dimen(R.dimen.screen_gutter)
    val column = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(gutter, dimen(R.dimen.space_m), gutter, dimen(R.dimen.space_xxl))
    }
    content(column)
    return ScrollView(this).apply {
        clipToPadding = true
        addView(
            column,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
    }
}

/** The screen's own name, shown once at the top. NoActionBar, so this is the only title. */
fun Context.screenTitle(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceHeadlineMedium)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
    layoutParams = columnParams(bottom = dimen(R.dimen.space_s))
}

/** A one-line explanation under [screenTitle], for what the screen is for. */
fun Context.screenSubtitle(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceBodyMedium)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
    layoutParams = columnParams(bottom = dimen(R.dimen.space_m))
}

// MARK: - Sections

/**
 * A `Section` header. Uppercase-free and sentence-cased, like iOS's grouped list headers, sitting
 * on the window background above the card rather than inside it.
 */
fun Context.sectionTitle(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceTitleSmall)
    setTextColor(themeColor(com.google.android.material.R.attr.colorPrimary))
    layoutParams = columnParams(
        top = dimen(R.dimen.section_spacing),
        bottom = dimen(R.dimen.space_s),
        horizontal = dimen(R.dimen.space_xs),
    )
}

/**
 * A `Section` footer: the small print under a card that says what the setting above actually does.
 * iOS puts a lot of its explanation here, and copying that is most of why these screens can stay
 * uncluttered while remaining self-explanatory.
 */
fun Context.sectionFooter(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceBodySmall)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
    layoutParams = columnParams(
        top = dimen(R.dimen.space_s),
        horizontal = dimen(R.dimen.space_xs),
    )
}

/**
 * The grouped inset card a section's rows live in -- iOS's `.insetGrouped` list section.
 *
 * Flat (no elevation) on a container colour, which is the Material 3 reading of the same idea: the
 * grouping comes from the shape and the colour step, not from a shadow. Hairline dividers go
 * between rows automatically, so callers pass content and never separators.
 */
fun Context.card(vararg rows: View): MaterialCardView {
    val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    rows.forEachIndexed { index, row ->
        if (index > 0) body.addView(divider())
        body.addView(
            row,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
    }
    return MaterialCardView(this).apply {
        radius = dimen(R.dimen.card_corner).toFloat()
        cardElevation = 0f
        strokeWidth = 0
        setCardBackgroundColor(
            themeColor(com.google.android.material.R.attr.colorSurfaceContainerLow),
        )
        addView(
            body,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        layoutParams = columnParams()
    }
}

/**
 * [card] over a column the caller keeps a reference to, for the sections whose rows are rebuilt as
 * state changes -- history, the dictionary, the setup checklist. Those callers add their own
 * [divider]s, because only they know where a row ends.
 */
fun Context.cardHolding(body: LinearLayout): MaterialCardView = MaterialCardView(this).apply {
    radius = dimen(R.dimen.card_corner).toFloat()
    cardElevation = 0f
    strokeWidth = 0
    setCardBackgroundColor(themeColor(com.google.android.material.R.attr.colorSurfaceContainerLow))
    addView(
        body,
        ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ),
    )
    layoutParams = columnParams()
}

/**
 * A row built around a control that is too wide to sit at the end of a [settingRow] -- a spinner, a
 * group of radio buttons, a text field. The label goes above the control rather than beside it, so
 * a long provider name has the full width of the card to be read in.
 */
fun Context.controlRow(title: String?, control: View): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    val padding = dimen(R.dimen.space_m)
    setPadding(padding, dimen(R.dimen.space_s), padding, dimen(R.dimen.space_s))
    if (title != null) {
        addView(
            TextView(context).apply {
                text = title
                appearance(com.google.android.material.R.attr.textAppearanceBodyLarge)
                setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
                layoutParams = columnParams(bottom = dimen(R.dimen.space_xs))
            },
        )
    }
    addView(
        control,
        LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ),
    )
}

/**
 * A [settingRow] whose trailing control is a switch, and whose whole row toggles it. Reaching only
 * the switch itself is a small target for something this screen asks for repeatedly.
 */
fun Context.switchRow(
    title: String,
    detail: String? = null,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
): LinearLayout {
    val toggle = MaterialSwitch(this).apply {
        isChecked = checked
        setOnCheckedChangeListener { _, value -> onChange(value) }
    }
    return settingRow(title, detail, trailing = toggle) { toggle.toggle() }
}

/** The hairline between two rows of a [card]. Inset from the left, as iOS insets its separators. */
fun Context.divider(): View = View(this).apply {
    tag = DIVIDER_TAG
    setBackgroundColor(themeColor(com.google.android.material.R.attr.colorOutlineVariant))
    layoutParams = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        maxOf(1, dp(1) / 2),
    ).apply { leftMargin = dimen(R.dimen.space_m) }
}

private const val DIVIDER_TAG = "dnt-card-divider"

/**
 * Shows or hides a card row along with the hairline above it.
 *
 * Hiding the row alone leaves the separator behind, and a card that ends in a line with nothing
 * under it looks like a row that failed to draw rather than one that does not apply. Rows do
 * disappear here: the fallback key and delay are meaningless until a second service is chosen.
 */
fun View.setRowVisible(visible: Boolean) {
    visibility = if (visible) View.VISIBLE else View.GONE
    val parent = parent as? LinearLayout ?: return
    val index = parent.indexOfChild(this)
    if (index > 0) parent.getChildAt(index - 1).takeIf { it.tag == DIVIDER_TAG }?.visibility =
        visibility
}

// MARK: - Rows

/**
 * One row of a card: a title, optional secondary line, and an optional trailing control (a switch,
 * a value, a chevron). Tapping the row runs [onClick] if one is given, so the whole row is the
 * target rather than just the control -- the same affordance as an iOS list row.
 */
fun Context.settingRow(
    title: String,
    detail: String? = null,
    trailing: View? = null,
    onClick: (() -> Unit)? = null,
): LinearLayout {
    val labels = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        addView(
            TextView(context).apply {
                text = title
                appearance(com.google.android.material.R.attr.textAppearanceBodyLarge)
                setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
            },
        )
        if (detail != null) {
            addView(
                TextView(context).apply {
                    text = detail
                    appearance(com.google.android.material.R.attr.textAppearanceBodySmall)
                    setTextColor(
                        themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant),
                    )
                    layoutParams = LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                    ).apply { topMargin = dimen(R.dimen.space_xs) }
                },
            )
        }
    }
    return LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dimen(R.dimen.row_min_height)
        val padding = dimen(R.dimen.space_m)
        setPadding(padding, dimen(R.dimen.space_s), padding, dimen(R.dimen.space_s))
        addView(labels)
        if (trailing != null) {
            addView(
                trailing,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { leftMargin = dimen(R.dimen.space_m) },
            )
        }
        if (onClick != null) {
            isClickable = true
            isFocusable = true
            setBackgroundResource(context.themeStyle(android.R.attr.selectableItemBackground))
            setOnClickListener { onClick() }
        }
    }
}

/**
 * A setup step: the row iOS's `SetupRow` draws, with a leading mark for its state.
 *
 * [done] is deliberately nullable, matching iOS's three-way reading. `true` is done, `false` is not
 * done, and `null` is "no evidence either way" -- which is a real state on both platforms, because
 * whether the user has actually enabled the keyboard in system settings is something the app can
 * ask about but not always answer. A null shown as a red cross would be a lie.
 */
fun Context.setupRow(title: String, detail: String? = null, done: Boolean?): LinearLayout {
    val mark = TextView(this).apply {
        text = when (done) {
            true -> "✓"
            false -> "○"
            null -> "?"
        }
        appearance(com.google.android.material.R.attr.textAppearanceTitleMedium)
        setTextColor(
            when (done) {
                true -> androidx.core.content.ContextCompat.getColor(context, R.color.dnt_success)
                false -> themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant)
                null -> androidx.core.content.ContextCompat.getColor(context, R.color.dnt_warning)
            },
        )
        gravity = Gravity.CENTER
        minWidth = dp(24)
    }
    return settingRow(title, detail).apply {
        addView(
            mark,
            0,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                // Beside the title rather than centred on the whole row: with a two-line detail
                // underneath, a centred mark drifts down to the gap between the lines and stops
                // reading as the title's own state.
                gravity = Gravity.TOP
                rightMargin = dimen(R.dimen.space_m)
            },
        )
    }
}

// MARK: - Buttons

/** The one action a screen or section is mainly for. Filled, full width. */
fun Context.primaryButton(title: String, onClick: () -> Unit): MaterialButton =
    MaterialButton(this).apply {
        text = title
        minHeight = dimen(R.dimen.row_min_height)
        setOnClickListener { onClick() }
        layoutParams = columnParams(top = dimen(R.dimen.space_s))
    }

/** A secondary action that still deserves an outline -- "Test connection", "Retry". */
fun Context.tonalButton(title: String, onClick: () -> Unit): MaterialButton =
    MaterialButton(
        this,
        null,
        com.google.android.material.R.attr.materialButtonOutlinedStyle,
    ).apply {
        text = title
        minHeight = dimen(R.dimen.row_min_height)
        setOnClickListener { onClick() }
        layoutParams = columnParams(top = dimen(R.dimen.space_s))
    }

/** Navigation and small print -- "Open source licenses". No container. */
fun Context.textButton(title: String, onClick: () -> Unit): MaterialButton =
    MaterialButton(
        this,
        null,
        com.google.android.material.R.attr.borderlessButtonStyle,
    ).apply {
        text = title
        setOnClickListener { onClick() }
        layoutParams = columnParams(top = dimen(R.dimen.space_xs))
    }

// MARK: - Text

/** Ordinary running text on the window background, between sections. */
fun Context.body(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceBodyMedium)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
    layoutParams = columnParams(top = dimen(R.dimen.space_xs))
}

/** Small print -- iOS's `.footnote` in `.secondary`. */
fun Context.caption(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceBodySmall)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
    layoutParams = columnParams(top = dimen(R.dimen.space_xs))
}

/**
 * Machine output: connection-test results, log lines, request identifiers.
 *
 * Never given a line limit anywhere it is used. A failure that has been cut off at two lines is a
 * failure nobody can act on, and these strings exist precisely so they can be copied into a bug
 * report intact.
 */
fun Context.monospace(text: String): TextView = TextView(this).apply {
    this.text = text
    appearance(com.google.android.material.R.attr.textAppearanceBodySmall)
    setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
    setTypeface(Typeface.MONOSPACE)
    setTextIsSelectable(true)
    layoutParams = columnParams(top = dimen(R.dimen.space_s))
}

/** [monospace], recoloured for a result that is good news or bad. */
fun Context.statusText(text: String, isError: Boolean): TextView = monospace(text).apply {
    setTextColor(
        if (isError) {
            themeColor(com.google.android.material.R.attr.colorError)
        } else {
            androidx.core.content.ContextCompat.getColor(context, R.color.dnt_success)
        },
    )
}

// MARK: - Fields

/**
 * Wraps an existing editor in a labelled outlined field.
 *
 * Takes the [EditText] rather than building one, because every caller here keeps a reference to
 * the editor and reads it back later. The label persists above the text once you start typing,
 * which a bare `hint` does not -- a screen of half-filled fields whose hints have all vanished is
 * one of the things that made this app read as a prototype.
 *
 * The shell is inflated from res/layout/dnt_field.xml; see that file for why it cannot be
 * constructed here. Because the editor comes from the caller it misses the box style's own
 * editText overlay, so the padding the outlined box needs is applied to it directly.
 */
fun Context.fieldContainer(
    label: String,
    field: EditText,
    password: Boolean = false,
    helper: String? = null,
): TextInputLayout =
    (LayoutInflater.from(this).inflate(R.layout.dnt_field, null, false) as TextInputLayout).apply {
        hint = label
        helperText = helper
        isHelperTextEnabled = helper != null
        // A key you cannot read back is a key you cannot check a typo in.
        if (password) endIconMode = TextInputLayout.END_ICON_PASSWORD_TOGGLE
        val inset = dimen(R.dimen.space_m)
        field.background = null
        field.setPadding(inset, inset, inset, inset)
        addView(
            field,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        layoutParams = columnParams(top = dimen(R.dimen.space_s))
    }

/** [fieldContainer] over an editor it builds itself, for callers that only need the text once. */
fun Context.textField(
    label: String,
    value: String = "",
    helper: String? = null,
    password: Boolean = false,
    configure: (TextInputEditText) -> Unit = {},
): TextInputLayout {
    val field = TextInputEditText(this).apply {
        setText(value)
        if (password) {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        configure(this)
    }
    return fieldContainer(label, field, password, helper)
}

// MARK: - Layout params

/** Full-width column params with the margins these builders share. */
fun Context.columnParams(
    top: Int = 0,
    bottom: Int = 0,
    horizontal: Int = 0,
): LinearLayout.LayoutParams =
    LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
        topMargin = top
        bottomMargin = bottom
        leftMargin = horizontal
        rightMargin = horizontal
    }
