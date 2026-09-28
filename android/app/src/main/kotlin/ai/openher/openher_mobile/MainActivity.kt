package ai.openher.openher_mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Canal de plataforma para instalar el APK descargado.
 *
 * Dart no puede abrir un intent de instalación por sí solo: hace falta la
 * authority de un `FileProvider` (Android 7+ forbids `file://`) y el permiso
 * `REQUEST_INSTALL_PACKAGES`. Todo eso vive acá; Dart sólo pasa la ruta.
 *
 * También expone `updatesDir`: la carpeta donde se guarda el APK. Vive acá a
 * propósito — es la misma que declara `res/xml/file_paths.xml`, y así hay una
 * sola fuente de verdad (agregar `path_provider` en Dart sería una dep más
 * para leer algo que este archivo ya sabe).
 */
class MainActivity : FlutterActivity() {

    private val channel = "ai.openher/install"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canInstall())
                    "updatesDir" -> result.success(updatesDir())
                    // El `versionCode` real del build. Dart lo necesita para
                    // comparar contra el del manifiesto: Android rechaza
                    // instalar un APK con un versionCode menor o igual. Se lee
                    // del paquete instalado (no de `BuildConfig`, que exige
                    // encender `buildFeatures.buildConfig`) y por lo tanto es
                    // exactamente el número con el que Android decide.
                    "versionCode" -> result.success(installedVersionCode())
                    "versionName" -> result.success(installedVersionName())
                    "install" -> {
                        val path = call.argument<String>("path")
                        result.success(install(path))
                    }
                    "openInstallSettings" -> result.success(openInstallSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Carpeta compartida con el `FileProvider`. `cacheDir` es lo correcto: es
     * lo único que el sistema puede borrar solo, así que un APK de 50 MB
     * huérfano no se queda ocupando espacio para siempre.
     */
    private fun updatesDir(): String {
        val dir = File(cacheDir, "updates")
        if (!dir.exists()) dir.mkdirs()
        return dir.absolutePath
    }

    /** Android 8+ pregunta al usuario una sola vez; el chequeo evita el crash. */
    private fun canInstall(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun installedVersionCode(): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageManager.getPackageInfo(packageName, 0).longVersionCode.toInt()
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0).versionCode
            }
        } catch (e: Exception) {
            -1
        }
    }

    private fun installedVersionName(): String? {
        return try {
            packageManager.getPackageInfo(packageName, 0).versionName
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Cuando falta el permiso, `install()` no sirve de nada: Android no deja
     * abrir el instalador. Se manda al usuario a la pantalla que lo concede.
     */
    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun install(path: String?): Boolean {
        if (path == null) return false
        val file = File(path)
        if (!file.exists()) return false
        if (!canInstall()) return false
        return try {
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
