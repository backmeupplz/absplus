package com.borodutch.absplus

import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.google.android.material.textfield.TextInputLayout
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

/** Sign-in and link-account fields: the password is masked as typed, the toggle reveals it, every field is one line. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PasswordFieldTest {
    private lateinit var controller: org.robolectric.android.controller.ActivityController<Main>
    private lateinit var activity: Main

    @Before fun setUp() {
        controller = Robolectric.buildActivity(Main::class.java).create()
        activity = controller.get()
        Abs.p.edit().clear().putString("server", "http://127.0.0.1:1").commit()
    }

    @After fun tearDown() {
        ShadowDialog.getLatestDialog()?.dismiss()
        Abs.p.edit().clear().commit()
        controller.destroy()
    }

    private fun call(name: String, vararg args: Any) = Main::class.java.declaredMethods
        .single { it.name == name }.apply { isAccessible = true }.invoke(activity, *args)
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun content() = Main::class.java.getDeclaredField("content").apply { isAccessible = true }.get(activity) as FrameLayout

    private fun check(root: View, hints: List<String>) {
        val layouts = views(root).filterIsInstance<TextInputLayout>()
        assertEquals(hints, layouts.map { it.hint.toString() })
        for (l in layouts) {
            val e = l.editText!!
            assertTrue("${l.hint} is one line", e.isSingleLine)
            assertEquals("${l.hint} stays one line", 1, e.maxLines)
        }
        val pass = layouts.single { it.hint == "Password" }
        val e = pass.editText!!
        assertEquals(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, e.inputType)
        assertEquals(TextInputLayout.END_ICON_PASSWORD_TOGGLE, pass.endIconMode)
        e.setText("demo")
        assertTrue("password masked as typed", e.transformationMethod is PasswordTransformationMethod)
        assertNotEquals("demo", e.layout?.text?.toString() ?: e.transformationMethod.getTransformation(e.text, e).toString())
        val toggle = views(pass).single { it.id == com.google.android.material.R.id.text_input_end_icon }
        toggle.performClick()
        assertFalse("toggle reveals the password", e.transformationMethod is PasswordTransformationMethod)
        assertTrue("revealed password stays one line", e.isSingleLine)
        toggle.performClick()
        assertTrue("toggle hides the password again", e.transformationMethod is PasswordTransformationMethod)
        for (l in layouts - pass) assertFalse("${l.hint} is not masked", l.editText!!.transformationMethod is PasswordTransformationMethod)
    }

    @Test fun signInMasksPassword() {
        call("login")
        check(content(), listOf("Server URL", "Username", "Password"))
    }

    @Test fun linkAccountMasksPassword() {
        call("addAccount", {})
        val dialog = ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        check(dialog.window!!.decorView, listOf("Username", "Password"))
    }
}
