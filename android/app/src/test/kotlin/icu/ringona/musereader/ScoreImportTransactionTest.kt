package icu.ringona.musereader

import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ScoreImportTransactionTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun copyFailurePreservesTheOldCollectionAndRemovesPartialCopies() {
        val directory = temporary.newFolder("imports")
        val old = File(directory, "old.mscx").apply { writeText("old score") }
        val failure = IOException("provider disconnected")

        val thrown = runCatching {
            replaceImportedScores(directory) { staging ->
                File(staging, "new.mscx").writeText("partial score")
                throw failure
            }
        }.exceptionOrNull()

        assertSame(failure, thrown)
        assertEquals("old score", old.readText())
        assertEquals(listOf("imports"), temporary.root.listFiles()!!.map { it.name })
        assertEquals(listOf("old.mscx"), directory.listFiles()!!.map { it.name })
    }

    @Test
    fun successfulImportReplacesTheCollectionAndReturnsPersistentPathsInOrder() {
        val directory = temporary.newFolder("imports")
        File(directory, "old.mscx").writeText("old score")
        File(directory, "cache").mkdir()
        val names = listOf("2_a.mscx", "1_b.mscz")

        val imported = replaceImportedScores(directory) { staging ->
            names.forEach { File(staging, it).writeText(it) }
            assertTrue(File(directory, "old.mscx").exists())
            names
        }

        assertEquals(names.map { File(directory, it).absolutePath }, imported)
        assertEquals(names, imported.map { File(it).readText() })
        assertFalse(File(directory, "old.mscx").exists())
        assertFalse(File(directory, "cache").exists())
        assertEquals(listOf("imports"), temporary.root.listFiles()!!.map { it.name })
    }

    @Test
    fun confirmedEmptyImportReplacesTheCollectionWithAnEmptyDirectory() {
        val directory = temporary.newFolder("imports")
        File(directory, "old.mscx").writeText("old score")

        assertTrue(replaceImportedScores(directory) { emptyList() }.isEmpty())
        assertTrue(directory.isDirectory)
        assertTrue(directory.listFiles()!!.isEmpty())
    }

    @Test
    fun reusedFilesAndTheirCachedSidecarsSurviveAnImport() {
        val directory = temporary.newFolder("imports")
        val sidecarSuffix = ".musereader-library-v1.json"
        val reused = File(directory, "1750000000000_kept.mscx")
            .apply { writeText("kept score") }
        val reusedSidecar = File(directory, reused.name + sidecarSuffix)
            .apply { writeText("{\"sourceModifiedUs\":1}") }
        val stale = File(directory, "1749999999999_dropped.mscx")
            .apply { writeText("dropped score") }
        val staleSidecar = File(directory, stale.name + sidecarSuffix)
            .apply { writeText("{\"sourceModifiedUs\":2}") }

        val keep = preservedImportNames(
            existing = directory.listFiles()!!.map { it.name },
            reused = setOf(reused.name),
            sidecarSuffixes = listOf(sidecarSuffix),
        )
        val imported = replaceImportedScores(directory, keep) { staging ->
            File(staging, "1750000000001_fresh.mscx").writeText("fresh score")
            listOf("1750000000001_fresh.mscx")
        }

        // The reused score keeps its bytes and its cache; the dropped one and
        // its cache are gone; the new copy is installed in the live directory.
        assertEquals("kept score", reused.readText())
        assertTrue(reusedSidecar.isFile)
        assertFalse(stale.exists())
        assertFalse(staleSidecar.exists())
        assertEquals(listOf(File(directory, "1750000000001_fresh.mscx").absolutePath), imported)
        assertEquals("fresh score", File(imported.single()).readText())
        assertEquals(
            listOf("1750000000000_kept.mscx", "1750000000000_kept.mscx$sidecarSuffix", "1750000000001_fresh.mscx"),
            directory.listFiles()!!.map { it.name }.sorted(),
        )
        assertEquals(listOf("imports"), temporary.root.listFiles()!!.map { it.name })
    }

    @Test
    fun preservedImportNamesKeepsOnlyReusedFilesAndTheirCaches() {
        val existing = listOf(
            "1750000000000_kept.mscx",
            "1750000000000_kept.mscx.musereader-library-v1.json",
            "1750000000000_kept.mscx.musereader-cover-v1.png",
            "1749999999999_dropped.mscx",
            "1749999999999_dropped.mscx.musereader-cover-v1.png",
            "notes.txt",
        )

        val keep = preservedImportNames(
            existing = existing,
            reused = setOf("1750000000000_kept.mscx"),
            sidecarSuffixes = listOf(
                ".musereader-library-v1.json",
                ".musereader-cover-v1.png",
            ),
        )

        assertEquals(
            setOf(
                "1750000000000_kept.mscx",
                "1750000000000_kept.mscx.musereader-library-v1.json",
                "1750000000000_kept.mscx.musereader-cover-v1.png",
            ),
            keep,
        )
        assertTrue(preservedImportNames(existing, emptySet(), emptyList()).isEmpty())
    }
}
