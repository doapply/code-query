/**
 * Provides classes and predicates for guards that check for the current OS.
 */

import java
import semmle.code.java.controlflow.Guards
private import semmle.code.java.environment.SystemProperty
private import semmle.code.java.frameworks.apache.Lang
private import semmle.code.java.dataflow.DataFlow
private import semmle.code.java.dataflow.TaintTracking

/**
 * A guard that checks if the current OS is Windows.
 * When True, the OS is Windows.
 * When False, the OS is not Windows.
 */
abstract class IsWindowsGuard extends Guard { }

/**
 * A guard that checks if the current OS is a specific Windows variant.
 * When True, the OS is Windows.
 * When False, the OS *may* still be Windows.
 */
abstract class IsSpecificWindowsVariant extends Guard { }

/**
 * A guard that checks if the current OS is unix or unix-like.
 * When True, the OS is unix or unix-like.
 * When False, the OS is not unix or unix-like.
 */
abstract class IsUnixGuard extends Guard { }

/**
 * A guard that checks if the current OS is a specific unix or unix-like variant.
 * When True, the OS is unix or unix-like.
 * When False, the OS *may* still be unix or unix-like.
 */
abstract class IsSpecificUnixVariant extends Guard { }

/**
 * Holds when `ma` compares the current OS against the string constant `osString`.
 */
bindingset[osString]
private predicate isOsFromSystemProp(MethodAccess ma, string osString) {
  TaintTracking::localExprTaint(getSystemProperty("os.name"), ma.getQualifier()) and // Call from System.getProperty (or equivalent) to some partial match method
  exists(StringPartialMatchMethod m, CompileTimeConstantExpr matchedStringConstant |
    m = ma.getMethod() and
    matchedStringConstant.getStringValue().toLowerCase().matches(osString)
  |
    DataFlow::localExprFlow(matchedStringConstant, ma.getArgument(m.getMatchParameterIndex()))
  )
}

private class IsWindowsFromSystemProp extends IsWindowsGuard instanceof MethodAccess {
  IsWindowsFromSystemProp() { isOsFromSystemProp(this, "window%") }
}

/**
 * Holds when the Guard is an equality check between the system property with the name `propertyName`
 * and the string or char constant `compareToLiteral`, and the branch evaluates to `branch`.
 */
private Guard isOsFromSystemPropertyEqualityCheck(
  string propertyName, string compareToLiteral, boolean branch
) {
  result
      .isEquality(getSystemProperty(propertyName),
        any(Literal literal |
          (literal instanceof CharacterLiteral or literal instanceof StringLiteral) and
          literal.getValue() = compareToLiteral
        ), branch)
}

private class IsWindowsFromCharPathSeparator extends IsWindowsGuard {
  IsWindowsFromCharPathSeparator() {
    this = isOsFromSystemPropertyEqualityCheck("path.separator", ";", true) or
    this = isOsFromSystemPropertyEqualityCheck("path.separator", ":", false)
  }
}

private class IsWindowsFromCharSeparator extends IsWindowsGuard {
  IsWindowsFromCharSeparator() {
    this = isOsFromSystemPropertyEqualityCheck("file.separator", "\\", true) or
    this = isOsFromSystemPropertyEqualityCheck("file.separator", "/", false)
  }
}

private class IsUnixFromCharPathSeparator extends IsUnixGuard {
  IsUnixFromCharPathSeparator() {
    this = isOsFromSystemPropertyEqualityCheck("path.separator", ":", true) or
    this = isOsFromSystemPropertyEqualityCheck("path.separator", ";", false)
  }
}

private class IsUnixFromCharSeparator extends IsUnixGuard {
  IsUnixFromCharSeparator() {
    this = isOsFromSystemPropertyEqualityCheck("file.separator", "/", true) or
    this = isOsFromSystemPropertyEqualityCheck("file.separator", "\\", false)
  }
}

private class IsUnixFromSystemProp extends IsSpecificUnixVariant instanceof MethodAccess {
  IsUnixFromSystemProp() { isOsFromSystemProp(this, ["mac%", "linux%"]) }
}

bindingset[fieldNamePattern]
private predicate isOsFromApacheCommons(FieldAccess fa, string fieldNamePattern) {
  exists(Field f | f = fa.getField() |
    f.getDeclaringType() instanceof ApacheSystemUtils and
    f.getName().matches(fieldNamePattern)
  )
}

private class IsWindowsFromApacheCommons extends IsWindowsGuard instanceof FieldAccess {
  IsWindowsFromApacheCommons() { isOsFromApacheCommons(this, "IS_OS_WINDOWS") }
}

private class IsSpecificWindowsVariantFromApacheCommons extends IsSpecificWindowsVariant instanceof FieldAccess {
  IsSpecificWindowsVariantFromApacheCommons() { isOsFromApacheCommons(this, "IS_OS_WINDOWS_%") }
}

private class IsUnixFromApacheCommons extends IsUnixGuard instanceof FieldAccess {
  IsUnixFromApacheCommons() { isOsFromApacheCommons(this, "IS_OS_UNIX") }
}

private class IsSpecificUnixVariantFromApacheCommons extends IsSpecificUnixVariant instanceof FieldAccess {
  IsSpecificUnixVariantFromApacheCommons() {
    isOsFromApacheCommons(this,
      [
        "IS_OS_AIX", "IS_OS_HP_UX", "IS_OS_IRIX", "IS_OS_LINUX", "IS_OS_MAC%", "IS_OS_FREE_BSD",
        "IS_OS_OPEN_BSD", "IS_OS_NET_BSD", "IS_OS_SOLARIS", "IS_OS_SUN_OS", "IS_OS_ZOS"
      ])
  }
}

/**
 * A guard that checks if the `java.nio.file.FileSystem` supports posix file permissions.
 * This is often used to infer if the OS is unix-based and can generally be considered to be true for all unix-based OSes
 * ([source](https://en.wikipedia.org/wiki/POSIX#POSIX-oriented_operating_systems)).
 * Looks for calls to `contains("posix")` on the `supportedFileAttributeViews()` method returned by `FileSystem`.
 */
private class IsUnixFromPosixFromFileSystem extends IsUnixGuard instanceof MethodAccess {
  IsUnixFromPosixFromFileSystem() {
    exists(Method m | m = this.getMethod() |
      m.getDeclaringType()
          .getASupertype*()
          .getSourceDeclaration()
          .hasQualifiedName("java.util", "Set") and
      m.hasName("contains")
    ) and
    this.getArgument(0).(CompileTimeConstantExpr).getStringValue() = "posix" and
    exists(Method supportedFileAttributeViewsMethod |
      supportedFileAttributeViewsMethod.hasName("supportedFileAttributeViews") and
      supportedFileAttributeViewsMethod.getDeclaringType() instanceof TypeFileSystem
    |
      DataFlow::localExprFlow(any(MethodAccess ma |
          ma.getMethod() = supportedFileAttributeViewsMethod
        ), super.getQualifier())
    )
  }
}
