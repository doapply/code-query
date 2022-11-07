package com.github.codeql

import com.github.codeql.utils.isExternalDeclaration
import com.github.codeql.utils.isExternalFileClassMember
import com.semmle.extractor.java.OdasaOutput
import com.semmle.util.data.StringDigestor
import org.jetbrains.kotlin.backend.common.extensions.IrPluginContext
import org.jetbrains.kotlin.ir.declarations.*
import org.jetbrains.kotlin.ir.util.fqNameWhenAvailable
import org.jetbrains.kotlin.ir.util.isFileClass
import org.jetbrains.kotlin.ir.util.packageFqName
import org.jetbrains.kotlin.ir.util.parentClassOrNull
import org.jetbrains.kotlin.name.FqName
import java.io.File
import java.util.ArrayList
import java.util.HashSet
import java.util.zip.GZIPOutputStream

class ExternalDeclExtractor(val logger: FileLogger, val invocationTrapFile: String, val sourceFilePath: String, val primitiveTypeMapping: PrimitiveTypeMapping, val pluginContext: IrPluginContext, val globalExtensionState: KotlinExtractorGlobalState, val diagnosticTrapWriter: TrapWriter) {

    val declBinaryNames = HashMap<IrDeclaration, String>()
    val externalDeclsDone = HashSet<Pair<String, String>>()
    val externalDeclWorkList = ArrayList<Pair<IrDeclaration, String>>()

    val propertySignature = ";property"
    val fieldSignature = ";field"

    fun extractLater(d: IrDeclarationWithName, signature: String): Boolean {
        if (d !is IrClass && !isExternalFileClassMember(d)) {
            logger.errorElement("External declaration is neither a class, nor a top-level declaration", d)
            return false
        }
        val declBinaryName = declBinaryNames.getOrPut(d) { getIrDeclBinaryName(d) }
        val ret = externalDeclsDone.add(Pair(declBinaryName, signature))
        if (ret) externalDeclWorkList.add(Pair(d, signature))
        return ret
    }
    fun extractLater(c: IrClass) = extractLater(c, "")

    fun extractExternalClasses() {
        val output = OdasaOutput(false, logger)
        output.setCurrentSourceFile(File(sourceFilePath))
        do {
            val nextBatch = ArrayList(externalDeclWorkList)
            externalDeclWorkList.clear()
            nextBatch.forEach { workPair ->
                val (irDecl, possiblyLongSignature) = workPair
                // In order to avoid excessively long signatures which can lead to trap file names longer than the filesystem
                // limit, we truncate and add a hash to preserve uniqueness if necessary.
                val signature = if (possiblyLongSignature.length > 100) {
                    possiblyLongSignature.substring(0, 92) + "#" + StringDigestor.digest(possiblyLongSignature).substring(0, 8)
                } else { possiblyLongSignature }
                output.getTrapLockerForDecl(irDecl, signature).useAC { locker ->
                    locker.trapFileManager.useAC { manager ->
                        val shortName = when(irDecl) {
                            is IrDeclarationWithName -> irDecl.name.asString()
                            else -> "(unknown name)"
                        }
                        if(manager == null) {
                            logger.info("Skipping extracting external decl $shortName")
                        } else {
                            val trapFile = manager.file
                            val trapTmpFile = File.createTempFile("${trapFile.nameWithoutExtension}.", ".${trapFile.extension}.tmp", trapFile.parentFile)

                            val containingClass = getContainingClassOrSelf(irDecl)
                            if (containingClass == null) {
                                logger.errorElement("Unable to get containing class", irDecl)
                                return
                            }
                            val binaryPath = getIrClassBinaryPath(containingClass)
                            try {
                                GZIPOutputStream(trapTmpFile.outputStream()).bufferedWriter().use { trapFileBW ->
                                    // We want our comments to be the first thing in the file,
                                    // so start off with a mere TrapWriter
                                    val tw = TrapWriter(logger.loggerBase, TrapLabelManager(), trapFileBW, diagnosticTrapWriter)
                                    tw.writeComment("Generated by the CodeQL Kotlin extractor for external dependencies")
                                    tw.writeComment("Part of invocation $invocationTrapFile")
                                    if (signature != possiblyLongSignature) {
                                        tw.writeComment("Function signature abbreviated; full signature is: $possiblyLongSignature")
                                    }
                                    // Now elevate to a SourceFileTrapWriter, and populate the
                                    // file information if needed:
                                    val ftw = tw.makeFileTrapWriter(binaryPath, true)

                                    val fileExtractor = KotlinFileExtractor(logger, ftw, null, binaryPath, manager, this, primitiveTypeMapping, pluginContext, KotlinFileExtractor.DeclarationStack(), globalExtensionState)

                                    if (irDecl is IrClass) {
                                        // Populate a location and compilation-unit package for the file. This is similar to
                                        // the beginning of `KotlinFileExtractor.extractFileContents` but without an `IrFile`
                                        // to start from.
                                        val pkg = irDecl.packageFqName?.asString() ?: ""
                                        val pkgId = fileExtractor.extractPackage(pkg)
                                        ftw.writeHasLocation(ftw.fileId, ftw.getWholeFileLocation())
                                        ftw.writeCupackage(ftw.fileId, pkgId)

                                        fileExtractor.extractClassSource(irDecl, extractDeclarations = !irDecl.isFileClass, extractStaticInitializer = false, extractPrivateMembers = false, extractFunctionBodies = false)
                                    } else {
                                        fileExtractor.extractDeclaration(irDecl, extractPrivateMembers = false, extractFunctionBodies = false)
                                    }
                                }

                                if (!trapTmpFile.renameTo(trapFile)) {
                                    logger.error("Failed to rename $trapTmpFile to $trapFile")
                                }
                            } catch (e: Exception) {
                                manager.setHasError()
                                logger.error("Failed to extract '$shortName'. Partial TRAP file location is $trapTmpFile", e)
                            }
                        }
                    }
                }
            }
        } while (externalDeclWorkList.isNotEmpty())
        output.writeTrapSet()
    }

}
