/// Opaque, typed identifiers.
///
/// Each id is a value type wrapping a `String`. Two ids that share the same
/// underlying string but have different concrete types are **not** equal —
/// e.g. `PersonId('x') != WisaId('x')`. This prevents accidental cross-system
/// identity leakage (a `WisaId` should never silently flow into a slot that
/// expects a `PersonId`).
library;

/// Base for string-valued, runtime-type-discriminated identifiers.
abstract class StringId {
  final String value;

  const StringId(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other.runtimeType == runtimeType &&
          other is StringId &&
          other.value == value);

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => '$runtimeType($value)';

  String toJson() => value;
}

/// Local, stable identifier for a [Person]. Opaque UUID; not tied to any
/// external system.
final class PersonId extends StringId {
  const PersonId(super.value);
}

/// Primary identifier for a student or staff member in WISA.
final class WisaId extends StringId {
  const WisaId(super.value);
}

/// Staff-scope identifier in WISA. May or may not equal the `WisaId` for the
/// same person (see `docs/domain-model.md` OQ-1).
final class WisaStaffCode extends StringId {
  const WisaStaffCode(super.value);
}

/// Identifier for a [Group] (class or group node), scoped by [Origin].
final class GroupId extends StringId {
  const GroupId(super.value);
}

/// Identifier for a `LinkedAccount` produced by the linker.
final class LinkedAccountId extends StringId {
  const LinkedAccountId(super.value);
}
