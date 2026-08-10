---
title: Expressions
description: Drive one property from another with a small script.
sidebar:
  order: 16
---

:::caution[Not implemented yet]
Expressions are specified and partly built, but they are not ready to use.

The menu commands for it are listed and disabled, marked *(Not implemented)*, so you can see what is coming. Progress is tracked on [GitHub](https://github.com/luminalmvm/Lumit/issues).
:::

## What is planned

An **expression** is a small script on a property. It computes the property's value each
frame, and it can read other properties.

Expressions are for relationships a keyframe cannot express: a value that follows
another, wobbles, repeats, or reacts.

Until they land, use [parenting](/use/transform/) for one layer following another, and
[keyframes](/use/keyframes/) for everything else.

## Related

- [Keyframes](/use/keyframes/)
