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
  BridgeSharedFrameInfoLinux get field0;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WorkerResponseCopyWith<WorkerResponse> get copyWith =>
      _$WorkerResponseCopyWithImpl<WorkerResponse>(
          this as WorkerResponse, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WorkerResponse &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'WorkerResponse(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $WorkerResponseCopyWith<$Res> {
  factory $WorkerResponseCopyWith(
          WorkerResponse value, $Res Function(WorkerResponse) _then) =
      _$WorkerResponseCopyWithImpl;
  @useResult
  $Res call({BridgeSharedFrameInfoLinux field0});
}

/// @nodoc
class _$WorkerResponseCopyWithImpl<$Res>
    implements $WorkerResponseCopyWith<$Res> {
  _$WorkerResponseCopyWithImpl(this._self, this._then);

  final WorkerResponse _self;
  final $Res Function(WorkerResponse) _then;

  /// Create a copy of WorkerResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? field0 = null,
  }) {
    return _then(_self.copyWith(
      field0: null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BridgeSharedFrameInfoLinux,
    ));
  }
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
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that);
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
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf():
        return renderedDmaBuf(_that);
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
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that);
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
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that.field0);
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
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf():
        return renderedDmaBuf(_that.field0);
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
  }) {
    final _that = this;
    switch (_that) {
      case WorkerResponse_RenderedDMABuf() when renderedDmaBuf != null:
        return renderedDmaBuf(_that.field0);
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
  @override
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
  @override
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
  @override
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

// dart format on
