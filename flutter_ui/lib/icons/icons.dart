// Lumit's icons: the Iconoir set (MIT), ported one-for-one from
// crates/lumit-ui/src/icons.rs (K-085). Same rules as the Rust side: every
// glyph is a real icon from one consistent set, emoji are banned, icons take
// the text colour of their state, and the motion-blur mark is drawn from the
// owner's artwork rather than looked up (Iconoir has no motion-blur glyph).

import 'package:flutter/widgets.dart';
import 'package:iconoir_flutter/regular/align_left.dart' as ic;
import 'package:iconoir_flutter/regular/circle.dart' as ic;
import 'package:iconoir_flutter/regular/color_picker.dart' as ic;
import 'package:iconoir_flutter/regular/cube.dart' as ic;
import 'package:iconoir_flutter/regular/cursor_pointer.dart' as ic;
import 'package:iconoir_flutter/regular/design_nib.dart' as ic;
import 'package:iconoir_flutter/regular/drag_hand_gesture.dart' as ic;
import 'package:iconoir_flutter/regular/ease_curve_control_points.dart' as ic;
import 'package:iconoir_flutter/regular/eye.dart' as ic;
import 'package:iconoir_flutter/regular/eye_closed.dart' as ic;
import 'package:iconoir_flutter/regular/fill_color.dart' as ic;
import 'package:iconoir_flutter/regular/flare.dart' as ic;
import 'package:iconoir_flutter/regular/folder.dart' as ic;
import 'package:iconoir_flutter/regular/frame.dart' as ic;
import 'package:iconoir_flutter/regular/fx.dart' as ic;
import 'package:iconoir_flutter/regular/keyframe.dart' as ic;
import 'package:iconoir_flutter/regular/keyframe_plus.dart' as ic;
import 'package:iconoir_flutter/regular/label.dart' as ic;
import 'package:iconoir_flutter/regular/link.dart' as ic;
import 'package:iconoir_flutter/regular/link_xmark.dart' as ic;
import 'package:iconoir_flutter/regular/lock.dart' as ic;
import 'package:iconoir_flutter/regular/lock_slash.dart' as ic;
import 'package:iconoir_flutter/regular/magnet.dart' as ic;
import 'package:iconoir_flutter/regular/media_video.dart' as ic;
import 'package:iconoir_flutter/regular/movie.dart' as ic;
import 'package:iconoir_flutter/regular/nav_arrow_down.dart' as ic;
import 'package:iconoir_flutter/regular/nav_arrow_left.dart' as ic;
import 'package:iconoir_flutter/regular/nav_arrow_right.dart' as ic;
import 'package:iconoir_flutter/regular/network.dart' as ic;
import 'package:iconoir_flutter/regular/pause.dart' as ic;
import 'package:iconoir_flutter/regular/play.dart' as ic;
import 'package:iconoir_flutter/regular/refresh_double.dart' as ic;
import 'package:iconoir_flutter/regular/sound_high.dart' as ic;
import 'package:iconoir_flutter/regular/sound_off.dart' as ic;
import 'package:iconoir_flutter/regular/square.dart' as ic;
import 'package:iconoir_flutter/regular/star.dart' as ic;
import 'package:iconoir_flutter/regular/text.dart' as ic;
import 'package:iconoir_flutter/regular/timer.dart' as ic;
import 'package:iconoir_flutter/regular/video_camera.dart' as ic;
import 'package:iconoir_flutter/regular/view_columns_3.dart' as ic;
import 'package:iconoir_flutter/regular/wind.dart' as ic;
import 'package:iconoir_flutter/solid/keyframe.dart' as ics;

/// One icon — the same 44 variants as the Rust `Icon` enum, same names.
enum LumitIcon {
  pointer,
  move,
  rectangle,
  ellipse,
  star,
  pen,
  play,
  pause,
  lock,
  unlock,
  link,
  unlink,
  folder,
  film,
  graphCurve,
  timelineBars,
  nodes,
  footage,
  comp,
  solid,
  sequence,
  text,
  camera,
  eye,
  eyeClosed,
  audio,
  mute,
  prevKeyframe,
  nextKeyframe,
  keyframeAdd,
  keyframe,
  keyframeFilled,
  stopwatch,
  twirlClosed,
  twirlOpen,
  collapse,
  flow,
  cube3d,
  magnet,
  eyedropper,
  reset,
  motionBlur,
  fx,

