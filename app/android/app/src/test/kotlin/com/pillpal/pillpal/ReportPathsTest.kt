package com.pillpal.pillpal

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

class ReportPathsTest {
    private lateinit var base: File
    private lateinit var root: File

    @Before
    fun setUp() {
        base = Files.createTempDirectory("pillpal-paths").toFile().canonicalFile
        root = File(base, "reports").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        base.deleteRecursively()
    }

    private fun pdf(dir: File, name: String = "pillpal-report-a.pdf"): File {
        dir.mkdirs()
        return File(dir, name).apply { writeBytes(byteArrayOf(1)) }
    }

    @Test
    fun acceptsAPdfInsideTheRoot() {
        val file = pdf(File(root, "id-1"))
        assertEquals(file, ReportPaths.validatedReportFile(root, file))
    }

    @Test
    fun rejectsDotDotThatLeavesTheRoot() {
        val outside = pdf(File(base, "secret"))
        val sneaky = File(root, "id-1/../../secret/" + outside.name)
        assertNull(ReportPaths.validatedReportFile(root, sneaky))
    }

    @Test
    fun acceptsDotDotThatStaysInside() {
        val file = pdf(File(root, "id-2"))
        val roundabout = File(root, "id-1/../id-2/" + file.name)
        assertEquals(file, ReportPaths.validatedReportFile(root, roundabout))
    }

    @Test
    fun rejectsASymlinkLeadingOutside() {
        val outside = pdf(File(base, "secret"))
        val link = File(root, "link.pdf")
        try {
            Files.createSymbolicLink(link.toPath(), outside.toPath())
        } catch (error: Exception) {
            assumeTrue("symlinks are not available here", false)
        }
        assertNull(ReportPaths.validatedReportFile(root, link))
    }

    @Test
    fun rejectsASiblingFolderWithTheSamePrefix() {
        val evil = pdf(File(base, "reports-evil/id-1"))
        val two = pdf(File(base, "reports2/id-1"))
        assertNull(ReportPaths.validatedReportFile(root, evil))
        assertNull(ReportPaths.validatedReportFile(root, two))
    }

    @Test
    fun rejectsTheRootItselfAndAFolder() {
        val folder = File(root, "id-1").apply { mkdirs() }
        assertNull(ReportPaths.validatedReportFile(root, root))
        assertNull(ReportPaths.validatedReportFile(root, folder))
    }

    @Test
    fun rejectsAFileThatIsNotAPdf() {
        val file = pdf(File(root, "id-1"), "notes.txt")
        assertNull(ReportPaths.validatedReportFile(root, file))
    }

    @Test
    fun rejectsAMissingFile() {
        val missing = File(root, "id-1/pillpal-report-a.pdf")
        assertNull(ReportPaths.validatedReportFile(root, missing))
    }
}
