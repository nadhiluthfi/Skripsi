package com.polar.polarsensordatacollector.ui.graph

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.fragment.app.DialogFragment
import com.polar.polarsensordatacollector.R
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class HrGraphFragment : DialogFragment() {

    override fun getTheme(): Int = R.style.Theme_GraphDialog

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return ComposeView(requireContext()).apply {
            setViewCompositionStrategy(
                ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed
            )
            setContent {
                HrGraphView(
                    onClose = { dismiss() }
                )
            }
        }
    }
}
