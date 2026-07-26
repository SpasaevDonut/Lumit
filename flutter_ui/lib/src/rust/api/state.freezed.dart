// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$WorkerResponse {
  Object get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'WorkerResponse(field0: $field0)';
  }
}

/// @nodoc
class $WorkerResponseCopyWith<$Res> {
  $WorkerResponseCopyWith(WorkerResponse _, $Res Function(WorkerResponse) __);
}

/// Adds pattern-matching-related methods to [WorkerResponse].
extension WorkerResponsePatterns on WorkerResponse {
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
    TResult Function(WorkerResponse_RenderedDMABuf value)? renderedDmaBuf,
    TResult Function(WorkerResponse_RenderedSharedTexture value)?
        renderedSharedTexture,
    TResult Function(WorkerResponse_RenderedPixels value)? renderedPixels,
    TResult Function(WorkerResponse_Scope value)? scope,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that);
      case WorkerResponse_RenderedSharedTexture()
          when renderedSharedTexture != null:
        return renderedSharedTexture(_that);
      case WorkerResponse_RenderedPixels() when renderedPixels != null:
        return renderedPixels(_that);
      case WorkerResponse_Scope() when scope != null:
        return scope(_that);
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
    required TResult Function(WorkerResponse_RenderedDMABuf value)
        renderedDmaBuf,
    required TResult Function(WorkerResponse_RenderedSharedTexture value)
        renderedSharedTexture,
    required TResult Function(WorkerResponse_RenderedPixels value)
        renderedPixels,
    required TResult Function(WorkerResponse_Scope value) scope,
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf():
        return renderedDmaBuf(_that);
      case WorkerResponse_RenderedSharedTexture():
        return renderedSharedTexture(_that);
      case WorkerResponse_RenderedPixels():
        return renderedPixels(_that);
      case WorkerResponse_Scope():
        return scope(_that);
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
    TResult? Function(WorkerResponse_RenderedDMABuf value)? renderedDmaBuf,
    TResult? Function(WorkerResponse_RenderedSharedTexture value)?
        renderedSharedTexture,
    TResult? Function(WorkerResponse_RenderedPixels value)? renderedPixels,
    TResult? Function(WorkerResponse_Scope value)? scope,
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that);
      case WorkerResponse_RenderedSharedTexture()
          when renderedSharedTexture != null:
        return renderedSharedTexture(_that);
      case WorkerResponse_RenderedPixels() when renderedPixels != null:
        return renderedPixels(_that);
      case WorkerResponse_Scope() when scope != null:
        return scope(_that);
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
    TResult Function(BridgeSharedFrameInfoLinux field0)? renderedDmaBuf,
    TResult Function(BridgeSharedFrameInfo field0)? renderedSharedTexture,
    TResult Function(BridgeRenderedFrame field0)? renderedPixels,
    TResult Function(BridgeScopeTrace field0)? scope,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that.field0);
      case WorkerResponse_RenderedSharedTexture()
          when renderedSharedTexture != null:
        return renderedSharedTexture(_that.field0);
      case WorkerResponse_RenderedPixels() when renderedPixels != null:
        return renderedPixels(_that.field0);
      case WorkerResponse_Scope() when scope != null:
        return scope(_that.field0);
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
    required TResult Function(BridgeSharedFrameInfoLinux field0) renderedDmaBuf,
    required TResult Function(BridgeSharedFrameInfo field0)
        renderedSharedTexture,
    required TResult Function(BridgeRenderedFrame field0) renderedPixels,
    required TResult Function(BridgeScopeTrace field0) scope,
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf():
        return renderedDmaBuf(_that.field0);
      case WorkerResponse_RenderedSharedTexture():
        return renderedSharedTexture(_that.field0);
      case WorkerResponse_RenderedPixels():
        return renderedPixels(_that.field0);
      case WorkerResponse_Scope():
        return scope(_that.field0);
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
    TResult? Function(BridgeSharedFrameInfoLinux field0)? renderedDmaBuf,
    TResult? Function(BridgeSharedFrameInfo field0)? renderedSharedTexture,
    TResult? Function(BridgeRenderedFrame field0)? renderedPixels,
    TResult? Function(BridgeScopeTrace field0)? scope,
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that.field0);
      case WorkerResponse_RenderedSharedTexture()
          when renderedSharedTexture != null:
        return renderedSharedTexture(_that.field0);
      case WorkerResponse_RenderedPixels() when renderedPixels != null:
        return renderedPixels(_that.field0);
      case WorkerResponse_Scope() when scope != null:
        return scope(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class WorkerResponse_RenderedDMABuf extends WorkerResponse {
  const WorkerResponse_RenderedDMABuf(this.field0) : super._();

  @override
  final BridgeSharedFrameInfoLinux field0;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WorkerResponse_RenderedDMABufCopyWith<WorkerResponse_RenderedDMABuf>
      get copyWith => _$WorkerResponse_RenderedDMABufCopyWithImpl<
          WorkerResponse_RenderedDMABuf>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse_RenderedDMABuf &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'WorkerResponse.renderedDmaBuf(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $WorkerResponse_RenderedDMABufCopyWith<$Res>
    implements $WorkerResponseCopyWith<$Res> {
  factory $WorkerResponse_RenderedDMABufCopyWith(
          WorkerResponse_RenderedDMABuf value,
          $Res Function(WorkerResponse_RenderedDMABuf) _then) =
      _$WorkerResponse_RenderedDMABufCopyWithImpl;
  @useResult
  $Res call({BridgeSharedFrameInfoLinux field0});
}

/// @nodoc
class _$WorkerResponse_RenderedDMABufCopyWithImpl<$Res>
    implements $WorkerResponse_RenderedDMABufCopyWith<$Res> {
  _$WorkerResponse_RenderedDMABufCopyWithImpl(this._self, this._then);

  final WorkerResponse_RenderedDMABuf _self;
  final $Res Function(WorkerResponse_RenderedDMABuf) _then;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(WorkerResponse_RenderedDMABuf(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeSharedFrameInfoLinux,
    ));
  }
}

/// @nodoc

class WorkerResponse_RenderedSharedTexture extends WorkerResponse {
  const WorkerResponse_RenderedSharedTexture(this.field0) : super._();

  @override
  final BridgeSharedFrameInfo field0;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WorkerResponse_RenderedSharedTextureCopyWith<
          WorkerResponse_RenderedSharedTexture>
      get copyWith => _$WorkerResponse_RenderedSharedTextureCopyWithImpl<
          WorkerResponse_RenderedSharedTexture>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse_RenderedSharedTexture &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'WorkerResponse.renderedSharedTexture(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $WorkerResponse_RenderedSharedTextureCopyWith<$Res>
    implements $WorkerResponseCopyWith<$Res> {
  factory $WorkerResponse_RenderedSharedTextureCopyWith(
          WorkerResponse_RenderedSharedTexture value,
          $Res Function(WorkerResponse_RenderedSharedTexture) _then) =
      _$WorkerResponse_RenderedSharedTextureCopyWithImpl;
  @useResult
  $Res call({BridgeSharedFrameInfo field0});
}

/// @nodoc
class _$WorkerResponse_RenderedSharedTextureCopyWithImpl<$Res>
    implements $WorkerResponse_RenderedSharedTextureCopyWith<$Res> {
  _$WorkerResponse_RenderedSharedTextureCopyWithImpl(this._self, this._then);

  final WorkerResponse_RenderedSharedTexture _self;
  final $Res Function(WorkerResponse_RenderedSharedTexture) _then;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(WorkerResponse_RenderedSharedTexture(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeSharedFrameInfo,
    ));
  }
}

/// @nodoc

class WorkerResponse_RenderedPixels extends WorkerResponse {
  const WorkerResponse_RenderedPixels(this.field0) : super._();

  @override
  final BridgeRenderedFrame field0;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WorkerResponse_RenderedPixelsCopyWith<WorkerResponse_RenderedPixels>
      get copyWith => _$WorkerResponse_RenderedPixelsCopyWithImpl<
          WorkerResponse_RenderedPixels>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse_RenderedPixels &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'WorkerResponse.renderedPixels(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $WorkerResponse_RenderedPixelsCopyWith<$Res>
    implements $WorkerResponseCopyWith<$Res> {
  factory $WorkerResponse_RenderedPixelsCopyWith(
          WorkerResponse_RenderedPixels value,
          $Res Function(WorkerResponse_RenderedPixels) _then) =
      _$WorkerResponse_RenderedPixelsCopyWithImpl;
  @useResult
  $Res call({BridgeRenderedFrame field0});
}

/// @nodoc
class _$WorkerResponse_RenderedPixelsCopyWithImpl<$Res>
    implements $WorkerResponse_RenderedPixelsCopyWith<$Res> {
  _$WorkerResponse_RenderedPixelsCopyWithImpl(this._self, this._then);

  final WorkerResponse_RenderedPixels _self;
  final $Res Function(WorkerResponse_RenderedPixels) _then;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(WorkerResponse_RenderedPixels(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeRenderedFrame,
    ));
  }
}

/// @nodoc

class WorkerResponse_Scope extends WorkerResponse {
  const WorkerResponse_Scope(this.field0) : super._();

  @override
  final BridgeScopeTrace field0;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WorkerResponse_ScopeCopyWith<WorkerResponse_Scope> get copyWith =>
      _$WorkerResponse_ScopeCopyWithImpl<WorkerResponse_Scope>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse_Scope &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'WorkerResponse.scope(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $WorkerResponse_ScopeCopyWith<$Res>
    implements $WorkerResponseCopyWith<$Res> {
  factory $WorkerResponse_ScopeCopyWith(WorkerResponse_Scope value,
          $Res Function(WorkerResponse_Scope) _then) =
      _$WorkerResponse_ScopeCopyWithImpl;
  @useResult
  $Res call({BridgeScopeTrace field0});
}

/// @nodoc
class _$WorkerResponse_ScopeCopyWithImpl<$Res>
    implements $WorkerResponse_ScopeCopyWith<$Res> {
  _$WorkerResponse_ScopeCopyWithImpl(this._self, this._then);

  final WorkerResponse_Scope _self;
  final $Res Function(WorkerResponse_Scope) _then;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(WorkerResponse_Scope(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeScopeTrace,
    ));
  }
}

// dart format on