  /// The label-colour column's tag (docs/07 §4.2).
  label,

  /// Shy: hide-from-the-layer-list, and the master filter that honours it.
  /// Drawn, not looked up (Iconoir has no peek): lines standing above the
  /// list's baseline.
  shy,

  /// The shy mark's hidden state: the lines ducked down to a stub over the
  /// baseline — this layer is (or these layers are) hidden from the list.
  shyHidden,

  /// A filled circle — the solo switch's on state; [ellipse] is its off.
  circleFilled,

  /// A Null layer: an empty square crossed corner to corner, the mark After
  /// Effects puts on a null. Drawn, not looked up (Iconoir has no crosshair),
  /// and deliberately unlike [rectangle] and [solid], which are plain squares.
  nullLayer,
}

/// Build `icon` at `size` in `color`. The motion-blur mark is drawn, not
/// looked up, exactly as in the Rust frontend.
Widget lumitIcon(LumitIcon icon, {required double size, required Color color}) {
  final painter = switch (icon) {
    LumitIcon.motionBlur => MotionBlurPainter(color) as CustomPainter,
    LumitIcon.shy => ShyPainter(color, hidden: false),
    LumitIcon.shyHidden => ShyPainter(color, hidden: true),
    LumitIcon.circleFilled => CircleFillPainter(color),
    LumitIcon.nullLayer => NullLayerPainter(color),
    _ => null,
  };
  if (painter != null) {
    return CustomPaint(size: Size.square(size), painter: painter);
  }
  final w = _glyph(icon, color);
  return SizedBox(width: size, height: size, child: w);
}

Widget _glyph(LumitIcon icon, Color color) => switch (icon) {
      LumitIcon.pointer => ic.CursorPointer(color: color),
      LumitIcon.move => ic.DragHandGesture(color: color),
      LumitIcon.rectangle => ic.Square(color: color),
      LumitIcon.ellipse => ic.Circle(color: color),
      LumitIcon.star => ic.Star(color: color),
      LumitIcon.pen => ic.DesignNib(color: color),
      LumitIcon.play => ic.Play(color: color),
      LumitIcon.pause => ic.Pause(color: color),
      LumitIcon.lock => ic.Lock(color: color),
      LumitIcon.unlock => ic.LockSlash(color: color),
      LumitIcon.link => ic.Link(color: color),
      LumitIcon.unlink => ic.LinkXmark(color: color),
      LumitIcon.folder => ic.Folder(color: color),
      LumitIcon.film => ic.Movie(color: color),
      LumitIcon.graphCurve => ic.EaseCurveControlPoints(color: color),
      LumitIcon.timelineBars => ic.AlignLeft(color: color),
      LumitIcon.nodes => ic.Network(color: color),
      LumitIcon.footage => ic.MediaVideo(color: color),
      LumitIcon.comp => ic.Frame(color: color),
      LumitIcon.solid => ic.FillColor(color: color),
      LumitIcon.sequence => ic.ViewColumns3(color: color),
      LumitIcon.text => ic.Text(color: color),
      LumitIcon.camera => ic.VideoCamera(color: color),
      LumitIcon.eye => ic.Eye(color: color),
      LumitIcon.eyeClosed => ic.EyeClosed(color: color),
      LumitIcon.audio => ic.SoundHigh(color: color),
      LumitIcon.mute => ic.SoundOff(color: color),
      LumitIcon.prevKeyframe => ic.NavArrowLeft(color: color),
      LumitIcon.nextKeyframe => ic.NavArrowRight(color: color),
      LumitIcon.keyframeAdd => ic.KeyframePlus(color: color),
      LumitIcon.keyframe => ic.Keyframe(color: color),
      LumitIcon.keyframeFilled => ics.KeyframeSolid(color: color),
      LumitIcon.stopwatch => ic.Timer(color: color),
      LumitIcon.twirlClosed => ic.NavArrowRight(color: color),
      LumitIcon.twirlOpen => ic.NavArrowDown(color: color),
      LumitIcon.collapse => ic.Flare(color: color),
      LumitIcon.flow => ic.Wind(color: color),
      LumitIcon.cube3d => ic.Cube(color: color),
      LumitIcon.magnet => ic.Magnet(color: color),
      LumitIcon.eyedropper => ic.ColorPicker(color: color),
      LumitIcon.reset => ic.RefreshDouble(color: color),
      LumitIcon.motionBlur => const SizedBox.shrink(), // handled above
      LumitIcon.fx => ic.Fx(color: color),
      LumitIcon.label => ic.Label(color: color),
      // Painter-drawn, handled above.
      LumitIcon.shy ||
      LumitIcon.shyHidden ||
      LumitIcon.circleFilled ||
      LumitIcon.nullLayer =>
        const SizedBox.shrink(),
    };

