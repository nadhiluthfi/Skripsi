package com.polar.polarsensordatacollector.ui.landing

import android.Manifest
import android.content.Intent
import android.content.res.Resources
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.navigation.fragment.NavHostFragment
import androidx.navigation.ui.AppBarConfiguration
import androidx.navigation.ui.onNavDestinationSelected
import androidx.navigation.ui.setupWithNavController
import com.polar.androidcommunications.api.ble.model.polar.BlePolarDeviceCapabilitiesUtility
import com.polar.polarsensordatacollector.R
import com.polar.polarsensordatacollector.repository.PolarDeviceRepository
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity: AppCompatActivity() {
    @Inject lateinit var polarDeviceRepository: PolarDeviceRepository

    companion object {
        private val TAG = MainActivity::class.java.simpleName
        private const val PERMISSION_REQUEST_CODE = 1
        private const val MANAGE_EXTERNAL_STORAGE_REQUEST_CODE = 99
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Shutting down Polar Sensor Data Collector app, shutting down Polar SDK")
        polarDeviceRepository.sdkShutDown()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        val navHostFragment =
            supportFragmentManager.findFragmentById(R.id.nav_host_fragment) as NavHostFragment
        val navController = navHostFragment.navController

        val topAppBar = findViewById<Toolbar>(R.id.top_tool_bar)
        val appBarConfiguration = AppBarConfiguration(navController.graph)
        topAppBar.setupWithNavController(navController, appBarConfiguration)
        topAppBar.setOnMenuItemClickListener { item ->
            item.onNavDestinationSelected(navController) || super.onOptionsItemSelected(item)
        }

        navController.addOnDestinationChangedListener { _, destination, _ ->
            val dest: String = try {
                resources.getResourceName(destination.id)
            } catch (e: Resources.NotFoundException) {
                destination.id.toString()
            }

            // Set the settings invisible in other than main destination
            topAppBar.menu.findItem(R.id.settings_dest).isVisible = destination.id == R.id.mainFragment
            topAppBar.menu.findItem(R.id.about_dest).isVisible = destination.id == R.id.mainFragment

            // Debugging of navigation
            //Toast.makeText(this@NewMainActivity, "Navigated to $dest", Toast.LENGTH_SHORT).show()
            Log.d("Navigation", "Navigated to $dest")
            //navController.backQueue.mapNotNull { dest ->
            //    Log.d("Navigation", "Current back stack $dest")
            //}
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST_CODE)
            } else {
                requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), PERMISSION_REQUEST_CODE)
            }
        }

        requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), PERMISSION_REQUEST_CODE)

        // Request permission for external polar device capabilities config file
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                Log.d(TAG, "Requesting MANAGE_EXTERNAL_STORAGE permission")
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                intent.data = android.net.Uri.parse("package:$packageName")
                startActivityForResult(intent, MANAGE_EXTERNAL_STORAGE_REQUEST_CODE)
            } else {
                Log.d(TAG, "All files access already granted")
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            Log.d(TAG, "bt ready")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MANAGE_EXTERNAL_STORAGE_REQUEST_CODE) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) {
                Log.d(TAG, "All files access granted by user")
                BlePolarDeviceCapabilitiesUtility.initialize(this.applicationContext)
            } else {
                Log.e(TAG, "All files access denied")
            }
        }
    }
}
