package com.pillpal.pillpal

import androidx.core.content.FileProvider

/**
 * Serves the stored report PDFs to the viewer or share target the person
 * chose (docs/adr/0019 §5). A subclass of its own, so that it never merges
 * with another library's FileProvider declaration. Not exported; every Uri
 * carries a one-file read grant. Paths: `res/xml/report_paths.xml`.
 */
class ReportFileProvider : FileProvider()