/// The motion-blur mark: a ring with speed streaks running into it, from the
/// owner's artwork on a 24×24 grid — coordinates identical to the Rust
/// `draw_motion_blur` so the two frontends paint the same mark.
class MotionBlurPainter extends CustomPainter {
  final Color color;
  const MotionBlurPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24.0;
    final origin = Offset(
      size.width / 2 - 12.0 * s,
      size.height / 2 - 12.0 * s,
    );
    Offset at(double x, double y) => origin + Offset(x * s, y * s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.butt;
    // The ring: a 2-unit stroke on a 4-unit radius, centred at (17, 12).
    canvas.drawCircle(at(17, 12), 4.0 * s, paint);
    // The streaks; two rows broken by a shorter dash further left, which is
    // what makes the mark read as motion rather than a plain arrow.
    const rows = [
      (4.0, 14.0, 8.0),
      (10.0, 13.0, 12.0),
      (8.0, 14.0, 16.0),
      (3.0, 7.0, 12.0),
      (4.0, 5.0, 16.0),
    ];
    for (final (x1, x2, y) in rows) {
      canvas.drawLine(at(x1, y), at(x2, y), paint);
    }
  }

  @override
  bool shouldRepaint(MotionBlurPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The shy mark, on a 24×24 grid. Not hidden: two lines standing over the
/// list's long baseline. Hidden: just a stub ducked close over the baseline —
/// the layers have dropped out of the list.
class ShyPainter extends CustomPainter {
  final Color color;
  final bool hidden;
  const ShyPainter(this.color, {required this.hidden});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24.0;
    Offset at(double x, double y) => Offset(x * s, y * s);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.round;
    // The baseline: the layer list itself.
    canvas.drawLine(at(4, 19), at(20, 19), paint);
    if (hidden) {
      canvas.drawLine(at(9, 13), at(15, 13), paint);
    } else {
      canvas.drawLine(at(6, 12), at(18, 12), paint);
      canvas.drawLine(at(9, 5), at(15, 5), paint);
    }
  }

  @override
  bool shouldRepaint(ShyPainter old) =>
      old.color != color || old.hidden != hidden;
}

/// A filled circle: the solo switch's on state.
class CircleFillPainter extends CustomPainter {
  final Color color;
  const CircleFillPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide * 0.32,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(CircleFillPainter old) => old.color != color;
}

/// The Null layer's mark, on the same 24×24 grid as the other drawn marks: an
/// empty square crossed corner to corner. A Null has no pixels, so the square
/// stands for the transform box and the cross says there is nothing in it.
class NullLayerPainter extends CustomPainter {
  final Color color;
  const NullLayerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24.0;
    Offset at(double x, double y) => Offset(x * s, y * s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt;
    canvas.drawRect(Rect.fromPoints(at(4, 4), at(20, 20)), paint);
    canvas.drawLine(at(4, 4), at(20, 20), paint);
    canvas.drawLine(at(20, 4), at(4, 20), paint);
  }

  @override
  bool shouldRepaint(NullLayerPainter old) => old.color != color;
}
