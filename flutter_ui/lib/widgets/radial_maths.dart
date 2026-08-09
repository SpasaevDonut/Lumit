// The geometry of a Blender-style radial menu (K-319).
//
// In plain terms: a radial (or "pie") menu puts its choices in a ring around
// where the pointer already is, so every choice is the same short distance
// away and — the part that matters — always in the *same direction*. After a
// few uses the hand learns "delete is down-left" and stops reading the menu at
// all. That is what a list of items in a dropdown can never offer: a list's
// third entry moves the moment the list grows.
//
// Two rules follow from that, and they are the whole of this file:
//
//   - A slice is chosen by ANGLE alone, not by whether the pointer is inside
//     any drawn shape. Flick in a direction and the choice is made, however
//     far the pointer travelled — so the gesture can be as fast as the hand.
//   - There is a dead zone in the middle. Inside it nothing is selected, so
//     opening the menu and releasing without moving cancels rather than
//     picking whatever happened to be under the cursor.
//
// Kept free of widgets so it can be tested as arithmetic.

import 'dart:math' as math;

/// How far the pointer must leave the centre before any slice is chosen.
/// Below this the menu is open but nothing is picked (Blender's own idea).
const double radialDeadZone = 26;

/// The ring's radius: where the labels sit.
const double radialRadius = 96;

/// The angle, in radians clockwise from straight up, at which slice [index] of
/// [count] sits — the centre of its wedge.
///
/// Straight up is the first slice, because "up" is the direction a hand
/// reaches for first and the one the eye finds without looking.
double radialSliceAngle(int index, int count) {
  if (count <= 0) return 0;
  return index * 2 * math.pi / count;
}

/// Where slice [index] of [count] is drawn, relative to the menu's centre.
///
/// Screen coordinates: y grows downward, so "up" is a negative dy.
({double dx, double dy}) radialSliceOffset(int index, int count,
    {double radius = radialRadius}) {
  final angle = radialSliceAngle(index, count);
  return (dx: radius * math.sin(angle), dy: -radius * math.cos(angle));
}

/// Which slice a pointer at ([dx], [dy]) from the centre is choosing, or null
/// inside the dead zone (and for an empty menu).
///
/// By angle only: the distance beyond the dead zone does not matter, so a
/// confident flick lands the same choice as a careful one.
int? radialSliceAt(double dx, double dy, int count,
    {double deadZone = radialDeadZone}) {
  if (count <= 0) return null;
  if (dx * dx + dy * dy < deadZone * deadZone) return null;
  // atan2 measured from straight up, clockwise, wrapped into [0, 2pi).
  var angle = math.atan2(dx, -dy);
  if (angle < 0) angle += 2 * math.pi;
  final slice = 2 * math.pi / count;
  // Each wedge is centred on its angle, so the boundary sits half a wedge
  // either side — hence the half-slice shift before flooring.
  final index = ((angle + slice / 2) / slice).floor() % count;
  return index;
}
