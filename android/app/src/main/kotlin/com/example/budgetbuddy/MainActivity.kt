package com.example.budgetbuddy

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File


class MainActivity : FlutterActivity() {
	private val CHANNEL = "budgetbuddy/media_store"

	override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"saveImageToMediaStore" -> {
					val filename = call.argument<String>("filename") ?: "receipt_${System.currentTimeMillis()}.jpg"
					val bytes = call.argument<ByteArray>("bytes")
					val mime = call.argument<String>("mime") ?: "image/jpeg"
					if (bytes == null) {
						result.error("invalid_args", "bytes missing", null)
						return@setMethodCallHandler
					}
					try {
						val uri = saveToMediaStore(filename, bytes, mime)
						result.success(uri?.toString())
					} catch (e: Exception) {
						result.error("save_failed", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun saveToMediaStore(filename: String, bytes: ByteArray, mime: String): android.net.Uri? {
		val resolver = contentResolver
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				// Insert into Images collection (Pictures/BudgetBuddy) so gallery apps show the image
				val values = ContentValues().apply {
					put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
					put(MediaStore.MediaColumns.MIME_TYPE, mime)
					put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/BudgetBuddy")
				}

				val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
				val uri = resolver.insert(collection, values) ?: return null
				resolver.openOutputStream(uri).use { out ->
					out?.write(bytes)
					out?.flush()
				}

				return uri
		} else {
			// Pre-Q: write to public Pictures/BudgetBuddy and request media scan so it appears in Gallery
			val picsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
			val folder = File(picsDir, "BudgetBuddy")
			if (!folder.exists()) folder.mkdirs()
			val outFile = File(folder, filename)
			outFile.outputStream().use { it.write(bytes) }
			// Ensure the file is discoverable by media providers
			MediaScannerConnection.scanFile(
				this,
				arrayOf(outFile.absolutePath),
				arrayOf(mime),
				null
			)
			return android.net.Uri.fromFile(outFile)
		}
	}
}
