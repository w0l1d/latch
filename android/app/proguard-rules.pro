# R8 rules for the release build.
#
# Keep this file small. Every rule is code R8 can no longer remove or rename,
# and the default Flutter/AGP rules already cover the engine, the plugin method
# channels, and the Android framework entry points.
#
# What is *not* protected by a rule and must never grow to need one: any lookup
# by class name, field name, or method name from a string. If code starts doing
# that, add the narrowest keep rule that fixes it — never a package-wide wildcard.

# The SAF bridge sits between a Dart method channel and the framework. Today
# MainActivity calls it directly, so R8 already sees the use — these keeps are a
# belt for the day that stops being true, not a fix for a known break.
#
# Matched by class name, not by package: the application id/namespace move is
# its own change (the package was `com.latch.latch`, and is being renamed), and
# a rule pinned to one of them would silently stop protecting anything.
-keep class **.ExternalStorageDocIds { *; }
-keep class **.DocumentPathResolver { *; }
