package com.pillpal.pillpal

import java.io.File

/** The path rule of the `pillpal/reports` channel; plain JVM code, unit-tested. */
object ReportPaths {
    /**
     * [candidate] resolved to its canonical form if it is a `.pdf` file
     * strictly inside [root] (itself canonicalised), else null. Symlinks and
     * `..` are resolved first, so neither can lead out; a sibling such as
     * `reports2` does not match because the root is compared with a trailing
     * separator.
     */
    fun validatedReportFile(root: File, candidate: File): File? {
        val canonicalRoot = root.canonicalFile
        val canonical = candidate.canonicalFile
        val inside = canonical.path.startsWith(canonicalRoot.path + File.separator)
        return if (inside && canonical.isFile && canonical.name.endsWith(".pdf")) {
            canonical
        } else {
            null
        }
    }
}
