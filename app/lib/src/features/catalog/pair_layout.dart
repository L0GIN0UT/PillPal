import 'package:flutter/widgets.dart';

/// From this text scale a pair of buttons or tiles of the add flow goes one
/// under the other (B2-README section 9.6). The pair is two columns of about
/// 140 px on a 320 px screen, which holds «Сканировать» up to about x1.2.
const double stackPairFromScale = 1.25;

/// Whether a pair of buttons has to be stacked at the current text scale.
bool stacksPair(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) >= stackPairFromScale;
