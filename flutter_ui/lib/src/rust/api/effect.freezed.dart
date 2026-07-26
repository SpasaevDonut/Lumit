// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'effect.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$BridgeEffectValue {
  Object? get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'BridgeEffectValue(field0: $field0)';
  }
}

/// @nodoc
class $BridgeEffectValueCopyWith<$Res> {
  $BridgeEffectValueCopyWith(
      BridgeEffectValue _, $Res Function(BridgeEffectValue) __);
}

/// Adds pattern-matching-related methods to [BridgeEffectValue].
extension BridgeEffectValuePatterns on BridgeEffectValue {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(BridgeEffectValue_Float value)? float,
    TResult Function(BridgeEffectValue_Point value)? point,
    TResult Function(BridgeEffectValue_Colour value)? colour,
    TResult Function(BridgeEffectValue_Bool value)? bool,
    TResult Function(BridgeEffectValue_Choice value)? choice,
    TResult Function(BridgeEffectValue_Seed value)? seed,
    TResult Function(BridgeEffectValue_File value)? file,
    TResult Function(BridgeEffectValue_Layer value)? layer,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float() when float != null:
        return float(_that);
      case BridgeEffectValue_Point() when point != null:
        return point(_that);
      case BridgeEffectValue_Colour() when colour != null:
        return colour(_that);
      case BridgeEffectValue_Bool() when bool != null:
        return bool(_that);
      case BridgeEffectValue_Choice() when choice != null:
        return choice(_that);
      case BridgeEffectValue_Seed() when seed != null:
        return seed(_that);
      case BridgeEffectValue_File() when file != null:
        return file(_that);
      case BridgeEffectValue_Layer() when layer != null:
        return layer(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(BridgeEffectValue_Float value) float,
    required TResult Function(BridgeEffectValue_Point value) point,
    required TResult Function(BridgeEffectValue_Colour value) colour,
    required TResult Function(BridgeEffectValue_Bool value) bool,
    required TResult Function(BridgeEffectValue_Choice value) choice,
    required TResult Function(BridgeEffectValue_Seed value) seed,
    required TResult Function(BridgeEffectValue_File value) file,
    required TResult Function(BridgeEffectValue_Layer value) layer,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float():
        return float(_that);
      case BridgeEffectValue_Point():
        return point(_that);
      case BridgeEffectValue_Colour():
        return colour(_that);
      case BridgeEffectValue_Bool():
        return bool(_that);
      case BridgeEffectValue_Choice():
        return choice(_that);
      case BridgeEffectValue_Seed():
        return seed(_that);
      case BridgeEffectValue_File():
        return file(_that);
      case BridgeEffectValue_Layer():
        return layer(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(BridgeEffectValue_Float value)? float,
    TResult? Function(BridgeEffectValue_Point value)? point,
    TResult? Function(BridgeEffectValue_Colour value)? colour,
    TResult? Function(BridgeEffectValue_Bool value)? bool,
    TResult? Function(BridgeEffectValue_Choice value)? choice,
    TResult? Function(BridgeEffectValue_Seed value)? seed,
    TResult? Function(BridgeEffectValue_File value)? file,
    TResult? Function(BridgeEffectValue_Layer value)? layer,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float() when float != null:
        return float(_that);
      case BridgeEffectValue_Point() when point != null:
        return point(_that);
      case BridgeEffectValue_Colour() when colour != null:
        return colour(_that);
      case BridgeEffectValue_Bool() when bool != null:
        return bool(_that);
      case BridgeEffectValue_Choice() when choice != null:
        return choice(_that);
      case BridgeEffectValue_Seed() when seed != null:
        return seed(_that);
      case BridgeEffectValue_File() when file != null:
        return file(_that);
      case BridgeEffectValue_Layer() when layer != null:
        return layer(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(BridgeScalar field0)? float,
    TResult Function(BridgePoint field0)? point,
    TResult Function(BridgeColour field0)? colour,
    TResult Function(bool field0)? bool,
    TResult Function(int field0)? choice,
    TResult Function(int field0)? seed,
    TResult Function(BridgeFileParam field0)? file,
    TResult Function(UuidValue? field0)? layer,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float() when float != null:
        return float(_that.field0);
      case BridgeEffectValue_Point() when point != null:
        return point(_that.field0);
      case BridgeEffectValue_Colour() when colour != null:
        return colour(_that.field0);
      case BridgeEffectValue_Bool() when bool != null:
        return bool(_that.field0);
      case BridgeEffectValue_Choice() when choice != null:
        return choice(_that.field0);
      case BridgeEffectValue_Seed() when seed != null:
        return seed(_that.field0);
      case BridgeEffectValue_File() when file != null:
        return file(_that.field0);
      case BridgeEffectValue_Layer() when layer != null:
        return layer(_that.field0);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(BridgeScalar field0) float,
    required TResult Function(BridgePoint field0) point,
    required TResult Function(BridgeColour field0) colour,
    required TResult Function(bool field0) bool,
    required TResult Function(int field0) choice,
    required TResult Function(int field0) seed,
    required TResult Function(BridgeFileParam field0) file,
    required TResult Function(UuidValue? field0) layer,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float():
        return float(_that.field0);
      case BridgeEffectValue_Point():
        return point(_that.field0);
      case BridgeEffectValue_Colour():
        return colour(_that.field0);
      case BridgeEffectValue_Bool():
        return bool(_that.field0);
      case BridgeEffectValue_Choice():
        return choice(_that.field0);
      case BridgeEffectValue_Seed():
        return seed(_that.field0);
      case BridgeEffectValue_File():
        return file(_that.field0);
      case BridgeEffectValue_Layer():
        return layer(_that.field0);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(BridgeScalar field0)? float,
    TResult? Function(BridgePoint field0)? point,
    TResult? Function(BridgeColour field0)? colour,
    TResult? Function(bool field0)? bool,
    TResult? Function(int field0)? choice,
    TResult? Function(int field0)? seed,
    TResult? Function(BridgeFileParam field0)? file,
    TResult? Function(UuidValue? field0)? layer,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeEffectValue_Float() when float != null:
        return float(_that.field0);
      case BridgeEffectValue_Point() when point != null:
        return point(_that.field0);
      case BridgeEffectValue_Colour() when colour != null:
        return colour(_that.field0);
      case BridgeEffectValue_Bool() when bool != null:
        return bool(_that.field0);
      case BridgeEffectValue_Choice() when choice != null:
        return choice(_that.field0);
      case BridgeEffectValue_Seed() when seed != null:
        return seed(_that.field0);
      case BridgeEffectValue_File() when file != null:
        return file(_that.field0);
      case BridgeEffectValue_Layer() when layer != null:
        return layer(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class BridgeEffectValue_Float extends BridgeEffectValue {
  const BridgeEffectValue_Float(this.field0) : super._();

  @override
  final BridgeScalar field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_FloatCopyWith<BridgeEffectValue_Float> get copyWith =>
      _$BridgeEffectValue_FloatCopyWithImpl<BridgeEffectValue_Float>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Float &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.float(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_FloatCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_FloatCopyWith(BridgeEffectValue_Float value,
          $Res Function(BridgeEffectValue_Float) _then) =
      _$BridgeEffectValue_FloatCopyWithImpl;
  @useResult
  $Res call({BridgeScalar field0});

  $BridgeScalarCopyWith<$Res> get field0;
}

/// @nodoc
class _$BridgeEffectValue_FloatCopyWithImpl<$Res>
    implements $BridgeEffectValue_FloatCopyWith<$Res> {
  _$BridgeEffectValue_FloatCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Float _self;
  final $Res Function(BridgeEffectValue_Float) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Float(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeScalar,
    ));
  }

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $BridgeScalarCopyWith<$Res> get field0 {
    return $BridgeScalarCopyWith<$Res>(_self.field0, (value) {
      return _then(_self.copyWith(field0: value));
    });
  }
}

/// @nodoc

class BridgeEffectValue_Point extends BridgeEffectValue {
  const BridgeEffectValue_Point(this.field0) : super._();

  @override
  final BridgePoint field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_PointCopyWith<BridgeEffectValue_Point> get copyWith =>
      _$BridgeEffectValue_PointCopyWithImpl<BridgeEffectValue_Point>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Point &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.point(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_PointCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_PointCopyWith(BridgeEffectValue_Point value,
          $Res Function(BridgeEffectValue_Point) _then) =
      _$BridgeEffectValue_PointCopyWithImpl;
  @useResult
  $Res call({BridgePoint field0});
}

/// @nodoc
class _$BridgeEffectValue_PointCopyWithImpl<$Res>
    implements $BridgeEffectValue_PointCopyWith<$Res> {
  _$BridgeEffectValue_PointCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Point _self;
  final $Res Function(BridgeEffectValue_Point) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Point(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgePoint,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_Colour extends BridgeEffectValue {
  const BridgeEffectValue_Colour(this.field0) : super._();

  @override
  final BridgeColour field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_ColourCopyWith<BridgeEffectValue_Colour> get copyWith =>
      _$BridgeEffectValue_ColourCopyWithImpl<BridgeEffectValue_Colour>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Colour &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.colour(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_ColourCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_ColourCopyWith(BridgeEffectValue_Colour value,
          $Res Function(BridgeEffectValue_Colour) _then) =
      _$BridgeEffectValue_ColourCopyWithImpl;
  @useResult
  $Res call({BridgeColour field0});
}

/// @nodoc
class _$BridgeEffectValue_ColourCopyWithImpl<$Res>
    implements $BridgeEffectValue_ColourCopyWith<$Res> {
  _$BridgeEffectValue_ColourCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Colour _self;
  final $Res Function(BridgeEffectValue_Colour) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Colour(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeColour,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_Bool extends BridgeEffectValue {
  const BridgeEffectValue_Bool(this.field0) : super._();

  @override
  final bool field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_BoolCopyWith<BridgeEffectValue_Bool> get copyWith =>
      _$BridgeEffectValue_BoolCopyWithImpl<BridgeEffectValue_Bool>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Bool &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.bool(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_BoolCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_BoolCopyWith(BridgeEffectValue_Bool value,
          $Res Function(BridgeEffectValue_Bool) _then) =
      _$BridgeEffectValue_BoolCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$BridgeEffectValue_BoolCopyWithImpl<$Res>
    implements $BridgeEffectValue_BoolCopyWith<$Res> {
  _$BridgeEffectValue_BoolCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Bool _self;
  final $Res Function(BridgeEffectValue_Bool) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Bool(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_Choice extends BridgeEffectValue {
  const BridgeEffectValue_Choice(this.field0) : super._();

  @override
  final int field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_ChoiceCopyWith<BridgeEffectValue_Choice> get copyWith =>
      _$BridgeEffectValue_ChoiceCopyWithImpl<BridgeEffectValue_Choice>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Choice &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.choice(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_ChoiceCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_ChoiceCopyWith(BridgeEffectValue_Choice value,
          $Res Function(BridgeEffectValue_Choice) _then) =
      _$BridgeEffectValue_ChoiceCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$BridgeEffectValue_ChoiceCopyWithImpl<$Res>
    implements $BridgeEffectValue_ChoiceCopyWith<$Res> {
  _$BridgeEffectValue_ChoiceCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Choice _self;
  final $Res Function(BridgeEffectValue_Choice) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Choice(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_Seed extends BridgeEffectValue {
  const BridgeEffectValue_Seed(this.field0) : super._();

  @override
  final int field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_SeedCopyWith<BridgeEffectValue_Seed> get copyWith =>
      _$BridgeEffectValue_SeedCopyWithImpl<BridgeEffectValue_Seed>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Seed &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.seed(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_SeedCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_SeedCopyWith(BridgeEffectValue_Seed value,
          $Res Function(BridgeEffectValue_Seed) _then) =
      _$BridgeEffectValue_SeedCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$BridgeEffectValue_SeedCopyWithImpl<$Res>
    implements $BridgeEffectValue_SeedCopyWith<$Res> {
  _$BridgeEffectValue_SeedCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Seed _self;
  final $Res Function(BridgeEffectValue_Seed) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_Seed(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_File extends BridgeEffectValue {
  const BridgeEffectValue_File(this.field0) : super._();

  @override
  final BridgeFileParam field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_FileCopyWith<BridgeEffectValue_File> get copyWith =>
      _$BridgeEffectValue_FileCopyWithImpl<BridgeEffectValue_File>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_File &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.file(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_FileCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_FileCopyWith(BridgeEffectValue_File value,
          $Res Function(BridgeEffectValue_File) _then) =
      _$BridgeEffectValue_FileCopyWithImpl;
  @useResult
  $Res call({BridgeFileParam field0});
}

/// @nodoc
class _$BridgeEffectValue_FileCopyWithImpl<$Res>
    implements $BridgeEffectValue_FileCopyWith<$Res> {
  _$BridgeEffectValue_FileCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_File _self;
  final $Res Function(BridgeEffectValue_File) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeEffectValue_File(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeFileParam,
    ));
  }
}

/// @nodoc

class BridgeEffectValue_Layer extends BridgeEffectValue {
  const BridgeEffectValue_Layer([this.field0]) : super._();

  @override
  final UuidValue? field0;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeEffectValue_LayerCopyWith<BridgeEffectValue_Layer> get copyWith =>
      _$BridgeEffectValue_LayerCopyWithImpl<BridgeEffectValue_Layer>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeEffectValue_Layer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeEffectValue.layer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeEffectValue_LayerCopyWith<$Res>
    implements $BridgeEffectValueCopyWith<$Res> {
  factory $BridgeEffectValue_LayerCopyWith(BridgeEffectValue_Layer value,
          $Res Function(BridgeEffectValue_Layer) _then) =
      _$BridgeEffectValue_LayerCopyWithImpl;
  @useResult
  $Res call({UuidValue? field0});
}

/// @nodoc
class _$BridgeEffectValue_LayerCopyWithImpl<$Res>
    implements $BridgeEffectValue_LayerCopyWith<$Res> {
  _$BridgeEffectValue_LayerCopyWithImpl(this._self, this._then);

  final BridgeEffectValue_Layer _self;
  final $Res Function(BridgeEffectValue_Layer) _then;

  /// Create a copy of BridgeEffectValue
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = freezed,
  }) {
    return _then(BridgeEffectValue_Layer(
      freezed == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as UuidValue?,
    ));
  }
}

/// @nodoc
mixin _$BridgeScalar {
  Object get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeScalar &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'BridgeScalar(field0: $field0)';
  }
}

/// @nodoc
class $BridgeScalarCopyWith<$Res> {
  $BridgeScalarCopyWith(BridgeScalar _, $Res Function(BridgeScalar) __);
}

/// Adds pattern-matching-related methods to [BridgeScalar].
extension BridgeScalarPatterns on BridgeScalar {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(BridgeScalar_Static value)? static_,
    TResult Function(BridgeScalar_Keyframed value)? keyframed,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static() when static_ != null:
        return static_(_that);
      case BridgeScalar_Keyframed() when keyframed != null:
        return keyframed(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(BridgeScalar_Static value) static_,
    required TResult Function(BridgeScalar_Keyframed value) keyframed,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static():
        return static_(_that);
      case BridgeScalar_Keyframed():
        return keyframed(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(BridgeScalar_Static value)? static_,
    TResult? Function(BridgeScalar_Keyframed value)? keyframed,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static() when static_ != null:
        return static_(_that);
      case BridgeScalar_Keyframed() when keyframed != null:
        return keyframed(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(double field0)? static_,
    TResult Function(List<BridgeKeyframe> field0)? keyframed,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static() when static_ != null:
        return static_(_that.field0);
      case BridgeScalar_Keyframed() when keyframed != null:
        return keyframed(_that.field0);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(double field0) static_,
    required TResult Function(List<BridgeKeyframe> field0) keyframed,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static():
        return static_(_that.field0);
      case BridgeScalar_Keyframed():
        return keyframed(_that.field0);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(double field0)? static_,
    TResult? Function(List<BridgeKeyframe> field0)? keyframed,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeScalar_Static() when static_ != null:
        return static_(_that.field0);
      case BridgeScalar_Keyframed() when keyframed != null:
        return keyframed(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class BridgeScalar_Static extends BridgeScalar {
  const BridgeScalar_Static(this.field0) : super._();

  @override
  final double field0;

  /// Create a copy of BridgeScalar
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeScalar_StaticCopyWith<BridgeScalar_Static> get copyWith =>
      _$BridgeScalar_StaticCopyWithImpl<BridgeScalar_Static>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeScalar_Static &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeScalar.static_(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeScalar_StaticCopyWith<$Res>
    implements $BridgeScalarCopyWith<$Res> {
  factory $BridgeScalar_StaticCopyWith(
          BridgeScalar_Static value, $Res Function(BridgeScalar_Static) _then) =
      _$BridgeScalar_StaticCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$BridgeScalar_StaticCopyWithImpl<$Res>
    implements $BridgeScalar_StaticCopyWith<$Res> {
  _$BridgeScalar_StaticCopyWithImpl(this._self, this._then);

  final BridgeScalar_Static _self;
  final $Res Function(BridgeScalar_Static) _then;

  /// Create a copy of BridgeScalar
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeScalar_Static(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class BridgeScalar_Keyframed extends BridgeScalar {
  const BridgeScalar_Keyframed(final List<BridgeKeyframe> field0)
      : _field0 = field0,
        super._();

  final List<BridgeKeyframe> _field0;
  @override
  List<BridgeKeyframe> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of BridgeScalar
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeScalar_KeyframedCopyWith<BridgeScalar_Keyframed> get copyWith =>
      _$BridgeScalar_KeyframedCopyWithImpl<BridgeScalar_Keyframed>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeScalar_Keyframed &&
            const DeepCollectionEquality().equals(other._field0, _field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_field0));

  @override
  String toString() {
    return 'BridgeScalar.keyframed(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeScalar_KeyframedCopyWith<$Res>
    implements $BridgeScalarCopyWith<$Res> {
  factory $BridgeScalar_KeyframedCopyWith(BridgeScalar_Keyframed value,
          $Res Function(BridgeScalar_Keyframed) _then) =
      _$BridgeScalar_KeyframedCopyWithImpl;
  @useResult
  $Res call({List<BridgeKeyframe> field0});
}

/// @nodoc
class _$BridgeScalar_KeyframedCopyWithImpl<$Res>
    implements $BridgeScalar_KeyframedCopyWith<$Res> {
  _$BridgeScalar_KeyframedCopyWithImpl(this._self, this._then);

  final BridgeScalar_Keyframed _self;
  final $Res Function(BridgeScalar_Keyframed) _then;

  /// Create a copy of BridgeScalar
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeScalar_Keyframed(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<BridgeKeyframe>,
    ));
  }
}

/// @nodoc
mixin _$BridgeSideInterp {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is BridgeSideInterp);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'BridgeSideInterp()';
  }
}

/// @nodoc
class $BridgeSideInterpCopyWith<$Res> {
  $BridgeSideInterpCopyWith(
      BridgeSideInterp _, $Res Function(BridgeSideInterp) __);
}

/// Adds pattern-matching-related methods to [BridgeSideInterp].
extension BridgeSideInterpPatterns on BridgeSideInterp {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(BridgeSideInterp_Hold value)? hold,
    TResult Function(BridgeSideInterp_Linear value)? linear,
    TResult Function(BridgeSideInterp_Bezier value)? bezier,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold() when hold != null:
        return hold(_that);
      case BridgeSideInterp_Linear() when linear != null:
        return linear(_that);
      case BridgeSideInterp_Bezier() when bezier != null:
        return bezier(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(BridgeSideInterp_Hold value) hold,
    required TResult Function(BridgeSideInterp_Linear value) linear,
    required TResult Function(BridgeSideInterp_Bezier value) bezier,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold():
        return hold(_that);
      case BridgeSideInterp_Linear():
        return linear(_that);
      case BridgeSideInterp_Bezier():
        return bezier(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(BridgeSideInterp_Hold value)? hold,
    TResult? Function(BridgeSideInterp_Linear value)? linear,
    TResult? Function(BridgeSideInterp_Bezier value)? bezier,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold() when hold != null:
        return hold(_that);
      case BridgeSideInterp_Linear() when linear != null:
        return linear(_that);
      case BridgeSideInterp_Bezier() when bezier != null:
        return bezier(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function()? hold,
    TResult Function()? linear,
    TResult Function(BridgeBezierSide field0)? bezier,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold() when hold != null:
        return hold();
      case BridgeSideInterp_Linear() when linear != null:
        return linear();
      case BridgeSideInterp_Bezier() when bezier != null:
        return bezier(_that.field0);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function() hold,
    required TResult Function() linear,
    required TResult Function(BridgeBezierSide field0) bezier,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold():
        return hold();
      case BridgeSideInterp_Linear():
        return linear();
      case BridgeSideInterp_Bezier():
        return bezier(_that.field0);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function()? hold,
    TResult? Function()? linear,
    TResult? Function(BridgeBezierSide field0)? bezier,
  }) {
    final _that = this;
    switch (_that) {
      case BridgeSideInterp_Hold() when hold != null:
        return hold();
      case BridgeSideInterp_Linear() when linear != null:
        return linear();
      case BridgeSideInterp_Bezier() when bezier != null:
        return bezier(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class BridgeSideInterp_Hold extends BridgeSideInterp {
  const BridgeSideInterp_Hold() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is BridgeSideInterp_Hold);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'BridgeSideInterp.hold()';
  }
}

/// @nodoc

class BridgeSideInterp_Linear extends BridgeSideInterp {
  const BridgeSideInterp_Linear() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is BridgeSideInterp_Linear);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'BridgeSideInterp.linear()';
  }
}

/// @nodoc

class BridgeSideInterp_Bezier extends BridgeSideInterp {
  const BridgeSideInterp_Bezier(this.field0) : super._();

  final BridgeBezierSide field0;

  /// Create a copy of BridgeSideInterp
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $BridgeSideInterp_BezierCopyWith<BridgeSideInterp_Bezier> get copyWith =>
      _$BridgeSideInterp_BezierCopyWithImpl<BridgeSideInterp_Bezier>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is BridgeSideInterp_Bezier &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'BridgeSideInterp.bezier(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $BridgeSideInterp_BezierCopyWith<$Res>
    implements $BridgeSideInterpCopyWith<$Res> {
  factory $BridgeSideInterp_BezierCopyWith(BridgeSideInterp_Bezier value,
          $Res Function(BridgeSideInterp_Bezier) _then) =
      _$BridgeSideInterp_BezierCopyWithImpl;
  @useResult
  $Res call({BridgeBezierSide field0});
}

/// @nodoc
class _$BridgeSideInterp_BezierCopyWithImpl<$Res>
    implements $BridgeSideInterp_BezierCopyWith<$Res> {
  _$BridgeSideInterp_BezierCopyWithImpl(this._self, this._then);

  final BridgeSideInterp_Bezier _self;
  final $Res Function(BridgeSideInterp_Bezier) _then;

  /// Create a copy of BridgeSideInterp
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(BridgeSideInterp_Bezier(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeBezierSide,
    ));
  }
}

// dart format on
