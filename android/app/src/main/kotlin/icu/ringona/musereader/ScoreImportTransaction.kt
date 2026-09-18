package icu.ringona.musereader

import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * Replace the imported collection without ever leaving it half written.
 *
 * [populate] fills a fresh staging directory with the files that have to be
 * copied and returns their live names. It runs before anything inside
 * [directory] is touched, so a provider that fails mid-copy leaves the previous
 * collection exactly as it was — the caller can report the failure while the
 * library still holds the scores it had.
 *
 * [keep] names the existing entries that must survive the import: the files
 * reused in place plus the cached sidecars that belong to them. Everything else
 * in [directory] is stale and is removed once the new files are staged, which
 * also drops the caches of scores the folder no longer contains.
 */
internal fun replaceImportedScores(
    directory: File,
    keep: Set<String> = emptySet(),
    populate: (File) -> List<String>,
): List<String> {
    val parent = requireNotNull(directory.parentFile)
    val transaction = UUID.randomUUID().toString()
    val staging = File(parent, "${directory.name}-$transaction.staging")
    check(staging.mkdir()) { "Cannot prepare the import directory." }
    val staged: List<String>
    try {
        staged = populate(staging)
    } catch (error: Throwable) {
        staging.deleteRecursively()
        throw error
    }
    try {
        directory.listFiles()?.forEach { entry ->
            if (entry.name !in keep) entry.deleteRecursively()
        }
        staged.forEach { name ->
            val source = File(staging, name)
            if (!source.renameTo(File(directory, name))) {
                throw IOException("Cannot install the imported collection.")
            }
        }
    } finally {
        staging.deleteRecursively()
    }
    return staged.map { File(directory, it).absolutePath }
}

/**
 * The entries an import must leave alone: [reused] plus the sidecars cached
 * next to them (a sidecar is named after its file, for example
 * `1750000000000_alpha.mscx.musereader-library-v1.json`). Returning names
 * rather than files keeps the decision testable without a device.
 */
internal fun preservedImportNames(
    existing: Collection<String>,
    reused: Set<String>,
    sidecarSuffixes: Collection<String>,
): Set<String> = existing.filterTo(HashSet()) { name ->
    name in reused ||
        sidecarSuffixes.any { suffix ->
            name.endsWith(suffix) && name.dropLast(suffix.length) in reused
        }
}
