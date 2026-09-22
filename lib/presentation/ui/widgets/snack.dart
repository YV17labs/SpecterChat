import 'package:flutter/material.dart';

/// One-line feedback at the bottom of the window. Does nothing once the
/// widget that asked for it is gone — every caller is after an await.
void showSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
